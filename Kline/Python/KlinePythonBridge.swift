//
//  KlinePythonBridge.swift
//  Kline
//
//  生产桥接层：Swift 业务 → 进程内 Python（复用 PythonEngineHost 的 PyRun 通道 runPyBridge）。
//
//  契约：
//  - 业务脚本随 App bundle 打包：Bundle.main/PyScripts/<script>.py；
//  - 调用方传 input 字典 → 以 JSON 写临时输入文件；包装脚本统一负责：读输入、
//    注入全局 kline_input、exec 业务脚本、捕获异常、把结果 JSON 落临时输出文件（Swift 读回）；
//  - 业务脚本须在全局作用域定义 dict 类型的 `kline_result`（如 {"ok": true, ...}）；
//    包装层校验：输出顶层 dict 且 ok==true 才算成功，原始 Data 原样返回（payload 由调用方解码）。
//
//  降级原则：
//  - 引擎未就绪（isReady==false）即失败返回，绝不触发引擎初始化；调用方自行决定
//    是否先显式后台调 ensureReady(_:)，失败走纯 Swift 降级路径；
//  - 绝不在主线程同步等待 Python（blockingCall 有 assert 兜底）。
//
//  两个版本轴：
//  - 业务脚本（PyScripts/）随 App bundle 发版更新；
//  - Python 引擎包（KlineEngine/Engine.app）独立发版，apiVersion 配对校验由宿主负责。
//

import Foundation

// MARK: - 错误

/// 桥接错误（自定义枚举；不复用调试域的全局 String: Error conform）
enum PyBridgeError: Error {
    case engineNotReady(String)   // 引擎未加载/状态非 installed
    case timeout                  // 等待超时
    case scriptError(String)      // 脚本报错（含输出文件缺失/ok=false）
}

// MARK: - 零拷贝批量通道（bin）

/// bin 调用结果：payload 为输出 JSON 顶层 dict（ok/results/audit/__bin_meta__ 等小元数据），
/// arrays 为 __bin_meta__ 各段从 .bin 文件解码出的双精度数组（键 = 脚本 __bin_out__ 的键）
struct PyBinResult {
    let payload: [String: Any]
    let arrays: [String: [Double]]
}

// MARK: - 桥接

final class KlinePythonBridge {

    static let shared = KlinePythonBridge()

    /// 串行队列：ensureReady 的加载决策在此排队（不占宿主 workQueue）
    private let bridgeQueue = DispatchQueue(label: "com.sunck.Kline.pybridge")
    private let fm = FileManager.default

    private init() {}

    // MARK: 就绪

    /// 引擎是否已加载（只读，绝不触发初始化）
    var isReady: Bool {
        PythonEngineHost.shared.isLoaded
    }

    /// 会话内一次性后台激活门闩（只在 bridgeQueue 上读写）
    private var ensureOnceTriggered = false

    /// 惰性激活：调用点（聚合/校准）发现引擎未就绪时后台触发一次 ensureReady。
    /// 会话内只尝试一次——就绪后 isReady=true 后续 call 直接生效；
    /// 失败（未安装等）本会话不再重试（降级矩阵语义：未安装 = Swift 现状；
    /// Engine.app 热装后重启 App 首次聚合即激活）。结果由 ensureReady 内部 DebugLogger 记录。
    func ensureOnce() {
        bridgeQueue.async {
            guard !self.ensureOnceTriggered else { return }
            self.ensureOnceTriggered = true
            self.ensureReady { _ in }
        }
    }

    /// R1 启动预热：ensureReady 成功后追加一次 tdx_eval 空转 bin 调用——
    /// 预热 PyRun 编译缓存、json/ctypes/array 模块与 bin 通道本身，
    /// 让首个用户触发的首帧求值直接进入稳态（无首调抖动：真机实测首调比稳态慢一个量级）。
    /// 全程后台异步，绝不阻塞主线程；失败静默（日志记录），不影响任何降级路径。
    /// 与 ensureOnce 共用会话门闩——先到者生效，另一方自动跳过。
    func warmUp() {
        bridgeQueue.async {
            guard !self.ensureOnceTriggered else { return }
            self.ensureOnceTriggered = true
            self.ensureReady { result in
                guard case .success = result else { return }
                DispatchQueue.global(qos: .utility).async { self.preheatTDXEval() }
            }
        }
    }

    /// tdx_eval 空转预热（后台线程；结果丢弃，只求「下一次调用进入稳态」）
    private func preheatTDXEval() {
        let bars: [Double] = [10.0, 10.5, 11.0]
        let seriesBin: [String: [Double]] = ["c": bars, "h": bars, "l": bars,
                                              "o": bars, "v": bars, "a": bars]
        let input: [String: Any] = [
            "__bin__": 1,
            "requests": [["stmts": [["n": "X", "o": 1, "e": ["t": "var", "n": "C"]]]]],
        ]
        let t0 = CFAbsoluteTimeGetCurrent()
        if case .success = blockingCallBin(script: "tdx_eval", input: input,
                                           seriesBin: seriesBin, seriesInto: "bars", timeout: 10) {
            DebugLogger.shared.log(String(
                format: "[PyBridge] tdx_eval 预热完成（%.0fms，编译缓存+bin 通道就绪）",
                (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }

    /// 后台确保引擎就绪（只能显式后台调用，绝不从首帧/启动链同步触发引擎初始化）：
    /// - 已加载 → 直接成功；
    /// - status == .installed → 调 loadEngine（成功或「引擎已加载」的竞态失败均算成功）；
    /// - 其余状态（未安装/版本不匹配/损坏）→ 失败返回，不尝试加载。
    /// 完成回调派发主线程；全程 DebugLogger 记录（含耗时）。
    func ensureReady(_ completion: @escaping (Result<Void, String>) -> Void) {
        bridgeQueue.async {
            let t0 = CFAbsoluteTimeGetCurrent()
            if PythonEngineHost.shared.isLoaded {
                DebugLogger.shared.log("[PyBridge] ensureReady：引擎已加载")
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            switch PythonEngineHost.shared.status() {
            case .installed:
                DebugLogger.shared.log("[PyBridge] ensureReady：引擎已安装未加载，触发 loadEngine…")
                PythonEngineHost.shared.loadEngine { r in
                    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    switch r {
                    case .success:
                        DebugLogger.shared.log(String(format: "[PyBridge] ensureReady：加载成功（%.0fms）", ms))
                        completion(.success(()))
                    case .failure(let e):
                        // 竞态兜底：另一路并发已把引擎加载完成，loadEngine 的「已加载」失败视为成功
                        if e.contains("引擎已加载") {
                            DebugLogger.shared.log(String(format: "[PyBridge] ensureReady：已加载（竞态兜底，%.0fms）", ms))
                            completion(.success(()))
                        } else {
                            DebugLogger.shared.log(String(format: "[PyBridge] ensureReady：加载失败（%.0fms）——%@", ms, e))
                            completion(.failure(e))
                        }
                    }
                }
            case .notInstalled:
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let msg = "引擎未安装（无内嵌引擎且未安装 Engine.app）"
                DebugLogger.shared.log("[PyBridge] ensureReady 失败（\(ms)ms）：\(msg)")
                DispatchQueue.main.async { completion(.failure(msg)) }
            case .versionMismatch(let v):
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let msg = "引擎 apiVersion=\(v) 超出兼容区间 [\(PythonEngineHost.minEngineAPI), \(PythonEngineHost.maxEngineAPI)]"
                DebugLogger.shared.log("[PyBridge] ensureReady 失败（\(ms)ms）：\(msg)")
                DispatchQueue.main.async { completion(.failure(msg)) }
            case .corrupted(let reason):
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                let msg = "引擎损坏：\(reason)"
                DebugLogger.shared.log("[PyBridge] ensureReady 失败（\(ms)ms）：\(msg)")
                DispatchQueue.main.async { completion(.failure(msg)) }
            }
        }
    }

    // MARK: 异步调用

    /// 异步执行业务脚本（JSON 通道；完成回调派发主线程；早期前置失败在调用线程同步回调）。
    /// - 引擎未就绪 → .engineNotReady，绝不触发 ensureReady/加载（调用方自行先 ensureReady）；
    /// - 成功返回原始输出 Data（顶层 dict 且 ok==true），payload 由调用方解码；
    /// - 超时只上报失败：底层 run 继续跑完（不取消、不阻塞引擎队列）。
    func call(script: String, input: [String: Any], timeout: TimeInterval,
              completion: @escaping (Result<Data, PyBridgeError>) -> Void) {
        dispatch(script: script, jsonInput: input, pin: nil, timeout: timeout,
                 read: { Self.readResult(script: $0, outPath: $1, inPath: $2, fm: self.fm) },
                 completion: completion)
    }

    /// 异步执行业务脚本（bin 通道：大数组零拷贝进 + 二进制出）。
    /// - seriesBin 的大数组不进 JSON：地址 + 根数直传（进程内同地址空间），Python 侧
    ///   ctypes 构建零拷贝视图后注入 kline_input[seriesInto]（键同名覆盖 JSON 同名序列）；
    /// - 脚本可在 kline_result["__bin_out__"] = {键: 序列} 二进制回传大数组（包装脚本统一
    ///   落 <输出>.bin 并附 __bin_meta__ 偏移表，本层解码为 arrays 返回）；
    /// - 生命周期：seriesBin 被 completion 闭包捕获持有，Python 读取期间绝不释放；
    ///   调用期间无人改写 → 无 COW 搬移，地址恒稳定。
    func callBin(script: String, input: [String: Any], seriesBin: [String: [Double]],
                 seriesInto: String, timeout: TimeInterval,
                 completion: @escaping (Result<PyBinResult, PyBridgeError>) -> Void) {
        // 地址元数据：空数组不传地址（Python 侧落到空 list）
        var ptrs: [String: Any] = [:]
        for (name, arr) in seriesBin where !arr.isEmpty {
            arr.withUnsafeBufferPointer { buf in
                // Swift Array 存储在存活且无 mutation 期间不搬移；arr 由 pin 持有到调用完成
                ptrs[name] = ["addr": Int(bitPattern: UInt(bitPattern: buf.baseAddress)),
                              "n": arr.count]
            }
        }
        var jsonInput = input
        jsonInput["__series_ptr__"] = ptrs
        jsonInput["__series_into__"] = seriesInto
        dispatch(script: script, jsonInput: jsonInput, pin: seriesBin, timeout: timeout,
                 read: { Self.readResultBin(script: $0, outPath: $1, inPath: $2, fm: self.fm) },
                 completion: completion)
    }

    /// 通用调度核心（call 与 callBin 共用）：写输入 → PyRun → 读输出 → 清理。
    /// pin：需在 Python 读取期间保活的大数组（闭包捕获持有到 runPyBridge 完成）。
    private func dispatch<R>(script: String, jsonInput: [String: Any], pin: [String: [Double]]?,
                            timeout: TimeInterval,
                            read: @escaping (_ script: String, _ outPath: String, _ inPath: String) -> Result<R, PyBridgeError>,
                            completion: @escaping (Result<R, PyBridgeError>) -> Void) {
        // 前置：业务脚本存在（随 App bundle）
        let path = Bundle.main.bundlePath + "/PyScripts/" + script + ".py"
        guard fm.fileExists(atPath: path) else {
            DebugLogger.shared.log("[PyBridge] 业务脚本缺失: \(script).py")
            completion(.failure(.scriptError("业务脚本缺失: \(script).py")))
            return
        }
        // 前置：引擎未就绪直接失败，绝不触发加载
        guard isReady else {
            completion(.failure(.engineNotReady("引擎未就绪")))
            return
        }
        // 临时输入/输出文件（UUID 防并发互踩）
        let tmp = fm.temporaryDirectory
        let inPath = tmp.appendingPathComponent("kline_py_\(UUID().uuidString)_in.json").path
        let outPath = tmp.appendingPathComponent("kline_py_\(UUID().uuidString)_out.json").path
        do {
            let inData = try JSONSerialization.data(withJSONObject: jsonInput)
            try inData.write(to: URL(fileURLWithPath: inPath), options: .atomic)
        } catch {
            DebugLogger.shared.log("[PyBridge] \(script).py 输入写入失败：\(error.localizedDescription)")
            completion(.failure(.scriptError("输入 JSON 写入失败：" + error.localizedDescription)))
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let pyScript = Self.assemblePyRun(scriptPath: path, inPath: inPath, outPath: outPath)

        // settled 只在主线程读写：超时看门狗（main.asyncAfter）与完成回调（runPyBridge 派发主线程）
        // 同队列串行，先到先得，另一方自动失效
        var settled = false
        func deliver(_ r: Result<R, PyBridgeError>) {
            guard !settled else { return }
            settled = true
            completion(r)
        }
        // 超时看门狗；临时文件（含 .bin）由迟到的完成回调兜底清理（彼时读写均已结束，删除安全）
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !settled else { return }
            DebugLogger.shared.log("[PyBridge] \(script).py 超时（\(timeout)s，底层继续执行）")
            deliver(.failure(.timeout))
        }
        PythonEngineHost.shared.runPyBridge(pyScript) { [weak self, pin] r in
            guard let self = self else { return }
            _ = pin   // 保活大数组：Python ctypes 读取期间地址不得失效（读取已完成才到此处）
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let result: Result<R, PyBridgeError>
            switch r {
            case .failure(let msg):
                try? self.fm.removeItem(atPath: inPath)
                try? self.fm.removeItem(atPath: outPath)
                try? self.fm.removeItem(atPath: outPath + ".bin")
                DebugLogger.shared.log("[PyBridge] \(script).py PyRun 失败：\(msg)")
                result = .failure(.scriptError(msg))
            case .success:
                result = read(script, outPath, inPath)
                var verdict = "失败"
                if case .success = result { verdict = "完成" }
                DebugLogger.shared.log(String(format: "[PyBridge] %@ %@（%.0fms）",
                                              script + ".py", verdict, ms))
            }
            deliver(result)
        }
    }

    // MARK: 同步调用

    /// 同步执行业务脚本（JSON 通道；仅供后台线程生产路径，主线程调用直接 assert）。
    /// 超时返回 .timeout：底层 run 继续跑完即可，不取消、不阻塞引擎队列。
    func blockingCall(script: String, input: [String: Any],
                      timeout: TimeInterval) -> Result<Data, PyBridgeError> {
        assert(!Thread.isMainThread, "禁止主线程同步等待 Python（blockingCall）")
        let sem = DispatchSemaphore(value: 0)
        var boxed: Result<Data, PyBridgeError>?   // completion 闭包强持有 sem 保活；跨线程经信号量同步
        call(script: script, input: input, timeout: timeout) { r in
            boxed = r
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(.timeout)
        }
        return boxed ?? .failure(.timeout)
    }

    /// 同步执行业务脚本（bin 通道；仅供后台线程，主线程调用直接 assert）。
    func blockingCallBin(script: String, input: [String: Any], seriesBin: [String: [Double]],
                         seriesInto: String, timeout: TimeInterval) -> Result<PyBinResult, PyBridgeError> {
        assert(!Thread.isMainThread, "禁止主线程同步等待 Python（blockingCallBin）")
        let sem = DispatchSemaphore(value: 0)
        var boxed: Result<PyBinResult, PyBridgeError>?
        callBin(script: script, input: input, seriesBin: seriesBin, seriesInto: seriesInto,
                timeout: timeout) { r in
            boxed = r
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(.timeout)
        }
        return boxed ?? .failure(.timeout)
    }

    // MARK: 内部

    /// 组装 PyRun 包装脚本：三个路径全部 base64 注入（防拼接注入）
    private static func assemblePyRun(scriptPath: String, inPath: String, outPath: String) -> String {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        // 多行字面量：Python 各行与结尾 """ 同缩进（Swift 剥掉该层级缩进，
        // 落进 PyRun 的脚本文本顶层语句顶格——Python 对缩进敏感）
        return """
        import base64 as _kb64, json as _kjson, traceback as _ktb
        __kline_out__ = _kb64.b64decode('\(b64(outPath))').decode()
        __kline_in__ = _kb64.b64decode('\(b64(inPath))').decode()
        __kline_script__ = _kb64.b64decode('\(b64(scriptPath))').decode()
        _kres = {"ok": False, "error": "unreachable"}
        try:
            # 编译缓存：PyRun_SimpleString 的 __main__ 命名空间跨调用持久，
            # 业务脚本（随 bundle 不变）只 compile 一次，后续调用直接 exec 字节码。
            # A8 实测每次重编译 ~500 行脚本贡献了「越跑越慢」的主要份额。
            try:
                _kcode_cache
            except NameError:
                _kcode_cache = {}
            import os as _kos
            _kst = _kos.stat(__kline_script__)
            _kk = (__kline_script__, _kst.st_size, _kst.st_mtime)
            _kc = _kcode_cache.get(_kk)
            if _kc is None:
                with open(__kline_script__, "r", encoding="utf-8") as _f:
                    _kc = compile(_f.read(), __kline_script__, "exec")
                _kcode_cache[_kk] = _kc
            with open(__kline_in__, "r", encoding="utf-8") as _f:
                _kinput = _kjson.load(_f)
            # 零拷贝序列重建：地址 + 根数 → ctypes c_double 数组视图（无拷贝，进程内同地址空间）。
            # 数组由 Swift 侧调用闭包持有，本段执行期间地址恒有效；空序列落到空 list。
            _kptrs = _kinput.pop("__series_ptr__", None)
            if isinstance(_kptrs, dict) and _kptrs:
                import ctypes as _kct
                _kinto = _kinput.pop("__series_into__", "series")
                _ktgt = _kinput.setdefault(_kinto, {})
                for _k, _m in _kptrs.items():
                    _kn = int(_m["n"])
                    _ktgt[_k] = (_kct.c_double * _kn).from_address(int(_m["addr"])) if _kn > 0 else []
            _g = {"__name__": "__main__", "__file__": __kline_script__, "kline_input": _kinput}
            exec(_kc, _g)
            _kres = _g.get("kline_result")
            if not isinstance(_kres, dict):
                raise RuntimeError("脚本未定义 dict 类型的 kline_result")
        except Exception:
            _kres = {"ok": False, "error": _ktb.format_exc()}
        # 二进制输出：脚本把大数组放 kline_result["__bin_out__"]（键 → 数值序列），
        # 统一打包为单个 <输出>.bin（array 'd' 一次拷贝）+ __bin_meta__ 偏移表（JSON 内）。
        # array.array('d') 接受 list / ndarray / ctypes 数组（buffer 协议），NaN 原样保留。
        if isinstance(_kres, dict) and isinstance(_kres.get("__bin_out__"), dict):
            _kbo = _kres.pop("__bin_out__")
            if _kbo:
                import array as _karr
                _kmeta = {}
                _kbuf = bytearray()
                for _k, _seq in _kbo.items():
                    _kd = _karr.array("d", _seq)
                    _kmeta[_k] = [len(_kbuf) // 8, len(_kd)]
                    _kbuf += _kd.tobytes()
                _kres["__bin_meta__"] = _kmeta
                with open(__kline_out__ + ".bin", "wb") as _f:
                    _f.write(_kbuf)
        with open(__kline_out__, "w", encoding="utf-8") as _f:
            _kjson.dump(_kres, _f, ensure_ascii=False)
        """
    }

    /// 读回输出文件并校验（顶层 dict 且 ok==true）；无论成败读完即删临时文件（defer 保证正常路径清理）
    private static func readResult(script: String, outPath: String, inPath: String,
                                   fm: FileManager) -> Result<Data, PyBridgeError> {
        defer {
            try? fm.removeItem(atPath: inPath)
            try? fm.removeItem(atPath: outPath)
        }
        guard let data = fm.contents(atPath: outPath) else {
            DebugLogger.shared.log("[PyBridge] \(script).py 输出文件未生成")
            return .failure(.scriptError("输出文件未生成"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            DebugLogger.shared.log("[PyBridge] \(script).py 输出 JSON 非法（顶层非 dict）")
            return .failure(.scriptError("输出 JSON 非法（顶层非 dict）"))
        }
        if (dict["ok"] as? Bool) == true {
            return .success(data)
        }
        let err = (dict["error"] as? String) ?? "(输出缺 error 字段)"
        DebugLogger.shared.log("[PyBridge] \(script).py 脚本报错：\(err)")
        return .failure(.scriptError(err))
    }

    /// 读回 bin 通道输出并解码（JSON 元数据 + __bin_meta__ 各段二进制数组）；
    /// 无论成败读完即删临时文件（含 .bin）
    private static func readResultBin(script: String, outPath: String, inPath: String,
                                      fm: FileManager) -> Result<PyBinResult, PyBridgeError> {
        defer {
            try? fm.removeItem(atPath: inPath)
            try? fm.removeItem(atPath: outPath)
            try? fm.removeItem(atPath: outPath + ".bin")
        }
        guard let data = fm.contents(atPath: outPath) else {
            DebugLogger.shared.log("[PyBridge] \(script).py 输出文件未生成")
            return .failure(.scriptError("输出文件未生成"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            DebugLogger.shared.log("[PyBridge] \(script).py 输出 JSON 非法（顶层非 dict）")
            return .failure(.scriptError("输出 JSON 非法（顶层非 dict）"))
        }
        if (dict["ok"] as? Bool) != true {
            let err = (dict["error"] as? String) ?? "(输出缺 error 字段)"
            DebugLogger.shared.log("[PyBridge] \(script).py 脚本报错：\(err)")
            return .failure(.scriptError(err))
        }
        var arrays: [String: [Double]] = [:]
        if let meta = dict["__bin_meta__"] as? [String: Any], !meta.isEmpty {
            guard let binData = fm.contents(atPath: outPath + ".bin"),
                  binData.count % 8 == 0 else {
                DebugLogger.shared.log("[PyBridge] \(script).py bin 段缺失或长度非法")
                return .failure(.scriptError("bin 段缺失或长度非法"))
            }
            // Foundation 读文件的缓冲区为 malloc 分配（≥8 字节对齐），bindMemory 安全
            let doubles = binData.withUnsafeBytes { raw -> [Double] in
                Array(raw.bindMemory(to: Double.self))
            }
            for (key, m) in meta {
                guard let seg = m as? [Any], seg.count == 2,
                      let off = (seg[0] as? NSNumber)?.intValue,
                      let n = (seg[1] as? NSNumber)?.intValue,
                      off >= 0, n >= 0, off + n <= doubles.count else { continue }
                arrays[key] = Array(doubles[off..<(off + n)])
            }
        }
        return .success(PyBinResult(payload: dict, arrays: arrays))
    }
}

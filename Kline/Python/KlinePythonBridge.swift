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

    /// 异步执行业务脚本（完成回调派发主线程；早期前置失败在调用线程同步回调）。
    /// - 引擎未就绪 → .engineNotReady，绝不触发 ensureReady/加载（调用方自行先 ensureReady）；
    /// - 成功返回原始输出 Data（顶层 dict 且 ok==true），payload 由调用方解码；
    /// - 超时只上报失败：底层 run 继续跑完（不取消、不阻塞引擎队列）。
    func call(script: String, input: [String: Any], timeout: TimeInterval,
              completion: @escaping (Result<Data, PyBridgeError>) -> Void) {
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
            let inData = try JSONSerialization.data(withJSONObject: input)
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
        func deliver(_ r: Result<Data, PyBridgeError>) {
            guard !settled else { return }
            settled = true
            completion(r)
        }
        // 超时看门狗；临时文件由迟到的完成回调兜底清理（彼时读写均已结束，删除安全）
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !settled else { return }
            DebugLogger.shared.log("[PyBridge] \(script).py 超时（\(timeout)s，底层继续执行）")
            deliver(.failure(.timeout))
        }
        PythonEngineHost.shared.runPyBridge(pyScript) { [weak self] r in
            guard let self = self else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let result: Result<Data, PyBridgeError>
            switch r {
            case .failure(let msg):
                try? self.fm.removeItem(atPath: inPath)
                try? self.fm.removeItem(atPath: outPath)
                DebugLogger.shared.log("[PyBridge] \(script).py PyRun 失败：\(msg)")
                result = .failure(.scriptError(msg))
            case .success:
                result = self.readResult(script: script, outPath: outPath, inPath: inPath)
                var verdict = "失败"
                if case .success = result { verdict = "完成" }
                DebugLogger.shared.log(String(format: "[PyBridge] %@ %@（%.0fms）",
                                              script + ".py", verdict, ms))
            }
            deliver(result)
        }
    }

    // MARK: 同步调用

    /// 同步执行业务脚本（仅供后台线程生产路径；主线程调用直接 assert）。
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
            with open(__kline_in__, "r", encoding="utf-8") as _f:
                _kinput = _kjson.load(_f)
            _g = {"__name__": "__main__", "__file__": __kline_script__, "kline_input": _kinput}
            with open(__kline_script__, "r", encoding="utf-8") as _f:
                _ksrc = _f.read()
            exec(compile(_ksrc, __kline_script__, "exec"), _g)
            _kres = _g.get("kline_result")
            if not isinstance(_kres, dict):
                raise RuntimeError("脚本未定义 dict 类型的 kline_result")
        except Exception:
            _kres = {"ok": False, "error": _ktb.format_exc()}
        with open(__kline_out__, "w", encoding="utf-8") as _f:
            _kjson.dump(_kres, _f, ensure_ascii=False)
        """
    }

    /// 读回输出文件并校验（顶层 dict 且 ok==true）；无论成败读完即删临时文件（defer 保证正常路径清理）
    private func readResult(script: String, outPath: String, inPath: String) -> Result<Data, PyBridgeError> {
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
}

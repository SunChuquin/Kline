//
//  PythonEngineHost.swift
//  Kline
//
//  Phase-0 Stage B：Python 引擎宿主（纯调试，引擎不进 IPA）。
//  契约：.trae/documents/python-engine/Phase-0引擎实验-plan.md
//
//  硬约束：
//  - 引擎不进 IPA：本文件不嵌入任何 Python 资源，只在用户点按钮时下载/加载
//  - 所有 Python C API 经 dlsym 函数指针调用（版本无关，不 import 任何 Python 头文件，
//    只依赖 Py_Initialize / PyRun_SimpleString / Py_Finalize 三个最简符号，不碰 PyConfig 结构体）
//  - dlopen 句柄进程内永不释放（dlclose 不可靠，§5.6）
//  - 引擎激活走 staging→rename 原子切换，任何失败保留旧 active（§5.6 禁止覆盖写）
//

import Foundation
import Darwin
import CryptoKit
import Compression

// MARK: - 状态机

/// 引擎安装状态（§5.6.1 配对校验：App 内置常量区间 vs manifest.apiVersion）
enum PythonEngineStatus: Equatable {
    case notInstalled                       // 无 active
    case installed                          // active 存在 + manifest 可读 + apiVersion 在区间 + dylib 存在
    case versionMismatch(apiVersion: Int)   // manifest 可读但 apiVersion 不在 [min, max]
    case corrupted(reason: String)          // manifest 不可读或 dylib 缺失
}

/// engine/manifest.json（schema v1，两端共用契约）
struct EngineManifest: Codable {
    let schema: Int
    let engineId: String
    let engineVersion: String
    let build: String
    let apiVersion: Int
    let layout: Layout
    struct Layout: Codable {
        let dylib: String
        let home: String
    }
}

/// 引擎加载结果（各阶段耗时，CFAbsoluteTimeGetCurrent 计时）
struct EngineLoadResult {
    var dlopenMs: Double
    var initMs: Double
    var engineVersion: String
    var build: String
}

/// 解包/流程错误（带可读信息）
struct EngineFlowError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

// MARK: - 宿主

final class PythonEngineHost: ObservableObject {

    static let shared = PythonEngineHost()

    /// App 内置引擎 API 兼容区间（§5.6.1 配对校验，Phase-0 = 1..1）
    static let minEngineAPI = 1
    static let maxEngineAPI = 1

    // MARK: 状态（主线程发布，UI 由 @Published 驱动）
    @Published private(set) var isBusy = false
    @Published private(set) var busyText = ""
    @Published private(set) var downloadProgress: Double = 0    // 0~1（下载引擎包）
    @Published private(set) var extractProgress: Double = 0     // 0~1（解包 tar）
    @Published private(set) var isLoaded = false                // Py_Initialize 已成功（进程内只一次）
    @Published private(set) var outputLines: [String] = []      // 结果区逐行输出（等宽展示）

    // MARK: 目录布局（Documents/KlineEngine/{active, staging} + incoming.*）
    let rootPath: String
    let activePath: String
    let stagingPath: String

    /// 脚本结果回读文件（实验脚本把结果写这里，Swift 读回——绕开 stdout 重定向的复杂性）
    static var pyOutPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("py_out.json").path
    }

    private let workQueue = DispatchQueue(label: "com.sunck.Kline.pyengine")   // 串行：下载/解包/加载/跑脚本全在此排队
    private var busy = false                                                  // 只在 workQueue 上读写
    private let fm = FileManager.default

    // Python C API 函数指针（dlsym 取用；版本无关：仅三个最简符号，不 import Python 头）
    private typealias Py_InitializeFn = @convention(c) () -> Void
    private typealias PyRun_SimpleStringFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias Py_FinalizeFn = @convention(c) -> Void
    private var pyHandle: UnsafeMutableRawPointer?
    private var pyInitFn: Py_InitializeFn?
    private var pyRunFn: PyRun_SimpleStringFn?
    private var pyFinalizeFn: Py_FinalizeFn?   // 仅持有引用，进程内不调用（dlclose/卸载不可靠）

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("KlineEngine").path
        rootPath = root
        activePath = root + "/active"
        stagingPath = root + "/staging"
    }

    // MARK: - 输出与日志

    /// 追加一行结果输出（同步写 DebugLogger，主线程更新 UI）
    func appendOutput(_ line: String) {
        DebugLogger.shared.log("[PyEngine] " + line)
        let stamped = Self.stamp() + " " + line
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outputLines.append(stamped)
            if self.outputLines.count > 200 {
                self.outputLines.removeFirst(self.outputLines.count - 200)
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func stamp() -> String {
        stampFormatter.string(from: Date())
    }

    private func beginBusy(_ text: String) {
        busy = true
        DispatchQueue.main.async {
            self.isBusy = true
            self.busyText = text
            self.downloadProgress = 0
            self.extractProgress = 0
        }
    }

    private func updateBusy(_ text: String) {
        DispatchQueue.main.async { self.busyText = text }
    }

    private func endBusy() {
        busy = false
        DispatchQueue.main.async { self.isBusy = false; self.busyText = "" }
    }

    // MARK: - 状态扫描

    /// 状态机：notInstalled / installed / versionMismatch / corrupted（§5.6.1）
    func status() -> PythonEngineStatus {
        guard fm.fileExists(atPath: activePath) else { return .notInstalled }
        guard let m = readManifest(in: activePath) else {
            return .corrupted(reason: "manifest.json 不可读")
        }
        guard fm.fileExists(atPath: Self.resolve(activePath, m.layout.dylib)) else {
            return .corrupted(reason: "dylib 缺失")
        }
        guard (Self.minEngineAPI...Self.maxEngineAPI).contains(m.apiVersion) else {
            return .versionMismatch(apiVersion: m.apiVersion)
        }
        return .installed
    }

    /// active 引擎 manifest（可读即返回，供 UI 显示版本/构建号）
    func activeManifest() -> EngineManifest? {
        guard fm.fileExists(atPath: activePath) else { return nil }
        return readManifest(in: activePath)
    }

    private func readManifest(in dir: String) -> EngineManifest? {
        guard let data = fm.contents(atPath: dir + "/manifest.json") else { return nil }
        return try? JSONDecoder().decode(EngineManifest.self, from: data)
    }

    /// manifest.layout 相对路径解析：先按「相对解包根（engine/... 前缀）」拼；
    /// 不存在则去掉 engine/ 前缀按「相对 engine 目录本身」拼（切换后 active 即 engine 目录）
    static func resolve(_ base: String, _ rel: String) -> String {
        let fm = FileManager.default
        let direct = base + "/" + rel
        if fm.fileExists(atPath: direct) { return direct }
        let stripped = rel.hasPrefix("engine/") ? String(rel.dropFirst("engine/".count)) : rel
        return base + "/" + stripped
    }

    // MARK: - 下载 → 校验 → 解包 → 原子激活（§5.6：禁止覆盖写，失败保留旧 active）

    /// 下载引擎包与 .sha256 sidecar 到 staging，校验后解包，manifest 合法则原子切换为 active
    func downloadAndActivate(from tarURL: URL,
                             completion: @escaping (Result<EngineManifest, String>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion(.failure("已有任务进行中")) }
                return
            }
            self.beginBusy("下载引擎包…")
            self.appendOutput("开始下载：\(tarURL.lastPathComponent)")
            do {
                try self.fm.createDirectory(atPath: self.rootPath, withIntermediateDirectories: true)
                let tarPath = self.rootPath + "/incoming.tar.gz"
                let shaPath = self.rootPath + "/incoming.sha256"

                // ① tar.gz 与 .sha256 sidecar（CI 同名发布）
                try self.downloadFileSync(tarURL, to: tarPath) { f in
                    DispatchQueue.main.async { self.downloadProgress = f }
                }
                guard tarURL.absoluteString.hasSuffix(".tar.gz"),
                      let shaURL = URL(string: tarURL.absoluteString + ".sha256") else {
                    throw EngineFlowError(msg: "无法推导 sidecar 地址（URL 非 .tar.gz）")
                }
                try self.downloadFileSync(shaURL, to: shaPath, progress: nil)

                // ② sha256 校验（CryptoKit 流式）
                self.updateBusy("sha256 校验…")
                let expect = try Self.expectedSha256(sidecarPath: shaPath)
                let actual = try Self.fileSHA256(path: tarPath)
                guard expect.lowercased() == actual.lowercased() else {
                    throw EngineFlowError(msg: "sha256 不匹配（期望 \(expect.prefix(12))…，实际 \(actual.prefix(12))…）")
                }
                self.appendOutput("sha256 校验通过")

                // ③ 解包到 staging（gunzip → tar 解包，均带进度）
                self.updateBusy("解压 tar.gz…")
                try self.cleanAndRecreateStaging()
                let tmpTar = self.stagingPath + "/.unpack.tar"
                try EngineArchive.gunzip(srcPath: tarPath, dstPath: tmpTar)
                try EngineArchive.untar(tarPath: tmpTar, into: self.stagingPath) { f in
                    DispatchQueue.main.async { self.extractProgress = f }
                }
                try? self.fm.removeItem(atPath: tmpTar)

                // ④ 校验 staging/engine：manifest + apiVersion 配对 + dylib 存在
                self.updateBusy("校验引擎包…")
                guard let m = self.readManifest(in: self.stagingPath + "/engine") else {
                    throw EngineFlowError(msg: "staging/engine/manifest.json 不可读")
                }
                guard (Self.minEngineAPI...Self.maxEngineAPI).contains(m.apiVersion) else {
                    throw EngineFlowError(msg: "apiVersion=\(m.apiVersion) 超出兼容区间 [\(Self.minEngineAPI), \(Self.maxEngineAPI)]")
                }
                guard self.fm.fileExists(atPath: Self.resolve(self.stagingPath, m.layout.dylib)) else {
                    throw EngineFlowError(msg: "dylib 缺失：\(m.layout.dylib)")
                }

                // ⑤ 原子切换：active.old-<ts> → staging/engine rename 为 active → 删 old
                self.updateBusy("切换 active…")
                try self.activateStagedEngine()
                self.appendOutput("引擎已激活：v\(m.engineVersion)（\(m.build)，api=\(m.apiVersion)）")
                self.endBusy()
                DispatchQueue.main.async { completion(.success(m)) }
            } catch {
                let msg = (error as? EngineFlowError)?.msg ?? error.localizedDescription
                self.appendOutput("下载/激活失败：" + msg)
                // 失败清理 staging（旧 active 原样保留）
                try? self.fm.removeItem(atPath: self.stagingPath)
                self.endBusy()
                DispatchQueue.main.async { completion(.failure(msg)) }
            }
        }
    }

    /// staging/engine → active 的 rename 原子切换（同容器内 rename；失败回滚旧 active）
    private func activateStagedEngine() throws {
        let stagedEngine = stagingPath + "/engine"
        guard fm.fileExists(atPath: stagedEngine + "/manifest.json") else {
            throw EngineFlowError(msg: "staging/engine 不完整")
        }
        if fm.fileExists(atPath: activePath) {
            let old = rootPath + "/active.old-\(Int(Date().timeIntervalSince1970))"
            try fm.moveItem(atPath: activePath, toPath: old)
            do {
                try fm.moveItem(atPath: stagedEngine, toPath: activePath)
            } catch {
                try? fm.moveItem(atPath: old, toPath: activePath)   // 回滚，保留在用引擎
                throw EngineFlowError(msg: "切换 active 失败（已回滚）：\(error.localizedDescription)")
            }
            try? fm.removeItem(atPath: old)
        } else {
            try fm.moveItem(atPath: stagedEngine, toPath: activePath)
        }
        try? fm.removeItem(atPath: stagingPath)   // 清理 staging 残留
    }

    private func cleanAndRecreateStaging() throws {
        if fm.fileExists(atPath: stagingPath) { try fm.removeItem(atPath: stagingPath) }
        try fm.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)
    }

    /// 同步下载（workQueue 上用信号量等完成；进度经主线程回调）
    private func downloadFileSync(_ url: URL, to target: String,
                                  progress: ((Double) -> Void)?) throws {
        var errMsg: String?
        let sem = DispatchSemaphore(value: 0)
        downloadFile(url, to: target, progress: progress) { err in
            errMsg = err
            sem.signal()
        }
        sem.wait()
        if let e = errMsg { throw EngineFlowError(msg: e) }
    }

    /// URLSession downloadTask 落盘下载（写法对齐 GitHubRemoteUpdate.downloadLatestIPA）
    private func downloadFile(_ url: URL, to target: String,
                              progress: ((Double) -> Void)?,
                              completion: @escaping (String?) -> Void) {   // nil = 成功
        if fm.fileExists(atPath: target) { try? fm.removeItem(atPath: target) }
        let session = URLSession(configuration: .ephemeral)
        let req = URLRequest(url: url, timeoutInterval: 60)
        let task = session.downloadTask(with: req) { tmp, resp, err in
            session.finishTasksAndInvalidate()
            if let err = err { completion(err.localizedDescription); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let tmp = tmp, (200..<300).contains(status) else {
                completion("HTTP \(status)")
                return
            }
            do {
                let targetURL = URL(fileURLWithPath: target)
                do {
                    try FileManager.default.moveItem(at: tmp, to: targetURL)
                } catch {
                    try FileManager.default.copyItem(at: tmp, to: targetURL)
                    try? FileManager.default.removeItem(at: tmp)
                }
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
        // 进度采样定时器必须挂主线程 runloop（workQueue 无 runloop）
        if let progress = progress {
            var poll: Timer?
            DispatchQueue.main.async {
                poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    progress(task.progress.fractionCompleted)
                    if task.progress.isFinished || task.progress.isCancelled { poll?.invalidate() }
                }
            }
        }
        task.resume()
    }

    /// sidecar 首个空白分隔 token 即十六进制摘要
    private static func expectedSha256(sidecarPath: String) throws -> String {
        guard let raw = FileManager.default.contents(atPath: sidecarPath),
              let text = String(data: raw, encoding: .utf8) else {
            throw EngineFlowError(msg: "sha256 sidecar 不可读")
        }
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first
        guard let token = token, token.count == 64 else {
            throw EngineFlowError(msg: "sha256 sidecar 格式异常")
        }
        return String(token)
    }

    /// 文件 sha256（CryptoKit 流式）
    private static func fileSHA256(path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 加载（dlopen + Py_Initialize）

    /// dlopen 引擎 dylib → dlsym 三个最简 C API 符号 → setenv PYTHONHOME → Py_Initialize。
    /// 各阶段计时；句柄进程内不释放；Py_Finalize 不调用（进程内卸载不可靠）。
    func loadEngine(completion: @escaping (Result<EngineLoadResult, String>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            if self.pyHandle != nil {
                DispatchQueue.main.async { completion(.failure("引擎已加载（进程内只能初始化一次）")) }
                return
            }
            let st = self.status()
            switch st {
            case .installed:
                break
            case .notInstalled:
                DispatchQueue.main.async { completion(.failure("未安装引擎（请先下载引擎包）")) }
                return
            case .versionMismatch(let v):
                DispatchQueue.main.async {
                    completion(.failure("apiVersion=\(v) 超出兼容区间 [\(Self.minEngineAPI), \(Self.maxEngineAPI)]"))
                }
                return
            case .corrupted(let r):
                DispatchQueue.main.async { completion(.failure("引擎损坏：\(r)")) }
                return
            }
            guard let m = self.readManifest(in: self.activePath) else {
                DispatchQueue.main.async { completion(.failure("manifest 读取失败")) }
                return
            }
            let dylibPath = Self.resolve(self.activePath, m.layout.dylib)
            let homePath = Self.resolve(self.activePath, m.layout.home)

            self.beginBusy("dlopen 引擎…")
            let t0 = CFAbsoluteTimeGetCurrent()
            // RTLD_GLOBAL：后续 Python 扩展模块（_ssl/_socket 等）需要解析 libpython 符号
            guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
                var msg = "dlopen 失败"
                if let e = dlerror() { msg += "：" + String(cString: e) }
                self.appendOutput(msg + "（\(dylibPath)）")
                self.endBusy()
                DispatchQueue.main.async { completion(.failure(msg)) }
                return
            }
            guard let symInit = dlsym(handle, "Py_Initialize"),
                  let symRun = dlsym(handle, "PyRun_SimpleString"),
                  let symFin = dlsym(handle, "Py_Finalize") else {
                self.appendOutput("dlsym 失败：缺少 Python C API 符号")
                self.endBusy()
                DispatchQueue.main.async {
                    completion(.failure("dlsym 缺少 Py_Initialize / PyRun_SimpleString / Py_Finalize"))
                }
                return
            }
            let dlopenMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            // 初始化前设置 PYTHONHOME（值随引擎包 manifest 走，不硬编码）
            setenv("PYTHONHOME", homePath, 1)
            self.appendOutput("PYTHONHOME=\(homePath)")

            let initFn = unsafeBitCast(symInit, to: Py_InitializeFn.self)
            let runFn = unsafeBitCast(symRun, to: PyRun_SimpleStringFn.self)
            let finFn = unsafeBitCast(symFin, to: Py_FinalizeFn.self)

            self.updateBusy("Py_Initialize…")
            let t1 = CFAbsoluteTimeGetCurrent()
            initFn()   // 经函数指针调用，版本无关
            let initMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000

            self.pyHandle = handle          // 永不 dlclose
            self.pyInitFn = initFn
            self.pyRunFn = runFn
            self.pyFinalizeFn = finFn       // 只持有引用，不调用
            DispatchQueue.main.async { self.isLoaded = true }
            self.appendOutput(String(format: "加载完成：dlopen %.1fms，Py_Initialize %.1fms", dlopenMs, initMs))
            self.endBusy()
            DispatchQueue.main.async {
                completion(.success(EngineLoadResult(dlopenMs: dlopenMs,
                                                     initMs: initMs,
                                                     engineVersion: m.engineVersion,
                                                     build: m.build)))
            }
        }
    }

    // MARK: - 脚本执行（计时 + 结果回读）

    /// PyRun_SimpleString 计时执行（引擎未加载则失败）
    func runScript(_ script: String, completion: @escaping (Result<Double, String>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self, self.pyHandle != nil, let run = self.pyRunFn else {
                DispatchQueue.main.async { completion(.failure("引擎未加载")) }
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let rc = script.withCString { run($0) }   // 经函数指针调用，版本无关
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                completion(rc == 0 ? .success(ms)
                                   : .failure("PyRun_SimpleString 返回 \(rc)（脚本执行异常，见日志）"))
            }
        }
    }

    /// 结果捕获执行：输出文件路径经 base64 传给脚本（防拼接注入），
    /// 脚本体把 JSON 写到 Documents/py_out.json，Swift 读回。
    func runScriptCapturingOutput(_ body: String,
                                  completion: @escaping (Result<(data: Data, totalMs: Double), String>) -> Void) {
        let outPath = Self.pyOutPath
        try? fm.removeItem(atPath: outPath)
        let script = Self.wrappedScript(body, outPath: outPath)
        beginBusy("运行脚本…")
        runScript(script) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .failure(let e):
                self.endBusy()
                completion(.failure(e))
            case .success(let ms):
                self.workQueue.async {
                    self.endBusy()
                    if let data = self.fm.contents(atPath: outPath) {
                        completion(.success((data, ms)))
                    } else {
                        completion(.failure("输出文件未生成（脚本可能未执行到写文件，或 stdlib 导入失败）"))
                    }
                }
            }
        }
    }

    /// 输出捕获包装：__kline_out__ = base64 解码出的结果文件绝对路径
    static func wrappedScript(_ body: String, outPath: String) -> String {
        let b64 = Data(outPath.utf8).base64EncodedString()
        return "import base64 as _kb64\n"
             + "__kline_out__ = _kb64.b64decode('" + b64 + "').decode()\n"
             + body
    }

    // MARK: - 卸载重置

    /// 删除 active/staging/incoming。不做 Py_Finalize：进程内卸载不可靠，
    /// 已加载的解释器待下次启动 App 后才真正释放（UI 文案需说明）。
    func resetEngine(completion: @escaping (String) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion("有任务进行中，稍后再试") }
                return
            }
            var removed: [String] = []
            let targets = [self.activePath, self.stagingPath,
                           self.rootPath + "/incoming.tar.gz",
                           self.rootPath + "/incoming.sha256"]
            for p in targets where self.fm.fileExists(atPath: p) {
                try? self.fm.removeItem(atPath: p)
                removed.append((p as NSString).lastPathComponent)
            }
            let note = self.pyHandle != nil
                ? "；已加载的解释器进程内不卸载（dlclose 不可靠），重启 App 后彻底释放"
                : ""
            let msg = removed.isEmpty ? "无引擎文件可删除" : "已删除：" + removed.joined(separator: "、") + note
            self.appendOutput("重置：" + msg)
            DispatchQueue.main.async { completion(msg) }
        }
    }
}

// MARK: - 引擎包解包（gzip → tar，纯 Swift；iOS 无 libarchive/tar 可用）

/// 引擎包解包器：gzip（RFC1952 容器）→ raw DEFLATE（Compression 框架流式）→ tar 解包。
/// tar 支持：普通文件/目录/软链/硬链、ustar prefix、GNU 'L' 长名、pax 'x' 扩展头 path 记录。
enum EngineArchive {

    private static let chunkSize = 1 << 18   // 256KB

    /// gzip 解码到目标文件（头部手工解析，payload 为 raw DEFLATE 流式解码）
    static func gunzip(srcPath: String, dstPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dstPath) { try fm.removeItem(atPath: dstPath) }
        guard fm.createFile(atPath: dstPath, contents: nil),
              let dst = FileHandle(forWritingAtPath: dstPath) else {
            throw EngineFlowError(msg: "创建解压输出文件失败")
        }
        defer { try? dst.close() }

        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: srcPath))
        defer { try? src.close() }

        // 解析 gzip 头（RFC1952）
        guard let head = try src.read(upToCount: 512), head.count >= 10 else {
            throw EngineFlowError(msg: "gzip 头不完整")
        }
        let b = [UInt8](head)
        guard b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else {
            throw EngineFlowError(msg: "不是 gzip 文件")
        }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= b.count else { throw EngineFlowError(msg: "gzip 头越界") }
            let xlen = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2 + xlen
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FNAME
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                                              // FHCRC
        guard i <= b.count else { throw EngineFlowError(msg: "gzip 头越界") }

        var pending: Data? = (i < head.count) ? Data(head.dropFirst(i)) : nil
        try deflateDecode(src: src, pending: &pending, dst: dst)
    }

    /// raw DEFLATE 流式解码（COMPRESSION_ZLIB 即 raw DEFLATE，无 zlib 头，与 gzip payload 匹配）
    private static func deflateDecode(src: FileHandle, pending: inout Data?, dst: FileHandle) throws {
        let dstCap = chunkSize
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dstBuf.deallocate() }

        var stream = compression_stream(dst_ptr: dstBuf, dst_size: dstCap,
                                        src_ptr: UnsafePointer<UInt8>(dstBuf), src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw EngineFlowError(msg: "Compression 流初始化失败")
        }

        var current: Data?    // 当前喂给流的输入块（强持有到被消费，防悬垂）
        var srcEOF = false
        while true {
            if stream.src_size == 0, !srcEOF {
                if let p = pending {
                    current = p
                    pending = nil
                } else if let chunk = try src.read(upToCount: chunkSize), !chunk.isEmpty {
                    current = chunk
                } else {
                    current = nil
                    srcEOF = true
                }
                if let cur = current {
                    cur.withUnsafeBytes { raw in
                        stream.src_ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                                         ?? UnsafePointer<UInt8>(dstBuf)
                        stream.src_size = raw.count
                    }
                }
            }
            let flags: Int32 = srcEOF ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let st = compression_stream_process(&stream, flags)
            if st == COMPRESSION_STATUS_ERROR { throw EngineFlowError(msg: "DEFLATE 解码失败") }
            if stream.dst_size < dstCap {
                let produced = dstCap - stream.dst_size
                dst.write(Data(bytes: dstBuf, count: produced))
                stream.dst_ptr = dstBuf
                stream.dst_size = dstCap
            }
            if st == COMPRESSION_STATUS_END { break }
            if srcEOF && stream.src_size > 0 {
                throw EngineFlowError(msg: "DEFLATE 流异常终止")
            }
        }
    }

    /// 解包 tar 到目标目录（progress：已处理字节 / 总字节）
    static func untar(tarPath: String, into destDir: String,
                      progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let total = (try fm.attributesOfItem(atPath: tarPath)[.size] as? UInt64) ?? 0
        let src = try FileHandle(forReadingFrom: URL(fileURLWithPath: tarPath))
        defer { try? src.close() }

        var offset: UInt64 = 0
        var longName: String?    // GNU 'L' 长名
        var paxPath: String?     // pax 'x' 扩展头 path 记录

        while offset + 512 <= total {
            let header = try readAt(src, offset: offset, count: 512)
            if header.allSatisfy({ $0 == 0 }) { break }   // 结束块
            let name0 = cstr(Array(header[0..<100]))
            let size = octal(Array(header[124..<136]))
            let type = header[156]
            let link = cstr(Array(header[157..<257]))
            let magic = cstr(Array(header[257..<263]))
            var name = name0
            if magic.hasPrefix("ustar") {
                let prefix = cstr(Array(header[345..<500]))
                if !prefix.isEmpty { name = prefix + "/" + name0 }
            }
            offset += 512

            // typeflag（十六进制字面量，避免字符转换歧义）：0x30='0' 文件 0x35='5' 目录
            // 0x32='2' 软链 0x31='1' 硬链 0x4C='L' GNU 长名 0x78='x'/0x67='g' pax 头
            let effectiveName = longName ?? paxPath ?? name
            switch type {
            case 0x4C:
                let data = try readAt(src, offset: offset, count: Int(size))
                longName = cstr([UInt8](data))
            case 0x78, 0x67:
                let data = try readAt(src, offset: offset, count: Int(size))
                paxPath = paxPathValue(data)
            case 0x35:
                try fm.createDirectory(atPath: destDir + "/" + effectiveName,
                                       withIntermediateDirectories: true)
            case 0x32:
                let target = destDir + "/" + effectiveName
                try? fm.removeItem(atPath: target)
                try fm.createSymbolicLink(atPath: target, withDestinationPath: link)
            case 0x31:
                let dstp = destDir + "/" + effectiveName
                let srcp = destDir + "/" + link
                try? fm.removeItem(atPath: dstp)
                if fm.fileExists(atPath: srcp) { try fm.copyItem(atPath: srcp, toPath: dstp) }
            case 0x30, 0:
                try extractFile(src: src, at: offset, size: size, to: destDir + "/" + effectiveName)
                let mode = octal(Array(header[100..<108]))
                if mode > 0 {   // 恢复 tar 记录的权限（保留可执行位）
                    try? fm.setAttributes([.posixPermissions: Int(mode & 0o7777)],
                                          ofItemAtPath: destDir + "/" + effectiveName)
                }
            default:
                break   // 其它类型跳过数据体
            }
            offset += (size + 511) & ~UInt64(511)
            longName = nil
            paxPath = nil
            if total > 0 { progress(min(1, Double(offset) / Double(total))) }
        }
        progress(1)
    }

    /// 定位读一块 tar 数据
    private static func readAt(_ src: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try src.seek(toOffset: offset)
        guard let d = try src.read(upToCount: count), d.count == count else {
            throw EngineFlowError(msg: "tar 数据不完整")
        }
        return d
    }

    /// 流式抽取普通文件（分块读写，避免整块载入内存）
    private static func extractFile(src: FileHandle, at offset: UInt64, size: UInt64,
                                    to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: path)
        guard fm.createFile(atPath: path, contents: nil),
              let dst = FileHandle(forWritingAtPath: path) else {
            throw EngineFlowError(msg: "创建文件失败：\((path as NSString).lastPathComponent)")
        }
        defer { try? dst.close() }
        try src.seek(toOffset: offset)
        var remaining = size
        while remaining > 0 {
            let want = Int(min(UInt64(1 << 20), remaining))
            guard let d = try src.read(upToCount: want), !d.isEmpty else {
                throw EngineFlowError(msg: "tar 文件数据不完整")
            }
            try dst.write(contentsOf: d)
            remaining -= UInt64(d.count)
        }
    }

    /// NUL 截断的 C 字符串（UTF-8）
    private static func cstr(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// 八进制长度/模式解析（容忍空格与 NUL 填充）
    private static func octal(_ bytes: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for b in bytes {
            if b == 0 || b == 0x20 { if v > 0 { break }; continue }
            guard b >= 0x30, b <= 0x37 else { break }
            v = v << 3 | UInt64(b - 0x30)
        }
        return v
    }

    /// pax 扩展头记录解析（"<len> path=...\n" 逐条），取 path 值
    private static func paxPathValue(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 0x20 { j += 1 }
            guard let len = Int(String(decoding: bytes[i..<j], as: UTF8.self)),
                  len > 0, i + len <= bytes.count else { break }
            let rec = String(decoding: bytes[(j + 1)..<(i + len)], as: UTF8.self)
            if rec.hasPrefix("path=") { return String(rec.dropFirst(5)) }
            i += len
        }
        return nil
    }
}

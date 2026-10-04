//
//  PythonEngineHost.swift
//  Kline
//
//  Phase-0 Stage B：Python 引擎宿主（纯调试，引擎不进 IPA）。
//  契约：.trae/documents/python-engine/Phase-0引擎实验-plan.md
//  （Engine.app 方案：沙盒 staging/active 下载激活链路已废弃——实测「运行时下载 dylib
//   到沙盒再 dlopen」被 iOS AMFI 拒绝（code signature invalid，TrollStore 信任只在安装时
//   授予），引擎改打包成迷你 Engine.app 的 .tipa，经 TrollStore 安装授信，
//   主 App 从 Engine.app 安装路径 dlopen）
//
//  硬约束：
//  - 引擎不进 IPA：本文件不嵌入任何 Python 资源，只在用户点按钮时下载/安装/加载
//  - 所有 Python C API 经 dlsym 函数指针调用（版本无关，不 import 任何 Python 头文件，
//    只依赖 Py_Initialize / PyRun_SimpleString / Py_Finalize 三个最简符号，不碰 PyConfig 结构体）
//  - dlopen 句柄进程内永不释放（dlclose 不可靠）
//  - Engine.app 整包随安装由 TrollStore 授信（安装原子），App 侧不做逐文件 sha256 校验
//

import Foundation
import Darwin
import Combine
import UIKit
import CryptoKit

// MARK: - 状态机

/// 引擎安装状态（配对校验：App 内置常量区间 vs manifest.apiVersion）
enum PythonEngineStatus: Equatable {
    case notInstalled                       // Engine.app 未安装（Bundle/Application 下找不到）
    case installed                          // 已安装 + manifest 可读 + apiVersion 在区间 + dylib 存在
    case versionMismatch(apiVersion: Int)   // manifest 可读但 apiVersion 不在 [min, max]
    case corrupted(reason: String)          // manifest 不可读或 dylib 缺失（TrollStore 内卸载引擎后重装）
}

/// Engine.app 内 manifest.json（schema v1，两端共用契约；layout 为相对仓库根的旧前缀，
/// 实际路径相对 Engine.app，解析时剥掉「Engine.app/」前缀）
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

/// 流程错误（带可读信息）
struct EngineFlowError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// 调试代码域内统一以 String 作为 Result.Failure（本模块显式声明 conform，
/// 免去宿主与调试页共 15+ 处 `.failure(...)` 的机械包装；仅调试文件作用，不外溢）
extension String: Error {}

// MARK: - 宿主

final class PythonEngineHost: ObservableObject {

    static let shared = PythonEngineHost()

    /// App 内置引擎 API 兼容区间（配对校验，Phase-0 = 1..1）
    static let minEngineAPI = 1
    static let maxEngineAPI = 1

    // MARK: Engine.app 契约常量
    /// Engine.app 的 bundle id（CI 构建 .tipa 时固定，定位时核对 Info.plist）
    static let engineBundleID = "com.sunck.KlineEngine"
    /// 用户级 App 安装根（每个 App 一个 <UUID> 子目录；App entitlements 含 no-sandbox，可枚举）
    static let bundleAppsRoot = "/var/containers/Bundle/Application"
    /// 迷你引擎 App 的目录名
    static let engineAppName = "Engine.app"
    /// 引擎 tipa 文件名（下载产物与 TrollStore 安装共用）
    static let tipaFileName = "KlineEngine-3.14.7.tipa"

    /// 引擎 tipa 落盘路径：Documents/Downloads/（与 Kline.ipa 同目录，
    /// 该目录经 KlineHTTPServer 的 /sandbox 路由暴露给 TrollStore）
    static var tipaLocalPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads/" + tipaFileName).path
    }

    /// 引擎 tipa 是否已下载（下载完成后为 true，供「拉起安装」前置提示）
    static var tipaDownloaded: Bool {
        FileManager.default.fileExists(atPath: tipaLocalPath)
    }

    // MARK: 状态（主线程发布，UI 由 @Published 驱动）
    @Published private(set) var isBusy = false
    @Published private(set) var busyText = ""
    @Published private(set) var downloadProgress: Double = 0    // 0~1（下载引擎包）
    @Published private(set) var isLoaded = false                // Py_Initialize 已成功（进程内只一次）
    @Published private(set) var outputLines: [String] = []      // 结果区逐行输出（等宽展示）

    /// 脚本结果回读文件（实验脚本把结果写这里，Swift 读回——绕开 stdout 重定向的复杂性）
    static var pyOutPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("py_out.json").path
    }

    /// Python stderr 捕获文件（Py_Initialize fatal abort 的死前信息落这里；仅进程内加载链路用）
    static var pyStderrPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("py_stderr.log").path
    }

    /// pyrunner 子进程脚本文件（每次隔离执行前重写；内容 = wrappedScript 包装后的实脚本）
    static var pyScriptPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("py_script.py").path
    }

    /// pyrunner 子进程自己的 stderr（dlopen/init/脚本的死前信息；独立命名，
    /// 避免与进程内加载链路的 py_stderr.log 混淆）
    static var pyRunnerStderrPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("py_runner_stderr.log").path
    }

    private let workQueue = DispatchQueue(label: "com.sunck.Kline.pyengine")   // 串行：下载/加载/跑脚本全在此排队
    private var busy = false                                                  // 只在 workQueue 上读写
    private let fm = FileManager.default

    // Python C API 函数指针（dlsym 取用；版本无关：仅三个最简符号，不 import Python 头）
    private typealias Py_InitializeFn = @convention(c) () -> Void
    private typealias PyRun_SimpleStringFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias Py_FinalizeFn = @convention(c) () -> Void
    private var pyHandle: UnsafeMutableRawPointer?
    private var pyInitFn: Py_InitializeFn?
    private var pyRunFn: PyRun_SimpleStringFn?
    private var pyFinalizeFn: Py_FinalizeFn?   // 仅持有引用，进程内不调用（dlclose/卸载不可靠）

    private init() {}

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
        }
    }

    private func updateBusy(_ text: String) {
        DispatchQueue.main.async { self.busyText = text }
    }

    private func endBusy() {
        busy = false
        DispatchQueue.main.async { self.isBusy = false; self.busyText = "" }
    }

    // MARK: - Engine.app 定位与状态扫描

    /// 定位 Engine.app：枚举 /var/containers/Bundle/Application/ 下每个目录，
    /// 找 Engine.app 子目录并核对 Info.plist 的 CFBundleIdentifier（防撞名）。
    /// 未找到返回 nil（no-sandbox entitlement 下可枚举该目录）。
    func locateEngineApp() -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.bundleAppsRoot) else {
            return nil
        }
        for uuid in entries {
            let appPath = Self.bundleAppsRoot + "/" + uuid + "/" + Self.engineAppName
            let plistPath = appPath + "/Info.plist"
            guard fm.fileExists(atPath: plistPath),
                  let info = NSDictionary(contentsOfFile: plistPath),
                  let bid = info["CFBundleIdentifier"] as? String else { continue }
            if bid == Self.engineBundleID { return appPath }
        }
        return nil
    }

    /// 状态机：notInstalled / installed / versionMismatch / corrupted
    func status() -> PythonEngineStatus {
        guard let appPath = locateEngineApp() else { return .notInstalled }
        guard let m = readManifest(in: appPath) else {
            return .corrupted(reason: "manifest.json 不可读")
        }
        guard fm.fileExists(atPath: Self.resolve(appPath, m.layout.dylib)) else {
            return .corrupted(reason: "dylib 缺失")
        }
        guard (Self.minEngineAPI...Self.maxEngineAPI).contains(m.apiVersion) else {
            return .versionMismatch(apiVersion: m.apiVersion)
        }
        return .installed
    }

    /// 已安装 Engine.app 的 manifest（可读即返回，供 UI 显示版本/构建号）
    func engineManifest() -> EngineManifest? {
        guard let appPath = locateEngineApp() else { return nil }
        return readManifest(in: appPath)
    }

    private func readManifest(in dir: String) -> EngineManifest? {
        guard let data = fm.contents(atPath: dir + "/manifest.json") else { return nil }
        return try? JSONDecoder().decode(EngineManifest.self, from: data)
    }

    /// manifest.layout 相对路径解析：先按「相对 Engine.app 根」直接拼；
    /// 不存在则剥掉「Engine.app/」前缀再拼（manifest 里的 layout 是相对仓库根的旧前缀，
    /// 相对 Engine.app 的实际路径要去掉该前缀）
    static func resolve(_ base: String, _ rel: String) -> String {
        let fm = FileManager.default
        let direct = base + "/" + rel
        if fm.fileExists(atPath: direct) { return direct }
        let stripped = rel.hasPrefix("Engine.app/") ? String(rel.dropFirst("Engine.app/".count)) : rel
        return base + "/" + stripped
    }

    // MARK: - 下载（tipa + sha256 sidecar → Documents/Downloads，安装交给 TrollStore）

    /// 下载引擎 .tipa 与同名 .sha256 sidecar 到 Documents/Downloads/，
    /// sha256 校验通过即完成（文件随 TrollStore 安装整包授信，App 侧不再逐文件校验）
    func downloadTipa(from tipaURL: URL,
                      completion: @escaping (Result<String, String>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion(.failure("已有任务进行中")) }
                return
            }
            self.beginBusy("下载引擎包…")
            self.appendOutput("开始下载：\(tipaURL.lastPathComponent)")
            do {
                let tipaPath = Self.tipaLocalPath
                let shaPath = tipaPath + ".sha256"
                try self.fm.createDirectory(atPath: (tipaPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)

                // ① tipa 与 .sha256 sidecar（CI 同名发布）。
                //    加时间戳查询参数穿透缓存：Release 资产 --clobber 更新后，同名 URL 可能被
                //    GitHub CDN / 用户代理缓存到旧文件，导致「新 sidecar + 旧包」哈希不匹配。
                guard tipaURL.absoluteString.hasSuffix(".tipa") else {
                    throw EngineFlowError(msg: "引擎包 URL 非 .tipa")
                }
                let tipaStr = tipaURL.absoluteString
                let bust = "?nc=\(Int(Date().timeIntervalSince1970))"
                guard let tipaBusted = URL(string: tipaStr + bust),
                      let shaBusted = URL(string: tipaStr + ".sha256" + bust) else {
                    throw EngineFlowError(msg: "URL 拼接失败")
                }
                try self.downloadFileSync(tipaBusted, to: tipaPath) { f in
                    DispatchQueue.main.async { self.downloadProgress = f }
                }
                try self.downloadFileSync(shaBusted, to: shaPath, progress: nil)

                // ② sha256 校验（CryptoKit 流式）。通过即完成——安装交给 TrollStore
                self.updateBusy("sha256 校验…")
                let expect = try Self.expectedSha256(sidecarPath: shaPath)
                let actual = try Self.fileSHA256(path: tipaPath)
                guard expect.lowercased() == actual.lowercased() else {
                    throw EngineFlowError(msg: "sha256 不匹配（期望 \(expect.prefix(12))…，实际 \(actual.prefix(12))…）")
                }
                self.appendOutput("sha256 校验通过：\(tipaPath)")
                self.appendOutput("下一步：点「用 TrollStore 安装」，装完 Engine.app 后回本页刷新状态并加载")
                self.endBusy()
                DispatchQueue.main.async { completion(.success(tipaPath)) }
            } catch {
                let msg = (error as? EngineFlowError)?.msg ?? error.localizedDescription
                self.appendOutput("下载失败：" + msg)
                self.endBusy()
                DispatchQueue.main.async { completion(.failure(msg)) }
            }
        }
    }

    /// 拉起 TrollStore 安装已下载的引擎 tipa。
    /// 复用 LocalUpdateView 同一条链路：本地 HTTP /sandbox 路由 + opener 守护 +
    /// apple-magnifier URL + 后台执行时间（不走 trollStoreInstallURL——其 /download 路由
    /// 映射的是公共 /var/mobile/Media/Downloads 且会剥掉子路径，tipa 在沙盒 Documents/Downloads）。
    func installViaTrollStore() {
        guard Self.tipaDownloaded else {
            appendOutput("未找到 \(Self.tipaFileName)，请先下载引擎包")
            return
        }
        KlineHTTPServer.shared.start()
        let dlURL = "http://127.0.0.1:\(KlineHTTPServer.shared.port)/sandbox/Downloads/\(Self.tipaFileName)"
        let trollURL = "apple-magnifier://install?url=\(dlURL.percentEncodedForQuery)"
        // 拉起 TrollStore 前先申请后台执行时间：否则 App 切后台被挂起后，
        // TrollStore 从 127.0.0.1 取文件连得上却收不到数据，安装卡死
        keepServingForInstall()
        KlineHTTPServer.shared.triggerTrollStoreInstall(trollURL: trollURL)
        appendOutput("已拉起 TrollStore 安装（\(Self.tipaFileName)）；装完回本页点「刷新状态」→「加载引擎」")
    }

    /// 拉起 TrollStore 前申请一段后台执行时间（写法对齐 LocalUpdateView.keepServingIPAForInstall）：
    /// App 会随 URL scheme 切后台，若被系统挂起，本地 HTTP 监听虽能被连上但没人回包。
    /// 到期自动释放，不影响正常后台行为。
    private func keepServingForInstall(seconds: Double = 30) {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "kline-serve-engine-tipa") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// 诊断：目录树转储（限预算防刷屏；目录带 / 后缀，文件带字节数）
    static func dumpTree(_ path: String, depth: Int, budget: Int) -> String {
        guard budget > 0 else { return "…（超出预算截断）" }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "(目录不可枚举: \(path))"
        }
        guard !items.isEmpty else { return "(空目录: \((path as NSString).lastPathComponent))" }
        var lines: [String] = []
        for name in items.sorted() {
            guard lines.count < budget else { lines.append("…"); break }
            let p = path + "/" + name
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue {
                lines.append(String(repeating: "  ", count: depth) + name + "/")
                lines.append(dumpTree(p, depth: depth + 1, budget: budget - lines.count))
            } else {
                let sz = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
                lines.append(String(repeating: "  ", count: depth) + name + " (\(sz) bytes)")
            }
        }
        return lines.joined(separator: "\n")
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

    // MARK: - 加载（定位 Engine.app → dlopen + Py_Initialize）

    /// dlopen Engine.app 内引擎 dylib → dlsym 三个最简 C API 符号 → setenv PYTHONHOME → Py_Initialize。
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
                DispatchQueue.main.async { completion(.failure("未安装 Engine.app（请先下载引擎包并用 TrollStore 安装）")) }
                return
            case .versionMismatch(let v):
                DispatchQueue.main.async {
                    completion(.failure("apiVersion=\(v) 超出兼容区间 [\(Self.minEngineAPI), \(Self.maxEngineAPI)]"))
                }
                return
            case .corrupted(let r):
                DispatchQueue.main.async {
                    completion(.failure("引擎损坏：\(r)——请在 TrollStore 内卸载 Engine.app 后重装"))
                }
                return
            }
            guard let appPath = self.locateEngineApp() else {
                DispatchQueue.main.async { completion(.failure("Engine.app 定位失败")) }
                return
            }
            guard let m = self.readManifest(in: appPath) else {
                DispatchQueue.main.async { completion(.failure("manifest 读取失败")) }
                return
            }
            let dylibPath = Self.resolve(appPath, m.layout.dylib)
            let homePath = Self.resolve(appPath, m.layout.home)

            self.beginBusy("dlopen 引擎…")
            let t0 = CFAbsoluteTimeGetCurrent()
            // RTLD_GLOBAL：后续 Python 扩展模块（_ssl/_socket 等）需要解析 libpython 符号
            guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
                var msg = "dlopen 失败"
                if let e = dlerror() { msg += "：" + String(cString: e) }
                self.appendOutput(msg + "（\(dylibPath)）")
                self.appendOutput("Engine.app 树：\n" + Self.dumpTree(appPath, depth: 0, budget: 30))
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

            // PYTHONHOME 是 **prefix** 语义：CPython 恒定在 <prefix>/lib/python3.14 找 stdlib
            // （platlibdir='lib'），我们无法改变它的查找方式，只能让布局与校验都对齐这个语义。
            // 鲁棒性硬规则：Py_Initialize 的 fatal abort 进程级不可捕获，stdlib 预检不过
            // 就必须在这里以可读错误返回，绝不触碰 init（否则就是闪退）。
            let stdlibDir = homePath + "/lib/python3.14"
            let landmarks = [
                ("encodings 包", stdlibDir + "/encodings/__init__.py"),
                ("os 模块", stdlibDir + "/os.py"),
                ("C 扩展目录", stdlibDir + "/lib-dynload"),
            ]
            var missing: [String] = []
            for (label, p) in landmarks where !self.fm.fileExists(atPath: p) {
                missing.append("\(label)（缺 \(p)）")
            }
            guard missing.isEmpty else {
                let msg = "stdlib 预检失败（home=\(homePath)）：" + missing.joined(separator: "；")
                    + "。Py_Initialize 未执行（避免闪退）——请检查引擎包布局或版本"
                self.appendOutput(msg)
                self.endBusy()
                DispatchQueue.main.async { completion(.failure(msg)) }
                return
            }
            self.appendOutput("stdlib 预检通过：\(stdlibDir)")

            // 初始化前设置 PYTHONHOME（值随引擎包 manifest 走，不硬编码；指向 Engine.app 内 stdlib prefix）
            setenv("PYTHONHOME", homePath, 1)
            self.appendOutput("PYTHONHOME=\(homePath)")

            // stderr 捕获：CPython stdlib 发现失败时 fatal error + abort（进程级闪退），
            // 死前信息全走 stderr——重定向到文件才能跨闪退取证
            if let f = fopen(Self.pyStderrPath, "a") {
                dup2(fileno(f), 2)
                fclose(f)
            }

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

    // MARK: - 子进程隔离执行（pyrunner，Phase-0 实验主链路）

    /// 经 pyrunner 子进程执行脚本：进程内 PyRun_SimpleString 曾发生零 stderr 原生段错误
    /// （直接闪退），故 Python 执行全部挪到独立子进程——引擎崩溃只死 pyrunner，App 不受影响。
    /// 前置只要求 Engine.app 已安装（pyrunner/dylib/home 都在其中）：解释器初始化由子进程自做，
    /// 进程内 loadEngine 的成功状态不再是实验前置（loadEngine 保留，仅用于进程内 init 计时）。
    ///
    /// spawn 说明：RootRunner.spawnDetached 以 root（persona 99 + uid/gid 0）detached 拉起
    /// pyrunner，不回读、不 waitpid，子进程孤儿化由 launchd 收养；App 进程内绝无任何
    /// Python 调用。计时从 spawn 前到读到 py_out.json（总耗时含子进程启动 + Py_Initialize，
    /// 这正是 Phase-0 要的「含隔离开销」数字）。
    func runScriptIsolated(_ body: String,
                           completion: @escaping (Result<(data: Data, totalMs: Double), String>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion(.failure("已有任务进行中")) }
                return
            }
            switch self.status() {
            case .installed:
                break
            case .notInstalled:
                DispatchQueue.main.async { completion(.failure("未安装引擎")) }
                return
            case .versionMismatch(let v):
                DispatchQueue.main.async {
                    completion(.failure("apiVersion=\(v) 超出兼容区间 [\(Self.minEngineAPI), \(Self.maxEngineAPI)]"))
                }
                return
            case .corrupted(let r):
                DispatchQueue.main.async {
                    completion(.failure("引擎损坏：\(r)——请在 TrollStore 内卸载 Engine.app 后重装"))
                }
                return
            }
            guard let appPath = self.locateEngineApp(),
                  let m = self.readManifest(in: appPath) else {
                DispatchQueue.main.async { completion(.failure("Engine.app 定位失败")) }
                return
            }
            let dylibPath = Self.resolve(appPath, m.layout.dylib)
            let homePath = Self.resolve(appPath, m.layout.home)
            let scriptPath = Self.pyScriptPath
            let outPath = Self.pyOutPath
            let stderrPath = Self.pyRunnerStderrPath

            self.beginBusy("pyrunner 运行脚本…")

            // ① 写脚本：复用 wrappedScript 包装（__kline_out__ base64 注入，防拼接注入）；
            //    先删旧输出/旧 stderr，轮询以「py_out.json 出现」为完成信号
            try? self.fm.removeItem(atPath: outPath)
            try? self.fm.removeItem(atPath: stderrPath)
            let script = Self.wrappedScript(body, outPath: outPath)
            do {
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            } catch {
                self.endBusy()
                DispatchQueue.main.async { completion(.failure("脚本写入失败：" + error.localizedDescription)) }
                return
            }

            // ③ 借道 opener 的 --py 模式（root detached）执行：opener 是 Kline.app 内
            //    已被证明可 exec 的受信二进制，而 Engine.app 内的二进制 exec 会被 AMFI SIGKILL
            //    （2026-10-04 实证）。dlopen Engine.app 内 libpython 则不受此限（App 内已成功）。
            //    opener 退出码：0=脚本成功 4=dlopen 失败 5=dlsym 失败 6/7=脚本读写失败；
            //    Python fatal abort 时进程死掉 → out 文件不出现 → 轮询超时（stderr 已重定向落盘）。
            let openerPath = Bundle.main.bundlePath + "/opener"
            guard self.fm.fileExists(atPath: openerPath) else {
                self.endBusy()
                DispatchQueue.main.async { completion(.failure("opener 不存在（构建异常）")) }
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let sr = RootRunner.spawnDetached(executable: openerPath,
                                              arguments: ["--py", dylibPath, homePath,
                                                          scriptPath, outPath, stderrPath])
            guard sr == 0 else {
                self.endBusy()
                DispatchQueue.main.async { completion(.failure("opener spawn 失败（sr=\(sr)）")) }
                return
            }

            // ④ 轮询 out 文件（每 200ms，上限 60s：含子进程 spawn + dlopen + init）
            let deadline = CFAbsoluteTimeGetCurrent() + 60.0
            while CFAbsoluteTimeGetCurrent() < deadline {
                if self.fm.fileExists(atPath: outPath) {
                    let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    guard let data = self.fm.contents(atPath: outPath) else {
                        self.endBusy()
                        DispatchQueue.main.async { completion(.failure("py_out.json 读取失败")) }
                        return
                    }
                    self.appendOutput(String(format: "opener --py 完成，总耗时 %.1fms（含子进程启动+init）", totalMs))
                    self.endBusy()
                    DispatchQueue.main.async { completion(.success((data, totalMs))) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            self.endBusy()
            let stderrTail = (self.fm.contents(atPath: stderrPath))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { $0.count > 400 ? String($0.suffix(400)) : $0 } ?? "(空)"
            DispatchQueue.main.async {
                completion(.failure("opener --py 超时（Python fatal abort，stderr 尾部：\n\(stderrTail)）"))
            }
        }
    }

    // MARK: - 排障：导出崩溃报告

    /// 把 /var/mobile/Library/Logs/CrashReporter 拷进 App Documents/crashlogs（排障用，
    /// 不做 UI 浏览——用户经既有沙盒/日志通道确认）。CrashReporter 属 root 受限目录，
    /// 走 root detached cp；cp 二进制在 iOS 上的路径不固定，依次尝试 /bin/cp、/usr/bin/cp。
    /// 注意 detached spawn 不等退出码，「已导出」仅代表已成功拉起 cp（结果看 Documents/crashlogs）。
    func exportCrashLogs(completion: @escaping (String) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion("有任务进行中，稍后再试") }
                return
            }
            self.beginBusy("导出崩溃报告…")
            let docs = self.fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = docs.appendingPathComponent("crashlogs").path
            try? self.fm.removeItem(atPath: dest)
            let candidates = ["/bin/cp", "/usr/bin/cp"]
            var spawned = false
            var existed = false
            var lastSr: Int32 = -1
            for cp in candidates {
                guard !spawned else { break }
                guard self.fm.fileExists(atPath: cp) else { continue }
                existed = true
                lastSr = RootRunner.spawnDetached(
                    executable: cp,
                    arguments: ["-R", "/var/mobile/Library/Logs/CrashReporter", dest])
                spawned = (lastSr == 0)
            }
            self.endBusy()
            DispatchQueue.main.async {
                if spawned {
                    let msg = "已导出到 Documents/crashlogs"
                    self.appendOutput(msg)
                    completion(msg)
                } else if !existed {
                    let msg = "导出失败：/bin/cp 与 /usr/bin/cp 均不存在"
                    self.appendOutput(msg)
                    completion(msg)
                } else {
                    let msg = "导出失败：cp 拉起失败（sr=\(lastSr)）"
                    self.appendOutput(msg)
                    completion(msg)
                }
            }
        }
    }

    // MARK: - 清理下载文件

    /// 删除已下载的 tipa 与 .sha256（Engine.app 本体由 TrollStore 管理，
    /// 卸载请在 TrollStore 内操作）。不做 Py_Finalize：进程内卸载不可靠，
    /// 已加载的解释器待下次启动 App 后才真正释放（UI 文案需说明）。
    func cleanDownloads(completion: @escaping (String) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.busy else {
                DispatchQueue.main.async { completion("有任务进行中，稍后再试") }
                return
            }
            var removed: [String] = []
            let tipaPath = Self.tipaLocalPath
            for p in [tipaPath, tipaPath + ".sha256"] where self.fm.fileExists(atPath: p) {
                try? self.fm.removeItem(atPath: p)
                removed.append((p as NSString).lastPathComponent)
            }
            let note = self.pyHandle != nil
                ? "；已加载的解释器进程内不卸载（dlclose 不可靠），重启 App 后彻底释放"
                : ""
            let msg = removed.isEmpty ? "无下载文件可删除" : "已删除：" + removed.joined(separator: "、") + note
            self.appendOutput("清理：" + msg)
            DispatchQueue.main.async { completion(msg) }
        }
    }
}

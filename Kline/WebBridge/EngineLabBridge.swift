//
//  EngineLabBridge.swift
//  Kline
//
//  Python 引擎实验室桥（协议 v2 lab.*）：P2-6c-1 PythonEngineLabView Web 化的 Swift 侧。
//  引擎下载/安装/加载与实验①-④只在本页触发，不进任何生产路径（Phase-0 契约不变）。
//
//  状态留原生：PythonEngineHost 单例（isBusy/busyText/downloadProgress/isLoaded/outputLines
//  全 @Published，objectWillChange 订阅节流推送）。实验脚本常量与编排逻辑从视图原样迁入
//  （结果文件路径经 base64 注入防拼接注入；实验经 pyrunner 子进程隔离执行）。
//
//  线程约定：动作入口均在主线程；host 完成回调统一 DispatchQueue.main.async 包裹后再
//  改 @Published / appendOutput（runScriptCapturingOutput 等回调可能来自工作队列）。
//

import Combine
import Foundation
import UIKit

@MainActor
final class EngineLabBridge: ObservableObject {

    static let shared = EngineLabBridge()

    private let host = PythonEngineHost.shared

    // MARK: - 状态区（由「刷新状态」与各操作完成后刷新）

    @Published private(set) var engineStatus: PythonEngineStatus = .notInstalled
    @Published private(set) var sourceText = "—"
    @Published private(set) var appPathText = "—"
    @Published private(set) var manifestText = "—"
    /// 当前运行中的实验编号（Web 端图标位转圈）
    @Published private(set) var runningExp = 0

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    /// host 状态/输出变化节流（下载进度与逐行输出都高频）
    private let changedThrottle: TimeInterval = 0.2

    private init() {
        host.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("status") }
            .store(in: &cancellables)
    }

    // MARK: - 生命周期

    func onOpen() {
        refreshStatus()
    }

    // MARK: - 变化信号 → lab.changed 推送

    private func scheduleChanged(_ reason: String) {
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("lab.changed", payload: ["reason": reason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "refresh":
            shared.refreshStatus()
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "download":
            shared.downloadEngine()
            return WebBridgeResponse.ok(request.id)
        case "install":
            shared.installEngine()
            return WebBridgeResponse.ok(request.id)
        case "loadEngine":
            shared.loadEngine()
            return WebBridgeResponse.ok(request.id)
        case "runExp":
            guard let id = (request.payload["id"] as? NSNumber)?.intValue, (1...4).contains(id) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "实验编号必须在 1~4")
            }
            switch id {
            case 1: shared.runExp1()
            case 2: shared.runExp2()
            case 3: shared.runExp3()
            default: shared.runExp4()
            }
            return WebBridgeResponse.ok(request.id)
        case "cleanDownloads":
            shared.cleanDownloads()
            return WebBridgeResponse.ok(request.id)
        case "exportCrash":
            shared.exportCrashLogs()
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "lab.\(request.action) 未实现")
        }
    }

    // MARK: - 状态刷新

    func refreshStatus() {
        engineStatus = host.status()
        let loc = host.locateEngineDir()
        if let src = loc?.source {
            switch src {
            case .embedded:  sourceText = "内嵌（随包）"
            case .engineApp: sourceText = "Engine.app"
            }
        } else {
            sourceText = "—"
        }
        appPathText = loc?.path ?? "—"
        if let m = host.engineManifest() {
            manifestText = "v\(m.engineVersion)（\(m.build)，api=\(m.apiVersion)）"
        } else {
            manifestText = "—"
        }
    }

    /// 状态行文案（对齐原生 statusText）
    static func statusText(_ st: PythonEngineStatus) -> String {
        switch st {
        case .notInstalled:
            return "未安装（请用 TrollStore 安装 Engine.app）"
        case .installed:
            return "已安装（可用）"
        case .versionMismatch(let v):
            return "版本不兼容（api=\(v)，App 支持 [\(PythonEngineHost.minEngineAPI), \(PythonEngineHost.maxEngineAPI)]）"
        case .corrupted(let r):
            return "损坏（\(r)）——请在 TrollStore 内卸载引擎后重装"
        }
    }

    // MARK: - 操作实现（下载 → 安装 → 加载 三段式）

    /// ① 下载 .tipa + .sha256（校验通过即完成，安装交给 TrollStore）
    private func downloadEngine() {
        host.downloadTipa(from: GitHubUpdateService.engineTipaURL) { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshStatus()
                self.scheduleChanged("status")
                if case .failure(let e) = r {
                    self.host.appendOutput("引擎包下载失败：" + e)
                }
            }
        }
    }

    /// ② 拉起 TrollStore 安装（复用 Kline.ipa 同一条本地 HTTP + opener 链路；装完手动回本页）
    private func installEngine() {
        host.installViaTrollStore()
    }

    /// ③ 从 Engine.app 安装路径 dlopen 并初始化解释器
    private func loadEngine() {
        host.loadEngine { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshStatus()
                self.scheduleChanged("status")
                switch r {
                case .success(let res):
                    self.host.appendOutput("引擎 v\(res.engineVersion)（\(res.build)）已就绪")
                case .failure(let e):
                    self.host.appendOutput("加载失败：" + e)
                }
            }
        }
    }

    /// 清理已下载的 tipa / .sha256（Engine.app 本体由 TrollStore 管理）
    private func cleanDownloads() {
        host.cleanDownloads { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshStatus()
                self.scheduleChanged("status")
            }
        }
    }

    /// 排障：把系统 CrashReporter 拷进 Documents/crashlogs（结果由 host appendOutput 到输出区）
    private func exportCrashLogs() {
        host.exportCrashLogs { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleChanged("output") }
        }
    }

    // MARK: - 快照组装

    static func snapshotData() -> [String: Any] {
        let b = shared
        let host = PythonEngineHost.shared
        return [
            "status": statusKey(b.engineStatus),
            "apiVersion": apiVersion(b.engineStatus),
            "statusText": statusText(b.engineStatus),
            "source": b.sourceText,
            "appPath": b.appPathText,
            "manifest": b.manifestText,
            "isLoaded": host.isLoaded,
            "isBusy": host.isBusy,
            "busyText": host.busyText,
            "downloadPercent": Int((host.downloadProgress * 100).rounded()),
            "runningExp": b.runningExp,
            "outputLines": host.outputLines,
        ]
    }

    private static func statusKey(_ st: PythonEngineStatus) -> String {
        switch st {
        case .notInstalled: return "notInstalled"
        case .installed: return "installed"
        case .versionMismatch: return "versionMismatch"
        case .corrupted: return "corrupted"
        }
    }

    private static func apiVersion(_ st: PythonEngineStatus) -> Any {
        if case .versionMismatch(let v) = st { return v }
        return NSNull()
    }

    // MARK: - 实验① 最小脚本（sys.version / platform 回读）

    /// 脚本常量（结果写到 __kline_out__，路径由宿主 base64 注入）
    private static let exp1Script = """
    import sys, platform, json
    open(__kline_out__, 'w').write(json.dumps({
        'version': sys.version,
        'platform': platform.platform(),
        'prefix': getattr(sys, 'prefix', ''),
    }))
    """

    private func runExp1() {
        runningExp = 1
        scheduleChanged("progress")
        host.runScriptCapturingOutput(Self.exp1Script) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, let host = self.hostRef() else { return }
                self.runningExp = 0
                self.refreshStatus()
                self.scheduleChanged("status")
                switch r {
                case .success(let out):
                    if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                        host.appendOutput(String(format: "实验① 完成，总耗时 %.1fms（含子进程启动+init 隔离开销）", out.totalMs))
                        host.appendOutput("sys.version：\(obj["version"] as? String ?? "?")")
                        host.appendOutput("platform：\(obj["platform"] as? String ?? "?")")
                        host.appendOutput("sys.prefix：\(obj["prefix"] as? String ?? "?")")
                    } else {
                        host.appendOutput("实验① 输出解析失败（py_out.json 非 JSON）")
                    }
                case .failure(let e):
                    host.appendOutput("实验① 失败：" + e)
                }
            }
        }
    }

    // MARK: - 实验② 150 根 OHLC：MA5/MA10/EMA12 纯 Python 计时

    /// 脚本常量：data 由 Swift 注入为 Python list 字面量（固定种子，只有数字，无注入面）
    private static let exp2Body = """
    import json, time
    def _ma(xs, n):
        out = []
        s = 0.0
        for i, v in enumerate(xs):
            s += v
            if i >= n:
                s -= xs[i - n]
            out.append(s / n if i >= n - 1 else None)
        return out
    def _ema(xs, n):
        k = 2.0 / (n + 1)
        out = [xs[0]]
        for i in range(1, len(xs)):
            out.append(xs[i] * k + out[-1] * (1.0 - k))
        return out
    closes = [d[3] for d in data]
    t0 = time.perf_counter()
    ma5 = _ma(closes, 5)
    ma10 = _ma(closes, 10)
    ema12 = _ema(closes, 12)
    t1 = time.perf_counter()
    open(__kline_out__, 'w').write(json.dumps({
        'bars': len(data),
        'pure_ms': (t1 - t0) * 1000.0,
        'ma5_at_100': ma5[99],
        'ma10_at_100': ma10[99],
        'ema12_last': ema12[-1],
    }))
    """

    /// 固定种子生成 150 根随机 OHLCV，拼成 Python list 字面量
    private static func makeBarLiteral(bars: Int = 150, seed: UInt64 = 20261004) -> String {
        var x = seed
        func rnd() -> Double {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Double((x >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
        }
        var price = 100.0
        var rows: [String] = []
        rows.reserveCapacity(bars)
        for _ in 0..<bars {
            let o = price
            let c = max(1.0, o * (1 + (rnd() - 0.5) * 0.04))
            let h = max(o, c) * (1 + rnd() * 0.01)
            let l = min(o, c) * (1 - rnd() * 0.01)
            let v = Int(rnd() * 900_000) + 100_000
            rows.append(String(format: "[%.4f,%.4f,%.4f,%.4f,%d]", o, h, l, c, v))
            price = c
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    private func runExp2() {
        runningExp = 2
        scheduleChanged("progress")
        let t0 = CFAbsoluteTimeGetCurrent()
        let literal = Self.makeBarLiteral()
        let genMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let script = "data = " + literal + "\n" + Self.exp2Body
        host.runScriptCapturingOutput(script) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, let host = self.hostRef() else { return }
                self.runningExp = 0
                self.refreshStatus()
                self.scheduleChanged("status")
                switch r {
                case .success(let out):
                    if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                        host.appendOutput(String(format: "实验② 总耗时 %.1fms（含隔离开销；Swift 生成数据 %.2fms）",
                                                 out.totalMs, genMs))
                        host.appendOutput(String(format: "纯计算 %.2fms（%d 根，MA5/MA10/EMA12 各一遍）",
                                                 obj["pure_ms"] as? Double ?? -1,
                                                 obj["bars"] as? Int ?? 0))
                        host.appendOutput(String(format: "抽样：MA5@100=%.4f MA10@100=%.4f EMA12末=%.4f",
                                                 obj["ma5_at_100"] as? Double ?? -1,
                                                 obj["ma10_at_100"] as? Double ?? -1,
                                                 obj["ema12_last"] as? Double ?? -1))
                    } else {
                        host.appendOutput("实验② 输出解析失败")
                    }
                case .failure(let e):
                    host.appendOutput("实验② 失败：" + e)
                }
            }
        }
    }

    // MARK: - 实验③ 并发吞吐（ThreadPoolExecutor + urllib，请求量保持小：约 20 次）

    /// 脚本常量：8 线程并发请求腾讯快照（一股一请求，共 20 次，避免触发限流）。
    /// 整体 try/except 自捕获；单请求自捕获 + 1 次重试（对齐生产 GapBackfill 重试语义）。
    private static let exp3Script = """
    import json, time, traceback, urllib.request
    from concurrent.futures import ThreadPoolExecutor
    # 禁用系统代理：设备侧直连行情源（项目硬约束）；VPN/HTTP 代理会劫持或拖慢国内直连请求
    _opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    codes = ['sh600000','sz000001','sh000001','sh600036','sz000002','sh600519',
             'sz000858','sh601318','sh601988','sz000651','sh600030','sz002415',
             'sh600887','sz002304','sh601899','sh600900','sh601166','sh600016',
             'sz000333','sh600276']
    result = {'reqs': len(codes), 'errors': []}
    try:
        def _fetch(c):
            last = None
            for _attempt in range(2):
                try:
                    with _opener.open('http://qt.gtimg.cn/q=' + c, timeout=5) as r:
                        return len(r.read())
                except Exception as e:
                    last = e
                    time.sleep(0.2)
            result['errors'].append(c + ':' + type(last).__name__)
            return -1
        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=8) as ex:
            sizes = list(ex.map(_fetch, codes))
        t1 = time.perf_counter()
        el = t1 - t0
        result['ok'] = sum(1 for s in sizes if s >= 0)
        result['total_ms'] = el * 1000.0
        result['rps'] = (len(codes) / el) if el > 0 else 0.0
    except Exception:
        result['error'] = traceback.format_exc()
    open(__kline_out__, 'w').write(json.dumps(result))
    """

    private func runExp3() {
        runningExp = 3
        scheduleChanged("progress")
        host.runScriptCapturingOutput(Self.exp3Script) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, let host = self.hostRef() else { return }
                self.runningExp = 0
                self.refreshStatus()
                self.scheduleChanged("status")
                switch r {
                case .success(let out):
                    if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                        if let err = obj["error"] as? String {
                            host.appendOutput("实验③ 失败（脚本内异常）：\n" + err)
                        } else {
                            let ok = obj["ok"] as? Int ?? 0
                            let reqs = obj["reqs"] as? Int ?? 0
                            let errors = obj["errors"] as? [String] ?? []
                            host.appendOutput(String(format: "实验③ 完成：%d/%d 次成功（失败 %d，含重试），总耗时 %.0fms，吞吐 %.1f req/s",
                                                     ok, reqs, reqs - ok,
                                                     obj["total_ms"] as? Double ?? -1,
                                                     obj["rps"] as? Double ?? -1))
                            if !errors.isEmpty {
                                host.appendOutput("重试后仍失败：" + errors.joined(separator: ", "))
                            }
                        }
                    } else {
                        host.appendOutput("实验③ 输出解析失败（网络/SSL 异常见日志）")
                    }
                case .failure(let e):
                    host.appendOutput("实验③ 失败：" + e)
                }
            }
        }
    }

    // MARK: - 实验④ 首帧端到端（进程内桥接；与 PyBridgeFirstFramePerfTests 同口径）

    /// 进程物理内存足迹（phys_footprint，jetsam 口径，比 RSS 严格）
    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    /// 固定种子 150 根 OHLC（与 PyBridgeFirstFramePerfTests.makeBars 同 LCG，跨端可比）
    private static func makePerfBars(_ n: Int = 150, seed: UInt64 = 20261012) -> [[Double]] {
        var x = seed
        func rnd() -> Double {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Double((x >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
        }
        var price = 100.0
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        for _ in 0..<n {
            let o = price
            let c = max(1.0, o * (1 + (rnd() - 0.5) * 0.04))
            let h = max(o, c) * (1 + rnd() * 0.01)
            let l = min(o, c) * (1 - rnd() * 0.01)
            rows.append([o, h, l, c])
            price = c
        }
        return rows
    }

    /// 实验④：A-① ensureReady（引擎加载）→ A-② 首调 mytt（numpy import，一次性）
    /// → B 稳态 20 次 150 根 MA/EMA/MACD 端到端（blockingCall 全程）→ 内存增量 → 判定。
    /// 判据：稳态 median < 16ms（60fps 一帧）理想；< 33ms（30fps）可用上限；≥ 33ms 红线维持。
    private func runExp4() {
        runningExp = 4
        scheduleChanged("progress")
        let bridge = KlinePythonBridge.shared
        let wasLoaded = bridge.isReady
        let t0 = CFAbsoluteTimeGetCurrent()
        bridge.ensureReady { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let host = self.hostRef() else { return }
                switch result {
                case .failure(let e):
                    self.runningExp = 0
                    host.appendOutput("实验④ 失败：引擎未就绪（\(e)）——需先安装/加载引擎")
                    self.scheduleChanged("status")
                case .success:
                    if wasLoaded {
                        host.appendOutput("实验④ A-① ensureReady：已就绪（本次未测加载耗时；重启 App 后立即跑可测真实值）")
                    } else {
                        host.appendOutput(String(format: "实验④ A-① ensureReady：%.0fms（dlopen + Py_Initialize；重估后为启动后台预热项）",
                                                 (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                    }
                    let mem1 = Self.physFootprintMB()
                    // 后台线程跑首调 + 稳态（blockingCall 禁主线程）
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self, let host = self.hostRef() else { return }
                        let bars = Self.makePerfBars()
                        let series: [String: [Double]] = [
                            "open": bars.map { $0[0] },
                            "high": bars.map { $0[1] },
                            "low": bars.map { $0[2] },
                            "close": bars.map { $0[3] },
                        ]
                        // args：序列直接用 series 键名；"$id" 是前序结果引用（勿混）
                        let calls: [[String: Any]] = [
                            ["fn": "MA", "args": ["close", 5]],
                            ["fn": "MA", "args": ["close", 10]],
                            ["fn": "EMA", "args": ["close", 12]],
                            ["fn": "MACD", "args": ["close", 12, 26, 9]],
                        ]
                        let input: [String: Any] = ["op": "functions", "series": series, "calls": calls]

                        // A-② 首调（含 numpy import + 模块加载，一次性；A8 设备可能数秒，属正常）
                        let tf = CFAbsoluteTimeGetCurrent()
                        let first = bridge.blockingCall(script: "mytt", input: input, timeout: 60)
                        let firstMs = (CFAbsoluteTimeGetCurrent() - tf) * 1000
                        guard case .success = first else {
                            DispatchQueue.main.async {
                                host.appendOutput("实验④ 失败：首调 mytt 失败（\(first)）——引擎就绪后失败属真实缺陷")
                                self.runningExp = 0
                                self.scheduleChanged("status")
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            host.appendOutput(String(format: "实验④ A-② 首调 mytt：%.0fms（numpy import + 模块加载，一次性；若此前跑过 mytt 则为稳态值）", firstMs))
                        }
                        let mem2 = Self.physFootprintMB()

                        // B 稳态 20 次端到端
                        var samples: [Double] = []
                        var steadyFail = ""
                        for _ in 0..<20 {
                            let t = CFAbsoluteTimeGetCurrent()
                            let r = bridge.blockingCall(script: "mytt", input: input, timeout: 30)
                            samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                            if case .failure(let e) = r {
                                steadyFail = "\(e)"
                                break
                            }
                        }
                        if !steadyFail.isEmpty {
                            DispatchQueue.main.async {
                                host.appendOutput("实验④ 失败：稳态调用失败（\(steadyFail)）")
                                self.runningExp = 0
                                self.scheduleChanged("status")
                            }
                            return
                        }
                        let sorted = samples.sorted()
                        let sMin = sorted[0], median = (sorted[9] + sorted[10]) / 2
                        let p95 = sorted[18], sMax = sorted[19]
                        DispatchQueue.main.async {
                            host.appendOutput(String(format: "实验④ B 稳态端到端（150根 MA5/MA10/EMA12/MACD，20 次）：min=%.1f median=%.1f p95=%.1f max=%.1f ms",
                                                     sMin, median, p95, sMax))
                            let mem3 = Self.physFootprintMB()
                            host.appendOutput(String(format: "实验④ 内存 phys_footprint：引擎后 %.1fMB → numpy 后 %.1fMB（增量 %.1fMB）→ 稳态 %.1fMB（稳态增量 %.1fMB）",
                                                     mem1, mem2, mem2 - mem1, mem3, mem3 - mem2))
                            let verdict: String
                            if median < 16 {
                                verdict = "稳态 median < 16ms（60fps 一帧预算）——阈值化条件满足，红线可重估"
                            } else if median < 33 {
                                verdict = "稳态 median < 33ms（30fps 一帧）——勉强可用，需结合单屏指标数与并帧预算评估"
                            } else {
                                verdict = "稳态 median ≥ 33ms——首帧红线维持"
                            }
                            host.appendOutput("实验④ 判定：" + verdict + "（对照模拟器 median 14.2ms；结果已同步落沙盒日志）")
                            self.runningExp = 0
                            self.scheduleChanged("status")
                        }
                    }
                }
            }
        }
    }

    /// host 强引用（闭包内防 host 释放；单例实际常驻）
    private func hostRef() -> PythonEngineHost? { PythonEngineHost.shared }
}

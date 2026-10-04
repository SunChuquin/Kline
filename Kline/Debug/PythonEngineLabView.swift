//
//  PythonEngineLabView.swift
//  Kline
//
//  Phase-0 Stage B：Python 引擎实验室（纯调试页，引擎不进 IPA）。
//  契约：.trae/documents/python-engine/Phase-0引擎实验-plan.md
//
//  - 引擎下载/加载只在本页按钮触发时发生，不进任何生产路径
//  - 行式布局与语义化颜色对齐 LocalUpdateView（48pt 行高、16pt 左右 padding、
//    secondarySystemBackground + 12 圆角，深浅色自适应）
//  - 实验脚本全部为常量；只有「结果文件路径」经 base64 传入脚本（防拼接注入）
//

import SwiftUI
import Foundation

/// Phase-0 Python 引擎实验室（仅 DEBUG 构建从个人中心进入）
struct PythonEngineLabView: View {

    /// 全屏 overlay 关闭回调（个人中心无 NavigationStack，页面跳转走既有 overlay 模式）
    var onClose: () -> Void

    @StateObject private var host = PythonEngineHost.shared

    /// 引擎包下载地址（GitHub Release 独立通道 tag engine-3.14.7，与 IPA 的 latest 互不干扰）
    private static let engineTarURL =
        URL(string: "https://github.com/SunChuquin/Kline/releases/download/engine-3.14.7/KlineEngine-3.14.7.tar.gz")!

    // 状态区（由「刷新状态」与各操作完成后刷新，避免每次渲染扫盘）
    @State private var engineStatus: PythonEngineStatus = .notInstalled
    @State private var manifestVersionText = "—"
    /// 当前运行中的实验编号（用于图标位转圈）
    @State private var runningExp = 0

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusSection
                    actionSection
                    outputSection
                }
                .padding()
            }
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（与个人中心同做法）
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { refreshStatus() }
    }

    // MARK: - 导航栏（与个人中心同款）

    private var navBar: some View {
        HStack {
            Button(action: { onClose() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24))
            }
            .padding(.leading, 16)

            Text("Python 引擎实验室")
                .font(.title)
                .fontWeight(.bold)

            Spacer()
        }
        .background(Color(.systemBackground))
        .frame(height: 56)
    }

    // MARK: - 状态区

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("引擎状态")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            VStack(spacing: 0) {
                // 刷新状态（整行可点，命中区 48pt ≥ 44pt）
                Button(action: { refreshStatus() }) {
                    HStack(spacing: 10) {
                        Text("刷新状态")
                            .font(.system(size: 16))
                            .foregroundColor(Color.primary)
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                            .frame(width: 24, height: 24)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(host.isBusy)

                Divider()

                infoRow(title: "当前状态", value: statusText(engineStatus), valueColor: statusColor(engineStatus))
                Divider()
                infoRow(title: "引擎版本", value: manifestVersionText)
                Divider()
                infoRow(title: "解释器", value: host.isLoaded ? "已加载（进程内常驻）" : "未加载",
                        valueColor: host.isLoaded ? .green : Color(.secondaryLabel))
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            if host.isBusy {
                // 忙指示：说明当前阶段 + 下载/解压进度，避免用户以为卡死
                HStack(spacing: 10) {
                    ProgressView()
                    Text(host.busyText)
                        .font(.system(size: 13))
                        .foregroundColor(Color(.secondaryLabel))
                    if host.busyText.hasPrefix("下载引擎包") {
                        Text("\(Int(host.downloadProgress * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                if host.busyText.hasPrefix("解压") {
                    ProgressView(value: host.extractProgress)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - 操作区

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("操作")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            VStack(spacing: 0) {
                // 下载引擎包（GitHub Release）：进行中图标位换成进度圈/百分比
                Button(action: { downloadEngine() }) {
                    HStack(spacing: 10) {
                        Text("下载引擎包（GitHub Release）")
                            .font(.system(size: 16))
                            .foregroundColor(host.isBusy ? Color.gray : Color.primary)
                        Spacer(minLength: 12)
                        downloadIcon
                            .frame(width: 24, height: 24)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(host.isBusy)

                Divider()

                actionRow(title: "加载引擎（dlopen + 初始化）",
                          systemImage: "play.circle",
                          enabled: !host.isBusy && engineStatus == .installed && !host.isLoaded,
                          showSpinner: host.isBusy && (host.busyText.hasPrefix("dlopen") || host.busyText.hasPrefix("Py_Initialize"))) {
                    loadEngine()
                }

                Divider()

                actionRow(title: "实验① 最小脚本",
                          systemImage: "1.circle",
                          enabled: !host.isBusy && host.isLoaded,
                          showSpinner: host.isBusy && host.busyText == "运行脚本…" && runningExp == 1) {
                    runExp1()
                }

                Divider()

                actionRow(title: "实验② 冷启动与150根计时",
                          systemImage: "2.circle",
                          enabled: !host.isBusy && host.isLoaded,
                          showSpinner: host.isBusy && host.busyText == "运行脚本…" && runningExp == 2) {
                    runExp2()
                }

                Divider()

                actionRow(title: "实验③ 并发吞吐",
                          systemImage: "3.circle",
                          enabled: !host.isBusy && host.isLoaded,
                          showSpinner: host.isBusy && host.busyText == "运行脚本…" && runningExp == 3) {
                    runExp3()
                }

                Divider()

                actionRow(title: "重置（删除引擎文件）",
                          systemImage: "trash",
                          tint: .red,
                          enabled: !host.isBusy) {
                    resetEngine()
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // 重置语义说明（卸载不可靠，必须讲清）
            Text("重置只删除引擎文件（active/staging/下载缓存）；已加载的解释器在下次启动 App 后才真正释放。")
                .font(.system(size: 12))
                .foregroundColor(Color.gray.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }

    /// 下载行图标位：下载中 = 进度圈 + 百分比，其它忙碌 = 转圈，空闲 = 下载图标
    @ViewBuilder
    private var downloadIcon: some View {
        if host.isBusy && host.busyText.hasPrefix("下载引擎包") {
            ZStack {
                Circle()
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, host.downloadProgress)))
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(host.downloadProgress * 100))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else if host.isBusy {
            ProgressView()
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundColor(.blue)
        }
    }

    /// 通用操作行（48pt 行高，图标位固定 24x24，布局不随状态变形）
    private func actionRow(title: String, systemImage: String,
                           tint: Color = .blue,
                           enabled: Bool,
                           showSpinner: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(enabled ? Color.primary : Color.gray)
                Spacer(minLength: 12)
                if showSpinner {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                        .foregroundColor(enabled ? tint : Color.gray)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 只读信息行（与 LocalUpdateView 同规格，行高固定 48）
    private func infoRow(title: String, value: String, valueColor: Color = Color(.secondaryLabel)) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15))
                .foregroundColor(valueColor)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }

    // MARK: - 结果输出区（等宽字体逐行展示）

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("结果输出")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if host.outputLines.isEmpty {
                            Text("（暂无输出）")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(.tertiaryLabel))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(host.outputLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(.secondaryLabel))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 280)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .onChange(of: host.outputLines.count) { _ in
                    proxy.scrollTo(max(0, host.outputLines.count - 1), anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 状态文案与配色

    private func statusText(_ st: PythonEngineStatus) -> String {
        switch st {
        case .notInstalled:
            return "未安装"
        case .installed:
            return "已安装（可用）"
        case .versionMismatch(let v):
            return "版本不兼容（api=\(v)，App 支持 [\(PythonEngineHost.minEngineAPI), \(PythonEngineHost.maxEngineAPI)]）"
        case .corrupted(let r):
            return "损坏（\(r)）"
        }
    }

    private func statusColor(_ st: PythonEngineStatus) -> Color {
        switch st {
        case .notInstalled:      return .gray
        case .installed:         return .green
        case .versionMismatch:   return .yellow
        case .corrupted:         return .red
        }
    }

    private func refreshStatus() {
        engineStatus = host.status()
        if let m = host.activeManifest() {
            manifestVersionText = "v\(m.engineVersion)（\(m.build)，api=\(m.apiVersion)）"
        } else {
            manifestVersionText = "—"
        }
    }

    // MARK: - 操作实现

    private func downloadEngine() {
        host.downloadAndActivate(from: Self.engineTarURL) { [weak host] r in
            refreshStatus()
            if case .failure(let e) = r {
                host?.appendOutput("引擎包下载/激活失败：" + e)
            }
        }
    }

    private func loadEngine() {
        host.loadEngine { [weak host] r in
            refreshStatus()
            switch r {
            case .success(let res):
                host?.appendOutput("引擎 v\(res.engineVersion)（\(res.build)）已就绪")
            case .failure(let e):
                host?.appendOutput("加载失败：" + e)
            }
        }
    }

    private func resetEngine() {
        host.resetEngine { [weak host] msg in
            refreshStatus()
            host?.appendOutput("重置完成：" + msg)
        }
    }

    // MARK: 实验① 最小脚本（sys.version / platform 回读）

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
        host.runScriptCapturingOutput(Self.exp1Script) { [weak host] r in
            runningExp = 0
            refreshStatus()
            guard let host = host else { return }
            switch r {
            case .success(let out):
                if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                    host.appendOutput(String(format: "实验① 完成，总耗时 %.1fms", out.totalMs))
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

    // MARK: 实验② 150 根 OHLC：MA5/MA10/EMA12 纯 Python 计时

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
        let t0 = CFAbsoluteTimeGetCurrent()
        let literal = Self.makeBarLiteral()
        let genMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let script = "data = " + literal + "\n" + Self.exp2Body
        host.runScriptCapturingOutput(script) { [weak host] r in
            runningExp = 0
            refreshStatus()
            guard let host = host else { return }
            switch r {
            case .success(let out):
                if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                    host.appendOutput(String(format: "实验② 总耗时 %.1fms（Swift 生成数据 %.2fms）",
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

    // MARK: 实验③ 并发吞吐（ThreadPoolExecutor + urllib，请求量保持小：约 20 次）

    /// 脚本常量：8 线程并发请求腾讯快照（一股一请求，共 20 次，避免触发限流）
    private static let exp3Script = """
    import json, time, urllib.request
    from concurrent.futures import ThreadPoolExecutor
    codes = ['sh600000','sz000001','sh000001','sh600036','sz000002','sh600519',
             'sz000858','sh601318','sh601988','sz000651','sh600030','sz002415',
             'sh600887','sz002304','sh601899','sh600900','sh601166','sh600016',
             'sz000333','sh600276']
    def _fetch(c):
        with urllib.request.urlopen('https://qt.gtimg.cn/q=' + c, timeout=10) as r:
            return len(r.read())
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=8) as ex:
        sizes = list(ex.map(_fetch, codes))
    t1 = time.perf_counter()
    el = t1 - t0
    open(__kline_out__, 'w').write(json.dumps({
        'reqs': len(codes),
        'ok': len(sizes),
        'total_ms': el * 1000.0,
        'rps': (len(codes) / el) if el > 0 else 0.0,
    }))
    """

    private func runExp3() {
        runningExp = 3
        host.runScriptCapturingOutput(Self.exp3Script) { [weak host] r in
            runningExp = 0
            refreshStatus()
            guard let host = host else { return }
            switch r {
            case .success(let out):
                if let obj = (try? JSONSerialization.jsonObject(with: out.data)) as? [String: Any] {
                    host.appendOutput(String(format: "实验③ 完成：%d/%d 次成功，总耗时 %.0fms，吞吐 %.1f req/s",
                                             obj["ok"] as? Int ?? 0,
                                             obj["reqs"] as? Int ?? 0,
                                             obj["total_ms"] as? Double ?? -1,
                                             obj["rps"] as? Double ?? -1))
                } else {
                    host.appendOutput("实验③ 输出解析失败（网络/SSL 异常见日志）")
                }
            case .failure(let e):
                host.appendOutput("实验③ 失败：" + e)
            }
        }
    }
}

//
//  GitHubRemoteUpdate.swift
//  Kline
//
//  Created on 2026/9/16.
//

import Foundation
import CryptoKit

// MARK: - 远程更新（GitHub Release 最新构建 IPA）

/// GitHub 最新 release 的信息（App 端据此判断是否有新版本）
struct GitHubReleaseInfo {
    /// Release 说明里的构建号（= GitHub run number），解析失败为 nil
    var buildNumber: Int?
    /// 发布时间本地化短格式（如 "09-16 08:30"）
    var publishedText: String?
    /// Kline.ipa 资产的官方 sha256（GitHub API assets[].digest，"sha256:hex" 去前缀；缺失为 nil）
    var ipaSHA256: String?
}

/// GitHub Release 查询与 IPA 下载（公开仓库，无需鉴权）。
///
/// CI（build.yml）每次构建后把 IPA 发布到单一 latest Release，
/// App 端经 /releases/latest 拿到最新构建号（releases/latest/download/Kline.ipa 为免鉴权稳定地址）。
enum GitHubUpdateService {
    static let repoOwner = "SunChuquin"
    static let repoName = "Kline"

    /// 最新 release 的 JSON 信息接口（公开免鉴权）
    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }
    /// 最新 IPA 稳定下载地址（公开免鉴权，重定向到 CDN 签名 URL）
    static var latestIpaURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/Kline.ipa")!
    }

    /// 当前已安装版本的构建号（CFBundleVersion = CI 注入的 GitHub run number）
    static var currentBuildNumber: Int? {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// 下载产物落地路径：沙盒 Documents/Downloads/Kline.ipa（App 容器内必然可写）。
    /// 与 USB 部署链路 /install-local(scope=sandbox) 的
    /// `/sandbox/Downloads` 一致；不要写公共 Downloads（跨容器 rename 会 EPERM）。
    static var targetIpaPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        return docs + "/Downloads/Kline.ipa"
    }

    /// 查询最新 release。completion 在主线程回调：(info, errorMessage) 互斥，主线程无需再切。
    static func fetchLatestRelease(completion: @escaping (GitHubReleaseInfo?, String?) -> Void) {
        var req = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err {
                    completion(nil, err.localizedDescription)
                    return
                }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(nil, "响应解析失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
                    return
                }
                // 构建号提取：优先 notes 里的 "#N"（gh release --notes 写入），title/tag 兜底
                let body = obj["body"] as? String ?? ""
                let title = obj["name"] as? String ?? ""
                let tag = obj["tag_name"] as? String ?? ""
                var num: Int?
                for src in [body, title, tag] {
                    if let r = src.range(of: #"#\d+"#, options: .regularExpression) {
                        num = Int(src[r].dropFirst())
                        break
                    }
                }
                // Kline.ipa 资产的官方 sha256（assets[].digest 形如 "sha256:hex..."）：
                // 下载完成后据此做完整性校验（防 CDN 缓存旧包/代理截断——TrollStore 解包失败的根因）
                var ipaSHA256: String?
                if let assets = obj["assets"] as? [[String: Any]] {
                    for a in assets where (a["name"] as? String) == "Kline.ipa" {
                        if let digest = a["digest"] as? String, digest.hasPrefix("sha256:") {
                            ipaSHA256 = String(digest.dropFirst("sha256:".count)).lowercased()
                        }
                        break
                    }
                }
                var publishedText: String?
                if let iso = obj["published_at"] as? String,
                   let d = ISO8601DateFormatter().date(from: iso) {
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    publishedText = f.string(from: d)
                }
                completion(GitHubReleaseInfo(buildNumber: num, publishedText: publishedText, ipaSHA256: ipaSHA256), nil)
            }
        }.resume()
    }

    /// 下载最新 IPA 到沙盒 Documents/Downloads（App 容器内，必然可写）。
    /// - URL 带时间戳穿透参数：--clobber 同名资产后 GitHub CDN 边缘可能仍回旧包/混合内容
    ///   （引擎 .tipa 链路同款教训），`?t=` 强制回源。
    /// - 落地后完整性校验：ZIP 魔数 + sha256（expectedSHA256 来自 release assets[].digest），
    ///   不合格即删除报错，绝不把坏包递给 TrollStore（此前「failed to extract ipa file」的根因）。
    /// progress 在主线程回调 0~1；completion:(sizeBytes, errorMessage) 互斥，主线程回调。
    static func downloadLatestIPA(expectedSHA256: String? = nil,
                                  progress: @escaping (Double) -> Void,
                                  completion: @escaping (Int64?, String?) -> Void) {
        let target = targetIpaPath
        let parent = (target as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.removeItem(atPath: target)
        }

        // 稳定地址加时间戳穿透（重定向到 CDN 签名 URL，query 透传）
        let busted = latestIpaURL.absoluteString + "?t=\(Int(Date().timeIntervalSince1970))"
        let url = URL(string: busted) ?? latestIpaURL

        // ephemeral 会话：不缓存 IPA；downloadTask 直接落盘临时文件
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: url) { tmpURL, resp, err in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                if let err = err {
                    completion(nil, err.localizedDescription)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard let tmp = tmpURL, (200..<300).contains(status) else {
                    completion(nil, "HTTP \(status)")
                    return
                }
                do {
                    // tmp（CFNetwork 临时文件）与目标同在 App 容器内，rename 应成功；极端情况退回拷贝
                    let targetURL = URL(fileURLWithPath: target)
                    do {
                        try FileManager.default.moveItem(at: tmp, to: targetURL)
                    } catch {
                        try FileManager.default.copyItem(at: tmp, to: targetURL)
                        try? FileManager.default.removeItem(at: tmp)   // 拷贝成功后清理临时文件
                    }
                    // 完整性校验：不过关删除文件并报可读错误（调用方保持 .failed，可重试）
                    if let problem = Self.integrityProblem(at: target, expectedSHA256: expectedSHA256) {
                        try? FileManager.default.removeItem(atPath: target)
                        completion(nil, problem)
                        return
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? Int64 ?? 0
                    completion(size, nil)
                } catch {
                    completion(nil, error.localizedDescription)
                }
            }
        }
        // 进度采样：downloadTask.progress 无进度回调，用定时器逐帧读取（前台下载，假定不切后台）
        var poll: Timer?
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            progress(task.progress.fractionCompleted)
            if task.progress.isFinished || task.progress.isCancelled {
                poll?.invalidate()
            }
        }
        task.resume()
    }

    /// 下载落地文件的完整性校验：返回 nil = 通过；否则返回可读问题文案。
    /// ① ZIP 魔数 PK\x03\x04（拦代理劫持返回的 HTML 错误页）；② 大小下限；③ sha256 精确比对。
    static func integrityProblem(at path: String, expectedSHA256: String?) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "下载文件不可读" }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else {
            return "下载文件过小（可能是空响应或代理错误页）"
        }
        guard head.prefix(2) == Data("PK".utf8) else {
            return "下载内容不是 IPA（ZIP 魔数不符——疑似代理劫持/CDN 错误页）"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
        guard size > 1_000_000 else {
            return "下载文件异常（\(size) 字节，疑似截断）"
        }
        guard let expected = expectedSHA256?.lowercased(), !expected.isEmpty else { return nil }
        guard let actual = Self.fileSHA256(path: path) else { return "sha256 计算失败" }
        guard actual == expected else {
            return "sha256 不匹配（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…——下载不完整，请重试）"
        }
        return nil
    }

    /// 文件 sha256（CryptoKit 流式，写法对齐 PythonEngineHost.fileSHA256）
    static func fileSHA256(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
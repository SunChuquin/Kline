//
//  GitHubRemoteUpdate.swift
//  Kline
//
//  Created on 2026/9/16.
//

import Foundation

// MARK: - 远程更新（GitHub Release 最新构建 IPA）

/// GitHub 最新 release 的信息（App 端据此判断是否有新版本）
struct GitHubReleaseInfo {
    /// Release 说明里的构建号（= GitHub run number），解析失败为 nil
    var buildNumber: Int?
    /// 发布时间本地化短格式（如 "09-16 08:30"）
    var publishedText: String?
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
    /// 与 USB 部署链路 /install-local(scope=sandbox) 及本地更新页 shareIPA 的
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
                var publishedText: String?
                if let iso = obj["published_at"] as? String,
                   let d = ISO8601DateFormatter().date(from: iso) {
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    publishedText = f.string(from: d)
                }
                completion(GitHubReleaseInfo(buildNumber: num, publishedText: publishedText), nil)
            }
        }.resume()
    }

    /// 下载最新 IPA 到沙盒 Documents/Downloads（App 容器内，必然可写）。
    /// progress 在主线程回调 0~1；completion:(sizeBytes, errorMessage) 互斥，主线程回调。
    static func downloadLatestIPA(progress: @escaping (Double) -> Void,
                                  completion: @escaping (Int64?, String?) -> Void) {
        let target = targetIpaPath
        let parent = (target as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.removeItem(atPath: target)
        }

        // ephemeral 会话：不缓存 IPA；downloadTask 直接落盘临时文件
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: latestIpaURL) { tmpURL, resp, err in
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
}
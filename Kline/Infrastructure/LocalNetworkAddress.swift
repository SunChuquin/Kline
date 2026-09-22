//
//  LocalNetworkAddress.swift
//  Kline
//
//  取本机 Wi-Fi / 局域网 IPv4（局域网直推通道要用：把 `http://<设备IP>:5051` 抄给电脑侧脚本）。
//  只读、不做任何权限申请、不缓存 —— 每次调用重新遍历一次网络接口，用户换 Wi-Fi 后结果随之变化。
//

import Foundation
import Darwin

enum LocalNetworkAddress {

    /// 本机局域网 IPv4 点分十进制字符串（如 "192.168.1.23"）；取不到返回 nil。
    ///
    /// 取值顺序：
    ///  1) `en0`（Wi-Fi）上的 AF_INET 地址 —— iPad / iPhone 的 Wi-Fi 接口名固定为 en0；
    ///  2) 回退：任意非回环（127.0.0.1 / 0.0.0.0）、非蜂窝（`pdp_ip*`）的 AF_INET 地址
    ///     （如个人热点 / 网卡共享出现的 en1、en2、bridge*）。
    static func currentIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        // 整条链表由 getifaddrs 一次性分配，遍历期间只读，统一在这里释放
        defer { freeifaddrs(head) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let ifa = current.pointee
            pointer = ifa.ifa_next                       // 节点内存属于 head 链表，不单独释放

            // 只看 IPv4 接口
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            // sockaddr → sockaddr_in → sin_addr → 点分十进制
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String in
                var raw = sin.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
                return String(cString: buffer)
            }
            guard !ip.isEmpty, ip != "127.0.0.1", ip != "0.0.0.0" else { continue }

            let name = String(cString: ifa.ifa_name)
            if name == "en0" { return ip }               // ① Wi-Fi 优先
            if !name.hasPrefix("pdp_ip"), fallback == nil {
                fallback = ip                            // ② 非蜂窝接口兜底
            }
        }
        return fallback
    }
}
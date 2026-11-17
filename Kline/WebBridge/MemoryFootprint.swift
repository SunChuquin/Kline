//
//  MemoryFootprint.swift
//  Kline
//
//  进程物理内存足迹（phys_footprint）读取：P0 桥接试点的内存红线探针。
//  iPad mini 4 仅 2GB，混合架构方案 §6 约定 WKWebView 进程预算 ≤150MB；
//  phys_footprint 是 iOS 上与 jetsam/内存压力最相关的口径（Xcode 内存报告同源）。
//

import Foundation

enum MemoryFootprint {
    /// 当前进程 phys_footprint（MB）；系统调用失败返回 -1
    static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}

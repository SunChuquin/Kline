//
//  BinFormat.swift
//  Kline
//
//  二进制行情文件（.bin）格式定义与解码。
//  与 PC 侧 Kline/src/txt2bin.py 共同维护，两者必须保持一致：
//    文件头 128B 小端:
//      magic "KLNB"(4) | version UInt8(1) | recordSize UInt8(1)
//      | code ASCII(16) | type UTF8(16) | name UTF8(64) | reserve(26)
//    数据区: N × recordSize 定长小端记录
//      Slim(36B)   : date UInt32 | open/high/low/close Float32 | vol UInt64 | amo Float64
//      Precise(52B): date UInt32 | open/high/low/close Float64 | vol UInt64 | amo Float64
//    count = (文件大小 - 128) / recordSize，最后一条不完整记录忽略（append 中断安全）。
//
//  Created by 孙楚昆 on 2026/9/18.
//

import Foundation

enum BinFormat {
    /// 文件头 magic "KLNB"
    static let magic: [UInt8] = [0x4B, 0x4C, 0x4E, 0x42]
    static let version: UInt8 = 1
    static let headerSize = 128
    /// Slim：价格 Float32（36B）
    static let slimRecordSize = 36
    /// Precise：价格 Float64（52B），与 SQLite REAL 完全一致
    static let preciseRecordSize = 52
    /// 行情文件扩展名（去掉点）
    static let fileExtension = "bin"
    /// 数据目录名（Documents 下）
    static let dataDirName = "tdx_data"

    struct Header {
        let code: String
        let type: String
        let name: String
        let version: UInt8
        let recordSize: Int
    }

    /// 解析数据区开头 128B 文件头；不合法返回 nil
    static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let magicBytes = Array(data.prefix(4))
        guard magicBytes == magic else { return nil }
        let version = data[4]
        let recordSize = Int(data[5])
        guard recordSize == slimRecordSize || recordSize == preciseRecordSize else { return nil }
        func fixedString(_ range: Range<Int>) -> String {
            var bytes: [UInt8] = []
            for i in range.lowerBound..<min(range.upperBound, data.count) {
                let b = data[i]
                if b == 0 { break }
                bytes.append(b)
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return Header(code: fixedString(6..<22),
                      type: fixedString(22..<38),
                      name: fixedString(38..<102),
                      version: version,
                      recordSize: recordSize)
    }

    /// 定长记录数（最后一条不完整自动忽略）
    static func recordCount(fileSize: Int, recordSize: Int) -> Int {
        guard fileSize > headerSize, recordSize > 0 else { return 0 }
        return (fileSize - headerSize) / recordSize
    }

    // MARK: - 记录解码（整文件）

    /// 解出全部记录（按文件内顺序 = 日期升序）
    static func decodeRecords(_ fileData: Data, recordSize: Int) -> [KlineItem] {
        let n = recordCount(fileSize: fileData.count, recordSize: recordSize)
        guard n > 0, fileData.count >= headerSize else { return [] }
        var out: [KlineItem] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            if let item = decodeLayout(fileData, offset: headerSize + i * recordSize, recordSize: recordSize) {
                out.append(item)
            }
        }
        return out
    }

    /// 从文件尾部直读最近 count 条定长记录（市场列表 80 根快读用，避免整文件 I/O），按文件内顺序返回
    static func readTailRecords(path: String, recordSize: Int, count: Int) -> [KlineItem] {
        guard count > 0, let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        let n = recordCount(fileSize: Int(size), recordSize: recordSize)
        guard n > 0 else { return [] }
        let take = min(count, n)
        let start = n - take
        try? fh.seek(toOffset: UInt64(headerSize + start * recordSize))
        let chunk = fh.readData(ofLength: take * recordSize)
        guard chunk.count == take * recordSize else { return [] }
        var out: [KlineItem] = []
        out.reserveCapacity(take)
        for i in 0..<take {
            if let item = decodeLayout(chunk, offset: i * recordSize, recordSize: recordSize) {
                out.append(item)
            }
        }
        return out
    }

    /// 读取文件中第 index 条记录的日期（meta 索引 first/last date 用）
    static func readDateAt(path: String, index: Int, recordSize: Int) -> Int? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        let n = recordCount(fileSize: Int(size), recordSize: recordSize)
        guard index >= 0, index < n else { return nil }
        try? fh.seek(toOffset: UInt64(headerSize + index * recordSize))
        let sub = fh.readData(ofLength: recordSize)
        guard sub.count == recordSize, let item = decodeLayout(sub, offset: 0, recordSize: recordSize) else { return nil }
        return item.date
    }

    // MARK: - 单条记录解码

    static func decodeRecord(_ fileData: Data, recordSize: Int, index: Int) -> KlineItem? {
        decodeLayout(fileData, offset: headerSize + index * recordSize, recordSize: recordSize)
    }

    /// 从任意 Data 的 offset 处解一条定长记录
    static func decodeLayout(_ d: Data, offset: Int, recordSize: Int) -> KlineItem? {
        guard offset + recordSize <= d.count else { return nil }
        let date = Int(u32(d, offset + 0))
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
        let turnover: Double
        if recordSize == slimRecordSize {
            open = Double(f32(d, offset + 4))
            high = Double(f32(d, offset + 8))
            low = Double(f32(d, offset + 12))
            close = Double(f32(d, offset + 16))
            volume = Double(u64(d, offset + 20))
            turnover = f64(d, offset + 28)
        } else {
            open = f64(d, offset + 4)
            high = f64(d, offset + 12)
            low = f64(d, offset + 20)
            close = f64(d, offset + 28)
            volume = Double(u64(d, offset + 36))
            turnover = f64(d, offset + 44)
        }
        return KlineItem(date: date, open: open, high: high, low: low,
                         close: close, volume: volume, turnover: turnover)
    }

    // MARK: - 小端原语

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }.littleEndian
    }

    private static func f32(_ d: Data, _ o: Int) -> Float {
        Float(bitPattern: u32(d, o))
    }

    private static func f64(_ d: Data, _ o: Int) -> Double {
        Double(bitPattern: u64(d, o))
    }
}
import Foundation

/// 最小 ZIP 写入器（spec/guided-capture T003 / FR-007）——**store 模式**（不压缩）。
///
/// ## 为什么自己写
/// 诊断包必须在**飞行模式**下从真机导出（验收 §5-7「纯离线」），且不能引入
/// 任何第三方依赖（本项目零网络、零外部包）。Foundation 无 zip 写入 API，
/// `NSFileCoordinator(.forUploading)` 能压包但行为不受控、测试不便。
/// 这里实现 store 模式的最小 ZIP（local header + central directory + EOCD），
/// 无压缩 → 实现简单、跨平台可解（macOS `unzip` / Windows 资源管理器均可解）。
///
/// ## 限制
/// - 不支持 Zip64（单文件 < 4GB、总条目 < 65535——诊断包量级远低于此）；
/// - 不写扩展字段/注释/加密；
/// - 条目名按 UTF-8 存储并置 UTF-8 标志位（bit 11）。
enum ZipArchiveWriter {
    /// 一个待写入条目（相对路径 + 内容）。
    struct Entry: Sendable {
        /// 归档内路径（用 `/` 分隔）。
        let path: String
        /// 内容。
        let data: Data

        init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    /// 写入 zip 文件（覆盖已存在文件）。
    static func write(entries: [Entry], to url: URL, timestamp: Date = Date()) throws {
        let (dosTime, dosDate) = dosTimestamp(timestamp)
        var archive = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            let name = Data(entry.path.replacingOccurrences(of: "\\", with: "/").utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)
            offsets.append(Int(offset))

            // local file header
            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)          // version needed
            archive.appendUInt16(0x0800)      // flags: UTF-8 名称
            archive.appendUInt16(0)           // method: store
            archive.appendUInt16(dosTime)
            archive.appendUInt16(dosDate)
            archive.appendUInt32(crc)
            archive.appendUInt32(size)        // compressed size
            archive.appendUInt32(size)        // uncompressed size
            archive.appendUInt16(UInt16(name.count))
            archive.appendUInt16(0)           // extra length
            archive.append(name)
            archive.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let name = Data(entry.path.replacingOccurrences(of: "\\", with: "/").utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            // central directory header
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)          // version made by
            central.appendUInt16(20)          // version needed
            central.appendUInt16(0x0800)      // flags: UTF-8 名称
            central.appendUInt16(0)           // method: store
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(size)
            central.appendUInt32(size)
            central.appendUInt16(UInt16(name.count))
            central.appendUInt16(0)           // extra
            central.appendUInt16(0)           // comment
            central.appendUInt16(0)           // disk number
            central.appendUInt16(0)           // internal attrs
            central.appendUInt32(0)           // external attrs
            central.appendUInt32(UInt32(offsets[index]))
            central.append(name)
        }

        var output = archive
        let centralOffset = UInt32(output.count)
        output.append(central)
        // end of central directory
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)               // disk number
        output.appendUInt16(0)               // disk with central directory
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(central.count))
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)               // comment length

        try output.write(to: url, options: .atomic)
    }

    /// DOS 时间/日期（zip 传统时间戳；秒精度 2 秒）。
    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(1980, components.year ?? 1980)
        let month = min(12, max(1, components.month ?? 1))
        let day = min(31, max(1, components.day ?? 1))
        let hour = min(23, max(0, components.hour ?? 0))
        let minute = min(59, max(0, components.minute ?? 0))
        let second = min(59, max(0, components.second ?? 0))
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        return (dosTime, dosDate)
    }
}

// MARK: - CRC32

/// CRC-32（IEEE 多项式）——zip 目录与文件头都要它。
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    /// 校验和。
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Data 追加小工具（zip 全为小端）

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

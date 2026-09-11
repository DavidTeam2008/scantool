import Foundation

enum ZipArchive {
    static func data(entries: [(name: String, data: Data)]) -> Data {
        var locals = Data()
        var central = Data()
        var offsets: [UInt32] = []
        for entry in entries {
            offsets.append(UInt32(locals.count))
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            local.appendLE(UInt16(20))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(crc)
            local.appendLE(size)
            local.appendLE(size)
            local.appendLE(UInt16(name.count))
            local.appendLE(UInt16(0))
            local.append(name)
            local.append(entry.data)
            locals.append(local)

            var dir = Data()
            dir.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            dir.appendLE(UInt16(20))
            dir.appendLE(UInt16(20))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(crc)
            dir.appendLE(size)
            dir.appendLE(size)
            dir.appendLE(UInt16(name.count))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt16(0))
            dir.appendLE(UInt32(0))
            dir.appendLE(offsets.last ?? 0)
            dir.append(name)
            central.append(dir)
        }
        var end = Data()
        end.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(central.count))
        end.appendLE(UInt32(locals.count))
        end.appendLE(UInt16(0))
        var result = Data()
        result.append(locals)
        result.append(central)
        result.append(end)
        return result
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

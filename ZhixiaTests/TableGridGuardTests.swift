import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

struct TableGridGuardTests {
    @Test("有边框表格能给出归一化外框")
    func detectsBorderedGrid() throws {
        let image = try makeImage { canvas in
            for x in 80..<320 {
                canvas.set(x, 40, 30)
                canvas.set(x, 160, 30)
            }
            for y in 40...160 {
                canvas.set(80, y, 30)
                canvas.set(320, y, 30)
            }
            for y in 40...160 where y % 20 == 0 {
                for x in 80...320 { canvas.set(x, y, 30) }
            }
        }
        let result = try #require(TableGridGuard().detect(in: image))
        let box = try #require(result.normalizedRects.first)
        #expect(result.horizontalLines >= 2)
        #expect(result.verticalLines >= 2)
        #expect(box.minX > 0.18 && box.minX < 0.23)
        #expect(box.maxX > 0.77 && box.maxX < 0.82)
        #expect(box.minY > 0.44 && box.minY < 0.49)
        #expect(box.maxY > 0.84 && box.maxY < 0.89)
    }

    @Test("深色表头块能给出保护框")
    func detectsDarkHeaderBlocks() throws {
        let image = try makeImage { canvas in
            for y in 20..<60 {
                for x in 80..<180 { canvas.set(x, y, 35) }
                for x in 200..<300 { canvas.set(x, y, 35) }
            }
        }
        let boxes = TableContentGuard().detect(in: image)
        #expect(!boxes.isEmpty)
        let left = CGRect(x: 0.20, y: 0.75, width: 0.01, height: 0.01)
        let right = CGRect(x: 0.60, y: 0.75, width: 0.01, height: 0.01)
        #expect(boxes.contains { $0.intersects(left) })
        #expect(boxes.contains { $0.intersects(right) })
    }

    @Test("只有文字横条、没有竖线时不误判表格")
    func ignoresTextRows() throws {
        let image = try makeImage { canvas in
            for y in [40, 60, 80, 100, 120] {
                for x in 40..<360 where x % 7 < 4 {
                    canvas.set(x, y, 20)
                }
            }
        }
        #expect(TableGridGuard().detect(in: image) == nil)
    }

    private struct Canvas {
        var bytes: [UInt8]
        let width: Int
        let height: Int

        mutating func set(_ x: Int, _ y: Int, _ value: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let offset = (y * width + x) * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
        }
    }

    private func makeImage(
        draw: (inout Canvas) -> Void
    ) throws -> CGImage {
        let width = 400
        let height = 300
        var canvas = Canvas(
            bytes: [UInt8](repeating: 255, count: width * height * 4),
            width: width,
            height: height
        )
        for index in stride(from: 3, to: canvas.bytes.count, by: 4) {
            canvas.bytes[index] = 255
        }
        draw(&canvas)
        let data = Data(canvas.bytes) as CFData
        let provider = try #require(CGDataProvider(data: data))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

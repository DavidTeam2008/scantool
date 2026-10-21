import Foundation
import UIKit

/// 诊断包导出（spec/guided-capture T003 / FR-007）——**纯本地、无网络**。
///
/// ## 包内容（FR-007 / 验收 §0-3）
/// - `trace.json`：逐帧事实 + 逐帧候选快照（全部 viable + top 8，硬上限 16）；
/// - `frames/*.jpg`：最近 5s 低分辨率帧（肉眼复现构图）；
/// - `originals/*.jpg`：本次会话的原图（成片真值）；
/// - `screenshot.png`：导出瞬间的屏幕截图。
///
/// ## 离线保证
/// 全部读写都是本地文件系统操作，**不引入任何网络依赖**（铁律 3）；飞行模式下
/// 功能完整（验收 §5-7）。
struct CaptureDiagnosticsExporter {
    /// 导出结果。
    struct Package: Sendable {
        /// zip 文件 URL（交给系统分享面板）。
        let url: URL
        /// 包内条目数。
        let entryCount: Int
    }

    /// 导出失败。
    enum ExportError: Error, LocalizedError {
        case encodingFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "诊断数据编码失败"
            case .writeFailed(let reason):
                return "诊断包写入失败：\(reason)"
            }
        }
    }

    /// 导出目录（默认临时目录下的 `ZhixiaDiagnostics`）。
    static func defaultOutputDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ZhixiaDiagnostics")
    }

    /// 构造诊断包并返回 zip 文件 URL。
    static func build(
        recorder: CaptureTraceRecorder,
        screenshot: Data? = nil,
        appVersion: String = "",
        deviceModel: String = "",
        osVersion: String = "",
        outputDirectory: URL = defaultOutputDirectory()
    ) throws -> Package {
        let payload = recorder.payload(
            appVersion: appVersion,
            deviceModel: deviceModel,
            osVersion: osVersion
        )

        let encoder = CaptureTraceCoding.makeEncoder()
        guard let json = try? encoder.encode(payload) else {
            throw ExportError.encodingFailed
        }

        var entries: [ZipArchiveWriter.Entry] = [
            ZipArchiveWriter.Entry(path: "trace.json", data: json)
        ]

        for (index, data) in recorder.recordedFrameImages.enumerated() {
            entries.append(
                ZipArchiveWriter.Entry(
                    path: String(format: "frames/frame-%04d.jpg", index + 1),
                    data: data
                )
            )
        }

        for (index, url) in recorder.recordedOriginals.enumerated() {
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(
                ZipArchiveWriter.Entry(
                    path: String(format: "originals/original-%04d-%@", index + 1, url.lastPathComponent),
                    data: data
                )
            )
        }

        if let screenshot {
            entries.append(ZipArchiveWriter.Entry(path: "screenshot.png", data: screenshot))
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let stamp = Self.fileTimestamp(Date())
        let zipURL = outputDirectory.appending(path: "ZhixiaDiagnostics-\(stamp).zip")
        do {
            try ZipArchiveWriter.write(entries: entries, to: zipURL)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return Package(url: zipURL, entryCount: entries.count)
    }

    /// 导出瞬间的屏幕截图（PNG；取不到返回 nil——诊断不该阻塞导出）。
    @MainActor
    static func captureScreenshot() -> Data? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        guard let window else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }

    /// 文件名时间戳（本地时区，秒精度）。
    static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

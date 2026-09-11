import Foundation

enum ZhixiaError: Equatable, Sendable, Error {
    case cameraDenied
    case cameraUnavailable
    case captureFailed
    case perspectiveFailed
    case diskFull
    case ocrFailed
    case exportFailed
    case reconstructFailed
    case reconstructCloudUnavailable
    case storeFailed
    case notFound

    var userMessage: String {
        switch self {
        case .cameraDenied:
            String(localized: "error.cameraDenied")
        case .cameraUnavailable:
            String(localized: "error.cameraUnavailable")
        case .captureFailed:
            String(localized: "error.captureFailed")
        case .perspectiveFailed:
            String(localized: "error.perspectiveFailed")
        case .diskFull:
            String(localized: "error.diskFull")
        case .ocrFailed:
            String(localized: "error.ocrFailed")
        case .exportFailed:
            String(localized: "error.exportFailed")
        case .reconstructFailed:
            String(localized: "error.reconstructFailed")
        case .reconstructCloudUnavailable:
            String(localized: "error.reconstructCloudUnavailable")
        case .storeFailed:
            String(localized: "error.storeFailed")
        case .notFound:
            String(localized: "error.notFound")
        }
    }
}

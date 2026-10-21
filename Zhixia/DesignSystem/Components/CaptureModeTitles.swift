import SwiftUI

/// 取景模式 / 拍摄意图的显示名（spec/guided-capture T012）——与 `Enhancement.title`
/// 同模式：文案留在 DesignSystem 层，Domain 只保留纯数据。
extension CaptureMode {
    var title: LocalizedStringResource {
        switch self {
        case .auto: "capture.mode.auto"
        case .guided: "capture.mode.guided"
        }
    }
}

extension CaptureIntent {
    var title: LocalizedStringResource {
        switch self {
        case .rightPage: "capture.intent.rightPage"
        case .leftPage: "capture.intent.leftPage"
        case .wholePage: "capture.intent.wholePage"
        }
    }
}

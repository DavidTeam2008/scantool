import SwiftUI
import UIKit

/// 系统分享面板（spec/guided-capture T003）——诊断包导出后交给用户主动分享。
///
/// **不自动上传**：分享面板由用户选择目标（AirDrop / 存到文件 / 邮件），
/// App 本身不发起任何网络请求（铁律 3 纯离线）。
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    /// 分享项（诊断包 zip 的 URL）。
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

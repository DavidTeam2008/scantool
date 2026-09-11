import SwiftUI

struct CameraPreviewRepresentable: UIViewRepresentable {
    let attacher: any CameraPreviewAttaching

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        Task { @MainActor in
            attacher.attachPreview(to: view.previewLayer)
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
}

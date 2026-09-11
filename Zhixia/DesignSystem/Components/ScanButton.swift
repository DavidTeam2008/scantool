import SwiftUI

struct ScanButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("scan.button")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: Tokens.scanButtonSize, height: Tokens.scanButtonSize)
                .background(Tokens.seal, in: Circle())
                .shadow(color: Tokens.seal.opacity(0.28), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("scan.accessibility"))
        .accessibilityHint(Text("scan.hint"))
    }
}

struct ShutterButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.white)
                .frame(width: Tokens.shutterSize - 8, height: Tokens.shutterSize - 8)
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 4)
                        .frame(width: Tokens.shutterSize, height: Tokens.shutterSize)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(Text("capture.shutter"))
    }
}

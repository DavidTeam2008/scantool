import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var permission: CameraAuthorization = .notDetermined

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 12) {
                Text("onboarding.title")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Tokens.ink)
                Text("onboarding.subtitle")
                    .font(.system(size: 17))
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            paperIllustration
            Spacer()
            if permission == .denied {
                Text("error.cameraDenied")
                    .font(.subheadline)
                    .foregroundStyle(Tokens.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("onboarding.settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            Button(action: continueTapped) {
                Text(permission == .denied ? "onboarding.skip" : "onboarding.start")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Tokens.seal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Tokens.paper.ignoresSafeArea())
        .task {
            permission = await environment.permissions.cameraStatus()
        }
    }

    private var paperIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.card)
                .frame(width: 180, height: 230)
                .shadow(color: Tokens.ink.opacity(0.08), radius: 16, y: 8)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Tokens.seal, lineWidth: 2.5)
                .frame(width: 148, height: 196)
        }
        .accessibilityHidden(true)
    }

    private func continueTapped() {
        Task {
            if permission != .authorized {
                permission = await environment.permissions.requestCamera()
            }
            if permission != .denied || environment.preferences.hasCompletedOnboarding == false {
                environment.preferences.hasCompletedOnboarding = true
            }
        }
    }
}

#Preview("欢迎") {
    OnboardingView()
        .environment(AppEnvironment.preview())
        .environment(AppCoordinator())
}

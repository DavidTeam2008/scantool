import SwiftUI

struct ExportSheet: View {
    let document: ScanDocument
    let imageURLs: [URL]
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL?
    @State private var isWorking = false
    @State private var error: ZhixiaError?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("export.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(Tokens.muted)
                    .padding(.top, 8)
                if isWorking {
                    ProgressView()
                }
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        label("export.pdf", prominent: true)
                    }
                } else {
                    Button {
                        Task { await makePDF() }
                    } label: {
                        label("export.pdf", prominent: true)
                    }
                }
                ShareLink(items: imageURLs) {
                    label("export.images", prominent: false)
                }
                .disabled(imageURLs.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 20)
            .background(Tokens.paper.ignoresSafeArea())
            .navigationTitle("export.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                }
            }
            .alert("error.exportFailed", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("common.ok", role: .cancel) {}
            }
        }
        .presentationDetents([.medium])
        .onDisappear {
            if let pdfURL {
                try? FileManager.default.removeItem(at: pdfURL)
            }
        }
    }

    private func label(_ key: LocalizedStringResource, prominent: Bool) -> some View {
        Text(key)
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                prominent ? Tokens.seal : Color(hex: 0xEFE8DC),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(prominent ? Color.white : Tokens.ink)
    }

    private func makePDF() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let name = "Zhixia-\(formatter.string(from: Date())).pdf"
            pdfURL = try await environment.pdf.makePDF(imageURLs: imageURLs, fileName: name)
        } catch {
            self.error = .exportFailed
        }
    }
}

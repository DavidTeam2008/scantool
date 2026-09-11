import SwiftUI
import UIKit

struct OCRView: View {
    @Bindable var viewModel: OCRViewModel
    var onCompleted: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ocr.local")
                .font(.caption)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Tokens.horizontalPadding)

            if viewModel.isRecognizing {
                ProgressView("ocr.working")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasAnyText {
                ContentUnavailableView {
                    Label("ocr.emptyTitle", systemImage: "text.viewfinder")
                } description: {
                    Text(viewModel.error?.userMessage ?? String(localized: "error.ocrFailed"))
                } actions: {
                    Button("ocr.retry") {
                        Task { await viewModel.recognizeAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.seal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(viewModel.allText)
                        .font(.system(size: 16))
                        .foregroundStyle(Tokens.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Tokens.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, Tokens.horizontalPadding)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(Tokens.paper.ignoresSafeArea())
        .navigationTitle("ocr.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("ocr.copy") {
                    UIPasteboard.general.string = viewModel.allText
                }
                .disabled(!viewModel.hasAnyText)
            }
        }
        .task {
            if viewModel.pages.isEmpty, !viewModel.isRecognizing {
                await viewModel.recognizeAll()
                if viewModel.hasAnyText {
                    onCompleted(viewModel.allText)
                }
            }
        }
    }
}

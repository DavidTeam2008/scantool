import Foundation

@MainActor
@Observable
final class OCRViewModel {
    var pages: [OCRPageText] = []
    var isRecognizing = false
    var error: ZhixiaError?
    var selectedIndex = 0

    private let document: ScanDocument
    private let scanPages: [ScanPage]
    private let fileStore: any PageFileStoring
    private let recognizer: any TextRecognizing

    init(
        document: ScanDocument,
        scanPages: [ScanPage],
        selectedIndex: Int,
        fileStore: any PageFileStoring,
        recognizer: any TextRecognizing
    ) {
        self.document = document
        self.scanPages = scanPages
        self.selectedIndex = min(max(0, selectedIndex), max(0, scanPages.count - 1))
        self.fileStore = fileStore
        self.recognizer = recognizer
    }

    var currentText: String {
        guard pages.indices.contains(selectedIndex) else { return "" }
        return pages[selectedIndex].joinedText
    }

    var allText: String {
        pages.enumerated().compactMap { index, page in
            let text = page.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if pages.count > 1 {
                return String(localized: "ocr.pageHeader \(index + 1)") + "\n" + text
            }
            return text
        }
        .joined(separator: "\n\n")
    }

    var hasAnyText: Bool {
        !allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recognizeAll() async {
        guard !isRecognizing else { return }
        isRecognizing = true
        error = nil
        defer { isRecognizing = false }
        var results: [OCRPageText] = []
        for page in scanPages {
            let rendered = fileStore.url(document: document.id, page: page.id, kind: .rendered)
            let original = fileStore.url(document: document.id, page: page.id, kind: .original)
            let renderedResult = await recognize(url: rendered, pageID: page.id)
            if let renderedResult, OCRTextQuality.cjkCount(renderedResult.joinedText) >= 12 {
                results.append(renderedResult)
                continue
            }
            let originalResult = rendered == original
                ? nil
                : await recognize(url: original, pageID: page.id)
            let best = [renderedResult, originalResult]
                .compactMap { $0 }
                .max(by: { $0.qualityScore < $1.qualityScore })
            results.append(best ?? OCRPageText(pageID: page.id, lines: []))
        }
        pages = results
        if !hasAnyText {
            error = .ocrFailed
        }
    }

    private func recognize(url: URL, pageID: UUID) async -> OCRPageText? {
        do {
            let result = try await recognizer.recognize(imageURL: url, pageID: pageID)
            return result.hasText ? result : nil
        } catch {
            return nil
        }
    }
}

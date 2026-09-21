import Foundation

actor PageFileStore: PageFileStoring {
    private let root: URL
    nonisolated private let filesDirectory: URL
    nonisolated private let tmpDirectory: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedRoot: URL
        if let root {
            resolvedRoot = root
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            resolvedRoot = support.appending(path: "Zhixia", directoryHint: .isDirectory)
        }
        self.root = resolvedRoot
        self.filesDirectory = resolvedRoot.appending(path: "files", directoryHint: .isDirectory)
        self.tmpDirectory = resolvedRoot.appending(path: "tmp", directoryHint: .isDirectory)
    }

    func writeOriginal(session: UUID, page: UUID, data: Data) async throws -> URL {
        let url = originalURL(session: session, page: page)
        try ensureParent(of: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated func originalURL(session: UUID, page: UUID) -> URL {
        tmpDirectory.appending(path: session.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(page.uuidString)-original.jpg")
    }

    nonisolated func url(document: UUID, page: UUID, kind: PageFileKind) -> URL {
        filesDirectory.appending(path: document.uuidString, directoryHint: .isDirectory)
            .appending(path: Self.fileName(page: page, kind: kind))
    }

    /// reconstruct 裁图持久目录（spec/layout-restore plan D2 / FR-010）：
    /// `files/<document>/reconstruct/<page>/`。
    ///
    /// 结构化档的 figure/barcode 裁图此前落 `temporaryDirectory`，系统随时可能清理，
    /// 「还原完成后过一阵再导出」就会缺图。迁到文档目录内之后：
    /// - `removeDocument(document:)` 删整个文档目录 → 裁图随文档走；
    /// - `sweep(knownDocumentIDs:)` 只保留已知文档目录 → 孤儿裁图自动回收。
    ///
    /// 注意：`PageFileStoring` 协议签名不变（plan D8）—— 这是具体类型上的新增方法，
    /// 由 `AppEnvironment.makeReconstructParser(documentID:)` 在构造 parser 时闭包注入。
    nonisolated func reconstructCropDirectory(document: UUID, page: UUID) -> URL {
        filesDirectory
            .appending(path: document.uuidString, directoryHint: .isDirectory)
            .appending(path: "reconstruct", directoryHint: .isDirectory)
            .appending(path: page.uuidString, directoryHint: .isDirectory)
    }

    func commit(
        document: UUID,
        drafts: [PageDraft],
        rendered: [UUID: Data],
        thumbs: [UUID: Data],
        keepOriginals: Bool
    ) async throws -> [ScanPage] {
        var pages: [ScanPage] = []
        // 失败回滚只删**本次新写入**的文件。
        // 曾经这里是无条件 `removeItem(at: documentDirectory(document))` —— 在「给已有文档加页」
        // 的场景下 `document` 是**已存在**文档的 ID，一旦第 N 页写盘失败（典型是磁盘满），
        // 会把该文档此前所有页的图全部删掉，而 `documentStore.appendPages` 因异常未执行 →
        // 数据库仍指向不存在的文件 → 文档永久损坏。见 docs/09 §6.2。
        var written: [URL] = []
        do {
            for (index, draft) in drafts.enumerated() {
                guard let renderedData = rendered[draft.id], let thumbData = thumbs[draft.id] else {
                    throw ZhixiaError.storeFailed
                }
                let originalSource = originalURL(session: draft.sessionID, page: draft.id)
                let originalDest = url(document: document, page: draft.id, kind: .original)
                let renderedDest = url(document: document, page: draft.id, kind: .rendered)
                let thumbDest = url(document: document, page: draft.id, kind: .thumbnail)
                try ensureParent(of: renderedDest)
                try renderedData.write(to: renderedDest, options: .atomic)
                written.append(renderedDest)
                try thumbData.write(to: thumbDest, options: .atomic)
                written.append(thumbDest)
                if keepOriginals, fileManager.fileExists(atPath: originalSource.path) {
                    if fileManager.fileExists(atPath: originalDest.path) {
                        try fileManager.removeItem(at: originalDest)
                    }
                    try fileManager.copyItem(at: originalSource, to: originalDest)
                    written.append(originalDest)
                }
                pages.append(
                    ScanPage(
                        id: draft.id,
                        documentID: document,
                        index: index,
                        quad: draft.quad,
                        enhancement: draft.enhancement,
                        rotationTurns: draft.rotationTurns,
                        originalRelativePath: keepOriginals ? Self.fileName(page: draft.id, kind: .original) : "",
                        renderedRelativePath: Self.fileName(page: draft.id, kind: .rendered),
                        thumbnailRelativePath: Self.fileName(page: draft.id, kind: .thumbnail)
                    )
                )
            }
        } catch {
            for url in written {
                try? fileManager.removeItem(at: url)
            }
            throw mapDiskError(error)
        }
        return pages
    }

    func removeDocument(document: UUID) async throws {
        let directory = documentDirectory(document)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func removeSession(session: UUID) async {
        let directory = tmpDirectory.appending(path: session.uuidString, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: directory)
    }

    func sweep(knownDocumentIDs: Set<UUID>) async {
        let files = filesDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            guard let id = UUID(uuidString: url.lastPathComponent) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            if !knownDocumentIDs.contains(id) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func storageByteCount() async -> Int64 {
        byteCount(at: root)
    }

    private func documentDirectory(_ document: UUID) -> URL {
        filesDirectory.appending(path: document.uuidString, directoryHint: .isDirectory)
    }

    private nonisolated static func fileName(page: UUID, kind: PageFileKind) -> String {
        "\(page.uuidString)-\(kind.rawValue).jpg"
    }

    private func ensureParent(of url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func mapDiskError(_ error: Error) -> ZhixiaError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        return .storeFailed
    }

    private func byteCount(at url: URL) -> Int64 {
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in enumerator {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}

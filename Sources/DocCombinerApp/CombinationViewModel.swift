import AppKit
import DocCombinerCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CombinationViewModel: ObservableObject {
    @Published private(set) var documents: [DocumentItem] = []
    @Published private(set) var isDropTargeted = false
    @Published private(set) var isCombining = false
    @Published var insertPageBreaks = true
    @Published var destinationURL: URL?
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var lastSummary: CombinationSummary?

    private let fileManager = FileManager.default

    var canCombine: Bool {
        documents.count >= 2 && !isCombining
    }

    var summaryText: String {
        if isCombining {
            return "Combining \(documents.count) documents"
        }
        if documents.isEmpty {
            return "Ready"
        }
        if documents.count == 1 {
            return "Add one more document"
        }
        return "\(documents.count) documents selected"
    }

    var effectiveDestinationURL: URL? {
        destinationURL ?? defaultDestinationURL
    }

    private var defaultDestinationURL: URL? {
        let urls = documents.map(\.url)
        guard urls.count >= 2 else {
            return nil
        }
        return DocxFileLocator.availableCombinedURL(for: urls, fileManager: fileManager)
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
    }

    func addDroppedURLs(_ urls: [URL]) {
        add(urls)
    }

    func chooseDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Choose Word Documents"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.docxDocument]

        guard panel.runModal() == .OK else {
            return
        }

        add(panel.urls)
    }

    func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Save Combined Document"
        panel.allowedContentTypes = [.docxDocument]
        panel.nameFieldStringValue = effectiveDestinationURL?.lastPathComponent ?? "Combined Document.docx"
        if let directory = effectiveDestinationURL?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        destinationURL = url
    }

    func combine() {
        guard canCombine, let outputURL = effectiveDestinationURL else {
            return
        }

        let sourceURLs = documents.map(\.url)
        isCombining = true
        statusMessage = "Combining"
        lastSummary = nil
        markAll(.pending, message: "Queued")

        Task {
            let accessTokens = (sourceURLs + [outputURL]).map { url in
                (url, url.startAccessingSecurityScopedResource())
            }
            defer {
                for (url, accessed) in accessTokens where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let insertPageBreaks = self.insertPageBreaks
                let summary = try await Task.detached(priority: .userInitiated) {
                    try DocxCombiner().combine(
                        sourceURLs,
                        destinationURL: outputURL,
                        options: CombinationOptions(insertPageBreaks: insertPageBreaks)
                    )
                }.value

                markAll(.combined, message: "Included")
                lastSummary = summary
                statusMessage = "Created \(summary.destinationURL.lastPathComponent)"
            } catch {
                markAll(.failed, message: error.localizedDescription)
                statusMessage = error.localizedDescription
            }
            isCombining = false
        }
    }

    func remove(_ item: DocumentItem) {
        documents.removeAll { $0.id == item.id }
        lastSummary = nil
        statusMessage = documents.isEmpty ? "Ready" : summaryText
    }

    func moveUp(_ item: DocumentItem) {
        guard let index = documents.firstIndex(where: { $0.id == item.id }), index > 0 else {
            return
        }
        documents.swapAt(index, index - 1)
        lastSummary = nil
    }

    func moveDown(_ item: DocumentItem) {
        guard let index = documents.firstIndex(where: { $0.id == item.id }), index < documents.count - 1 else {
            return
        }
        documents.swapAt(index, index + 1)
        lastSummary = nil
    }

    func clear() {
        documents = []
        destinationURL = nil
        lastSummary = nil
        statusMessage = "Ready"
    }

    func revealOutput() {
        guard let url = lastSummary?.destinationURL ?? effectiveDestinationURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func add(_ urls: [URL]) {
        let accessTokens = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, accessed) in accessTokens where accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let candidates = DocxFileLocator.docxFiles(in: urls, fileManager: fileManager)
        guard !candidates.isEmpty else {
            statusMessage = "No .docx files found"
            return
        }

        var existingPaths = Set(documents.map { $0.url.standardizedFileURL.path })
        let additions = candidates.compactMap { url -> DocumentItem? in
            guard existingPaths.insert(url.standardizedFileURL.path).inserted else {
                return nil
            }
            return DocumentItem(url: url, status: .pending, message: "Ready")
        }

        guard !additions.isEmpty else {
            statusMessage = "Already added"
            return
        }

        documents.append(contentsOf: additions)
        lastSummary = nil
        statusMessage = summaryText
    }

    private func markAll(_ status: DocumentStatus, message: String) {
        for index in documents.indices {
            documents[index].status = status
            documents[index].message = message
        }
    }
}

struct DocumentItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var status: DocumentStatus
    var message: String
}

enum DocumentStatus: Equatable {
    case pending
    case combined
    case failed

    var title: String {
        switch self {
        case .pending:
            return "Ready"
        case .combined:
            return "Included"
        case .failed:
            return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .pending:
            return "doc"
        case .combined:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

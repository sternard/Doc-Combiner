import DocCombinerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = CombinationViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                summary: viewModel.summaryText,
                chooseDocuments: viewModel.chooseDocuments,
                chooseDestination: viewModel.chooseDestination,
                combine: viewModel.combine,
                clear: viewModel.clear,
                canCombine: viewModel.canCombine,
                canClear: !viewModel.documents.isEmpty,
                isCombining: viewModel.isCombining
            )

            Divider()

            VStack(spacing: 18) {
                DropZone(
                    isTargeted: viewModel.isDropTargeted,
                    isCombining: viewModel.isCombining
                )
                .onDrop(
                    of: [.fileURL],
                    isTargeted: Binding(
                        get: { viewModel.isDropTargeted },
                        set: { viewModel.setDropTargeted($0) }
                    ),
                    perform: handleDrop
                )

                OptionsBar(
                    destinationURL: viewModel.effectiveDestinationURL,
                    insertPageBreaks: $viewModel.insertPageBreaks,
                    statusMessage: viewModel.statusMessage,
                    chooseDestination: viewModel.chooseDestination,
                    revealOutput: viewModel.revealOutput,
                    canReveal: viewModel.lastSummary != nil
                )

                DocumentList(
                    documents: viewModel.documents,
                    moveUp: viewModel.moveUp,
                    moveDown: viewModel.moveDown,
                    remove: viewModel.remove
                )
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            let urls = await loadFileURLs(from: providers)
            viewModel.addDroppedURLs(urls)
        }
        return true
    }

    private func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await loadFileURL(from: provider)
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }
}

private struct HeaderView: View {
    let summary: String
    let chooseDocuments: () -> Void
    let chooseDestination: () -> Void
    let combine: () -> Void
    let clear: () -> Void
    let canCombine: Bool
    let canClear: Bool
    let isCombining: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.title2)
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text("Doc Combiner")
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: chooseDocuments) {
                Label("Add", systemImage: "plus")
            }
            .help("Add documents")
            .disabled(isCombining)

            Button(action: chooseDestination) {
                Label("Output", systemImage: "square.and.arrow.down")
            }
            .help("Choose output file")
            .disabled(isCombining)

            Button(action: clear) {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear documents")
            .disabled(!canClear || isCombining)

            Button(action: combine) {
                Label(isCombining ? "Combining" : "Combine", systemImage: isCombining ? "arrow.triangle.2.circlepath" : "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCombine)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let isCombining: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isTargeted ? Color.indigo.opacity(0.18) : Color.indigo.opacity(0.1))
                    .frame(width: 72, height: 72)

                Image(systemName: isCombining ? "arrow.triangle.2.circlepath" : "doc.badge.plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 5) {
                Text("Drop Word documents")
                    .font(.title3.weight(.semibold))

                Text("Files are combined in the order shown below")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.indigo.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.indigo : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
        )
    }
}

private struct OptionsBar: View {
    let destinationURL: URL?
    @Binding var insertPageBreaks: Bool
    let statusMessage: String
    let chooseDestination: () -> Void
    let revealOutput: () -> Void
    let canReveal: Bool

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Page breaks", isOn: $insertPageBreaks)
                .toggleStyle(.switch)
                .frame(width: 140, alignment: .leading)

            Divider()
                .frame(height: 22)

            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)

            Text(destinationURL?.path(percentEncoded: false) ?? "Choose an output file")
                .font(.callout)
                .foregroundStyle(destinationURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(statusMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            Button(action: chooseDestination) {
                Label("Output", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .help("Choose output file")

            Button(action: revealOutput) {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help("Reveal output in Finder")
            .disabled(!canReveal)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DocumentList: View {
    let documents: [DocumentItem]
    let moveUp: (DocumentItem) -> Void
    let moveDown: (DocumentItem) -> Void
    let remove: (DocumentItem) -> Void

    var body: some View {
        Group {
            if documents.isEmpty {
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, item in
                        DocumentRow(
                            index: index + 1,
                            item: item,
                            canMoveUp: index > 0,
                            canMoveDown: index < documents.count - 1,
                            moveUp: { moveUp(item) },
                            moveDown: { moveDown(item) },
                            remove: { remove(item) }
                        )
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct DocumentRow: View {
    let index: Int
    let item: DocumentItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Image(systemName: item.status.symbol)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.status.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 72, alignment: .trailing)

            Button(action: moveUp) {
                Label("Move Up", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .help("Move up")
            .disabled(!canMoveUp)

            Button(action: moveDown) {
                Label("Move Down", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .help("Move down")
            .disabled(!canMoveDown)

            Button(action: remove) {
                Label("Remove", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Remove document")
        }
        .padding(.vertical, 5)
    }

    private var color: Color {
        switch item.status {
        case .pending:
            return .secondary
        case .combined:
            return .green
        case .failed:
            return .red
        }
    }
}

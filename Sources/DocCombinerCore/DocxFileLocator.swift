import Foundation

public enum DocxFileLocator {
    public static let docxExtension = "docx"

    public static func isDocxFile(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }

        return url.pathExtension.lowercased() == docxExtension
            && !url.lastPathComponent.hasPrefix("~$")
    }

    public static func docxFiles(in droppedURLs: [URL], fileManager: FileManager = .default) -> [URL] {
        var seenPaths = Set<String>()
        var results: [URL] = []

        for url in droppedURLs {
            for candidate in docxFiles(in: url, fileManager: fileManager) {
                let standardizedPath = candidate.standardizedFileURL.path
                guard seenPaths.insert(standardizedPath).inserted else {
                    continue
                }
                results.append(candidate.standardizedFileURL)
            }
        }

        return results
    }

    public static func docxFiles(in url: URL, fileManager: FileManager = .default) -> [URL] {
        guard url.isFileURL else {
            return []
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return isDocxFile(url) ? [url.standardizedFileURL] : []
        }

        if !isDirectory.boolValue {
            return isDocxFile(url) ? [url.standardizedFileURL] : []
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { isDocxFile($0) }
            .map { $0.standardizedFileURL }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func availableCombinedURL(
        for sourceURLs: [URL],
        fileManager: FileManager = .default
    ) -> URL {
        let directory = sourceURLs.first?.deletingLastPathComponent()
            ?? fileManager.homeDirectoryForCurrentUser
        let baseURL = directory.appendingPathComponent("Combined Document")
        let firstCandidate = baseURL.appendingPathExtension(docxExtension)

        guard fileManager.fileExists(atPath: firstCandidate.path) else {
            return firstCandidate
        }

        for suffix in 2... {
            let candidate = directory
                .appendingPathComponent("Combined Document \(suffix)")
                .appendingPathExtension(docxExtension)

            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return firstCandidate
    }
}

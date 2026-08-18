import Foundation

struct ZipArchive {
    var fileManager: FileManager = .default
    var dittoPath = "/usr/bin/ditto"

    func extract(_ archiveURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try runDitto(arguments: ["-x", "-k", archiveURL.path, destinationURL.path])
    }

    func createArchive(from directoryURL: URL, at archiveURL: URL) throws {
        let parentURL = archiveURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(archiveURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try runDitto(arguments: [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--norsrc",
            directoryURL.path,
            temporaryURL.path
        ])

        if fileManager.fileExists(atPath: archiveURL.path) {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        }
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dittoPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DocxCombinationError.archiveToolFailed(message ?? "ditto exited with status \(process.terminationStatus)")
        }
    }
}

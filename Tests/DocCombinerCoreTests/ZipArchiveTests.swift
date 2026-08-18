import Foundation
import XCTest
@testable import DocCombinerCore

final class ZipArchiveTests: XCTestCase {
    func testFailedArchiveCreationPreservesExistingDestination() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ZipArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let sourceDirectory = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceDirectory.appendingPathComponent("document.xml"))

        let destinationURL = temporaryDirectory.appendingPathComponent("Existing.docx")
        let existingData = Data("existing destination".utf8)
        try existingData.write(to: destinationURL)

        let archive = ZipArchive(fileManager: fileManager, dittoPath: "/usr/bin/false")
        XCTAssertThrowsError(try archive.createArchive(from: sourceDirectory, at: destinationURL))
        XCTAssertEqual(try Data(contentsOf: destinationURL), existingData)
    }
}

import Foundation
import XCTest
@testable import DocCombinerCore

final class DocxFileLocatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocCombinerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testDocxDetectionIsCaseInsensitiveAndSkipsWordLockFiles() {
        XCTAssertTrue(DocxFileLocator.isDocxFile(URL(fileURLWithPath: "/tmp/Report.DOCX")))
        XCTAssertFalse(DocxFileLocator.isDocxFile(URL(fileURLWithPath: "/tmp/Report.doc")))
        XCTAssertFalse(DocxFileLocator.isDocxFile(URL(fileURLWithPath: "/tmp/~$Report.docx")))
    }

    func testFolderExpansionFindsNestedDocxFilesInStableOrder() throws {
        let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let first = temporaryDirectory.appendingPathComponent("B.docx")
        let second = nestedDirectory.appendingPathComponent("A.docx")
        let ignored = nestedDirectory.appendingPathComponent("Ignored.txt")

        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: second.path, contents: Data())
        FileManager.default.createFile(atPath: ignored.path, contents: Data())

        let results = DocxFileLocator.docxFiles(in: temporaryDirectory)

        XCTAssertEqual(results, [first.standardizedFileURL, second.standardizedFileURL].sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
    }

    func testAvailableCombinedURLAvoidsExistingFiles() throws {
        let firstSource = temporaryDirectory.appendingPathComponent("First.docx")
        let firstOutput = temporaryDirectory.appendingPathComponent("Combined Document.docx")
        let secondOutput = temporaryDirectory.appendingPathComponent("Combined Document 2.docx")

        FileManager.default.createFile(atPath: firstSource.path, contents: Data())
        FileManager.default.createFile(atPath: firstOutput.path, contents: Data())

        XCTAssertEqual(DocxFileLocator.availableCombinedURL(for: [firstSource]), secondOutput)
    }
}

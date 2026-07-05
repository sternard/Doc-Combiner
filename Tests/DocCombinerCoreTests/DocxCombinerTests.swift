import Foundation
import XCTest
@testable import DocCombinerCore

final class DocxCombinerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DocCombinerTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testCombinesDocumentBodiesInOrderWithPageBreak() throws {
        let first = try makeDocx(
            name: "First",
            bodyBlocks: paragraph("First document")
        )
        let second = try makeDocx(
            name: "Second",
            bodyBlocks: paragraph("Second document")
        )
        let output = temporaryDirectory.appendingPathComponent("Combined.docx")

        let summary = try DocxCombiner().combine([first, second], destinationURL: output)
        let extracted = try extract(summary.destinationURL)
        let documentXML = try readPackageFile("word/document.xml", in: extracted)

        XCTAssertTrue(documentXML.contains("First document"))
        XCTAssertTrue(documentXML.contains("Second document"))
        XCTAssertTrue(documentXML.contains("w:type=\"page\""))
        XCTAssertLessThan(
            documentXML.range(of: "First document")!.lowerBound,
            documentXML.range(of: "Second document")!.lowerBound
        )
    }

    func testCopiesEmbeddedMediaAndRemapsRelationshipIDs() throws {
        let first = try makeDocx(
            name: "First",
            bodyBlocks: paragraph("First")
        )
        let second = try makeDocx(
            name: "Second",
            bodyBlocks: """
            <w:p><w:r><w:drawing><a:blip r:embed="rId5"/></w:drawing></w:r></w:p>
            """,
            relationships: [
                TestRelationship(
                    id: "rId5",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    target: "media/image1.png"
                )
            ],
            relatedFiles: [
                ("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47]))
            ],
            extraDefaults: [
                ("png", "image/png")
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("Combined.docx")

        _ = try DocxCombiner().combine([first, second], destinationURL: output)
        let extracted = try extract(output)
        let documentXML = try readPackageFile("word/document.xml", in: extracted)
        let relsXML = try readPackageFile("word/_rels/document.xml.rels", in: extracted)

        XCTAssertFalse(documentXML.contains("r:embed=\"rId5\""))
        XCTAssertTrue(documentXML.contains("r:embed=\"rId1\""))
        XCTAssertTrue(relsXML.contains("Target=\"media/doc2-image1.png\""))
        XCTAssertTrue(fileManager.fileExists(atPath: extracted.appendingPathComponent("word/media/doc2-image1.png").path))
    }

    func testMergesNumberingAndUpdatesAppendedBodyReferences() throws {
        let first = try makeDocx(
            name: "First",
            bodyBlocks: paragraph("First")
        )
        let second = try makeDocx(
            name: "Second",
            bodyBlocks: """
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="7"/></w:numPr></w:pPr><w:r><w:t>List item</w:t></w:r></w:p>
            """,
            numberingXML: """
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:abstractNum w:abstractNumId="3">
                <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
              </w:abstractNum>
              <w:num w:numId="7"><w:abstractNumId w:val="3"/></w:num>
            </w:numbering>
            """
        )
        let output = temporaryDirectory.appendingPathComponent("Combined.docx")

        _ = try DocxCombiner().combine([first, second], destinationURL: output)
        let extracted = try extract(output)
        let documentXML = try readPackageFile("word/document.xml", in: extracted)
        let numberingXML = try readPackageFile("word/numbering.xml", in: extracted)
        let relsXML = try readPackageFile("word/_rels/document.xml.rels", in: extracted)

        XCTAssertTrue(documentXML.contains("<w:numId w:val=\"1\""))
        XCTAssertTrue(numberingXML.contains("<w:abstractNum w:abstractNumId=\"0\""))
        XCTAssertTrue(numberingXML.contains("<w:num w:numId=\"1\""))
        XCTAssertTrue(relsXML.contains("relationships/numbering"))
    }

    func testRejectsDestinationThatMatchesSource() throws {
        let first = try makeDocx(name: "First", bodyBlocks: paragraph("First"))
        let second = try makeDocx(name: "Second", bodyBlocks: paragraph("Second"))

        XCTAssertThrowsError(try DocxCombiner().combine([first, second], destinationURL: first)) { error in
            XCTAssertEqual(error as? DocxCombinationError, .destinationMatchesSource(first.standardizedFileURL))
        }
    }

    private func makeDocx(
        name: String,
        bodyBlocks: String,
        relationships: [TestRelationship] = [],
        relatedFiles: [(String, Data)] = [],
        extraDefaults: [(String, String)] = [],
        numberingXML: String? = nil
    ) throws -> URL {
        let packageDirectory = temporaryDirectory.appendingPathComponent("\(name)-package", isDirectory: true)
        try fileManager.createDirectory(
            at: packageDirectory.appendingPathComponent("_rels", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: packageDirectory.appendingPathComponent("word/_rels", isDirectory: true),
            withIntermediateDirectories: true
        )

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
        \(extraDefaults.map { "  <Default Extension=\"\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined(separator: "\n"))
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        \(numberingXML == nil ? "" : "  <Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>")
        </Types>
        """, to: packageDirectory.appendingPathComponent("[Content_Types].xml"))

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """, to: packageDirectory.appendingPathComponent("_rels/.rels"))

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <w:body>
        \(bodyBlocks)
            <w:sectPr/>
          </w:body>
        </w:document>
        """, to: packageDirectory.appendingPathComponent("word/document.xml"))

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships.map(\.xml).joined(separator: "\n"))
        </Relationships>
        """, to: packageDirectory.appendingPathComponent("word/_rels/document.xml.rels"))

        if let numberingXML {
            try write(numberingXML, to: packageDirectory.appendingPathComponent("word/numbering.xml"))
        }

        for (relativePath, data) in relatedFiles {
            let fileURL = packageDirectory.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }

        let docxURL = temporaryDirectory.appendingPathComponent("\(name).docx")
        try ZipArchive().createArchive(from: packageDirectory, at: docxURL)
        return docxURL
    }

    private func paragraph(_ text: String) -> String {
        "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    private func extract(_ docxURL: URL) throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent("Extracted-\(UUID().uuidString)", isDirectory: true)
        try ZipArchive().extract(docxURL, to: directory)
        return directory
    }

    private func readPackageFile(_ relativePath: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func write(_ string: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try string.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TestRelationship {
    var id: String
    var type: String
    var target: String
    var targetMode: String?

    init(id: String, type: String, target: String, targetMode: String? = nil) {
        self.id = id
        self.type = type
        self.target = target
        self.targetMode = targetMode
    }

    var xml: String {
        let mode = targetMode.map { " TargetMode=\"\($0)\"" } ?? ""
        return "  <Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(target)\"\(mode)/>"
    }
}

import UniformTypeIdentifiers

extension UTType {
    static let docxDocument = UTType(filenameExtension: "docx") ?? .data
}

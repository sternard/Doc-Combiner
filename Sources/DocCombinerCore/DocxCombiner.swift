import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct CombinationOptions: Equatable, Sendable {
    public var insertPageBreaks: Bool

    public init(insertPageBreaks: Bool = true) {
        self.insertPageBreaks = insertPageBreaks
    }
}

public struct CombinationSummary: Equatable, Sendable {
    public let sourceURLs: [URL]
    public let destinationURL: URL
    public let pageBreaksInserted: Bool

    public init(sourceURLs: [URL], destinationURL: URL, pageBreaksInserted: Bool) {
        self.sourceURLs = sourceURLs
        self.destinationURL = destinationURL
        self.pageBreaksInserted = pageBreaksInserted
    }
}

public enum DocxCombinationError: Error, LocalizedError, Equatable {
    case tooFewDocuments(Int)
    case unsupportedFile(URL)
    case destinationMatchesSource(URL)
    case missingRequiredPart(String, URL)
    case invalidXML(String, URL)
    case missingRelationship(String, URL)
    case missingRelatedPart(String, URL)
    case cannotCreateDestination(URL)
    case archiveToolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tooFewDocuments:
            return "Choose at least two .docx files."
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not a supported .docx file."
        case .destinationMatchesSource(let url):
            return "The output file cannot replace \(url.lastPathComponent)."
        case .missingRequiredPart(let part, let url):
            return "\(url.lastPathComponent) is missing \(part)."
        case .invalidXML(let part, let url):
            return "\(url.lastPathComponent) has invalid XML in \(part)."
        case .missingRelationship(let id, let url):
            return "\(url.lastPathComponent) is missing relationship \(id)."
        case .missingRelatedPart(let part, let url):
            return "\(url.lastPathComponent) is missing related part \(part)."
        case .cannotCreateDestination(let url):
            return "Could not create \(url.lastPathComponent)."
        case .archiveToolFailed(let message):
            return message.isEmpty ? "The document archive tool failed." : message
        }
    }
}

public final class DocxCombiner: @unchecked Sendable {
    private let fileManager: FileManager
    private let archive: ZipArchive

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.archive = ZipArchive(fileManager: fileManager)
    }

    public func combine(
        _ sourceURLs: [URL],
        destinationURL: URL? = nil,
        options: CombinationOptions = CombinationOptions()
    ) throws -> CombinationSummary {
        let sources = sourceURLs.map { $0.standardizedFileURL }

        guard sources.count >= 2 else {
            throw DocxCombinationError.tooFewDocuments(sources.count)
        }

        for source in sources {
            guard DocxFileLocator.isDocxFile(source), fileManager.fileExists(atPath: source.path) else {
                throw DocxCombinationError.unsupportedFile(source)
            }
        }

        let destination = (destinationURL ?? DocxFileLocator.availableCombinedURL(for: sources, fileManager: fileManager))
            .standardizedFileURL
        let sourcePaths = Set(sources.map(\.path))
        guard !sourcePaths.contains(destination.path) else {
            throw DocxCombinationError.destinationMatchesSource(destination)
        }

        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent("DocCombiner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workspaceURL)
        }

        let baseDirectory = workspaceURL.appendingPathComponent("base", isDirectory: true)
        try archive.extract(sources[0], to: baseDirectory)

        let baseDocumentURL = documentURL(in: baseDirectory)
        let baseDocument = try loadDocumentXML(at: baseDocumentURL, sourceURL: sources[0])
        guard let baseBody = bodyElement(in: baseDocument) else {
            throw DocxCombinationError.invalidXML("word/document.xml", sources[0])
        }

        let baseRelationships = try DocumentRelationshipStore(packageDirectory: baseDirectory, fileManager: fileManager)
        let baseContentTypes = try ContentTypeStore(packageDirectory: baseDirectory, fileManager: fileManager)

        for (offset, sourceURL) in sources.dropFirst().enumerated() {
            let sourceIndex = offset + 2
            let sourceDirectory = workspaceURL.appendingPathComponent("source-\(sourceIndex)", isDirectory: true)
            try archive.extract(sourceURL, to: sourceDirectory)

            let sourceDocumentURL = documentURL(in: sourceDirectory)
            let sourceDocument = try loadDocumentXML(at: sourceDocumentURL, sourceURL: sourceURL)
            guard let sourceBody = bodyElement(in: sourceDocument) else {
                throw DocxCombinationError.invalidXML("word/document.xml", sourceURL)
            }

            try baseContentTypes.mergeDefaults(from: sourceDirectory)
            try mergeStyles(
                from: sourceDirectory,
                sourceURL: sourceURL,
                into: baseDirectory,
                relationships: baseRelationships,
                contentTypes: baseContentTypes
            )
            let relationshipIDMap = try mergeDocumentRelationships(
                from: sourceDirectory,
                sourceURL: sourceURL,
                sourceIndex: sourceIndex,
                sourceBody: sourceBody,
                into: baseDirectory,
                relationships: baseRelationships,
                contentTypes: baseContentTypes
            )
            updateRelationshipIDs(in: sourceBody, using: relationshipIDMap)
            try mergeNumbering(
                from: sourceDirectory,
                sourceURL: sourceURL,
                sourceBody: sourceBody,
                into: baseDirectory,
                relationships: baseRelationships,
                contentTypes: baseContentTypes
            )
            appendBody(
                from: sourceBody,
                to: baseBody,
                insertPageBreak: options.insertPageBreaks
            )
        }

        try saveXMLDocument(baseDocument, to: baseDocumentURL)
        try baseRelationships.save()
        try baseContentTypes.save()

        do {
            try archive.createArchive(from: baseDirectory, at: destination)
        } catch {
            throw DocxCombinationError.cannotCreateDestination(destination)
        }

        return CombinationSummary(
            sourceURLs: sources,
            destinationURL: destination,
            pageBreaksInserted: options.insertPageBreaks
        )
    }

    private func documentURL(in packageDirectory: URL) -> URL {
        packageDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("document.xml")
    }

    private func loadDocumentXML(at url: URL, sourceURL: URL) throws -> XMLDocument {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DocxCombinationError.missingRequiredPart("word/document.xml", sourceURL)
        }

        do {
            return try XMLDocument(contentsOf: url, options: .nodePreserveWhitespace)
        } catch {
            throw DocxCombinationError.invalidXML("word/document.xml", sourceURL)
        }
    }

    private func bodyElement(in document: XMLDocument) -> XMLElement? {
        guard let root = document.rootElement() else {
            return nil
        }

        return root.firstDescendantElement(localName: "body")
    }

    private func appendBody(from sourceBody: XMLElement, to baseBody: XMLElement, insertPageBreak: Bool) {
        var insertionIndex = indexOfSectionProperties(in: baseBody) ?? (baseBody.children?.count ?? 0)

        if insertPageBreak {
            baseBody.insertChild(pageBreakParagraph(), at: insertionIndex)
            insertionIndex += 1
        }

        for child in sourceBody.children ?? [] {
            if let element = child as? XMLElement, element.hasLocalName("sectPr") {
                continue
            }

            baseBody.insertChild(child.copy() as! XMLNode, at: insertionIndex)
            insertionIndex += 1
        }
    }

    private func indexOfSectionProperties(in body: XMLElement) -> Int? {
        guard let children = body.children else {
            return nil
        }

        return children.firstIndex { node in
            guard let element = node as? XMLElement else {
                return false
            }
            return element.hasLocalName("sectPr")
        }
    }

    private func pageBreakParagraph() -> XMLNode {
        let paragraph = XMLElement(name: "w:p")
        let run = XMLElement(name: "w:r")
        let breakElement = XMLElement(name: "w:br")
        breakElement.setAttribute(localName: "type", preferredName: "w:type", value: "page")
        run.addChild(breakElement)
        paragraph.addChild(run)
        return paragraph
    }

    private func mergeDocumentRelationships(
        from sourceDirectory: URL,
        sourceURL: URL,
        sourceIndex: Int,
        sourceBody: XMLElement,
        into baseDirectory: URL,
        relationships: DocumentRelationshipStore,
        contentTypes: ContentTypeStore
    ) throws -> [String: String] {
        let relationshipIDs = collectRelationshipIDs(in: sourceBody)
        guard !relationshipIDs.isEmpty else {
            return [:]
        }

        let sourceRelationships = try DocumentRelationshipStore(
            packageDirectory: sourceDirectory,
            fileManager: fileManager,
            createIfMissing: false
        )
        let sourceContentTypes = try ContentTypeStore(packageDirectory: sourceDirectory, fileManager: fileManager)
        var idMap: [String: String] = [:]

        for oldID in relationshipIDs.sortedByRelationshipID() {
            guard let relationship = sourceRelationships.relationship(id: oldID) else {
                throw DocxCombinationError.missingRelationship(oldID, sourceURL)
            }

            let newID = relationships.nextRelationshipID()
            var newTarget = relationship.target

            if relationship.targetMode?.lowercased() != "external",
               !relationship.target.looksLikeExternalTarget {
                let sourcePartURL = resolvedRelationshipTarget(relationship.target, in: sourceDirectory)
                guard fileManager.fileExists(atPath: sourcePartURL.path) else {
                    throw DocxCombinationError.missingRelatedPart(relationship.target, sourceURL)
                }

                let destination = try copyRelatedPart(
                    sourcePartURL,
                    originalTarget: relationship.target,
                    sourceIndex: sourceIndex,
                    into: baseDirectory
                )
                newTarget = destination.target

                let oldPartName = packagePartName(for: sourcePartURL, packageDirectory: sourceDirectory)
                let newPartName = packagePartName(for: destination.url, packageDirectory: baseDirectory)
                contentTypes.copyOverride(
                    oldPartName: oldPartName,
                    newPartName: newPartName,
                    from: sourceContentTypes
                )
            }

            relationships.add(
                id: newID,
                type: relationship.type,
                target: newTarget,
                targetMode: relationship.targetMode
            )
            idMap[oldID] = newID
        }

        return idMap
    }

    private func copyRelatedPart(
        _ sourcePartURL: URL,
        originalTarget: String,
        sourceIndex: Int,
        into baseDirectory: URL
    ) throws -> (target: String, url: URL) {
        let originalName = originalTarget.removingFragment.lastPathComponentFromPath
        let safeName = originalName.isEmpty ? "part.xml" : originalName
        let targetDirectory = preferredTargetDirectory(for: originalTarget)

        var suffix = 1
        var target = "\(targetDirectory)/doc\(sourceIndex)-\(safeName)"
        var destinationURL = baseDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent(target)

        while fileManager.fileExists(atPath: destinationURL.path) {
            suffix += 1
            target = "\(targetDirectory)/doc\(sourceIndex)-\(suffix)-\(safeName)"
            destinationURL = baseDirectory
                .appendingPathComponent("word", isDirectory: true)
                .appendingPathComponent(target)
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourcePartURL, to: destinationURL)

        return (target, destinationURL)
    }

    private func preferredTargetDirectory(for originalTarget: String) -> String {
        let target = originalTarget.removingFragment
        if target.hasPrefix("media/") {
            return "media"
        }
        if target.hasPrefix("embeddings/") {
            return "embeddings"
        }
        return "combined"
    }

    private func resolvedRelationshipTarget(_ target: String, in packageDirectory: URL) -> URL {
        packageDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent(target.removingFragment)
            .standardizedFileURL
    }

    private func packagePartName(for url: URL, packageDirectory: URL) -> String {
        let packagePath = packageDirectory.standardizedFileURL.path
        let partPath = url.standardizedFileURL.path
        guard partPath.hasPrefix(packagePath) else {
            return "/" + url.lastPathComponent
        }

        let relativePath = String(partPath.dropFirst(packagePath.count))
        return relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
    }

    private func collectRelationshipIDs(in element: XMLElement) -> Set<String> {
        var ids = Set<String>()
        walk(element) { node in
            for attribute in node.attributes ?? [] {
                guard attribute.normalizedLocalName == "id" || attribute.name == "r:id" || attribute.name == "r:embed" || attribute.name == "r:link" else {
                    continue
                }
                if let value = attribute.stringValue, value.hasPrefix("rId") {
                    ids.insert(value)
                }
            }
        }
        return ids
    }

    private func updateRelationshipIDs(in element: XMLElement, using idMap: [String: String]) {
        guard !idMap.isEmpty else {
            return
        }

        walk(element) { node in
            for attribute in node.attributes ?? [] {
                if let value = attribute.stringValue, let replacement = idMap[value] {
                    attribute.stringValue = replacement
                }
            }
        }
    }

    private func mergeStyles(
        from sourceDirectory: URL,
        sourceURL: URL,
        into baseDirectory: URL,
        relationships: DocumentRelationshipStore,
        contentTypes: ContentTypeStore
    ) throws {
        let sourceStylesURL = sourceDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("styles.xml")
        guard fileManager.fileExists(atPath: sourceStylesURL.path) else {
            return
        }

        let baseStylesURL = baseDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("styles.xml")

        if !fileManager.fileExists(atPath: baseStylesURL.path) {
            try fileManager.copyItem(at: sourceStylesURL, to: baseStylesURL)
            relationships.ensure(type: OpenXMLRelationshipType.styles, target: "styles.xml")
            contentTypes.ensureOverride(partName: "/word/styles.xml", contentType: OpenXMLContentType.styles)
            return
        }

        let baseDocument: XMLDocument
        let sourceDocument: XMLDocument
        do {
            baseDocument = try XMLDocument(contentsOf: baseStylesURL, options: .nodePreserveWhitespace)
            sourceDocument = try XMLDocument(contentsOf: sourceStylesURL, options: .nodePreserveWhitespace)
        } catch {
            throw DocxCombinationError.invalidXML("word/styles.xml", sourceURL)
        }

        guard let baseRoot = baseDocument.rootElement(),
              let sourceRoot = sourceDocument.rootElement() else {
            throw DocxCombinationError.invalidXML("word/styles.xml", sourceURL)
        }

        var existingStyleIDs = Set<String>()
        for style in baseRoot.childElements(localName: "style") {
            if let styleID = style.attributeValue(localName: "styleId") {
                existingStyleIDs.insert(styleID)
            }
        }

        var addedStyle = false
        for style in sourceRoot.childElements(localName: "style") {
            guard let styleID = style.attributeValue(localName: "styleId"),
                  !existingStyleIDs.contains(styleID) else {
                continue
            }

            baseRoot.addChild(style.copy() as! XMLNode)
            existingStyleIDs.insert(styleID)
            addedStyle = true
        }

        if addedStyle {
            try saveXMLDocument(baseDocument, to: baseStylesURL)
        }
    }

    private func mergeNumbering(
        from sourceDirectory: URL,
        sourceURL: URL,
        sourceBody: XMLElement,
        into baseDirectory: URL,
        relationships: DocumentRelationshipStore,
        contentTypes: ContentTypeStore
    ) throws {
        let usedNumberingIDs = collectNumberingIDs(in: sourceBody)
        guard !usedNumberingIDs.isEmpty else {
            return
        }

        let sourceNumberingURL = sourceDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("numbering.xml")
        guard fileManager.fileExists(atPath: sourceNumberingURL.path) else {
            throw DocxCombinationError.missingRequiredPart("word/numbering.xml", sourceURL)
        }

        let baseNumberingURL = baseDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("numbering.xml")
        let baseDocument: XMLDocument

        if fileManager.fileExists(atPath: baseNumberingURL.path) {
            do {
                baseDocument = try XMLDocument(contentsOf: baseNumberingURL, options: .nodePreserveWhitespace)
            } catch {
                throw DocxCombinationError.invalidXML("word/numbering.xml", sourceURL)
            }
        } else {
            baseDocument = try makeXMLDocument("""
            <?xml version="1.0" encoding="UTF-8"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
            """)
            relationships.ensure(type: OpenXMLRelationshipType.numbering, target: "numbering.xml")
            contentTypes.ensureOverride(partName: "/word/numbering.xml", contentType: OpenXMLContentType.numbering)
        }

        let sourceDocument: XMLDocument
        do {
            sourceDocument = try XMLDocument(contentsOf: sourceNumberingURL, options: .nodePreserveWhitespace)
        } catch {
            throw DocxCombinationError.invalidXML("word/numbering.xml", sourceURL)
        }

        guard let baseRoot = baseDocument.rootElement(),
              let sourceRoot = sourceDocument.rootElement() else {
            throw DocxCombinationError.invalidXML("word/numbering.xml", sourceURL)
        }

        let sourceAbstractNumbers = dictionaryByIntegerAttribute(
            sourceRoot.childElements(localName: "abstractNum"),
            attribute: "abstractNumId"
        )
        let sourceNumbers = dictionaryByIntegerAttribute(
            sourceRoot.childElements(localName: "num"),
            attribute: "numId"
        )
        var nextAbstractID = (maxIntegerAttribute(
            baseRoot.childElements(localName: "abstractNum"),
            attribute: "abstractNumId"
        ) ?? -1) + 1
        var nextNumberID = (maxIntegerAttribute(
            baseRoot.childElements(localName: "num"),
            attribute: "numId"
        ) ?? 0) + 1

        var numberingMap: [String: String] = [:]

        for oldNumberID in usedNumberingIDs.sorted() {
            guard let sourceNumber = sourceNumbers[oldNumberID],
                  let oldAbstractID = sourceNumber.firstChildElement(localName: "abstractNumId")?.integerAttribute(localName: "val"),
                  let sourceAbstractNumber = sourceAbstractNumbers[oldAbstractID] else {
                continue
            }

            let newAbstractID = nextAbstractID
            let newNumberID = nextNumberID
            nextAbstractID += 1
            nextNumberID += 1

            let abstractCopy = sourceAbstractNumber.copy() as! XMLElement
            abstractCopy.setAttribute(localName: "abstractNumId", preferredName: "w:abstractNumId", value: "\(newAbstractID)")
            baseRoot.addChild(abstractCopy)

            let numberCopy = sourceNumber.copy() as! XMLElement
            numberCopy.setAttribute(localName: "numId", preferredName: "w:numId", value: "\(newNumberID)")
            numberCopy.firstChildElement(localName: "abstractNumId")?
                .setAttribute(localName: "val", preferredName: "w:val", value: "\(newAbstractID)")
            baseRoot.addChild(numberCopy)

            numberingMap["\(oldNumberID)"] = "\(newNumberID)"
        }

        updateNumberingIDs(in: sourceBody, using: numberingMap)
        try saveXMLDocument(baseDocument, to: baseNumberingURL)
    }

    private func collectNumberingIDs(in element: XMLElement) -> Set<Int> {
        var ids = Set<Int>()
        walk(element) { node in
            guard node.hasLocalName("numId"),
                  let value = node.integerAttribute(localName: "val") else {
                return
            }
            ids.insert(value)
        }
        return ids
    }

    private func updateNumberingIDs(in element: XMLElement, using numberingMap: [String: String]) {
        guard !numberingMap.isEmpty else {
            return
        }

        walk(element) { node in
            guard node.hasLocalName("numId"),
                  let value = node.attributeValue(localName: "val"),
                  let replacement = numberingMap[value] else {
                return
            }
            node.setAttribute(localName: "val", preferredName: "w:val", value: replacement)
        }
    }

    private func dictionaryByIntegerAttribute(_ elements: [XMLElement], attribute: String) -> [Int: XMLElement] {
        Dictionary(uniqueKeysWithValues: elements.compactMap { element in
            guard let value = element.integerAttribute(localName: attribute) else {
                return nil
            }
            return (value, element)
        })
    }

    private func maxIntegerAttribute(_ elements: [XMLElement], attribute: String) -> Int? {
        elements.compactMap { $0.integerAttribute(localName: attribute) }.max()
    }

    private func walk(_ element: XMLElement, visit: (XMLElement) -> Void) {
        visit(element)

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else {
                continue
            }
            walk(childElement, visit: visit)
        }
    }

    private func saveXMLDocument(_ document: XMLDocument, to url: URL) throws {
        let data = document.xmlData(options: .nodePrettyPrint)
        try data.write(to: url, options: .atomic)
    }

    private func makeXMLDocument(_ xml: String) throws -> XMLDocument {
        let data = Data(xml.utf8)
        return try XMLDocument(data: data, options: .nodePreserveWhitespace)
    }
}

private struct OpenXMLRelationshipType {
    static let styles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let numbering = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
}

private struct OpenXMLContentType {
    static let styles = "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"
    static let numbering = "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
}

private struct DocumentRelationship: Equatable {
    var id: String
    var type: String
    var target: String
    var targetMode: String?
}

private final class DocumentRelationshipStore {
    private let fileManager: FileManager
    private let relationshipsURL: URL
    private var document: XMLDocument
    private var root: XMLElement

    init(
        packageDirectory: URL,
        fileManager: FileManager,
        createIfMissing: Bool = true
    ) throws {
        self.fileManager = fileManager
        self.relationshipsURL = packageDirectory
            .appendingPathComponent("word", isDirectory: true)
            .appendingPathComponent("_rels", isDirectory: true)
            .appendingPathComponent("document.xml.rels")

        if fileManager.fileExists(atPath: relationshipsURL.path) {
            self.document = try XMLDocument(contentsOf: relationshipsURL, options: .nodePreserveWhitespace)
        } else if createIfMissing {
            self.document = try XMLDocument(
                data: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
                """.utf8),
                options: .nodePreserveWhitespace
            )
        } else {
            self.document = try XMLDocument(
                data: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
                """.utf8),
                options: .nodePreserveWhitespace
            )
        }

        guard let root = document.rootElement() else {
            throw DocxCombinationError.invalidXML("word/_rels/document.xml.rels", packageDirectory)
        }
        self.root = root
    }

    func relationship(id: String) -> DocumentRelationship? {
        relationships().first { $0.id == id }
    }

    func relationships() -> [DocumentRelationship] {
        root.childElements(localName: "Relationship").compactMap { element in
            guard let id = element.attributeValue(localName: "Id"),
                  let type = element.attributeValue(localName: "Type"),
                  let target = element.attributeValue(localName: "Target") else {
                return nil
            }

            return DocumentRelationship(
                id: id,
                type: type,
                target: target,
                targetMode: element.attributeValue(localName: "TargetMode")
            )
        }
    }

    func nextRelationshipID() -> String {
        let maxID = relationships()
            .compactMap { relationship -> Int? in
                guard relationship.id.hasPrefix("rId") else {
                    return nil
                }
                return Int(relationship.id.dropFirst(3))
            }
            .max() ?? 0

        return "rId\(maxID + 1)"
    }

    @discardableResult
    func ensure(type: String, target: String, targetMode: String? = nil) -> String {
        if let existing = relationships().first(where: {
            $0.type == type && $0.target == target && $0.targetMode == targetMode
        }) {
            return existing.id
        }

        let id = nextRelationshipID()
        add(id: id, type: type, target: target, targetMode: targetMode)
        return id
    }

    func add(id: String, type: String, target: String, targetMode: String?) {
        let relationship = XMLElement(name: "Relationship")
        relationship.setAttribute(localName: "Id", preferredName: "Id", value: id)
        relationship.setAttribute(localName: "Type", preferredName: "Type", value: type)
        relationship.setAttribute(localName: "Target", preferredName: "Target", value: target)
        if let targetMode {
            relationship.setAttribute(localName: "TargetMode", preferredName: "TargetMode", value: targetMode)
        }
        root.addChild(relationship)
    }

    func save() throws {
        try fileManager.createDirectory(
            at: relationshipsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try document.xmlData(options: .nodePrettyPrint).write(to: relationshipsURL, options: .atomic)
    }
}

private final class ContentTypeStore {
    private let contentTypesURL: URL
    private var document: XMLDocument
    private var root: XMLElement

    init(packageDirectory: URL, fileManager: FileManager) throws {
        self.contentTypesURL = packageDirectory.appendingPathComponent("[Content_Types].xml")
        guard fileManager.fileExists(atPath: contentTypesURL.path) else {
            throw DocxCombinationError.missingRequiredPart("[Content_Types].xml", packageDirectory)
        }

        self.document = try XMLDocument(contentsOf: contentTypesURL, options: .nodePreserveWhitespace)
        guard let root = document.rootElement() else {
            throw DocxCombinationError.invalidXML("[Content_Types].xml", packageDirectory)
        }
        self.root = root
    }

    func mergeDefaults(from packageDirectory: URL) throws {
        let source = try ContentTypeStore(packageDirectory: packageDirectory, fileManager: .default)
        for defaultElement in source.root.childElements(localName: "Default") {
            guard let ext = defaultElement.attributeValue(localName: "Extension"),
                  let contentType = defaultElement.attributeValue(localName: "ContentType") else {
                continue
            }
            ensureDefault(fileExtension: ext, contentType: contentType)
        }
    }

    func copyOverride(oldPartName: String, newPartName: String, from source: ContentTypeStore) {
        guard let contentType = source.overrideContentType(partName: oldPartName) else {
            return
        }
        ensureOverride(partName: newPartName, contentType: contentType)
    }

    func ensureDefault(fileExtension: String, contentType: String) {
        if root.childElements(localName: "Default").contains(where: {
            $0.attributeValue(localName: "Extension")?.caseInsensitiveCompare(fileExtension) == .orderedSame
        }) {
            return
        }

        let defaultElement = XMLElement(name: "Default")
        defaultElement.setAttribute(localName: "Extension", preferredName: "Extension", value: fileExtension)
        defaultElement.setAttribute(localName: "ContentType", preferredName: "ContentType", value: contentType)
        root.addChild(defaultElement)
    }

    func ensureOverride(partName: String, contentType: String) {
        if overrideContentType(partName: partName) != nil {
            return
        }

        let override = XMLElement(name: "Override")
        override.setAttribute(localName: "PartName", preferredName: "PartName", value: partName)
        override.setAttribute(localName: "ContentType", preferredName: "ContentType", value: contentType)
        root.addChild(override)
    }

    func overrideContentType(partName: String) -> String? {
        root.childElements(localName: "Override")
            .first { $0.attributeValue(localName: "PartName") == partName }?
            .attributeValue(localName: "ContentType")
    }

    func save() throws {
        try document.xmlData(options: .nodePrettyPrint).write(to: contentTypesURL, options: .atomic)
    }
}

private extension XMLElement {
    func hasLocalName(_ name: String) -> Bool {
        normalizedLocalName == name
    }

    func childElements(localName: String) -> [XMLElement] {
        (children ?? []).compactMap { node in
            guard let element = node as? XMLElement, element.hasLocalName(localName) else {
                return nil
            }
            return element
        }
    }

    func firstChildElement(localName: String) -> XMLElement? {
        childElements(localName: localName).first
    }

    func firstDescendantElement(localName: String) -> XMLElement? {
        if hasLocalName(localName) {
            return self
        }

        for child in children ?? [] {
            guard let element = child as? XMLElement else {
                continue
            }
            if let match = element.firstDescendantElement(localName: localName) {
                return match
            }
        }

        return nil
    }

    func attributeValue(localName: String) -> String? {
        (attributes ?? []).first { $0.normalizedLocalName == localName || $0.name == localName }?.stringValue
    }

    func integerAttribute(localName: String) -> Int? {
        attributeValue(localName: localName).flatMap(Int.init)
    }

    func setAttribute(localName: String, preferredName: String, value: String) {
        if let attribute = (attributes ?? []).first(where: { $0.normalizedLocalName == localName || $0.name == preferredName }) {
            attribute.stringValue = value
            return
        }

        addAttribute(XMLNode.attribute(withName: preferredName, stringValue: value) as! XMLNode)
    }
}

private extension XMLNode {
    var normalizedLocalName: String {
        if let localName, !localName.isEmpty {
            return localName
        }

        guard let name, !name.isEmpty else {
            return ""
        }

        return name.split(separator: ":").last.map(String.init) ?? name
    }
}

private extension String {
    var removingFragment: String {
        split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? self
    }

    var lastPathComponentFromPath: String {
        (removingFragment as NSString).lastPathComponent
    }

    var looksLikeExternalTarget: Bool {
        let lowercased = lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("mailto:")
            || lowercased.hasPrefix("ftp://")
    }
}

private extension Sequence where Element == String {
    func sortedByRelationshipID() -> [String] {
        sorted { lhs, rhs in
            switch (lhs.relationshipNumber, rhs.relationshipNumber) {
            case let (left?, right?):
                return left < right
            default:
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }
}

private extension String {
    var relationshipNumber: Int? {
        guard hasPrefix("rId") else {
            return nil
        }
        return Int(dropFirst(3))
    }
}

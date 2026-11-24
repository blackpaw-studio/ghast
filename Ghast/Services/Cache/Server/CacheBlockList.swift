import Foundation

/// Parses an Azure `Put Block List` body (`<BlockList><Latest>id</Latest>…</BlockList>`) into
/// block IDs in commit order. Refuses a DOCTYPE or any entity declaration, never resolves
/// external entities, and caps the number of IDs.
enum CacheBlockList {
    static func parse(_ data: Data, maximumBlocks: Int) -> [String]? {
        guard !containsDeclaration(data) else { return nil }
        let delegate = Delegate(maximumBlocks: maximumBlocks)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.isRejected, delegate.sawRoot else { return nil }
        return delegate.ids
    }

    /// True when the body has a `<!DOCTYPE` or `<!ENTITY` (checked before XMLParser sees it).
    private static func containsDeclaration(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).uppercased()
        return text.contains("<!DOCTYPE") || text.contains("<!ENTITY")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private static let blockElements: Set<String> = ["Latest", "Committed", "Uncommitted"]
        let maximumBlocks: Int
        private(set) var ids: [String] = []
        private(set) var isRejected = false
        private(set) var sawRoot = false
        private var path: [String] = []
        private var text = ""

        init(maximumBlocks: Int) { self.maximumBlocks = maximumBlocks }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let isValid = path.isEmpty ? name == "BlockList" : path == ["BlockList"] && Self.blockElements.contains(name)
            guard isValid else { return reject(parser) }
            sawRoot = true
            path.append(name)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if text.utf8.count > 256 { reject(parser) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            guard Self.blockElements.contains(name) else { return }
            ids.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if ids.count > maximumBlocks { reject(parser) }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                    systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            reject(parser)
            return nil
        }

        private func reject(_ parser: XMLParser) {
            isRejected = true
            parser.abortParsing()
        }
    }
}

import Foundation

/// Parses an Azure `Put Block List` body (`<BlockList><Latest>id</Latest>…</BlockList>`) into
/// block IDs in commit order. Accepts only plain UTF-8 with no `<!` markup at all (so no
/// DOCTYPE or entity, in any encoding), never resolves external entities, and caps the
/// number of IDs.
enum CacheBlockList {
    static func parse(_ data: Data, maximumBlocks: Int) -> [String]? {
        guard let body = plainUTF8(data) else { return nil }
        let delegate = Delegate(maximumBlocks: maximumBlocks)
        let parser = XMLParser(data: body)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.isRejected, delegate.sawRoot else { return nil }
        return delegate.ids
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let allowedControls: Set<UInt8> = [0x09, 0x0A, 0x0D]

    /// The body without a UTF-8 byte order mark, when it is valid UTF-8 with no other control
    /// bytes (so XMLParser can't detect UTF-16 or UTF-32), no `<!` anywhere (no DOCTYPE,
    /// entity, comment or CDATA) and no XML declaration naming another encoding. Else nil.
    private static func plainUTF8(_ data: Data) -> Data? {
        let bytes = data.starts(with: utf8BOM) ? Array(data.dropFirst(utf8BOM.count)) : Array(data)
        guard String(validating: bytes, as: UTF8.self) != nil,
              !bytes.contains(where: { $0 < 0x20 && !allowedControls.contains($0) }),
              bytes.firstRange(of: Array("<!".utf8)) == nil,
              declaresOnlyUTF8(String(decoding: bytes, as: UTF8.self))
        else { return nil }
        return Data(bytes)
    }

    private static func declaresOnlyUTF8(_ text: String) -> Bool {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return true }
        let declaration = text[..<end.lowerBound].lowercased().replacingOccurrences(of: " ", with: "")
        guard declaration.contains("encoding") else { return true }
        return declaration.contains(#"encoding="utf-8""#) || declaration.contains("encoding='utf-8'")
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

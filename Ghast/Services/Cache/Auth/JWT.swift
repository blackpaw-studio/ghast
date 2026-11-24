import Foundation

/// A compact JWS split into its parts, with the header and payload decoded as JSON objects.
struct JWT {
    let header: [String: Any]
    let payload: [String: Any]
    /// `base64url(header).base64url(payload)`, the bytes the signature covers.
    let signingInput: Data
    let signature: Data

    /// Upper bound on a token's length; GitHub's job tokens are a few KiB.
    static let maximumLength = 16 * 1024

    init?(compact token: String) {
        guard token.utf8.count <= Self.maximumLength else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Base64URL.decode(parts[0]),
              let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        self.header = header
        self.payload = payload
        self.signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        self.signature = signature
    }
}

enum Base64URL {
    /// Decodes unpadded base64url; nil for anything else (including standard `+` and `/`).
    static func decode(_ text: some StringProtocol) -> Data? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

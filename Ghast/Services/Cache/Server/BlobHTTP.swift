import Foundation

/// A reply from a blob route: status, headers and a small body (downloads stream separately).
struct BlobResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    /// An Azure-style XML error, which the Azure SDK in `actions/cache` parses.
    static func azureError(_ status: Int, _ code: String) -> BlobResponse {
        let xml = #"<?xml version="1.0" encoding="utf-8"?><Error><Code>\#(code)</Code><Message>\#(code)</Message></Error>"#
        return BlobResponse(status: status, headers: ["content-type": "application/xml", "x-ms-error-code": code],
                            body: Data(xml.utf8))
    }

    static func created() -> BlobResponse {
        BlobResponse(status: 201, headers: ["x-ms-request-id": UUID().uuidString.lowercased()], body: Data())
    }
}

enum ConstantTime {
    /// Compares two secrets without stopping at the first different byte.
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

import Foundation

/// A request record from `GhastTests/Fixtures/ActionsCache/<name>.json` (Step 0.4 capture).
struct ActionsCacheFixtureRecord {
    let method: String
    let path: String
    let query: [(String, String)]
    let headers: [String: String]
    let bodyLength: Int
    let status: Int
    let responseHeaders: [String: String]
    let responseLength: Int
    /// The JSON (Twirp) or XML (block list) request body, when captured.
    let body: Any?
    let responseBody: Any?

    var jsonBody: Data? {
        guard let body, JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    func queryValue(_ name: String) -> String? { query.first { $0.0 == name }?.1 }
}

enum ActionsCacheFixture {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ActionsCache")

    static func records(_ name: String) throws -> [ActionsCacheFixtureRecord] {
        let data = try Data(contentsOf: folder.appendingPathComponent("\(name).json"))
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (document["requests"] as! [[String: Any]]).map { item in
            ActionsCacheFixtureRecord(
                method: item["method"] as! String,
                path: item["path"] as! String,
                query: (item["query"] as? [[String]] ?? []).map { ($0[0], $0[1]) },
                headers: item["headers"] as? [String: String] ?? [:],
                bodyLength: item["body_length"] as! Int,
                status: item["status"] as! Int,
                responseHeaders: item["response_headers"] as? [String: String] ?? [:],
                responseLength: item["response_length"] as! Int,
                body: item["body"].flatMap { $0 is NSNull ? nil : $0 },
                responseBody: item["response_body"].flatMap { $0 is NSNull ? nil : $0 })
        }
    }
}

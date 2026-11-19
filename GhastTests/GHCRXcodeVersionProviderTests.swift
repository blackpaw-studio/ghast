import Testing
import Foundation
@testable import Ghast

@Suite("GHCRXcodeVersionProvider")
struct GHCRXcodeVersionProviderTests {
    private let tags = #"{"name":"cirruslabs/macos-tahoe-xcode","tags":["latest","26.4","27-beta-4","27.2","26.10","27"]}"#

    @Test("fetches an anonymous pull token, then the tag list, and returns release tags newest first")
    func loads() async throws {
        let transport = FakeTransport([.json(#"{"token":"tok123"}"#), .json(tags)])

        let result = await GHCRXcodeVersionProvider(transport: transport).versions(for: .tahoe)

        #expect(result == TartXcodeVersions(tags: ["27.2", "27", "26.10", "26.4"], source: .loaded))
        let requests = await transport.requests
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://ghcr.io/token?scope=repository:cirruslabs/macos-tahoe-xcode:pull",
            "https://ghcr.io/v2/cirruslabs/macos-tahoe-xcode/tags/list?n=1000",
        ])
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok123")
    }

    @Test("uses the repository for the chosen macOS version")
    func sequoiaRepo() async {
        let transport = FakeTransport([.json(#"{"token":"t"}"#), .json(#"{"tags":["16.4"]}"#)])
        _ = await GHCRXcodeVersionProvider(transport: transport).versions(for: .sequoia)
        #expect(await transport.requests.first?.url?.absoluteString.contains("macos-sequoia-xcode") == true)
    }

    @Test("a transport failure falls back to the built-in list")
    func transportFailure() async {
        let transport = FakeTransport([.failure(URLError(.notConnectedToInternet))])
        let result = await GHCRXcodeVersionProvider(transport: transport).versions(for: .tahoe)
        #expect(result == TartXcodeVersions(tags: TartImageCatalog.fallbackTags(for: .tahoe), source: .fallback))
    }

    @Test("an HTTP error, bad JSON, or a list with no release tags all fall back", arguments: [
        [FakeTransport.Reply.json("{}", status: 403)],
        [.json(#"{"token":"t"}"#), .json("nope")],
        [.json(#"{"token":"t"}"#), .json(#"{"tags":["latest","27-beta-1"]}"#)],
        [.json(#"{"token":"t"}"#), .json("{}", status: 500)],
    ])
    func badReplies(replies: [FakeTransport.Reply]) async {
        let result = await GHCRXcodeVersionProvider(transport: FakeTransport(replies)).versions(for: .tahoe)
        #expect(result.source == .fallback)
        #expect(result.tags == TartImageCatalog.fallbackTags(for: .tahoe))
    }
}

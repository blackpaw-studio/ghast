import Testing
import Foundation
@testable import Ghast

/// Serves `/user/repos` as `lastPage` full pages, announcing the last page in a `Link` header
/// the way GitHub does. Pages after the first are held until `releaseThreshold` of them are
/// in flight at once, so a client that walks pages one after another never gets past page 2.
actor PagedTransport: HTTPTransport {
    let lastPage: Int
    let announcesLastPage: Bool
    private let releaseThreshold: Int
    private(set) var requestedPages: [Int] = []
    private(set) var maxInFlight = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(lastPage: Int, announcesLastPage: Bool = true, releaseThreshold: Int = 1) {
        self.lastPage = lastPage
        self.announcesLastPage = announcesLastPage
        self.releaseThreshold = releaseThreshold
    }

    static func ids(onPage page: Int) -> [Int] {
        (0..<100).map { (page - 1) * 100 + $0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = Int(items.first { $0.name == "page" }?.value ?? "1") ?? 1
        requestedPages.append(page)
        if page > 1 {
            await hold()
        }
        let body = "[" + Self.ids(onPage: page).map(Self.repoJSON).joined(separator: ",") + "]"
        var headers: [String: String] = [:]
        if announcesLastPage {
            headers["Link"] = "<https://api.github.com/user/repos?page=2&per_page=100>; rel=\"next\", "
                + "<https://api.github.com/user/repos?page=\(lastPage)&per_page=100>; rel=\"last\""
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }

    /// Waits until enough pages are in flight together (or no more can arrive), then lets
    /// every held page answer.
    private func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            maxInFlight = max(maxInFlight, held.count)
            let stillToCome = lastPage - 1 - requestedPages.filter { $0 > 1 }.count
            if held.count >= releaseThreshold || stillToCome == 0 {
                let ready = held
                held = []
                ready.forEach { $0.resume() }
            }
        }
    }

    private static func repoJSON(_ id: Int) -> String {
        #"{"id":\#(id),"name":"r\#(id)","full_name":"o/r\#(id)","description":null,"private":false,"owner":{"id":1,"login":"o","avatar_url":"","name":null,"email":null},"html_url":"https://github.com/o/r\#(id)"}"#
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct GitHubAPIPaginationTests {
    @Test func requestsTheRemainingPagesTogetherOnceGitHubNamesTheLastPage() async throws {
        let transport = PagedTransport(lastPage: 4, releaseThreshold: 3)
        let service = GitHubAPIService(transport: transport)

        let repositories = try await service.fetchRepositories()

        #expect(await transport.maxInFlight == 3)
        #expect(await transport.requestedPages.sorted() == [1, 2, 3, 4])
        #expect(repositories.map(\.id) == (1...4).flatMap(PagedTransport.ids(onPage:)))
    }

    @Test func keepsGitHubsOrderAcrossManyPagesFetchedFourAtATime() async throws {
        let transport = PagedTransport(lastPage: 12, releaseThreshold: 4)
        let service = GitHubAPIService(transport: transport)

        let repositories = try await service.fetchRepositories()

        #expect(await transport.maxInFlight == 4)
        #expect(repositories.map(\.id) == (1...12).flatMap(PagedTransport.ids(onPage:)))
    }

    @Test func stopsAtTheSafetyLimitWhenGitHubNamesTooManyPages() async throws {
        let transport = PagedTransport(lastPage: 60, releaseThreshold: 1)
        let service = GitHubAPIService(transport: transport)

        let repositories = try await service.fetchRepositories()

        #expect(await transport.requestedPages.sorted() == Array(1...50))
        #expect(repositories.count == 5_000)
    }
}

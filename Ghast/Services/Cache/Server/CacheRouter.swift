import Foundation
import HTTPTypes
import Hummingbird

/// Sends each request on one VM's listener to its handler. Every path is at the root, as
/// actions/toolkit builds them:
/// - `/devstoreaccount1/upload/<id>` and `/download/<id>`: the blob routes; the upload ID plus
///   `sig`, or the 128-bit download ID, is the capability.
/// - `/twirp/…CacheService/<Method>` (POST): the Twirp service; its event goes to that VM's
///   stream.
/// - anything else: the passthrough to the results service.
/// A VM that has unregistered gets 404 for everything but the blob routes.
struct CacheRouter: Sendable {
    let twirp: CacheTwirpService
    let upload: CacheBlobUploadHandler
    let download: CacheBlobDownloadHandler
    let passthrough: CachePassthrough
    let registry: CacheVMRegistry

    private static let twirpPrefix = "/twirp/" + CacheTwirp.servicePrefix
    private static let uploadPrefix = "/devstoreaccount1/upload/"
    private static let downloadPrefix = "/download/"

    func route(_ request: Request, serverBase: URL, vmID: String) async -> Response {
        let target = request.uri.string
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { return Self.twirpError(400, "malformed") }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if let id = Self.identifier(path, after: Self.uploadPrefix) {
            return await routeUpload(request, uploadID: id, target: target)
        }
        if let id = Self.identifier(path, after: Self.downloadPrefix) {
            return await routeDownload(request, downloadID: id)
        }
        guard registry.contains(vmID) else { return Self.twirpError(404, "bad_route") }
        guard path.lowercased().hasPrefix(Self.twirpPrefix.lowercased()) else {
            return await routePassthrough(request, target: target)
        }
        return await routeTwirp(request, path: path, serverBase: serverBase, vmID: vmID)
    }

    private func routeTwirp(_ request: Request, path: String, serverBase: URL, vmID: String) async -> Response {
        guard request.method == .post else { return Self.twirpError(404, "bad_route") }
        let method = String(path.dropFirst(Self.twirpPrefix.count))
        var request = request
        guard let buffer = try? await request.collectBody(upTo: CacheTwirp.maximumBodyBytes) else {
            return Self.twirpError(400, "malformed")
        }
        let (response, event) = await twirp.handle(method: method, bearer: Self.bearer(request.headers),
                                                   body: Data(buffer.readableBytesView), serverBase: serverBase)
        if let event { registry.emit(event, for: vmID) }
        return Response(status: .init(code: response.status), headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: response.body)))
    }

    private func routeUpload(_ request: Request, uploadID: String, target: String) async -> Response {
        let query = URLComponents(string: target)?.queryItems ?? []
        let reply = await upload.handle(method: request.method.rawValue, uploadID: uploadID, query: query,
                                        headers: Self.headerMap(request.headers),
                                        body: request.body.map { $0.readableBytesView })
        return Response(status: .init(code: reply.status), headers: Self.fields(reply.headers),
                        body: .init(byteBuffer: ByteBuffer(bytes: reply.body)))
    }

    private func routeDownload(_ request: Request, downloadID: String) async -> Response {
        let reply = await download.handle(method: request.method.rawValue, downloadID: downloadID,
                                          headers: Self.headerMap(request.headers))
        guard let body = reply.body else {
            return Response(status: .init(code: reply.status), headers: Self.fields(reply.headers), body: .init())
        }
        return Response(status: .init(code: reply.status), headers: Self.fields(reply.headers),
                        body: ResponseBody(contentLength: Int(body.length)) { writer in
                            for try await chunk in body.chunks() { try await writer.write(ByteBuffer(bytes: chunk)) }
                            try await writer.finish(nil)
                        })
    }

    private func routePassthrough(_ request: Request, target: String) async -> Response {
        let incoming = request.body
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await buffer in incoming { continuation.yield(Data(buffer.readableBytesView)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let reply = await passthrough.handle(method: request.method.rawValue, target: target,
                                             headers: request.headers.map { ($0.name.rawName, $0.value) }, body: body)
        var fields = HTTPFields()
        reply.headers.forEach { name, value in HTTPField.Name(name).map { fields.append(HTTPField(name: $0, value: value)) } }
        let stream = reply.body
        return Response(status: .init(code: reply.status), headers: fields, body: ResponseBody { writer in
            for try await chunk in stream { try await writer.write(ByteBuffer(bytes: chunk)) }
            try await writer.finish(nil)
        })
    }

    /// The single path segment after `prefix`, or nil.
    private static func identifier(_ path: String, after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        return id.isEmpty || id.contains("/") ? nil : id
    }

    private static func bearer(_ headers: HTTPFields) -> String? {
        guard let value = headers[.authorization], value.count > 7,
              value.prefix(7).lowercased() == "bearer " else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    private static func headerMap(_ headers: HTTPFields) -> [String: String] {
        Dictionary(headers.map { ($0.name.canonicalName, $0.value) }) { _, last in last }
    }

    private static func fields(_ headers: [String: String]) -> HTTPFields {
        var fields = HTTPFields()
        headers.sorted { $0.key < $1.key }.forEach { name, value in
            HTTPField.Name(name).map { fields.append(HTTPField(name: $0, value: value)) }
        }
        return fields
    }

    private static func twirpError(_ status: Int, _ code: String) -> Response {
        let body = CacheTwirpService.error(status, code, code == "bad_route" ? "not found" : "invalid request").body
        return Response(status: .init(code: status), headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }
}

/// The Hummingbird responder for one VM's listener; `serverBase` is that listener's origin.
struct CacheResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let router: CacheRouter
    let serverBase: URL
    let vmID: String

    func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
        await router.route(request, serverBase: serverBase, vmID: vmID)
    }
}

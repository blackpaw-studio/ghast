import Foundation

/// The subset of Azure block blob uploads `actions/cache` v4 sends to the signed upload URL
/// (`PUT /devstoreaccount1/upload/{id}?sig=…`): a single-shot `BlockBlob` PUT, `comp=block`
/// with a `blockid`, and `comp=blocklist`, which commits the blocks in list order. Bodies
/// stream to disk through `CachePartWriter`, off the store's actor.
struct CacheBlobUploadHandler: Sendable {
    struct Limits: Sendable {
        var maximumBlocks = 50_000
        var maximumBlockListBytes = 4 * 1024 * 1024
        var maximumBlockIDBytes = 64
    }

    let store: CacheStore
    var limits = Limits()

    private enum Operation {
        case whole
        case block(id: String)
        case blockList
    }

    func handle<Body: AsyncSequence>(method: String, uploadID: String, query: [URLQueryItem], headers: [String: String],
                                     body: Body) async -> BlobResponse
        where Body.Element: Collection, Body.Element.Element == UInt8 {
        guard method == "PUT" else { return .azureError(405, "UnsupportedHttpVerb") }
        guard let upload = await store.pendingUpload(uploadID) else { return .azureError(404, "BlobNotFound") }
        let sig = query.first { $0.name == "sig" }?.value ?? ""
        guard ConstantTime.equal(sig, upload.signature) else { return .azureError(403, "AuthenticationFailed") }
        let declaredLength = headers["content-length"].map { Int64($0) ?? -1 }
        if let declaredLength, declaredLength < 0 { return .azureError(400, "InvalidHeaderValue") }

        switch operation(query: query, headers: headers) {
        case nil:
            return .azureError(400, "InvalidQueryParameterValue")
        case .whole:
            return await writePart(.whole, uploadID: uploadID, declaredLength: declaredLength, body: body)
        case .block(let id):
            guard isValidBlockID(id) else { return .azureError(400, "InvalidQueryParameterValue") }
            if !upload.completedBlocks.contains(id), upload.completedBlocks.count >= limits.maximumBlocks {
                return .azureError(400, "BlockCountExceedsLimit")
            }
            return await writePart(.block(id: id), uploadID: uploadID, declaredLength: declaredLength, body: body)
        case .blockList:
            return await commit(uploadID: uploadID, body: body)
        }
    }

    private func operation(query: [URLQueryItem], headers: [String: String]) -> Operation? {
        switch query.first(where: { $0.name == "comp" })?.value {
        case nil: headers["x-ms-blob-type"] == "BlockBlob" ? .whole : nil
        case "block": query.first { $0.name == "blockid" }?.value.map { .block(id: $0) }
        case "blocklist": .blockList
        default: nil
        }
    }

    /// A block ID is standard base64 of 1–64 bytes. It names a hashed file, never a path.
    private func isValidBlockID(_ id: String) -> Bool {
        guard let decoded = Data(base64Encoded: id) else { return false }
        return (1 ... limits.maximumBlockIDBytes).contains(decoded.count)
    }

    private func writePart<Body: AsyncSequence>(_ part: CacheUploadPart, uploadID: String, declaredLength: Int64?,
                                                body: Body) async -> BlobResponse
        where Body.Element: Collection, Body.Element.Element == UInt8 {
        let capacity = await store.capacityBytes()
        if let declaredLength, declaredLength > capacity { return .azureError(413, "RequestBodyTooLarge") }
        let writer: CachePartWriter
        do {
            writer = try await store.beginPart(uploadID: uploadID, part: part)
        } catch {
            return Self.storeFailure(error)
        }
        var written: Int64 = 0
        do {
            for try await chunk in body {
                written += Int64(chunk.count)
                guard written <= capacity else {
                    await store.abandonPart(writer)
                    return .azureError(413, "RequestBodyTooLarge")
                }
                try writer.write(chunk)
            }
        } catch CacheStoreError.tooLarge {
            await store.abandonPart(writer)
            return .azureError(413, "RequestBodyTooLarge")
        } catch let error as CacheStoreError {
            return await finishAfterWriteError(writer, error)
        } catch {
            await store.abandonPart(writer)
            return .azureError(400, "IncompleteBody")
        }
        if let declaredLength, declaredLength != written {
            await store.abandonPart(writer)
            return .azureError(400, "IncompleteBody")
        }
        do {
            try await store.finishPart(writer)
            return .created()
        } catch {
            return Self.storeFailure(error)
        }
    }

    /// A failed write still goes through `finishPart`, so the store drops the upload.
    private func finishAfterWriteError(_ writer: CachePartWriter, _ error: CacheStoreError) async -> BlobResponse {
        do {
            try await store.finishPart(writer)
            return Self.storeFailure(error)
        } catch {
            return Self.storeFailure(error)
        }
    }

    private func commit<Body: AsyncSequence>(uploadID: String, body: Body) async -> BlobResponse
        where Body.Element: Collection, Body.Element.Element == UInt8 {
        var data = Data()
        do {
            for try await chunk in body {
                guard data.count + chunk.count <= limits.maximumBlockListBytes else {
                    return .azureError(413, "RequestBodyTooLarge")
                }
                data.append(contentsOf: chunk)
            }
        } catch {
            return .azureError(400, "IncompleteBody")
        }
        guard let order = CacheBlockList.parse(data, maximumBlocks: limits.maximumBlocks), !order.isEmpty,
              order.allSatisfy(isValidBlockID) else {
            return .azureError(400, "InvalidXmlDocument")
        }
        do {
            try await store.commitBlocks(uploadID: uploadID, order: order)
            return .created()
        } catch {
            return Self.storeFailure(error)
        }
    }

    private static func storeFailure(_ error: Error) -> BlobResponse {
        switch error as? CacheStoreError {
        case .unknownUpload: .azureError(404, "BlobNotFound")
        case .commitInProgress: .azureError(409, "OperationNotAllowedInCurrentState")
        case .missingBlock, .duplicateBlock: .azureError(400, "InvalidBlockList")
        case .tooLarge: .azureError(413, "RequestBodyTooLarge")
        default: .azureError(500, "InternalError")
        }
    }
}

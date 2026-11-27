import Foundation

/// A VM runner and the image it runs, for telling which stored images are in use.
struct RunnerImageUse: Equatable, Sendable {
    let runnerName: String
    /// The runner's `.tart(image:)`: a tag ref, a digest ref, or a local VM's name.
    let image: String
}

/// One image or VM Tart keeps on disk.
struct StoredImage: Identifiable, Equatable, Sendable {
    /// The digest ref for a pulled image (its folder), the tag for an unresolved tag, the name for a local VM.
    let id: String
    /// Its tags as short refs, or a short digest when it has none; a local VM's name.
    let displayName: String
    /// What `tart delete` takes: the digest ref for a pulled image (a tag delete would only drop
    /// the link), the tag for an unresolved tag, the name for a local VM.
    let deleteRef: String
    let sizeBytes: Int64
    let accessed: Date?
    /// Names of the runners that use it, sorted.
    let usedBy: [String]
    let isPulling: Bool
    let isRunning: Bool
    let isLocal: Bool
    /// A runner (or a pull) uses a tag of this repository that Ghast can't resolve to a digest, so
    /// it can't rule out that this image is the one the tag means.
    let isHeldByUnresolvedTag: Bool
    /// `deleteRef` is a shape `tart delete` may be given: a digest ref of a registry image, or
    /// the name of a local VM. Anything else is listed but never removed.
    let isSafeToDelete: Bool

    /// `Used by ci-runner` or `Not used by any runner`.
    var usageText: String {
        usedBy.isEmpty ? "Not used by any runner" : "Used by \(usedBy.joined(separator: ", "))"
    }

    /// Why Remove is off, or nil when the image can go.
    var removeBlockReason: String? {
        if !isSafeToDelete { return "Ghast can't safely remove this." }
        if isRunning { return "This VM is running." }
        if isPulling { return "This image is being pulled." }
        if !usedBy.isEmpty { return "Used by \(usedBy.joined(separator: ", "))." }
        if isHeldByUnresolvedTag { return "A runner uses a tag of this image that Ghast can't match to a download." }
        return nil
    }
}

/// What Tart stores, as the Tart Storage section shows it: `tart list` rows folded into one
/// entry per image. Pure; the model feeds it the list, the cache links and the runners.
struct TartStorageInventory: Equatable, Sendable {
    /// Pulled registry images, largest first.
    let pulled: [StoredImage]
    /// VMs made on this Mac, largest first. Ghast's own clones are left out.
    let localVMs: [StoredImage]
    /// Every listed image and VM once, in bytes.
    let totalBytes: Int64

    static let empty = TartStorageInventory(pulled: [], localVMs: [], totalBytes: 0)

    /// Pulled images that Remove Unused deletes: nothing uses, pulls or runs them. Local VMs
    /// are never part of it.
    var unusedPulled: [StoredImage] { pulled.filter { $0.removeBlockReason == nil } }

    private static let bytesPerGB: Int64 = 1_000_000_000
    private static let digestMarker = "@sha256:"

    static func make(
        entries: [TartVMEntry],
        digestForTag: (TartImageRef) -> String?,
        runnerImages: [RunnerImageUse],
        pullingImages: Set<String>
    ) -> TartStorageInventory {
        let visible = entries.filter { !$0.name.hasPrefix(TartBackend.clonePrefix) || $0.source != "local" }
        let pulled = pulledImages(
            visible.filter { $0.source != "local" },
            digestForTag: digestForTag, runnerImages: runnerImages, pullingImages: pullingImages,
            heldRepositories: unresolvedRepositories(
                of: runnerImages.map(\.image) + pullingImages, digestForTag: digestForTag
            )
        )
        let locals = visible.filter { $0.source == "local" }.map { entry in
            StoredImage(
                id: entry.name, displayName: entry.name, deleteRef: entry.name,
                sizeBytes: bytes(entry), accessed: entry.accessed,
                usedBy: users(of: [entry.name], in: runnerImages, resolving: digestForTag),
                isPulling: false, isRunning: entry.isRunning, isLocal: true, isHeldByUnresolvedTag: false,
                isSafeToDelete: isSafeLocalName(entry.name)
            )
        }
        return TartStorageInventory(
            pulled: bySize(pulled), localVMs: bySize(locals),
            totalBytes: (pulled + locals).reduce(0) { $0 + $1.sizeBytes }
        )
    }

    /// `host/repository` of every tag in use that doesn't resolve to a digest: failing closed, no
    /// image of those repositories may be removed.
    private static func unresolvedRepositories(of images: [String], digestForTag: (TartImageRef) -> String?) -> Set<String> {
        Set(images.compactMap { image in
            guard let ref = TartImageRef.parse(image), digestForTag(ref) == nil else { return nil }
            return "\(ref.host)/\(ref.repository)"
        })
    }

    // MARK: - Pulled images

    /// One image's rows: the digest row and every tag row that points at it.
    private struct Group {
        var repository: String
        var digest: String?
        var rows: [TartVMEntry] = []
        var tags: [String] = []
    }

    private static func pulledImages(
        _ rows: [TartVMEntry],
        digestForTag: (TartImageRef) -> String?,
        runnerImages: [RunnerImageUse],
        pullingImages: Set<String>,
        heldRepositories: Set<String>
    ) -> [StoredImage] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        func add(_ row: TartVMEntry, key: String, repository: String, digest: String?, tag: String?) {
            if groups[key] == nil {
                groups[key] = Group(repository: repository, digest: digest)
                order.append(key)
            }
            groups[key]?.rows.append(row)
            if let tag { groups[key]?.tags.append(tag) }
        }
        for row in rows {
            if let split = row.name.range(of: digestMarker) {
                let repository = String(row.name[..<split.lowerBound])
                add(row, key: row.name, repository: repository, digest: String(row.name[split.upperBound...]).withDigestPrefix, tag: nil)
            } else if let ref = TartImageRef.parse(row.name), let digest = digestForTag(ref) {
                let repository = "\(ref.host)/\(ref.repository)"
                add(row, key: repository + "@" + digest, repository: repository, digest: digest, tag: ref.reference)
            } else {
                add(row, key: row.name, repository: row.name, digest: nil, tag: row.name)
            }
        }
        return order.compactMap { groups[$0] }.map { group in
            stored(
                group, digestForTag: digestForTag, runnerImages: runnerImages, pullingImages: pullingImages,
                isHeld: heldRepositories.contains(group.repository)
            )
        }
    }

    private static func stored(
        _ group: Group,
        digestForTag: (TartImageRef) -> String?,
        runnerImages: [RunnerImageUse],
        pullingImages: Set<String>,
        isHeld: Bool
    ) -> StoredImage {
        let digestRef = group.digest.map { group.repository + "@" + $0 }
        let deleteRef = digestRef ?? group.repository
        // The digest row's size is the image's; a group of tag rows alone falls back to theirs.
        let sizeRow = group.rows.first { $0.name.contains(digestMarker) } ?? group.rows[0]
        let names = ([digestRef] + group.tags).compactMap { $0 }
        let tags = group.tags.sorted().map(TartImageRef.shortName(of:))
        return StoredImage(
            id: deleteRef,
            displayName: tags.isEmpty ? TartImageRef.shortName(of: deleteRef) : tags.joined(separator: ", "),
            deleteRef: deleteRef,
            sizeBytes: bytes(sizeRow),
            accessed: group.rows.compactMap(\.accessed).max(),
            usedBy: users(of: names, in: runnerImages, resolving: digestForTag),
            isPulling: !users(of: names, in: pullingImages.map { RunnerImageUse(runnerName: $0, image: $0) }, resolving: digestForTag).isEmpty,
            isRunning: group.rows.contains(where: \.isRunning),
            isLocal: false,
            isHeldByUnresolvedTag: isHeld,
            isSafeToDelete: group.rows.allSatisfy { $0.source == "OCI" } && TartImageRef.isDigestRef(deleteRef)
        )
    }

    // MARK: - Matching

    /// The runners whose image is one of `names` (the image's tag refs and digest ref). A runner
    /// on a tag also matches when that tag resolves to the image's digest.
    private static func users(
        of names: [String],
        in uses: [RunnerImageUse],
        resolving digestForTag: (TartImageRef) -> String?
    ) -> [String] {
        let wanted = Set(names)
        let matching = uses.filter { use in
            guard let ref = TartImageRef.parse(use.image) else { return wanted.contains(use.image) }
            if wanted.contains(ref.reference) { return true }
            return digestForTag(ref).map { wanted.contains("\(ref.host)/\(ref.repository)@\($0)") } ?? false
        }
        return Array(Set(matching.map(\.runnerName))).sorted()
    }

    /// A local VM may be deleted by name only if tart can't read the name as an option or a path
    /// and it isn't one of Ghast's own clones.
    private static func isSafeLocalName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("/")
            && !name.hasPrefix(TartBackend.clonePrefix) && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func bytes(_ entry: TartVMEntry) -> Int64 {
        Int64(entry.sizeGB ?? 0) * bytesPerGB
    }

    private static func bySize(_ images: [StoredImage]) -> [StoredImage] {
        images.sorted { ($0.sizeBytes, $1.displayName) > ($1.sizeBytes, $0.displayName) }
    }
}

private extension String {
    /// A digest as `sha256:<hex>` whether or not it already carries the prefix.
    var withDigestPrefix: String { hasPrefix("sha256:") ? self : "sha256:" + self }
}

import AppKit
import Observation
import SwiftUI

/// 16 pt round avatars for the "Add to" menu. Menu items draw images, not views, so these are
/// `NSImage`s: the owner's GitHub avatar once loaded, a monogram until then (and in the design
/// fixture, whose avatars have no URL).
@MainActor @Observable
final class ScopeAvatarImages {
    private var loaded: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }) {
        self.fetch = fetch
    }

    func image(for choice: NewRunnerScopeChoice) -> NSImage {
        loaded[choice.avatarURL] ?? Self.monogram(for: choice.name)
    }

    /// Starts loading every avatar not yet requested. Failures keep the monogram.
    func load(_ choices: [NewRunnerScopeChoice]) {
        for choice in choices where !choice.avatarURL.isEmpty && !requested.contains(choice.avatarURL) {
            requested.insert(choice.avatarURL)
            guard let url = URL(string: choice.avatarURL) else { continue }
            let fetch = fetch
            Task {
                guard let data = try? await fetch(url), let image = NSImage(data: data) else { return }
                loaded[choice.avatarURL] = Self.round(image)
            }
        }
    }

    private static var side: CGFloat { FocusMetrics.scopeAvatar }

    private static func round(_ image: NSImage) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
    }

    /// The name's first letter, white on a dark disc (the kit's stand-in avatar).
    private static func monogram(for name: String) -> NSImage {
        let letter = String(name.first.map(Character.init) ?? "?").uppercased()
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.56, weight: .bold),
                .foregroundColor: NSColor.windowBackgroundColor,
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}

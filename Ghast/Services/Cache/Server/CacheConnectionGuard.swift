import Foundation
import NIOCore
import NIOHTTPTypes
import Synchronization

/// Connection limits for one cache listener, so a VM can't hold the server's connections by
/// connecting and sending nothing, or sending slowly.
struct CacheConnectionLimits: Sendable {
    /// From connect (or the end of the last response) to a complete request head.
    var headerTimeout: Duration = .seconds(10)
    /// The longest gap between request body chunks.
    var bodyIdleTimeout: Duration = .seconds(60)
    /// The longest a request body may take in all.
    var bodyTimeout: Duration = .seconds(1800)
    /// Hummingbird's own idle timeout, as a backstop.
    var idleTimeout: Duration = .seconds(120)
    var maximumConnections = 64
    var maximumPerPeer = 16

    func duration(_ timer: CacheDeadlineState.Timer) -> Duration {
        switch timer {
        case .header: headerTimeout
        case .body: bodyTimeout
        case .bodyIdle: bodyIdleTimeout
        }
    }
}

/// Which read deadlines a connection is under, driven by the HTTP parts it reads and writes.
/// A deadline that passes closes the connection.
struct CacheDeadlineState {
    enum Timer: Hashable, Sendable { case header, body, bodyIdle }
    enum Action: Equatable, Sendable { case arm(Timer), cancel(Timer) }

    /// Requests whose response hasn't ended yet.
    private var inFlight = 0
    private var isReadingBody = false

    mutating func opened() -> [Action] { [.arm(.header)] }

    mutating func head() -> [Action] {
        inFlight += 1
        isReadingBody = true
        return [.cancel(.header), .arm(.body), .arm(.bodyIdle)]
    }

    mutating func bodyChunk() -> [Action] { isReadingBody ? [.arm(.bodyIdle)] : [] }

    mutating func requestEnd() -> [Action] {
        guard isReadingBody else { return [] }
        isReadingBody = false
        return [.cancel(.body), .cancel(.bodyIdle)] + (inFlight == 0 ? [.arm(.header)] : [])
    }

    mutating func responseEnd() -> [Action] {
        inFlight = max(0, inFlight - 1)
        return inFlight == 0 && !isReadingBody ? [.arm(.header)] : []
    }
}

/// Open connections per peer address, shared by every listener of one server.
final class CachePeerLimiter: Sendable {
    private let maximumPerPeer: Int
    private let counts = Mutex<[String: Int]>([:])

    init(maximumPerPeer: Int) { self.maximumPerPeer = maximumPerPeer }

    func acquire(_ peer: String) -> Bool {
        counts.withLock { counts in
            guard counts[peer, default: 0] < maximumPerPeer else { return false }
            counts[peer, default: 0] += 1
            return true
        }
    }

    func release(_ peer: String) {
        counts.withLock { counts in
            let remaining = counts[peer, default: 0] - 1
            counts[peer] = remaining > 0 ? remaining : nil
        }
    }
}

/// Applies `CacheDeadlineState` on the channel: sits after HTTP decoding and closes the
/// connection when a deadline passes.
final class CacheDeadlineHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart
    typealias InboundOut = HTTPRequestPart
    typealias OutboundIn = HTTPResponsePart
    typealias OutboundOut = HTTPResponsePart

    private let limits: CacheConnectionLimits
    private var state = CacheDeadlineState()
    private var timers: [CacheDeadlineState.Timer: Scheduled<Void>] = [:]
    private var isStarted = false

    init(limits: CacheConnectionLimits) { self.limits = limits }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { start(context) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { cancelAll() }

    func channelActive(context: ChannelHandlerContext) {
        start(context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelAll()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: apply(state.head(), context)
        case .body: apply(state.bodyChunk(), context)
        case .end: apply(state.requestEnd(), context)
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .end = unwrapOutboundIn(data) { apply(state.responseEnd(), context) }
        context.write(data, promise: promise)
    }

    private func start(_ context: ChannelHandlerContext) {
        guard !isStarted else { return }
        isStarted = true
        apply(state.opened(), context)
    }

    private func apply(_ actions: [CacheDeadlineState.Action], _ context: ChannelHandlerContext) {
        for action in actions {
            switch action {
            case .cancel(let timer):
                timers.removeValue(forKey: timer)?.cancel()
            case .arm(let timer):
                timers.removeValue(forKey: timer)?.cancel()
                let channel = context.channel
                timers[timer] = context.eventLoop.scheduleTask(in: .nanoseconds(Self.nanoseconds(limits.duration(timer)))) {
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func cancelAll() {
        timers.values.forEach { $0.cancel() }
        timers = [:]
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

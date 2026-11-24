import Foundation
import Testing
@testable import Ghast

@Suite("Cache connection deadlines")
struct CacheDeadlineStateTests {
    @Test("a new connection must send its request head before the header deadline")
    func opened() {
        var state = CacheDeadlineState()
        #expect(state.opened() == [.arm(.header)])
    }

    @Test("a head ends the header deadline and starts the body deadlines")
    func head() {
        var state = CacheDeadlineState()
        _ = state.opened()
        #expect(state.head() == [.cancel(.header), .arm(.body), .arm(.bodyIdle)])
    }

    @Test("each body chunk restarts the body idle deadline; the request end stops both")
    func body() {
        var state = CacheDeadlineState()
        _ = state.opened()
        _ = state.head()
        #expect(state.bodyChunk() == [.arm(.bodyIdle)])
        #expect(state.requestEnd() == [.cancel(.body), .cancel(.bodyIdle)])
    }

    @Test("after the response, a kept-alive connection gets a new header deadline")
    func keepAlive() {
        var state = CacheDeadlineState()
        _ = state.opened()
        _ = state.head()
        _ = state.requestEnd()
        #expect(state.responseEnd() == [.arm(.header)])
    }

    @Test("no header deadline while a response is still being written")
    func longResponse() {
        var state = CacheDeadlineState()
        _ = state.opened()
        _ = state.head()
        #expect(!state.requestEnd().contains(.arm(.header)))
    }

    @Test("a response sent before the request body ends arms the header deadline at the request end")
    func earlyResponse() {
        var state = CacheDeadlineState()
        _ = state.opened()
        _ = state.head()
        #expect(state.responseEnd() == [])
        #expect(state.requestEnd() == [.cancel(.body), .cancel(.bodyIdle), .arm(.header)])
    }

    @Test("pipelined requests keep the header deadline off until the last response")
    func pipelined() {
        var state = CacheDeadlineState()
        _ = state.opened()
        _ = state.head()
        _ = state.requestEnd()
        _ = state.head()
        _ = state.requestEnd()
        #expect(state.responseEnd() == [])
        #expect(state.responseEnd() == [.arm(.header)])
    }

    @Test("body chunks outside a request change nothing")
    func strayChunk() {
        var state = CacheDeadlineState()
        _ = state.opened()
        #expect(state.bodyChunk() == [])
    }
}

@Suite("Cache peer connection limit")
struct CachePeerLimiterTests {
    @Test("each peer gets at most its share of connections, given back on close")
    func perPeer() {
        let limiter = CachePeerLimiter(maximumPerPeer: 2)
        #expect(limiter.acquire("192.168.64.2"))
        #expect(limiter.acquire("192.168.64.2"))
        #expect(!limiter.acquire("192.168.64.2"))
        #expect(limiter.acquire("192.168.64.3"))
        limiter.release("192.168.64.2")
        #expect(limiter.acquire("192.168.64.2"))
    }
}

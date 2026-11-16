import Testing
import Foundation
@testable import Ghast

@Suite struct OutputViewModelTests {
    func line(_ id: Int, _ text: String, clock: String = "10:00:00") -> OutputLine {
        OutputLine(id: id, byteOffset: UInt64(id * 100), timestamp: nil, clockText: clock, text: text, kind: .plain)
    }

    var lines: [OutputLine] {
        [
            line(0, "Connected to GitHub"),
            line(1, "Running job: test"),
            line(2, "Job test completed with result: Succeeded"),
            line(3, "Listening for Jobs"),
        ]
    }

    // MARK: Find

    @Test func findIsCaseInsensitiveAndCountsEveryMatch() {
        var find = OutputFindModel()
        find.update(query: "TEST", lines: lines)
        #expect(find.matches.map(\.lineID) == [1, 2])
        #expect(find.matches.map(\.range) == [13..<17, 4..<8])
        #expect(find.matchCountText == "1 of 2")
        #expect(find.current?.lineID == 1)
    }

    @Test func severalMatchesOnOneLineAreSeparate() {
        var find = OutputFindModel()
        find.update(query: "o", lines: [line(0, "foo boo")])
        #expect(find.matches.map(\.range) == [1..<2, 2..<3, 5..<6, 6..<7])
    }

    @Test func nextAndPreviousWrapAround() {
        var find = OutputFindModel()
        find.update(query: "job", lines: lines)
        #expect(find.matches.count == 3)
        find.next(); find.next()
        #expect(find.currentIndex == 2)
        find.next()
        #expect(find.currentIndex == 0)
        find.previous()
        #expect(find.currentIndex == 2)
    }

    @Test func emptyQueryOrNoMatchHasNoCurrentMatch() {
        var find = OutputFindModel()
        find.update(query: "", lines: lines)
        #expect(find.matches.isEmpty && find.current == nil && find.matchCountText == "")
        find.update(query: "nothing", lines: lines)
        #expect(find.current == nil)
        #expect(find.matchCountText == "No matches")
        find.next()
        #expect(find.currentIndex == nil)
    }

    @Test func newLinesKeepTheCurrentMatch() {
        var find = OutputFindModel()
        find.update(query: "job", lines: lines)
        find.next()
        find.update(query: "job", lines: lines + [line(4, "Running job: lint")])
        #expect(find.current?.lineID == 2)
        #expect(find.matchCountText == "2 of 4")
    }

    @Test func connectedLineShowsAndFindsTextWithoutItsOwnMark() {
        let connected = OutputLine(id: 0, byteOffset: 0, timestamp: nil, clockText: "06:58:02", text: "√ Connected to GitHub", kind: .connected)
        #expect(connected.displayText == "Connected to GitHub")
        var find = OutputFindModel()
        find.update(query: "connected", lines: [connected])
        #expect(find.matches.map(\.range) == [0..<9])
        #expect(OutputLine.copyText([connected]) == "06:58:02  Connected to GitHub")
    }

    // MARK: Follow

    @Test func followIsOnByDefaultAndScrollingUpTurnsItOff() {
        var follow = FollowState()
        #expect(follow.isFollowing)
        follow.userScrolled(isAtEnd: true)
        #expect(follow.isFollowing)
        follow.userScrolled(isAtEnd: false)
        #expect(!follow.isFollowing)
    }

    @Test func followCommandTurnsItBackOnAndAsksForAJump() {
        var follow = FollowState()
        follow.userScrolled(isAtEnd: false)
        let before = follow.jumpRequest
        follow.follow()
        #expect(follow.isFollowing)
        #expect(follow.jumpRequest != before)
    }

    // MARK: Copy

    @Test func copyAllJoinsTimeAndTextPerLine() {
        let text = OutputLine.copyText([line(0, "Connected to GitHub"), line(1, "no prefix", clock: "")])
        #expect(text == "10:00:00  Connected to GitHub\nno prefix")
    }
}

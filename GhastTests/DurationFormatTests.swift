import Testing
import Foundation
@testable import Ghast

@Suite("DurationFormat")
struct DurationFormatTests {
    @Test("compact form", arguments: [
        (11_640.0, "3 h 14 min"),
        (3_720.0, "1 h 02 min"),
        (3_600.0, "1 h 00 min"),
        (2_700.0, "45 min"),
        (60.0, "1 min"),
        (183_600.0, "2 d 3 h"),
        (86_400.0, "1 d 0 h"),
        (86_340.0, "23 h 59 min"),
    ])
    func compact(interval: TimeInterval, expected: String) {
        #expect(DurationFormat.compact(interval) == expected)
    }

    @Test("rounds to the nearest minute and carries into the hour")
    func compactRounding() {
        #expect(DurationFormat.compact(149.0) == "2 min")
        #expect(DurationFormat.compact(150.0) == "3 min")
        #expect(DurationFormat.compact(3_580.0) == "1 h 00 min")
    }

    @Test("under a minute is shown as less than one")
    func compactUnderMinute() {
        #expect(DurationFormat.compact(0) == "< 1 min")
        #expect(DurationFormat.compact(59) == "< 1 min")
    }

    @Test("an unknown or negative duration is an em dash")
    func compactUnknown() {
        #expect(DurationFormat.compact(nil) == "—")
        #expect(DurationFormat.compact(-5) == "—")
    }

    @Test("started text: just now under a minute, then whole minutes")
    func startedText() {
        #expect(DurationFormat.started(elapsed: 0) == "started just now")
        #expect(DurationFormat.started(elapsed: 59) == "started just now")
        #expect(DurationFormat.started(elapsed: 60) == "started 1 min ago")
        #expect(DurationFormat.started(elapsed: 260.0) == "started 4 min ago")
        #expect(DurationFormat.started(elapsed: 280.0) == "started 5 min ago")
        #expect(DurationFormat.started(elapsed: 10_800.0) == "started 180 min ago")
    }

    @Test("spoken form", arguments: [
        (11_640.0, "3 hours 14 minutes"),
        (3_660.0, "1 hour 1 minute"),
        (3_600.0, "1 hour"),
        (2_700.0, "45 minutes"),
        (60.0, "1 minute"),
        (183_600.0, "2 days 3 hours"),
        (86_400.0, "1 day"),
        (20.0, "less than a minute"),
    ])
    func spoken(interval: TimeInterval, expected: String) {
        #expect(DurationFormat.spoken(interval) == expected)
    }

    @Test("spoken form of an unknown duration says so")
    func spokenUnknown() {
        #expect(DurationFormat.spoken(nil) == "unavailable")
    }
}

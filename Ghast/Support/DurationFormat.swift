import Foundation

/// How Ghast writes elapsed times: "3 h 14 min", "started 4 min ago", and the spoken form for
/// VoiceOver. Pure functions of a number of seconds, so the view layer owns the clock.
enum DurationFormat {
    private static let secondsPerMinute = 60
    private static let minutesPerHour = 60
    private static let hoursPerDay = 24
    private static let unknown = "—"

    /// `3 h 14 min`, `1 h 02 min`, `45 min`, `2 d 3 h`; "—" when unknown.
    static func compact(_ interval: TimeInterval?) -> String {
        guard let parts = Parts(interval) else { return unknown }
        switch parts {
        case .underMinute: return "< 1 min"
        case let .minutes(minutes): return "\(minutes) min"
        case let .hours(hours, minutes): return "\(hours) h \(String(format: "%02d", minutes)) min"
        case let .days(days, hours): return "\(days) d \(hours) h"
        }
    }

    /// A job's length with seconds kept under an hour: `48 s`, `6 min 12 s`, `1 h 03 min`; "—" when unknown.
    static func job(_ interval: TimeInterval?) -> String {
        guard let interval, interval >= 0 else { return unknown }
        let total = Int(interval)
        let secondsPerHour = secondsPerMinute * minutesPerHour
        if total >= secondsPerHour {
            let (hours, rest) = total.quotientAndRemainder(dividingBy: secondsPerHour)
            return "\(hours) h \(String(format: "%02d", rest / secondsPerMinute)) min"
        }
        let (minutes, seconds) = total.quotientAndRemainder(dividingBy: secondsPerMinute)
        return minutes == 0 ? "\(seconds) s" : "\(minutes) min \(String(format: "%02d", seconds)) s"
    }

    /// `started just now` under a minute, then `started {n} min ago` to the nearest minute.
    static func started(elapsed: TimeInterval) -> String {
        guard elapsed >= TimeInterval(secondsPerMinute) else { return "started just now" }
        return "started \(roundedMinutes(elapsed)) min ago"
    }

    /// `3 hours 14 minutes`, `2 days 3 hours`, `less than a minute`; zero trailing parts are left out.
    static func spoken(_ interval: TimeInterval?) -> String {
        guard let parts = Parts(interval) else { return "unavailable" }
        switch parts {
        case .underMinute: return "less than a minute"
        case let .minutes(minutes): return unit(minutes, "minute")
        case let .hours(hours, minutes): return join(unit(hours, "hour"), minutes == 0 ? nil : unit(minutes, "minute"))
        case let .days(days, hours): return join(unit(days, "day"), hours == 0 ? nil : unit(hours, "hour"))
        }
    }

    // MARK: -

    private enum Parts {
        case underMinute
        case minutes(Int)
        case hours(Int, minutes: Int)
        case days(Int, hours: Int)

        init?(_ interval: TimeInterval?) {
            guard let interval, interval >= 0 else { return nil }
            guard interval >= TimeInterval(DurationFormat.secondsPerMinute) else {
                self = .underMinute
                return
            }
            let total = DurationFormat.roundedMinutes(interval)
            let (hours, minutes) = total.quotientAndRemainder(dividingBy: DurationFormat.minutesPerHour)
            let (days, hoursOfDay) = hours.quotientAndRemainder(dividingBy: DurationFormat.hoursPerDay)
            if days > 0 {
                self = .days(days, hours: hoursOfDay)
            } else if hours > 0 {
                self = .hours(hours, minutes: minutes)
            } else {
                self = .minutes(minutes)
            }
        }
    }

    private static func roundedMinutes(_ interval: TimeInterval) -> Int {
        Int((interval / TimeInterval(secondsPerMinute)).rounded(.toNearestOrAwayFromZero))
    }

    private static func unit(_ count: Int, _ name: String) -> String {
        "\(count) \(name)\(count == 1 ? "" : "s")"
    }

    private static func join(_ first: String, _ second: String?) -> String {
        second.map { "\(first) \($0)" } ?? first
    }
}

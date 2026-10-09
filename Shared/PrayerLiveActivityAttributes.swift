import Foundation
import ActivityKit

@available(iOS 16.2, *)
struct PrayerLiveActivityAttributes: ActivityAttributes {
    struct Timing: Codable, Hashable {
        let key: String
        let label: String
        let time: String
        let atEpoch: Double
        let iqamaTime: String?
        let iqamaEpoch: Double?
    }

    struct ContentState: Codable, Hashable {
        let phase: String
        let prayerKey: String
        let label: String
        let targetEpoch: Double
        let timeZone: String
        let timeFormat: String
        let theme: String
        let backgroundPalette: String?
        let themeColors: [String: String]?
        let hijriDate: String
        let timings: [Timing]
    }

    let sessionID: String
}

@available(iOS 16.2, *)
enum PrayerLiveActivityClock {
    static func display(_ canonical: String, format: String) -> String {
        let parts = canonical.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return canonical }
        if format != "12h" { return String(format: "%02d:%02d", hour, minute) }
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12,
                      minute, hour < 12 ? "ص" : "م")
    }

    static func canonical(_ epoch: Double, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: epoch))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

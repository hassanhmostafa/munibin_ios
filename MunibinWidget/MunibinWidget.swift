import WidgetKit
import SwiftUI
import Foundation

private enum MunibinPrayerWidgetStore {
    static let appGroup = "group.com.motoonai.munibin"
    static let snapshotKey = "munibin.prayer-widget.snapshot.v1"
    static let snapshotFileName = "munibin.prayer-widget.snapshot.v1.json"
    static let timeFormatKey = "munibin.prayer-time-format.v1"
    static let themeKey = "munibin.prayer-widget.theme.v1"
}

private struct PrayerWidgetNextPrayer: Codable {
    let key: String
    let label: String
    let at: String
    let time: String
    let kind: String?
    let type: String?
    let prayerAt: String?

    init(key: String, label: String, at: String, time: String,
         kind: String? = nil, type: String? = nil, prayerAt: String? = nil) {
        self.key = key
        self.label = label
        self.at = at
        self.time = time
        self.kind = kind
        self.type = type
        self.prayerAt = prayerAt
    }

    var originalPrayerDate: Date? {
        if ["pre-prayer", "iqama"].contains(kind ?? type ?? "prayer") {
            return PrayerWidgetSupport.isoDate(from: prayerAt)
        }
        return PrayerWidgetSupport.isoDate(from: at)
    }
}

private struct PrayerWidgetTime: Codable, Identifiable {
    let key: String
    let label: String
    let time: String
    let at: String?

    init(key: String, label: String, time: String, at: String? = nil) {
        self.key = key
        self.label = label
        self.time = time
        self.at = at
    }

    var id: String { "\(key)-\(label)" }
}

private struct PrayerWidgetSchedule: Codable {
    struct Event: Codable {
        let key: String
        let label: String?
        let time: String
        let at: Double
        let iqamaAt: Double?
    }

    struct Day: Codable {
        let date: String
        let hijriDate: String?
        let events: [Event]
    }

    let timeZone: String
    let days: [Day]
}

private struct PrayerWidgetSnapshot: Codable {
    let version: Int
    let prayerTimesEnabled: Bool?
    let updatedAt: String
    let hijriDate: String
    let nextPrayer: PrayerWidgetNextPrayer?
    let timings: [PrayerWidgetTime]
    let upcomingPrayers: [PrayerWidgetNextPrayer]?
    let notificationsEnabled: Bool?
    let notificationConfigKey: String?
    let theme: String?
    let iqamaOffsets: [String: Int]?
    let timeFormat: String?
    let backgroundPalette: String?
    let themeColors: [String: String]?
    let livePrayerSchedule: PrayerWidgetSchedule?

    var isConfigured: Bool {
        prayerTimesEnabled == true && !timings.isEmpty
    }

    static let placeholder = PrayerWidgetSnapshot(
        version: 4,
        prayerTimesEnabled: false,
        updatedAt: "",
        hijriDate: "مواقيت منيبين",
        nextPrayer: nil,
        timings: [],
        upcomingPrayers: [],
        notificationsEnabled: false,
        notificationConfigKey: nil,
        theme: "dark",
        iqamaOffsets: [:],
        timeFormat: "24h",
        backgroundPalette: "cream",
        themeColors: nil,
        livePrayerSchedule: nil
    )
}

private struct MunibinPrayerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PrayerWidgetSnapshot
}

private struct PrayerWidgetCountdownTarget {
    let key: String
    let activePrayerKey: String
    let label: String
    let time: String
    let date: Date?
}

private enum PrayerWidgetSupport {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func normalizedKey(_ rawKey: String, label: String = "") -> String {
        let key = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        if ["fajr"].contains(key) { return "fajr" }
        if ["sunrise", "shuruq", "shurooq", "shorouq", "shorooq", "sunriseprayer"].contains(key) { return "sunrise" }
        if ["dhuhr", "zuhr", "zuhur"].contains(key) { return "dhuhr" }
        if ["asr"].contains(key) { return "asr" }
        if ["maghrib"].contains(key) { return "maghrib" }
        if ["isha", "ishaa"].contains(key) { return "isha" }

        if label.contains("الفجر") { return "fajr" }
        if label.contains("الشروق") || label.contains("شروق") { return "sunrise" }
        if label.contains("الظهر") { return "dhuhr" }
        if label.contains("العصر") { return "asr" }
        if label.contains("المغرب") { return "maghrib" }
        if label.contains("العشاء") { return "isha" }

        return key
    }

    static func timing(for key: String, in snapshot: PrayerWidgetSnapshot) -> PrayerWidgetTime? {
        snapshot.timings.first {
            normalizedKey($0.key, label: $0.label) == key
        }
    }

    private static func latinDigits(_ value: String) -> String {
        let arabic = Array("٠١٢٣٤٥٦٧٨٩")
        let persian = Array("۰۱۲۳۴۵۶۷۸۹")
        let latin = Array("0123456789")
        var result = ""

        for character in value {
            if let index = arabic.firstIndex(of: character) {
                result.append(latin[index])
            } else if let index = persian.firstIndex(of: character) {
                result.append(latin[index])
            } else {
                result.append(character)
            }
        }
        return result
    }

    // Stored clocks remain canonical HH:mm. This is presentation only, so a
    // format change cannot alter prayer dates, DST boundaries, or iqama offsets.
    static func displayClock(_ raw: String, format: String?) -> String {
        let normalized = latinDigits(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return normalized }
        if format != "12h" { return String(format: "%02d:%02d", hour, minute) }
        let digits = String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute)
        let suffix = hour < 12 ? "ص" : "م"
        // Match the Arabic clock reading order: digits first, then ص/م to their
        // left. The nested isolate keeps the English digit run left-to-right.
        return "\u{2067}\u{2066}\(digits)\u{2069} \(suffix)\u{2069}"
    }

    private static func calendar(in snapshot: PrayerWidgetSnapshot) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let identifier = snapshot.livePrayerSchedule?.timeZone,
           let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
            return calendar
        }
        if let raw = snapshot.notificationConfigKey,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let config = object as? [String: Any],
           let identifier = config["timeZone"] as? String,
           let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        return calendar
    }

    static func clockDate(from time: String, relativeTo now: Date, preferFuture: Bool,
                          timeZone: TimeZone = .current) -> Date? {
        let value = latinDigits(time).uppercased()
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }

        let hourDigits = String(parts[0].filter { $0.isNumber })
        let minuteDigits = String(parts[1].prefix { $0.isNumber })
        guard var hour = Int(hourDigits), let minute = Int(minuteDigits), minute >= 0, minute < 60 else {
            return nil
        }

        let hasAM = value.contains("AM")
        let hasPM = value.contains("PM")
        if hasAM || hasPM {
            guard hour >= 1, hour <= 12 else { return nil }
            if hasAM && hour == 12 { hour = 0 }
            if hasPM && hour != 12 { hour += 12 }
        }
        guard hour >= 0, hour <= 23 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var date = calendar.date(from: components) else { return nil }
        if preferFuture && date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    static func date(for timing: PrayerWidgetTime, relativeTo now: Date, preferFuture: Bool = false) -> Date? {
        if let date = isoDate(from: timing.at) {
            return date
        }
        return clockDate(from: timing.time, relativeTo: now, preferFuture: preferFuture)
    }

    // Published ISO dates are absolute instants. Only a missing adjacent day's
    // event falls back to the stored clock time, interpreted in the selected city.
    private static func prayerDates(for timing: PrayerWidgetTime, in snapshot: PrayerWidgetSnapshot,
                                    relativeTo now: Date, dayOffsets: ClosedRange<Int>) -> [Date] {
        let calendar = calendar(in: snapshot)
        let key = normalizedKey(timing.key, label: timing.label)
        var published: [Date] = []
        if let date = isoDate(from: timing.at) { published.append(date) }
        if let next = snapshot.nextPrayer,
           normalizedKey(next.key, label: next.label) == key,
           let date = next.originalPrayerDate { published.append(date) }
        for prayer in snapshot.upcomingPrayers ?? [] {
            if normalizedKey(prayer.key, label: prayer.label) == key,
               let date = prayer.originalPrayerDate { published.append(date) }
        }

        return dayOffsets.compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            if let date = published.first(where: { calendar.isDate($0, inSameDayAs: day) }) {
                return date
            }
            // An adjacent day's clock cannot be guessed from today's timetable.
            // Legacy undated snapshots can still show their current local day.
            guard published.isEmpty && offset == 0 else { return nil }
            return clockDate(from: timing.time, relativeTo: day, preferFuture: false,
                             timeZone: calendar.timeZone)
        }
    }

    private static func iqamaMinutes(for key: String, in snapshot: PrayerWidgetSnapshot) -> Int? {
        guard let offsets = snapshot.iqamaOffsets else { return nil }
        return offsets.first(where: { normalizedKey($0.key) == key })?.value
    }

    private struct ScheduledTarget {
        let day: PrayerWidgetSchedule.Day
        let event: PrayerWidgetSchedule.Event
        let iqama: Bool
    }

    private struct ScheduledEvent {
        let day: PrayerWidgetSchedule.Day
        let event: PrayerWidgetSchedule.Event
    }

    // A full dated schedule is shared even when Live Activity is switched off.
    // Select the table from the target's original prayer day, not the wall date
    // or iqama end date; an Isha iqama can continue across midnight.
    private static func scheduledTarget(snapshot: PrayerWidgetSnapshot, now: Date) -> ScheduledTarget? {
        guard let schedule = snapshot.livePrayerSchedule,
              TimeZone(identifier: schedule.timeZone) != nil else { return nil }
        let keys: Set<String> = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]
        let selectedCalendar = calendar(in: snapshot)
        let startOfToday = selectedCalendar.startOfDay(for: now)
        let firstDay = selectedCalendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let lastDay = selectedCalendar.date(byAdding: .day, value: 2, to: startOfToday) ?? startOfToday
        let firstDayMilliseconds: Double = firstDay.timeIntervalSince1970 * 1000
        let lastDayMilliseconds: Double = lastDay.timeIntervalSince1970 * 1000
        // Keep each collection operation separately typed. A chained filter /
        // flatMap / tuple sort exceeds Swift's type-checking budget here.
        var events: [ScheduledEvent] = []
        for day in schedule.days {
            guard day.events.count == keys.count else { continue }
            let eventKeys: Set<String> = Set(day.events.map { normalizedKey($0.key) })
            guard eventKeys == keys else { continue }
            guard day.events.allSatisfy({ $0.at.isFinite && $0.at > 0 }) else { continue }

            for event in day.events {
                guard event.at >= firstDayMilliseconds,
                      event.at < lastDayMilliseconds else { continue }
                events.append(ScheduledEvent(day: day, event: event))
            }
        }
        events.sort { $0.event.at < $1.event.at }
        let milliseconds = now.timeIntervalSince1970 * 1000
        if let active = events.first(where: { candidate in
            let event = candidate.event
            guard normalizedKey(event.key) != "sunrise", let end = event.iqamaAt,
                  end.isFinite, end > event.at else { return false }
            return event.at <= milliseconds && milliseconds < end
        }) {
            return ScheduledTarget(day: active.day, event: active.event, iqama: true)
        }
        guard let next = events.first(where: { $0.event.at > milliseconds }) else { return nil }
        return ScheduledTarget(day: next.day, event: next.event, iqama: false)
    }

    static func displaySnapshot(_ loaded: PrayerWidgetSnapshot, now: Date) -> PrayerWidgetSnapshot {
        guard loaded.isConfigured else { return loaded }
        let target = scheduledTarget(snapshot: loaded, now: now)
        let selectedCalendar = calendar(in: loaded)
        let startOfToday = selectedCalendar.startOfDay(for: now)
        let firstDay = selectedCalendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let lastDay = selectedCalendar.date(byAdding: .day, value: 2, to: startOfToday) ?? startOfToday
        // Each queued entry needs only its own adjacent days. Keep the provider's
        // loaded annual schedule intact for all future boundary entries, without
        // serializing that whole schedule into every WidgetKit timeline snapshot.
        let preparedSchedule = loaded.livePrayerSchedule.map { schedule in
            PrayerWidgetSchedule(timeZone: schedule.timeZone, days: schedule.days.filter { day in
                day.events.contains { event in
                    event.at >= firstDay.timeIntervalSince1970 * 1000 && event.at < lastDay.timeIntervalSince1970 * 1000
                }
            })
        }
        let table = target?.day.events.map { event in
            PrayerWidgetTime(key: normalizedKey(event.key),
                             label: event.label ?? defaultLabel(for: normalizedKey(event.key)),
                             time: event.time,
                             at: isoFormatter.string(from: Date(timeIntervalSince1970: event.at / 1000)))
        } ?? loaded.timings
        let originalDay = loaded.timings.compactMap { isoDate(from: $0.at) }.first
        let hijriDate = target.map { selected in
            let sameDay = originalDay.map {
                selectedCalendar.isDate($0, inSameDayAs: Date(timeIntervalSince1970: selected.event.at / 1000))
            } ?? false
            return selected.day.hijriDate ?? (sameDay ? loaded.hijriDate : selected.day.date)
        } ?? loaded.hijriDate
        return PrayerWidgetSnapshot(
            version: loaded.version, prayerTimesEnabled: loaded.prayerTimesEnabled,
            updatedAt: loaded.updatedAt,
            hijriDate: hijriDate,
            nextPrayer: loaded.nextPrayer, timings: table, upcomingPrayers: loaded.upcomingPrayers,
            notificationsEnabled: loaded.notificationsEnabled, notificationConfigKey: loaded.notificationConfigKey,
            theme: loaded.theme, iqamaOffsets: loaded.iqamaOffsets, timeFormat: loaded.timeFormat,
            backgroundPalette: loaded.backgroundPalette, themeColors: loaded.themeColors,
            livePrayerSchedule: preparedSchedule
        )
    }

    // Recalculate from published dates on every timeline entry, without depending
    // on the host app rewriting snapshot.nextPrayer at the exact boundary.
    static func countdownTarget(snapshot: PrayerWidgetSnapshot, now: Date) -> PrayerWidgetCountdownTarget? {
        if let target = scheduledTarget(snapshot: snapshot, now: now) {
            let event = target.event
            let key = normalizedKey(event.key)
            let label = event.label ?? defaultLabel(for: key)
            return PrayerWidgetCountdownTarget(
                key: target.iqama ? "iqama" : key, activePrayerKey: key,
                label: target.iqama ? "\(label) الإقامة" : label,
                time: target.iqama ? "" : displayClock(event.time, format: snapshot.timeFormat),
                date: Date(timeIntervalSince1970: (target.iqama ? event.iqamaAt! : event.at) / 1000)
            )
        }
        if snapshot.livePrayerSchedule != nil { return nil }
        // Iqama keeps its own countdown phase; notification opt-ins are independent.
        var activeIqama: PrayerWidgetCountdownTarget?
        var activePrayerDate = Date.distantFuture
        for timing in snapshot.timings {
            let key = normalizedKey(timing.key, label: timing.label)
            if key == "sunrise" || key.isEmpty { continue }
            guard let minutes = iqamaMinutes(for: key, in: snapshot), minutes > 0 else {
                continue
            }
            // An Isha iqama may end after the selected city's midnight. Keep an
            // earlier prayer active when its iqama overlaps a later prayer time.
            for start in prayerDates(for: timing, in: snapshot, relativeTo: now, dayOffsets: -1...0) {
                let iqamaDate = start.addingTimeInterval(TimeInterval(minutes * 60))
                if now >= start && now < iqamaDate && start < activePrayerDate {
                    activePrayerDate = start
                    activeIqama = PrayerWidgetCountdownTarget(
                        key: "iqama",
                        activePrayerKey: key,
                        label: "\(timing.label.isEmpty ? defaultLabel(for: key) : timing.label) الإقامة",
                        time: "",
                        date: iqamaDate
                    )
                }
            }
        }
        if let activeIqama { return activeIqama }

        // Recompute the next absolute target directly from the dated timings. This
        // makes Fajr -> Sunrise automatic once the Fajr iqama entry expires.
        var best: PrayerWidgetCountdownTarget?
        for timing in snapshot.timings {
            let key = normalizedKey(timing.key, label: timing.label)
            if key.isEmpty { continue }
            for targetDate in prayerDates(for: timing, in: snapshot, relativeTo: now, dayOffsets: 0...1) {
                guard targetDate > now else { continue }
                if best == nil || targetDate < (best?.date ?? .distantFuture) {
                    best = PrayerWidgetCountdownTarget(
                        key: key,
                        activePrayerKey: key,
                        label: timing.label.isEmpty ? defaultLabel(for: key) : timing.label,
                        time: displayClock(timing.time, format: snapshot.timeFormat),
                        date: targetDate
                    )
                }
            }
        }
        return best
    }

    private static func defaultLabel(for key: String) -> String {
        switch key {
        case "fajr": return "الفجر"
        case "sunrise": return "الشروق"
        case "dhuhr": return "الظهر"
        case "asr": return "العصر"
        case "maghrib": return "المغرب"
        case "isha": return "العشاء"
        default: return "الصلاة القادمة"
        }
    }

    // Pre-schedule visual state changes instead of relying on WidgetKit to reload
    // the provider exactly when a countdown hits zero. WidgetKit can defer reloads,
    // but it switches between already-provided timeline entries at their dates.
    static func transitionDates(snapshot: PrayerWidgetSnapshot, after now: Date) -> [Date] {
        guard snapshot.isConfigured else { return [] }
        let horizon = now.addingTimeInterval(30 * 60 * 60)
        var dates: [Date] = []

        if scheduledTarget(snapshot: snapshot, now: now) != nil,
           let schedule = snapshot.livePrayerSchedule {
            for event in schedule.days.flatMap({ $0.events }) where event.at.isFinite && event.at > 0 {
                let prayerDate = Date(timeIntervalSince1970: event.at / 1000)
                if prayerDate > now && prayerDate <= horizon { dates.append(prayerDate) }
                if normalizedKey(event.key) != "sunrise", let end = event.iqamaAt,
                   end.isFinite, end > event.at {
                    let iqamaDate = Date(timeIntervalSince1970: end / 1000)
                    if iqamaDate > now && iqamaDate <= horizon { dates.append(iqamaDate) }
                }
            }
            return Array(Set(dates)).sorted()
        }

        for timing in snapshot.timings {
            let key = normalizedKey(timing.key, label: timing.label)
            guard !key.isEmpty else { continue }

            // Include a previous-day iqama ending after midnight and every boundary
            // within the 30-hour horizon, even when that spans three local dates.
            for prayerDate in prayerDates(for: timing, in: snapshot, relativeTo: now, dayOffsets: -1...2) {
                if prayerDate > now && prayerDate <= horizon {
                    dates.append(prayerDate)
                }

                if key != "sunrise",
                   let minutes = iqamaMinutes(for: key, in: snapshot), minutes > 0 {
                    let iqamaDate = prayerDate.addingTimeInterval(TimeInterval(minutes * 60))
                    if iqamaDate > now && iqamaDate <= horizon {
                        dates.append(iqamaDate)
                    }
                }
            }
        }

        // Collapse duplicate boundaries (for example if two generated dates happen
        // to be identical) while retaining chronological order.
        let unique = Dictionary(grouping: dates) { Int($0.timeIntervalSince1970) }
            .compactMap { $0.value.first }
            .sorted()
        return unique
    }

    static func displayedTimings(snapshot: PrayerWidgetSnapshot) -> [PrayerWidgetTime] {
        let order: [(String, String)] = [
            ("isha", "العشاء"),
            ("maghrib", "المغرب"),
            ("asr", "العصر"),
            ("dhuhr", "الظهر"),
            ("sunrise", "الشروق"),
            ("fajr", "الفجر")
        ]

        return order.map { key, fallbackLabel in
            timing(for: key, in: snapshot)
                ?? PrayerWidgetTime(key: key, label: fallbackLabel, time: "--:--")
        }
    }
}

private struct MunibinPrayerTimelineProvider: TimelineProvider {
    private func withSavedPreferences(_ snapshot: PrayerWidgetSnapshot) -> PrayerWidgetSnapshot {
        let defaults = UserDefaults(suiteName: MunibinPrayerWidgetStore.appGroup)
        let saved = defaults?.string(forKey: MunibinPrayerWidgetStore.timeFormatKey)
        let format = saved == "24h" ? "24h" : (saved == "12h" ? "12h" : (snapshot.timeFormat == "12h" ? "12h" : "24h"))
        var selectedTheme: [String: Any] = [:]
        if let data = defaults?.data(forKey: MunibinPrayerWidgetStore.themeKey),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let theme = decoded as? [String: Any] { selectedTheme = theme }
        return PrayerWidgetSnapshot(
            version: snapshot.version,
            prayerTimesEnabled: snapshot.prayerTimesEnabled,
            updatedAt: snapshot.updatedAt,
            hijriDate: snapshot.hijriDate,
            nextPrayer: snapshot.nextPrayer,
            timings: snapshot.timings,
            upcomingPrayers: snapshot.upcomingPrayers,
            notificationsEnabled: snapshot.notificationsEnabled,
            notificationConfigKey: snapshot.notificationConfigKey,
            theme: selectedTheme["theme"] as? String ?? snapshot.theme,
            iqamaOffsets: snapshot.iqamaOffsets,
            timeFormat: format,
            backgroundPalette: selectedTheme["backgroundPalette"] as? String ?? snapshot.backgroundPalette,
            themeColors: selectedTheme["themeColors"] as? [String: String] ?? snapshot.themeColors,
            livePrayerSchedule: snapshot.livePrayerSchedule
        )
    }

    private func snapshot() -> PrayerWidgetSnapshot {
        let decoder = JSONDecoder()

        // Primary path: shared UserDefaults written by the host app.
        if let defaults = UserDefaults(suiteName: MunibinPrayerWidgetStore.appGroup),
           let data = defaults.data(forKey: MunibinPrayerWidgetStore.snapshotKey),
           let snapshot = try? decoder.decode(PrayerWidgetSnapshot.self, from: data) {
            return withSavedPreferences(snapshot)
        }

        // Fallback path: the host app also writes an atomic JSON file into the
        // App Group. Reading it here makes the existing fallback real instead of
        // leaving the widget on its placeholder when UserDefaults propagation is late.
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MunibinPrayerWidgetStore.appGroup
        ) {
            let url = container.appendingPathComponent(MunibinPrayerWidgetStore.snapshotFileName)
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(PrayerWidgetSnapshot.self, from: data) {
                return withSavedPreferences(snapshot)
            }
        }

        return withSavedPreferences(.placeholder)
    }

    private func snapshotForCurrentTime(_ loaded: PrayerWidgetSnapshot? = nil, now: Date = .now) -> PrayerWidgetSnapshot {
        let loaded = loaded ?? snapshot()
        guard loaded.isConfigured else { return loaded }
        if loaded.livePrayerSchedule != nil {
            return PrayerWidgetSupport.displaySnapshot(loaded, now: now)
        }
        guard let upcoming = loaded.upcomingPrayers,
              let current = upcoming.first(where: {
                  guard !["pre-prayer", "iqama"].contains($0.kind ?? $0.type ?? "prayer"),
                        let date = $0.originalPrayerDate else { return false }
                  return date > now
              }) else {
            return loaded
        }

        return PrayerWidgetSnapshot(
            version: loaded.version,
            prayerTimesEnabled: loaded.prayerTimesEnabled,
            updatedAt: loaded.updatedAt,
            hijriDate: loaded.hijriDate,
            nextPrayer: current,
            timings: loaded.timings,
            upcomingPrayers: loaded.upcomingPrayers,
            notificationsEnabled: loaded.notificationsEnabled,
            notificationConfigKey: loaded.notificationConfigKey,
            theme: loaded.theme,
            iqamaOffsets: loaded.iqamaOffsets,
            timeFormat: loaded.timeFormat,
            backgroundPalette: loaded.backgroundPalette,
            themeColors: loaded.themeColors,
            livePrayerSchedule: loaded.livePrayerSchedule
        )
    }

    func placeholder(in context: Context) -> MunibinPrayerWidgetEntry {
        MunibinPrayerWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MunibinPrayerWidgetEntry) -> Void) {
        let now = Date()
        completion(MunibinPrayerWidgetEntry(date: now, snapshot: snapshotForCurrentTime(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MunibinPrayerWidgetEntry>) -> Void) {
        let now = Date()
        let loaded = snapshot()
        var entries: [MunibinPrayerWidgetEntry] = [
            MunibinPrayerWidgetEntry(
                date: now,
                snapshot: snapshotForCurrentTime(loaded, now: now)
            )
        ]

        // Queue prayer-time and iqama-end entries in advance. The view recalculates
        // its target from entry.date, so at the exact iqama boundary the label/countdown
        // switches immediately without needing the user to tap the widget.
        for boundary in PrayerWidgetSupport.transitionDates(snapshot: loaded, after: now) {
            entries.append(
                MunibinPrayerWidgetEntry(
                    date: boundary,
                    snapshot: snapshotForCurrentTime(loaded, now: boundary)
                )
            )
        }

        // Ask for fresh host data periodically, while retaining the already queued
        // boundary entries if iOS postpones that provider refresh.
        let refresh = now.addingTimeInterval(6 * 60 * 60)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

struct MunibinPalette {
    let backgroundStart: Color
    let backgroundEnd: Color
    let accent: Color
    let primary: Color
    let secondary: Color
    let highlight: Color
    let iqama: Color
    let border: Color
    let iconBackground: Color

    private static let fallbackColors: [String: [String: String]] = [
        "dark.cream": ["backgroundStart":"#3D1506","backgroundEnd":"#4D1D09","accent":"#F59E0B","primary":"#FFFFFF","secondary":"#C1B0A9","border":"#6F3E0D","iconBackground":"#68370C"],
        "dark.gold": ["backgroundStart":"#3A2905","backgroundEnd":"#543B08","accent":"#F59E0B","primary":"#FFFFFF","secondary":"#C3BBA9","border":"#88681D","iconBackground":"#6E4F0B"],
        "dark.olive": ["backgroundStart":"#263020","backgroundEnd":"#3A482D","accent":"#F59E0B","primary":"#FFFFFF","secondary":"#BABFB6","border":"#5E6F44","iconBackground":"#595A29"],
        "dark.wood": ["backgroundStart":"#352016","backgroundEnd":"#4B2D1C","accent":"#F59E0B","primary":"#FFFFFF","secondary":"#C0B6B0","border":"#785133","iconBackground":"#66441B"],
        "dark.blue": ["backgroundStart":"#1F2B30","backgroundEnd":"#2C3C43","accent":"#F59E0B","primary":"#FFFFFF","secondary":"#B5BBBD","border":"#475B63","iconBackground":"#4E503A"],
        "dark.monochrome": ["backgroundStart":"#000000","backgroundEnd":"#0F0F0F","accent":"#FFFFFF","primary":"#FFFFFF","secondary":"#ABABAB","border":"#3F3F3F","iconBackground":"#272727"],
        "light.cream": ["backgroundStart":"#FDF6E3","backgroundEnd":"#F9EDCE","accent":"#B45309","primary":"#3D1506","secondary":"#7F604C","border":"#E8C69D","iconBackground":"#F1DAB6"],
        "light.gold": ["backgroundStart":"#FFF5CF","backgroundEnd":"#FFEDB6","accent":"#B45309","primary":"#3D1506","secondary":"#816043","border":"#E7CA85","iconBackground":"#F6DAA1"],
        "light.olive": ["backgroundStart":"#F1F3DF","backgroundEnd":"#E6EBCC","accent":"#B45309","primary":"#3D1506","secondary":"#78604B","border":"#C0CBA5","iconBackground":"#E0D9B4"],
        "light.wood": ["backgroundStart":"#F5E9DC","backgroundEnd":"#EFDAC6","accent":"#B45309","primary":"#3D1506","secondary":"#7B5A49","border":"#D4B79F","iconBackground":"#E8CAAF"],
        "light.blue": ["backgroundStart":"#E9F0F2","backgroundEnd":"#DCE7EA","accent":"#B45309","primary":"#3D1506","secondary":"#745E56","border":"#B7C8CD","iconBackground":"#D7D5CF"],
        "light.monochrome": ["backgroundStart":"#FFFFFF","backgroundEnd":"#FAFAFA","accent":"#000000","primary":"#000000","secondary":"#575757","border":"#CDCDCD","iconBackground":"#EAEAEA"]
    ]

    static func color(_ hex: String) -> Color {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt(cleaned, radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    static func forTheme(_ theme: String?, backgroundPalette: String? = nil,
                         themeColors: [String: String]? = nil) -> MunibinPalette {
        let light = theme == "light"
        let backgrounds: [String: (String, String)] = [
            "cream": ("#3D1506", "#FDF6E3"), "gold": ("#3A2905", "#FFF5CF"),
            "olive": ("#263020", "#F1F3DF"), "wood": ("#352016", "#F5E9DC"),
            "blue": ("#1F2B30", "#E9F0F2"), "monochrome": ("#000000", "#FFFFFF")
        ]
        let pair = backgrounds[backgroundPalette ?? "cream"] ?? backgrounds["cream"]!
        let fallbackBackground = light ? pair.1 : pair.0
        let monochrome = backgroundPalette == "monochrome"
        let fallback = fallbackColors[(light ? "light." : "dark.") + (backgroundPalette ?? "cream")]
            ?? fallbackColors[light ? "light.cream" : "dark.cream"]!
        func resolved(_ key: String, _ fallback: String) -> Color {
            guard let hex = themeColors?[key],
                  hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                return color(fallback)
            }
            return color(hex)
        }
        return MunibinPalette(
            backgroundStart: resolved("backgroundStart", fallback["backgroundStart"] ?? fallbackBackground),
            backgroundEnd: resolved("backgroundEnd", fallback["backgroundEnd"] ?? fallbackBackground),
            accent: resolved("accent", fallback["accent"] ?? (monochrome ? (light ? "#000000" : "#FFFFFF") : (light ? "#B45309" : "#F59E0B"))),
            primary: resolved("primary", fallback["primary"] ?? (light ? (monochrome ? "#000000" : "#3D1506") : "#FFFFFF")),
            secondary: resolved("secondary", fallback["secondary"] ?? (light ? "#776B60" : "#B7AC9D")),
            highlight: color(light ? "#12642F" : "#85F0AB"),
            iqama: color(light ? "#A32335" : "#FFB4AE"),
            border: resolved("border", fallback["border"] ?? fallbackBackground),
            iconBackground: resolved("iconBackground", fallback["iconBackground"] ?? fallbackBackground)
        )
    }
}

private struct MunibinPrayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MunibinPrayerWidgetEntry

    private var palette: MunibinPalette {
        MunibinPalette.forTheme(entry.snapshot.theme, backgroundPalette: entry.snapshot.backgroundPalette,
                               themeColors: entry.snapshot.themeColors)
    }

    private var target: PrayerWidgetCountdownTarget {
        PrayerWidgetSupport.countdownTarget(snapshot: entry.snapshot, now: entry.date)
            ?? PrayerWidgetCountdownTarget(key: "", activePrayerKey: "", label: "الصلاة القادمة", time: "—", date: nil)
    }

    private var displayedTimings: [PrayerWidgetTime] {
        PrayerWidgetSupport.displayedTimings(snapshot: entry.snapshot)
    }

    // Match the Live Activity's system-rendered, bounded countdown. Keep the
    // published target instant intact; it also drives the scheduled phase change.
    private func countdownText(to date: Date) -> Text {
        Text(timerInterval: date.addingTimeInterval(-2 * 24 * 3600)...date,
             countsDown: true, showsHours: true)
    }

    var body: some View {
        Group {
            if !entry.snapshot.isConfigured {
                if #available(iOSApplicationExtension 16.0, *), family == .accessoryInline {
                    lockScreenDisabledInlineLayout
                } else if #available(iOSApplicationExtension 16.0, *), family == .accessoryRectangular {
                    lockScreenDisabledRectangularLayout
                } else {
                    disabledHomeLayout
                }
            } else if #available(iOSApplicationExtension 16.0, *), family == .accessoryInline {
                lockScreenInlineLayout
            } else if #available(iOSApplicationExtension 16.0, *), family == .accessoryRectangular {
                lockScreenRectangularLayout
            } else if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .widgetURL(URL(string: "https://munibin.com/prayer-times"))
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }

    @available(iOSApplicationExtension 16.0, *)
    private var lockScreenDisabledInlineLayout: some View {
        Text("فعّل مواقيت الصلاة من التطبيق")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .environment(\.layoutDirection, .rightToLeft)
            .accessibilityLabel("فعّل مواقيت الصلاة من تطبيق منيبين")
    }

    @available(iOSApplicationExtension 16.0, *)
    private var lockScreenDisabledRectangularLayout: some View {
        VStack(spacing: 3) {
            Text("فعّل مواقيت الصلاة")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("من التطبيق")
                .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("فعّل مواقيت الصلاة من تطبيق منيبين")
    }

    private var disabledHomeLayout: some View {
        VStack(spacing: 9) {
            Image(systemName: "clock.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text("فعّل مواقيت الصلاة")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.primary)
            Text("افتح صفحة المواقيت في منيبين وحدد موقعك لعرض الأوقات هنا")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("فعّل مواقيت الصلاة من تطبيق منيبين")
    }

    // Opaque white is the strongest input to the Lock Screen vibrant material.
    // App palette colors can become faint when the system desaturates them.
    @available(iOSApplicationExtension 16.0, *)
    private var lockScreenInlineLayout: some View {
        Group {
            if let date = target.date {
                (Text(target.label + " • ").foregroundColor(Color.white)
                 + countdownText(to: date)
                    .foregroundColor(Color.white))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(target.label + " • " + target.time)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .multilineTextAlignment(.center)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityLabel("\(target.label)، الوقت المتبقي")
    }

    // Opaque white is the strongest input to the Lock Screen vibrant material.
    // App palette colors can become faint when the system desaturates them.
    @available(iOSApplicationExtension 16.0, *)
    private var lockScreenRectangularLayout: some View {
        VStack(spacing: 3) {
            Text(target.label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
                .environment(\.layoutDirection, .rightToLeft)

            if let date = target.date {
                countdownText(to: date)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(target.time)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.label)، الوقت المتبقي")
    }

    private var mediumLayout: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 275 || geometry.size.height < 122
            let rowContentWidth = max(1, geometry.size.width - 8)
            let countdownWidth = rowContentWidth * 0.56
            let prayerWidth = rowContentWidth / 5
            let sectionSpacing: CGFloat = compact
                ? (geometry.size.height < 116 ? 2 : 4)
                : (geometry.size.height < 128 ? 3 : 6)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    mediumCountdownBlock(width: countdownWidth, compact: compact)
                    mediumBranding
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Spacer(minLength: sectionSpacing)
                sunriseStrip(compact: compact)
                Spacer(minLength: sectionSpacing)
                prayerTimesRow(columnWidth: prayerWidth, compact: compact)
            }
            .padding(.top, compact ? 0 : 1)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, 2)
    }

    // A system timer must receive a finite width in this horizontal header.
    // Keeping that bound on the Text itself avoids the blank medium-widget
    // regression caused by an expanding timer inside a flexible HStack.
    private func mediumCountdownBlock(width: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.key == "iqama" ? target.label : "\(target.label) بعد")
                .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .environment(\.layoutDirection, .rightToLeft)
                .frame(width: width, alignment: .leading)

            if let date = target.date {
                countdownText(to: date)
                    .font(.system(size: compact ? 24 : 27, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(target.key == "iqama" ? palette.iqama : palette.highlight)
                    .lineLimit(1)
                    .frame(width: width, height: compact ? 29 : 33, alignment: .leading)
            } else {
                Text(target.time)
                    .font(.system(size: compact ? 24 : 27, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .frame(width: width, height: compact ? 29 : 33, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var mediumBranding: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("منيبين")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)

            Text(entry.snapshot.hijriDate)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .multilineTextAlignment(.trailing)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func sunriseStrip(compact: Bool) -> some View {
        let timing = PrayerWidgetSupport.timing(for: "sunrise", in: entry.snapshot)
        let isActive = target.activePrayerKey == "sunrise"

        return HStack(spacing: 5) {
            Text(PrayerWidgetSupport.displayClock(timing?.time ?? "--:--", format: entry.snapshot.timeFormat))
                .font(.system(size: compact ? 10 : 10.5, weight: .semibold, design: .rounded).monospacedDigit())
            Text("الشروق")
                .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
            Image(systemName: "sunrise.fill")
                .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
        }
        .lineLimit(1)
        .foregroundStyle(isActive ? palette.highlight : palette.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
        .background(palette.iconBackground, in: Capsule())
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .combine)
    }

    private func iqamaOffsetText(for timing: PrayerWidgetTime) -> String? {
        let key = PrayerWidgetSupport.normalizedKey(timing.key, label: timing.label)
        guard key != "sunrise",
              PrayerWidgetSupport.timing(for: key, in: entry.snapshot) != nil,
              let minutes = entry.snapshot.iqamaOffsets?.first(where: {
                  PrayerWidgetSupport.normalizedKey($0.key) == key
              })?.value,
              minutes > 0 else { return nil }
        return "+\(minutes)"
    }

    private func mediumClockText(for timing: PrayerWidgetTime, compact: Bool) -> Text {
        let clock = PrayerWidgetSupport.displayClock(timing.time, format: entry.snapshot.timeFormat)
        let parts = clock.split(separator: " ", maxSplits: 1)
        guard entry.snapshot.timeFormat == "12h", parts.count == 2 else {
            return Text(clock)
        }
        // Keep the formatter's RTL isolates and suffix order. A smaller ص/م
        // leaves room for larger clock digits without reducing the whole row.
        return Text(String(parts[0])) + Text(" " + String(parts[1]))
            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
    }

    private var smallLayout: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 8)

            countdownBlock(countdownSize: 27, labelSize: 13)

            Spacer(minLength: 4)
        }
        .padding(12)
    }

    private var header: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("منيبين")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.accent)
                .lineLimit(1)

            Text(entry.snapshot.hijriDate)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .multilineTextAlignment(.trailing)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func countdownBlock(countdownSize: CGFloat, labelSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(target.key == "iqama" ? target.label : "\(target.label) بعد")
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .environment(\.layoutDirection, .rightToLeft)

            if let date = target.date {
                countdownText(to: date)
                    .font(.system(size: countdownSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(target.key == "iqama" ? palette.iqama : palette.highlight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(target.time)
                    .font(.system(size: countdownSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func prayerTimesRow(columnWidth: CGFloat, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(displayedTimings.filter {
                PrayerWidgetSupport.normalizedKey($0.key, label: $0.label) != "sunrise"
            }) { timing in
                let isActive = PrayerWidgetSupport.normalizedKey(timing.key, label: timing.label) == target.activePrayerKey
                let offset = iqamaOffsetText(for: timing)

                VStack(spacing: 1) {
                    Text(timing.label)
                        .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
                        .lineLimit(1)

                    mediumClockText(for: timing, compact: compact)
                        .font(.system(size: entry.snapshot.timeFormat == "12h"
                                      ? (compact ? 12.5 : 13.5)
                                      : (compact ? 13.5 : 14.5),
                                      weight: .bold, design: .rounded).monospacedDigit())
                        .tracking(entry.snapshot.timeFormat == "12h" ? -0.2 : 0)
                        .lineLimit(1)

                    Text(offset ?? "")
                        .font(.system(size: compact ? 10 : 10.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle((isActive ? palette.highlight : palette.primary).opacity(0.72))
                        .lineLimit(1)
                        .frame(height: compact ? 12 : 13)
                        .accessibilityHidden(offset == nil)

                    Rectangle()
                        .fill(isActive ? palette.highlight : Color.clear)
                        .frame(width: columnWidth * 0.84, height: 1.5)
                }
                .foregroundStyle(
                    isActive
                        ? palette.highlight
                        : palette.primary
                )
                .frame(width: columnWidth)
            }
        }
        // Sunrise has its own strip, so five equal columns retain room for clocks.
        // Visual left -> right: Isha, Maghrib, Asr, Dhuhr, Fajr.
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct MunibinWidget: Widget {
    let kind = "MunibinPrayerWidget"

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 16.0, *) {
            return [.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular]
        }
        return [.systemSmall, .systemMedium]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MunibinPrayerTimelineProvider()) { entry in
            let palette = MunibinPalette.forTheme(entry.snapshot.theme,
                                                 backgroundPalette: entry.snapshot.backgroundPalette,
                                                 themeColors: entry.snapshot.themeColors)
            if #available(iOSApplicationExtension 17.0, *) {
                MunibinPrayerWidgetView(entry: entry)
                    .containerBackground(for: .widget) {
                        LinearGradient(colors: [palette.backgroundStart, palette.backgroundEnd],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
            } else {
                MunibinPrayerWidgetView(entry: entry)
                    .background(LinearGradient(colors: [palette.backgroundStart, palette.backgroundEnd],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .configurationDisplayName("مواقيت منيبين")
        .description("الصلاة القادمة والوقت المتبقي أعلى أو أسفل ساعة شاشة القفل، مع مواقيت اليوم على الشاشة الرئيسية.")
        .supportedFamilies(supportedFamilies)
    }
}


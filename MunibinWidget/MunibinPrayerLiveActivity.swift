import ActivityKit
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 16.2, *)
private struct PrayerLiveCountdown: View {
    let state: PrayerLiveActivityAttributes.ContentState
    let stale: Bool
    let size: CGFloat
    var onIsland: Bool = false

    private var palette: MunibinPalette {
        MunibinPalette.forTheme(onIsland ? "dark" : state.theme,
                               backgroundPalette: onIsland ? "monochrome" : state.backgroundPalette,
                               themeColors: onIsland ? nil : state.themeColors)
    }

    var body: some View {
        Group {
            if stale {
                Text("جارٍ تحديث المواقيت")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            } else {
                Text(timerInterval: Date(timeIntervalSince1970: state.targetEpoch - 2 * 24 * 3600)...Date(timeIntervalSince1970: state.targetEpoch),
                     countsDown: true, showsHours: true)
                    .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(state.phase == "iqama" ? palette.iqama : palette.highlight)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.layoutDirection, .leftToRight)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct PrayerLiveTimetable: View {
    let state: PrayerLiveActivityAttributes.ContentState
    let compact: Bool
    var onIsland: Bool = false
    var fittingLockScreen: Bool = false
    var showsRowCountdown: Bool = false
    var stale: Bool = false
    private var palette: MunibinPalette {
        MunibinPalette.forTheme(onIsland ? "dark" : state.theme,
                               backgroundPalette: onIsland ? "monochrome" : state.backgroundPalette,
                               themeColors: onIsland ? nil : state.themeColors)
    }

    // Offsets follow their prayer clock's color, with lighter emphasis. The
    // active iqama countdown keeps its distinct phase color above.
    private func iqamaOffsetColor(_ timing: PrayerLiveActivityAttributes.Timing) -> Color {
        (timing.key == state.prayerKey ? palette.highlight : palette.primary).opacity(0.72)
    }

    private func iqamaOffset(_ timing: PrayerLiveActivityAttributes.Timing) -> String? {
        guard timing.key != "sunrise", timing.atEpoch.isFinite, timing.atEpoch > 0,
              let end = timing.iqamaEpoch, end.isFinite else { return nil }
        // Absolute instants preserve offsets across midnight and DST. The
        // displayed clocks are deliberately never used to calculate this value.
        let seconds = end - timing.atEpoch
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = (seconds / 60).rounded()
        guard minutes >= 1, minutes < Double(Int.max), abs(seconds - minutes * 60) < 0.000001 else { return nil }
        return "+\(Int(minutes))"
    }

    private func displayClock(_ canonical: String) -> String {
        let formatted = PrayerLiveActivityClock.display(canonical, format: state.timeFormat)
        guard state.timeFormat != "24h", let separator = formatted.lastIndex(of: " ") else {
            return formatted
        }
        let digits = formatted[..<separator]
        let suffix = formatted[formatted.index(after: separator)...]
        guard suffix == "ص" || suffix == "م" else { return formatted }
        // Match the app's Arabic clock order while keeping English digits LTR.
        return "\u{2067}\u{2066}\(digits)\u{2069} \(suffix)\u{2069}"
    }

    private var rowClockSize: CGFloat { compact ? 16 : (fittingLockScreen ? 17 : 18) }
    private var rowNameSize: CGFloat { compact ? 15 : (fittingLockScreen ? 16 : 17) }
    private var rowTimerSize: CGFloat { compact ? 15 : (fittingLockScreen ? 16 : 17) }
    private var rowTimerWidth: CGFloat { compact ? 80 : (fittingLockScreen ? 84 : 92) }

    private var hasTargetRow: Bool {
        state.timings.contains { $0.key == state.prayerKey }
    }

    // The clock and offset stay at the left. The timer belongs to the name at
    // the right, not to the clock column. Its finite width is important because
    // native timer Text must not claim the whole available horizontal space.
    private var lockScreenRows: some View {
        VStack(spacing: 0) {
            ForEach(state.timings, id: \.key) { timing in
                HStack(spacing: 0) {
                    HStack(spacing: fittingLockScreen ? 5 : 7) {
                        Text(displayClock(timing.time))
                            .font(.system(size: rowClockSize, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(timing.key == state.prayerKey ? palette.highlight : palette.primary)
                        if let offset = iqamaOffset(timing) {
                            Text(offset)
                                .font(.system(size: fittingLockScreen ? 11.5 : 12, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(iqamaOffsetColor(timing))
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: fittingLockScreen ? 6 : 8)
                    HStack(spacing: fittingLockScreen ? 4 : 5) {
                        if timing.key == state.prayerKey {
                            VStack(alignment: .trailing, spacing: 0) {
                                if state.phase == "iqama" {
                                    Text("الإقامة")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(palette.iqama)
                                }
                                if state.targetEpoch.isFinite && state.targetEpoch > 0 {
                                    PrayerLiveCountdown(state: state, stale: stale, size: rowTimerSize)
                                        .frame(width: rowTimerWidth, alignment: .trailing)
                                } else {
                                    Text(stale ? "جارٍ تحديث المواقيت" : "غير متاح")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.secondary)
                                        .frame(width: rowTimerWidth, alignment: .trailing)
                                }
                            }
                        } else if !hasTargetRow && timing.key == state.timings.first?.key {
                            Text(stale ? "جارٍ تحديث المواقيت" : "غير متاح")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.secondary)
                                .frame(width: rowTimerWidth, alignment: .trailing)
                        }
                        Text(timing.label)
                            .font(.system(size: rowNameSize, weight: .semibold))
                            .foregroundStyle(timing.key == state.prayerKey ? palette.highlight : palette.primary)
                    }
                    .layoutPriority(1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
                if timing.key != state.timings.last?.key {
                    Spacer(minLength: 3)
                }
            }
        }
    }

    // The expanded island keeps its existing compact presentation. Only the
    // Lock Screen moves the countdown into the current prayer's timetable row.
    private var islandRows: some View {
        VStack(spacing: compact ? 2 : 3) {
            ForEach(state.timings, id: \.key) { timing in
                HStack(spacing: 7) {
                    Text(displayClock(timing.time))
                        .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(timing.key == state.prayerKey ? palette.highlight : palette.primary)
                    if let offset = iqamaOffset(timing) {
                        Text(offset)
                            .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(iqamaOffsetColor(timing))
                    }
                    Spacer(minLength: 4)
                    Text(timing.label)
                        .font(.system(size: compact ? 11.5 : 13.5, weight: .semibold))
                        .foregroundStyle(timing.key == state.prayerKey ? palette.highlight : palette.primary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
        }
    }

    var body: some View {
        Group {
            if showsRowCountdown {
                lockScreenRows
            } else {
                islandRows
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }
}

@available(iOSApplicationExtension 16.2, *)
struct MunibinPrayerLiveActivity: Widget {
    private func phaseLabel(_ state: PrayerLiveActivityAttributes.ContentState) -> String {
        state.phase == "iqama" ? state.label + " الإقامة" : state.label
    }

    // Give all six rows the space previously occupied by a separate headline.
    // First adapt to the available width, then let SwiftUI measure each table's
    // natural Arabic/rounded-font height before applying the 156-point host.
    // The final 16/15-point variant is still larger than the previous list and
    // protects the active iqama caption if a system font has taller line metrics.
    private func lockScreenBody(_ state: PrayerLiveActivityAttributes.ContentState,
                                stale: Bool, fitting: Bool, compact: Bool = false) -> some View {
        PrayerLiveTimetable(state: state, compact: compact, fittingLockScreen: fitting,
                            showsRowCountdown: true, stale: stale)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrayerLiveActivityAttributes.self) { context in
            let state = context.state
            let palette = MunibinPalette.forTheme(state.theme, backgroundPalette: state.backgroundPalette,
                                                 themeColors: state.themeColors)
            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    lockScreenBody(state, stale: context.isStale, fitting: geometry.size.width < 310)
                    lockScreenBody(state, stale: context.isStale, fitting: true)
                    lockScreenBody(state, stale: context.isStale, fitting: true, compact: true)
                }
                .frame(width: geometry.size.width, height: 156)
                .padding(.vertical, 2)
            }
            .frame(height: 160)
            .padding(.horizontal, 15)
            .activityBackgroundTint(palette.backgroundStart)
            .activitySystemActionForegroundColor(palette.accent)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .widgetURL(URL(string: "https://munibin.com/prayer-times"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PrayerLiveCountdown(state: context.state, stale: context.isStale, size: 24, onIsland: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(phaseLabel(context.state))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let palette = MunibinPalette.forTheme("dark", backgroundPalette: "monochrome")
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(palette.border)
                            .frame(height: 1)
                        PrayerLiveTimetable(state: context.state, compact: true, onIsland: true)
                    }
                }
            } compactLeading: {
                Text(context.state.phase == "iqama" ? "إقامة" : context.state.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white)
            } compactTrailing: {
                PrayerLiveCountdown(state: context.state, stale: context.isStale, size: 12, onIsland: true)
                    .frame(maxWidth: 75)
            } minimal: {
                Image(systemName: context.state.phase == "iqama" ? "bell.fill" : "clock.fill")
                    .foregroundStyle(Color(red: 133.0 / 255, green: 240.0 / 255, blue: 171.0 / 255))
            }
            .widgetURL(URL(string: "https://munibin.com/prayer-times"))
            .keylineTint(Color(red: 133.0 / 255, green: 240.0 / 255, blue: 171.0 / 255))
        }
    }
}

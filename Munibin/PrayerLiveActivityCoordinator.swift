import ActivityKit
import Foundation
import Security
import UIKit

@available(iOS 16.2, *)
private struct PrayerLiveActivityPlan {
    struct Update: Codable, Hashable {
        let at: Double
        let contentState: PrayerLiveActivityAttributes.ContentState
        let staleAt: Double
    }

    let contentState: PrayerLiveActivityAttributes.ContentState
    let updates: [Update]
    let expiresAt: Double

    private struct Event {
        let key: String
        let label: String
        let at: Double
        let iqamaAt: Double?
        let day: String
    }

    static func build(snapshot: [String: Any], now: Date, expiresAt: Double) -> Self? {
        guard snapshot["prayerTimesEnabled"] as? Bool == true,
              let schedule = snapshot["livePrayerSchedule"] as? [String: Any],
              let identifier = schedule["timeZone"] as? String,
              let zone = TimeZone(identifier: identifier),
              let days = schedule["days"] as? [[String: Any]], expiresAt > now.timeIntervalSince1970 else { return nil }
        let labels = ["fajr": "الفجر", "sunrise": "الشروق", "dhuhr": "الظهر",
                      "asr": "العصر", "maghrib": "المغرب", "isha": "العشاء"]
        let order = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]
        let originalAt = (snapshot["timings"] as? [[String: Any]])?.compactMap { $0["at"] as? String }.first
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let originalDate = originalAt.flatMap { isoFormatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        var selectedCalendar = Calendar(identifier: .gregorian)
        selectedCalendar.timeZone = zone
        var events: [Event] = []
        var hijriDates: [String: String] = [:]
        for day in days {
            guard let date = day["date"] as? String, let values = day["events"] as? [[String: Any]] else { continue }
            if let hijriDate = day["hijriDate"] as? String { hijriDates[date] = hijriDate }
            for value in values {
                guard let key = value["key"] as? String, let label = labels[key],
                      let milliseconds = value["at"] as? NSNumber,
                      milliseconds.doubleValue.isFinite, milliseconds.doubleValue > 0 else { continue }
                let at = floor(milliseconds.doubleValue / 1000)
                let rawIqama = (value["iqamaAt"] as? NSNumber)?.doubleValue ?? 0
                let iqama = floor(rawIqama / 1000)
                let validIqama = key != "sunrise" && rawIqama.isFinite && iqama > at
                events.append(Event(key: key, label: label, at: at, iqamaAt: validIqama ? iqama : nil, day: date))
            }
        }
        events.sort { $0.at < $1.at }
        // Several phase changes share the same day's six clocks. Format that
        // table once per day rather than again for every scheduled boundary.
        var tables: [String: [PrayerLiveActivityAttributes.Timing]] = [:]
        func state(at nowEpoch: Double) -> PrayerLiveActivityAttributes.ContentState? {
            // Keep the earliest prayer active until its iqama ends, even if a
            // later prayer has already begun. Sunrise never has an iqama phase.
            let active = events.first { event in
                guard let iqama = event.iqamaAt else { return false }
                return event.at <= nowEpoch && nowEpoch < iqama
            }
            guard let target = active ?? events.first(where: { $0.at > nowEpoch }) else { return nil }
            let table: [PrayerLiveActivityAttributes.Timing]
            if let cached = tables[target.day] {
                table = cached
            } else {
                table = order.compactMap { key -> PrayerLiveActivityAttributes.Timing? in
                    guard let event = events.first(where: { $0.day == target.day && $0.key == key }) else { return nil }
                    return .init(key: key, label: event.label,
                                 time: PrayerLiveActivityClock.canonical(event.at, zone: zone), atEpoch: event.at,
                                 iqamaTime: event.iqamaAt.map { PrayerLiveActivityClock.canonical($0, zone: zone) },
                                 iqamaEpoch: event.iqamaAt)
                }
                tables[target.day] = table
            }
            guard table.count == 6 else { return nil }
            let sameDay = originalDate.map {
                selectedCalendar.isDate($0, inSameDayAs: Date(timeIntervalSince1970: target.at))
            } ?? false
            return .init(phase: active == nil ? "prayer" : "iqama", prayerKey: target.key,
                         label: target.label, targetEpoch: active?.iqamaAt ?? target.at,
                         timeZone: identifier, timeFormat: snapshot["timeFormat"] as? String == "12h" ? "12h" : "24h",
                         theme: snapshot["theme"] as? String == "light" ? "light" : "dark",
                         backgroundPalette: snapshot["backgroundPalette"] as? String,
                         themeColors: snapshot["themeColors"] as? [String: String],
                         hijriDate: hijriDates[target.day] ?? (sameDay ? (snapshot["hijriDate"] as? String ?? target.day) : target.day),
                         timings: table)
        }
        let nowEpoch = floor(now.timeIntervalSince1970)
        guard let current = state(at: nowEpoch),
              let encoded = try? JSONEncoder().encode(current), encoded.count < 3500 else { return nil }
        var result = [Update(at: nowEpoch, contentState: current, staleAt: min(current.targetEpoch, expiresAt))]
        let boundaries = Set(events.flatMap { event in [event.at] + (event.iqamaAt.map { [$0] } ?? []) })
            .filter { $0 > nowEpoch && $0 < expiresAt }.sorted()
        var previous = current
        for boundary in boundaries {
            guard let next = state(at: boundary), next != previous else { continue }
            result.append(Update(at: boundary, contentState: next, staleAt: min(next.targetEpoch, expiresAt)))
            previous = next
        }
        return .init(contentState: current, updates: result, expiresAt: expiresAt)
    }
}

// The server binds each UUID to this private random capability. Neither the
// capability nor ActivityKit push tokens cross into WebView or browser storage.
private enum PrayerLiveActivityCapability {
    private static let service = "com.motoonai.prayer-live-activity"
    static func value(for id: String, create: Bool) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data, let existing = String(data: data, encoding: .utf8) { return existing }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let capability = bytes.map { String(format: "%02x", $0) }.joined()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: id,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecValueData as String: Data(capability.utf8)]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        return capability
    }
}

private final class PrayerLiveActivityTransport: NSObject, URLSessionTaskDelegate {
    static let shared = PrayerLiveActivityTransport()
    private let queue = DispatchQueue(label: "com.motoonai.prayer-live-activity-upload")
    private let pendingKey = "munibin.prayer-live-activity.pending.v1"
    // Serial-queue ownership prevents resume retries from uploading the same
    // durable revision twice while its first request is still in flight.
    private var inFlight: [String: Set<Int>] = [:]
    private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
    private lazy var session: URLSession = {
        // Background URLSession follows redirects automatically without asking
        // its delegate. Use a bounded ordinary session so this private capability
        // can never be redirected to a different server.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func submit(id: String, body: [String: Any]) {
        queue.async {
            let defaults = UserDefaults.standard
            let revisionKey = "munibin.prayer-live-activity.revision.\(id)"
            let revision = defaults.integer(forKey: revisionKey) + 1
            defaults.set(revision, forKey: revisionKey)
            var payload = body
            payload["revision"] = revision
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var pending = defaults.dictionary(forKey: self.pendingKey) as? [String: Data] ?? [:]
            // The newest end tombstone replaces every queued upsert for this UUID.
            pending[id] = data
            defaults.set(pending, forKey: self.pendingKey)
            defaults.synchronize()
            self.upload(id: id, data: data)
        }
    }

    func retryPending() {
        queue.async {
            let pending = UserDefaults.standard.dictionary(forKey: self.pendingKey) as? [String: Data] ?? [:]
            for (id, data) in pending { self.upload(id: id, data: data) }
        }
    }

    private func upload(id: String, data: Data) {
        guard UUID(uuidString: id) != nil,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = payload["revision"] as? Int, let action = payload["action"] as? String,
              inFlight[id]?.contains(revision) != true,
              let capability = PrayerLiveActivityCapability.value(for: id, create: false),
              let url = URL(string: "https://munibin.com/api/native-prayer-live-activity/\(id)") else { return }
        if action == "upsert", let expiry = payload["expiresAt"] as? NSNumber,
           expiry.doubleValue <= Date().timeIntervalSince1970 {
            clearPending(id: id, revision: revision)
            return
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrayerLiveActivityUploads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(id)-\(revision).json")
            try data.write(to: file, options: .atomic)
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = "\(id)|\(revision)|\(action)|\(file.path)"
            inFlight[id, default: []].insert(revision)
            DispatchQueue.main.async {
                let identifier = UIApplication.shared.beginBackgroundTask(withName: "Prayer live activity sync") {
                    task.cancel()
                    if let identifier = self.backgroundTasks.removeValue(forKey: task.taskIdentifier), identifier != .invalid {
                        UIApplication.shared.endBackgroundTask(identifier)
                    }
                }
                self.backgroundTasks[task.taskIdentifier] = identifier
                task.resume()
            }
        } catch { /* The durable pending body is retried when the app resumes. */ }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let identifier = self.backgroundTasks.removeValue(forKey: task.taskIdentifier), identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
        guard let description = task.taskDescription else { return }
        let parts = description.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count == 4 else { return }
        try? FileManager.default.removeItem(atPath: parts[3])
        queue.async {
            guard let revision = Int(parts[1]) else { return }
            self.inFlight[parts[0]]?.remove(revision)
            if self.inFlight[parts[0]]?.isEmpty == true { self.inFlight.removeValue(forKey: parts[0]) }
            guard error == nil, let response = task.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) || [400, 401, 403, 409, 410].contains(response.statusCode) else { return }
            self.clearPending(id: parts[0], revision: revision)
        }
    }

    private func clearPending(id: String, revision: Int) {
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Data] ?? [:]
        if let data = pending[id], let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["revision"] as? Int == revision {
            // Never remove a newer end tombstone when an old upload finishes.
            pending.removeValue(forKey: id)
            UserDefaults.standard.set(pending, forKey: pendingKey)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Capability authorization is valid for this exact HTTPS endpoint only.
        completionHandler(nil)
    }

}

@available(iOS 16.2, *)
@MainActor
final class PrayerLiveActivityCoordinator {
    static let shared = PrayerLiveActivityCoordinator()
    private let enabledKey = "munibin.prayer-live-activity.enabled.v1"
    private let sessionKey = "munibin.prayer-live-activity.session.v1"
    private var snapshot: [String: Any]?
    private var watchers: [String: [Task<Void, Never>]] = [:]
    private var explicitlyEnding = Set<String>()
    private var lastState: PrayerLiveActivityAttributes.ContentState?
    private var lastSchedule: [PrayerLiveActivityPlan.Update] = []
    private var cachedPlanInput: NSDictionary?
    private var cachedPlan: PrayerLiveActivityPlan?
    private var lastStatus: Data?

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        PrayerLiveActivityTransport.shared.retryPending()
        reconcileMissingActivity()
    }

    func handle(_ body: Any) {
        guard let payload = body as? [String: Any] else { return }
        if payload["action"] as? String == "status" { reportStatus(force: true); return }
        guard let enabled = payload["enabled"] as? Bool, payload["explicit"] as? Bool == true else {
            reportStatus(force: true); return
        }
        if !enabled {
            UserDefaults.standard.set(false, forKey: enabledKey)
            endAll()
            reportStatus()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            reportStatus(message: "فعّل الأنشطة المباشرة لمنيبين من إعدادات iPhone.")
            return
        }
        UserDefaults.standard.set(true, forKey: enabledKey)
        if Activity<PrayerLiveActivityAttributes>.activities.isEmpty,
           let oldID = UserDefaults.standard.string(forKey: sessionKey) {
            PrayerLiveActivityTransport.shared.submit(id: oldID, body: ["action": "end"])
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        reportStatus()
        if let snapshot { sync(snapshot: snapshot) }
    }

    func sync(snapshot: [String: Any]) {
        self.snapshot = snapshot
        reconcileMissingActivity()
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        guard snapshot["prayerTimesEnabled"] as? Bool == true else {
            // A startup/cache placeholder or cleared timetable pauses the display,
            // not the saved user choice. Only explicit OFF/dismissal changes it.
            endAll(); reportStatus(); return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { endAll(); reportStatus(); return }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let activities = Activity<PrayerLiveActivityAttributes>.activities
        var activity = activities.first(where: {
            !explicitlyEnding.contains($0.id) && ($0.activityState == .active || $0.activityState == .stale)
        })
        // A Live Activity is a bounded session, not an unlimited background task.
        // Existing sessions retain their original expiry when the app reopens.
        let expiryKey = activity.map { "munibin.prayer-live-activity.expiry.\($0.attributes.sessionID)" }
        let existingExpiry = floor(expiryKey.map { UserDefaults.standard.double(forKey: $0) } ?? 0)
        if let expired = activity, existingExpiry > 0, existingExpiry <= now.timeIntervalSince1970 {
            explicitlyEnding.insert(expired.id)
            PrayerLiveActivityTransport.shared.submit(id: expired.attributes.sessionID, body: ["action": "end"])
            Task { await expired.end(nil, dismissalPolicy: .immediate) }
            activity = nil
        }
        let expires = activity != nil && existingExpiry > 0 ? existingExpiry : floor(now.timeIntervalSince1970) + 7 * 3600 + 55 * 60
        guard let plan = self.plan(for: snapshot, now: now, expiresAt: expires) else {
            reportStatus(message: "جارٍ تجهيز مواقيت النشاط المباشر."); return
        }
        if let activity {
            observe(activity)
            let scheduleChanged = lastSchedule != Array(plan.updates.dropFirst())
            if lastState != plan.contentState || scheduleChanged {
                lastState = plan.contentState
                lastSchedule = Array(plan.updates.dropFirst())
                Task { await activity.update(ActivityContent(state: plan.contentState,
                                                              staleDate: Date(timeIntervalSince1970: plan.updates[0].staleAt))) }
                upload(activity, plan: plan)
            }
            reportStatus(); return
        }
        guard UIApplication.shared.applicationState == .active else { reportStatus(); return }
        do {
            let id = UUID().uuidString.lowercased()
            guard PrayerLiveActivityCapability.value(for: id, create: true) != nil else {
                reportStatus(message: "تعذر حفظ إعدادات النشاط المباشر."); return
            }
            let requested = try Activity.request(attributes: PrayerLiveActivityAttributes(sessionID: id),
                                                 content: ActivityContent(state: plan.contentState,
                                                                          staleDate: Date(timeIntervalSince1970: plan.updates[0].staleAt)),
                                                 pushType: .token)
            UserDefaults.standard.set(expires, forKey: "munibin.prayer-live-activity.expiry.\(id)")
            UserDefaults.standard.set(id, forKey: sessionKey)
            lastState = plan.contentState
            lastSchedule = Array(plan.updates.dropFirst())
            observe(requested)
            upload(requested, plan: plan)
            reportStatus()
        } catch {
            // Temporary OS/network/session failures do not erase the saved opt-in.
            // Foreground snapshots can retry once ActivityKit is available again.
            reportStatus(message: "تعذر بدء النشاط المباشر. تحقق من إعدادات iPhone.")
        }
    }

    private func resume() {
        PrayerLiveActivityTransport.shared.retryPending()
        reconcileMissingActivity()
        for activity in Activity<PrayerLiveActivityAttributes>.activities { observe(activity) }
        // Fresh first-state timestamps also repair a request deferred offline.
        lastState = nil
        if let snapshot { sync(snapshot: snapshot) }
        reportStatus()
    }

    private func plan(for snapshot: [String: Any], now: Date, expiresAt: Double) -> PrayerLiveActivityPlan? {
        // Widget freshness and notification queues do not change Live Activity
        // content. Compare its actual inputs without the clock-only updatedAt.
        let keys = ["prayerTimesEnabled", "livePrayerSchedule", "timeFormat", "theme",
                    "backgroundPalette", "themeColors", "hijriDate"]
        let input = NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: keys.map {
            ($0, snapshot[$0] ?? NSNull())
        }))
        let nowEpoch = floor(now.timeIntervalSince1970)
        if let cached = cachedPlan, cachedPlanInput?.isEqual(input) == true,
           cached.expiresAt == expiresAt, let first = cached.updates.first {
            let boundary = min(cached.updates.dropFirst().first?.at ?? cached.contentState.targetEpoch,
                               min(cached.contentState.targetEpoch, expiresAt))
            if nowEpoch >= first.at && nowEpoch < boundary {
                // Keep the wire's current-state timestamp fresh when resuming or
                // renewing a push token; future boundary updates stay identical.
                let current = PrayerLiveActivityPlan.Update(at: nowEpoch, contentState: cached.contentState,
                                                           staleAt: first.staleAt)
                return .init(contentState: cached.contentState,
                             updates: [current] + Array(cached.updates.dropFirst()), expiresAt: expiresAt)
            }
        }
        let built = PrayerLiveActivityPlan.build(snapshot: snapshot, now: now, expiresAt: expiresAt)
        cachedPlanInput = input
        cachedPlan = built
        return built
    }

    private func reconcileMissingActivity() {
        guard let id = UserDefaults.standard.string(forKey: sessionKey) else { return }
        let current = Activity<PrayerLiveActivityAttributes>.activities.first { $0.attributes.sessionID == id }
        if let current, current.activityState == .active || current.activityState == .stale { return }
        // A missing system session has no reliable dismissal reason: installing
        // an app update can remove it too. Keep the saved choice, clear the old
        // server registration and restore on the next authorized foreground.
        // Explicit toggle-off and actually observed dismissals still turn it off.
        PrayerLiveActivityTransport.shared.submit(id: id, body: ["action": "end"])
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    private func observe(_ activity: Activity<PrayerLiveActivityAttributes>) {
        // A terminal object present at launch may belong to the replaced app.
        // Observe live sessions only, so initial terminal replay cannot erase ON.
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        guard watchers[activity.id] == nil else { return }
        let token = Task { [weak self] in
            for await _ in activity.pushTokenUpdates {
                guard let self, UserDefaults.standard.bool(forKey: self.enabledKey),
                      let snapshot = self.snapshot else { continue }
                let expiry = UserDefaults.standard.double(forKey: "munibin.prayer-live-activity.expiry.\(activity.attributes.sessionID)")
                if let plan = self.plan(for: snapshot, now: Date(), expiresAt: expiry) {
                    self.upload(activity, plan: plan)
                }
            }
        }
        let state = Task { [weak self] in
            for await value in activity.activityStateUpdates {
                guard let self else { return }
                if value == .dismissed || value == .ended {
                    let id = activity.attributes.sessionID
                    PrayerLiveActivityTransport.shared.submit(id: id, body: ["action": "end"])
                    let expiry = UserDefaults.standard.double(forKey: "munibin.prayer-live-activity.expiry.\(id)")
                    if value == .dismissed && Date().timeIntervalSince1970 < expiry &&
                        !self.explicitlyEnding.contains(activity.id) {
                        // Dismissal turns the feature off. Lifetime expiry keeps
                        // its opt-in for a new session on the next foreground.
                        UserDefaults.standard.set(false, forKey: self.enabledKey)
                    }
                    if UserDefaults.standard.string(forKey: self.sessionKey) == id {
                        UserDefaults.standard.removeObject(forKey: self.sessionKey)
                    }
                    self.watchers.removeValue(forKey: activity.id)?.forEach { $0.cancel() }
                    self.explicitlyEnding.remove(activity.id)
                    self.lastState = nil
                    self.reportStatus()
                    return
                }
            }
        }
        watchers[activity.id] = [token, state]
    }

    private func endAll() {
        lastState = nil
        lastSchedule = []
        if let id = UserDefaults.standard.string(forKey: sessionKey) {
            PrayerLiveActivityTransport.shared.submit(id: id, body: ["action": "end"])
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        for activity in Activity<PrayerLiveActivityAttributes>.activities {
            explicitlyEnding.insert(activity.id)
            PrayerLiveActivityTransport.shared.submit(id: activity.attributes.sessionID, body: ["action": "end"])
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func upload(_ activity: Activity<PrayerLiveActivityAttributes>, plan: PrayerLiveActivityPlan) {
        guard UserDefaults.standard.bool(forKey: enabledKey), let token = activity.pushToken,
              let stateData = try? JSONEncoder().encode(plan.contentState),
              let state = try? JSONSerialization.jsonObject(with: stateData),
              let updatesData = try? JSONEncoder().encode(plan.updates),
              let updates = try? JSONSerialization.jsonObject(with: updatesData) else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        PrayerLiveActivityTransport.shared.submit(id: activity.attributes.sessionID, body: [
            "action": "upsert", "pushToken": token.map { String(format: "%02x", $0) }.joined(),
            "contentState": state, "updates": updates, "expiresAt": plan.expiresAt, "environment": environment
        ])
    }

    private func reportStatus(message: String? = nil, force: Bool = false) {
        var detail: [String: Any] = [
            "enabled": UserDefaults.standard.bool(forKey: enabledKey), "supported": true,
            "authorized": ActivityAuthorizationInfo().areActivitiesEnabled,
            "active": Activity<PrayerLiveActivityAttributes>.activities.contains { $0.activityState == .active || $0.activityState == .stale }
        ]
        if let message { detail["message"] = message }
        guard let identity = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]) else { return }
        guard force || lastStatus != identity else { return }
        lastStatus = identity
        sendNativeApnsEvent(name: "munibin-prayer-live-activity-status", detail: detail)
    }
}

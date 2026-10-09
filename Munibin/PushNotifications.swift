import WebKit
import FirebaseMessaging
import UserNotifications
import UIKit

func sendNativeApnsEvent(name: String, detail: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(detail),
          let data = try? JSONSerialization.data(withJSONObject: detail),
          let json = String(data: data, encoding: .utf8) else { return }
    checkViewAndEvaluate(event: name, detail: json)
}

func handleNativeApnsRegistration() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        let register = { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        switch settings.authorizationStatus {
        case .notDetermined:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if granted { register() }
                else { sendNativeApnsEvent(name: "munibin-native-apns-error", detail: ["message": error?.localizedDescription ?? "رفض iPhone إذن الإشعارات."]) }
            }
        case .authorized, .ephemeral, .provisional:
            register()
        case .denied:
            sendNativeApnsEvent(name: "munibin-native-apns-error", detail: ["message": "فعّل إشعارات منيبين من إعدادات iPhone ثم أعد المحاولة."])
        @unknown default:
            sendNativeApnsEvent(name: "munibin-native-apns-error", detail: ["message": "تعذر تجهيز إشعارات iPhone الآن."])
        }
    }
}

private func nativeChatNotificationIdentifier(_ threadId: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitized = threadId.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    return "munibin-chat-" + String((sanitized.isEmpty ? "thread" : sanitized).prefix(120))
}

func handleNativeChatNotification(_ body: Any) {
    guard let payload = body as? [String: Any],
          let action = payload["action"] as? String else { return }

    let center = UNUserNotificationCenter.current()
    switch action {
    case "request-permission":
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            default:
                break
            }
        }

    case "set-badge":
        let count = max(0, (payload["count"] as? NSNumber)?.intValue ?? 0)
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = count
        }

    case "clear-thread":
        guard let threadId = payload["threadId"] as? String, !threadId.isEmpty else { return }
        let identifier = nativeChatNotificationIdentifier(threadId)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

    case "notify":
        guard let threadId = payload["threadId"] as? String, !threadId.isEmpty else { return }
        let rawMessage = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = rawMessage.isEmpty ? "رسالة جديدة" : String(rawMessage.prefix(500))
        let count = max(1, (payload["count"] as? NSNumber)?.intValue ?? 1)
        var route = payload["route"] as? String ?? "/feedback?thread=\(threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadId)"
        if !route.hasPrefix("/") || route.hasPrefix("//") { route = "/feedback" }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else { return }
            let content = UNMutableNotificationContent()
            content.title = "منيبين 💬"
            content.body = message
            content.sound = .default
            content.badge = NSNumber(value: count)
            content.categoryIdentifier = "munibin-support-message"
            content.userInfo = [
                "route": route,
                "threadId": threadId,
                "type": "support_chat"
            ]
            let request = UNNotificationRequest(
                identifier: nativeChatNotificationIdentifier(threadId),
                content: content,
                trigger: nil
            )
            center.add(request)
        }

    default:
        break
    }
}

func sendNativeApnsToken(_ deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    sendNativeApnsEvent(name: "munibin-native-apns-token", detail: ["token": token])
}

class SubscribeMessage {
    var topic  = ""
    var eventValue = ""
    var unsubscribe = false
    struct Keys {
        static var TOPIC = "topic"
        static var UNSUBSCRIBE = "unsubscribe"
        static var EVENTVALUE = "eventValue"
    }
    convenience init(dict: Dictionary<String,Any>) {
        self.init()
        if let topic = dict[Keys.TOPIC] as? String {
            self.topic = topic
        }
        if let unsubscribe = dict[Keys.UNSUBSCRIBE] as? Bool {
            self.unsubscribe = unsubscribe
        }
        if let eventValue = dict[Keys.EVENTVALUE] as? String {
            self.eventValue = eventValue
        }
    }
}

func handleSubscribeTouch(message: WKScriptMessage) {
  // [START subscribe_topic]
    let subscribeMessages = parseSubscribeMessage(message: message)
    if (subscribeMessages.count > 0){
        let _message = subscribeMessages[0]
        if (_message.unsubscribe) {
            Messaging.messaging().unsubscribe(fromTopic: _message.topic) { error in }
        }
        else {
            Messaging.messaging().subscribe(toTopic: _message.topic) { error in }
        }
    }
    

  // [END subscribe_topic]
}

func parseSubscribeMessage(message: WKScriptMessage) -> [SubscribeMessage] {
    var subscribeMessages = [SubscribeMessage]()
    if let objStr = message.body as? String {

        let data: Data = objStr.data(using: .utf8)!
        do {
            let jsObj = try JSONSerialization.jsonObject(with: data, options: .init(rawValue: 0))
            if let jsonObjDict = jsObj as? Dictionary<String, Any> {
                let subscribeMessage = SubscribeMessage(dict: jsonObjDict)
                subscribeMessages.append(subscribeMessage)
            } else if let jsonArr = jsObj as? [Dictionary<String, Any>] {
                for jsonObj in jsonArr {
                    let sMessage = SubscribeMessage(dict: jsonObj)
                    subscribeMessages.append(sMessage)
                }
            }
        } catch _ {
            
        }
    }
    return subscribeMessages
}

func returnPermissionResult(isGranted: Bool){
    DispatchQueue.main.async(execute: {
        if (isGranted){
            Munibin.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'granted' }))")
        }
        else {
            Munibin.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'denied' }))")
        }
    })
}
func returnPermissionState(state: String){
    DispatchQueue.main.async(execute: {
        Munibin.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-state', { detail: '\(state)' }))")
    })
}

func handlePushPermission() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
                UNUserNotificationCenter.current().requestAuthorization(
                    options: authOptions,
                    completionHandler: { (success, error) in
                        if error == nil {
                            if success == true {
                                returnPermissionResult(isGranted: true)
                                DispatchQueue.main.async {
                                  UIApplication.shared.registerForRemoteNotifications()
                                }
                            }
                            else {
                                returnPermissionResult(isGranted: false)
                            }
                        }
                        else {
                            returnPermissionResult(isGranted: false)
                        }
                    }
                )
            case .denied:
                returnPermissionResult(isGranted: false)
            case .authorized, .ephemeral, .provisional:
                returnPermissionResult(isGranted: true)
            @unknown default:
                return;
            }
        }
}
func handlePushState() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
        switch settings.authorizationStatus {
        case .notDetermined:
            returnPermissionState(state: "notDetermined")
        case .denied:
            returnPermissionState(state: "denied")
        case .authorized:
            returnPermissionState(state: "authorized")
        case .ephemeral:
            returnPermissionState(state: "ephemeral")
        case .provisional:
            returnPermissionState(state: "provisional")
        @unknown default:
            returnPermissionState(state: "unknown")
            return;
        }
    }
}

func checkViewAndEvaluate(event: String, detail: String) {
    if (!Munibin.webView.isHidden && !Munibin.webView.isLoading ) {
        DispatchQueue.main.async(execute: {
            Munibin.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('\(event)', { detail: \(detail) }))")
        })
    }
    else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkViewAndEvaluate(event: event, detail: detail)
        }
    }
}

func handleFCMToken(){
    DispatchQueue.main.async(execute: {
        Messaging.messaging().token { token, error in
            if let error = error {
                print("Error fetching FCM registration token: \(error)")
                checkViewAndEvaluate(event: "push-token", detail: "ERROR GET TOKEN")
            } else if let token = token {
                print("FCM registration token: \(token)")
                checkViewAndEvaluate(event: "push-token", detail: "'\(token)'")
            }
        }   
    })
}

func sendPushToWebView(userInfo: [AnyHashable: Any]){
    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    checkViewAndEvaluate(event: "push-notification", detail: json)
}

private func internalNotificationRoute(from userInfo: [AnyHashable: Any]) -> URL? {
    guard let route = userInfo["route"] as? String,
          route.hasPrefix("/"),
          !route.hasPrefix("//"),
          let url = URL(string: route, relativeTo: rootUrl)?.absoluteURL,
          url.scheme == rootUrl.scheme,
          url.host == rootUrl.host else {
        return nil
    }
    return url
}

func sendPushClickToWebView(userInfo: [AnyHashable: Any]){
    if let routeUrl = internalNotificationRoute(from: userInfo) {
        // Preserve the route across a cold launch. If the web view already exists,
        // navigate immediately; otherwise ViewController.loadRootUrl consumes it.
        SceneDelegate.notificationLinkToLaunch = routeUrl
        DispatchQueue.main.async {
            if let activeWebView = Munibin.webView, !activeWebView.isLoading,
               let localRoute = NativeAppServer.shared.localURL(for: routeUrl) {
                SceneDelegate.notificationLinkToLaunch = nil
                activeWebView.load(URLRequest(url: localRoute))
            }
        }
    }

    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    // Keep the legacy event for compatibility with older/future web clients.
    checkViewAndEvaluate(event: "push-notification-click", detail: json)
}

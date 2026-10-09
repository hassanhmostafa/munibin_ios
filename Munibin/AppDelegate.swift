import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import AVFoundation


@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window : UIWindow?

    func application(_ application: UIApplication,
                       didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

// TODO: if we're using Firebase, uncomment next string
        //FirebaseApp.configure()

        // [START set_messaging_delegate]
        Messaging.messaging().delegate = self
        // [END set_messaging_delegate]
        // Register for remote notifications. This shows a permission dialog on first run, to
        // show the dialog at a more appropriate time move this registration accordingly.
        // [START register_for_notifications]
   
        UNUserNotificationCenter.current().delegate = self

      //  let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      //  UNUserNotificationCenter.current().requestAuthorization(
      //      options: authOptions,
      //      completionHandler: {_, _ in })

// TODO: if we're using Firebase, uncomment next string
        // application.registerForRemoteNotifications()

        // Keep spoken Quran playback active when the screen locks. WKWebView
        // media is still controlled by the web player, but the native playback
        // category prevents iOS from treating screen sleep as the end of the
        // audio session.
        do {
          let audioSession = AVAudioSession.sharedInstance()
          try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay])
          try audioSession.setActive(true)
          NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
          )
        } catch {
          print("Unable to configure background Quran audio: \(error.localizedDescription)")
        }

        // [END register_for_notifications]
        return true
      }

      @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .ended else { return }

        let rawOptions = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        guard options.contains(.shouldResume) else { return }

        do {
          try AVAudioSession.sharedInstance().setActive(true)
        } catch {
          print("Unable to reactivate Quran audio after interruption: \(error.localizedDescription)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          Munibin.webView?.evaluateJavaScript(
            "window.dispatchEvent(new Event('munibin-native-resume'));",
            completionHandler: nil
          )
        }
      }

      // [START receive_message]
      func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
          print("Message ID 1: \(messageID)")
        }

        // Print full message.
        print("push userInfo 1:", userInfo)
        sendPushToWebView(userInfo: userInfo)
      }

      func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                       fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // If you are receiving a notification message while your app is in the background,
        // this callback will not be fired till the user taps on the notification launching the application.
        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
          print("Message ID 2: \(messageID)")
        }

        // Print full message. **
        print("push userInfo 2:", userInfo)
        sendPushToWebView(userInfo: userInfo)

        completionHandler(UIBackgroundFetchResult.newData)
      }

      // [END receive_message]
      func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Unable to register for remote notifications: \(error.localizedDescription)")
        sendNativeApnsEvent(name: "munibin-native-apns-error", detail: ["message": error.localizedDescription])
      }

      // This function is added here only for debugging purposes, and can be removed if swizzling is enabled.
      // If swizzling is disabled then this function must be implemented so that the APNs token can be paired to
      // the FCM registration token.
      func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if FirebaseApp.app() != nil {
          Messaging.messaging().apnsToken = deviceToken
        }
        sendNativeApnsToken(deviceToken)
      }
    }

    // [START ios_10_message_handling]
    extension AppDelegate : UNUserNotificationCenterDelegate {

      func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo

        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
          print("Message ID: 3 \(messageID)")
        }

        // Print full message.
        print("push userInfo 3:", userInfo)
        sendPushToWebView(userInfo: userInfo)

        // Change this to your preferred presentation option
        completionHandler([.banner, .list, .sound])
      }

      func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  didReceive response: UNNotificationResponse,
                                  withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // Print message ID.
        if let messageID = userInfo[gcmMessageIDKey] {
          print("Message ID 4: \(messageID)")
        }

        // With swizzling disabled you must let Messaging know about the message, for Analytics
        // Messaging.messaging().appDidReceiveMessage(userInfo)
        // Print full message.
        print("push userInfo 4:", userInfo)
        sendPushClickToWebView(userInfo: userInfo)

        completionHandler()
      }
    }
    // [END ios_10_message_handling]

    extension AppDelegate : MessagingDelegate {
      // [START refresh_token]
      func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token: \(String(describing: fcmToken))")
        
        let dataDict:[String: String] = ["token": fcmToken ?? ""]
        NotificationCenter.default.post(name: Notification.Name("FCMToken"), object: nil, userInfo: dataDict)
        handleFCMToken()
        // TODO: If necessary send token to application server.
        // Note: This callback is fired at each app startup and whenever a new token is generated.
      }
      // [END refresh_token]
    }

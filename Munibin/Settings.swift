import WebKit

struct Cookie {
    var name: String
    var value: String
}

let gcmMessageIDKey = "00000000000" // update this with actual ID if using Firebase 

// URL for first launch
let rootUrl = URL(string: "https://munibin.com")!

// allowed origin is for what we are sticking to pwa domain
// This should also appear in Info.plist
let allowedOrigins: [String] = ["munibin.com"]

// auth origins will open in modal and show toolbar for back into the main origin.
// These should also appear in Info.plist
let authOrigins: [String] = []
// allowedOrigins + authOrigins <= 10

let platformCookie = Cookie(name: "app-platform", value: "iOS App Store")

// UI options
let displayMode = "standalone" // standalone / fullscreen.
// ⚠️ تم تغييره إلى false لأن true يتعارض مع iOS Theme Bridge
// adaptiveUIStyle=true كان يُعيد ضبط overrideUserInterfaceStyle للـ window
// بناءً على لون خلفية WebView، مما يُلغي تأثير prefers-color-scheme
let adaptiveUIStyle = false
let overrideStatusBar = false   // iOS 13-14 only. if you don't support dark/light system theme.
let statusBarTheme = "dark"    // dark / light, related to override option.
let pullToRefresh = false   // Native pull-to-refresh disabled: Quran swipe-down must not show the iOS refresh spinner.

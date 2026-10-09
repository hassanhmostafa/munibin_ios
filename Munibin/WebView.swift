import UIKit
import WebKit
import AuthenticationServices
import SafariServices


func createWebView(container: UIView, WKSMH: WKScriptMessageHandler, WKND: WKNavigationDelegate, NSO: NSObject, VC: ViewController) -> WKWebView{

    let config = WKWebViewConfiguration()
    let userContentController = WKUserContentController()

    userContentController.add(WKSMH, name: "print")
    userContentController.add(WKSMH, name: "push-subscribe")
    userContentController.add(WKSMH, name: "push-permission-request")
    userContentController.add(WKSMH, name: "push-permission-state")
    userContentController.add(WKSMH, name: "push-token")
    userContentController.add(WKSMH, name: "munibin-apns")
    userContentController.add(WKSMH, name: "munibin-chat")
    userContentController.add(WKSMH, name: "munibin-widget")
    userContentController.add(WKSMH, name: "prayer-time-format")
    userContentController.add(WKSMH, name: "prayer-theme")
    userContentController.add(WKSMH, name: "munibin-prayer-live-activity")
    userContentController.add(WKSMH, name: "munibin-prayer-permission")
    userContentController.add(WKSMH, name: "munibin-now-playing")
    userContentController.add(WKSMH, name: "munibin-speech")
    userContentController.add(WKSMH, name: "munibin-compass")
    userContentController.add(WKSMH, name: "munibin-persistence")
    userContentController.add(WKSMH, name: "munibin-social-auth")
    userContentController.add(WKSMH, name: "munibin-password")
    userContentController.add(WKSMH, name: "munibin-password-autofill")

    // Stable native-shell marker for the React app. WKWebView does not reliably
    // expose PWA display-mode signals, so the web layer uses this to hide store
    // download prompts and classify the App Store build as an installed app.
    let nativeShellScript = WKUserScript(
        source: "window.__munibinNativeApp = true; window.__munibinNativePlatform = 'ios';",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    userContentController.addUserScript(nativeShellScript)

    let liveSupported: Bool
    if #available(iOS 16.2, *) { liveSupported = true } else { liveSupported = false }
    let liveEnabled = UserDefaults.standard.bool(forKey: "munibin.prayer-live-activity.enabled.v1")
    userContentController.addUserScript(WKUserScript(
        source: "window.__munibinPrayerLiveActivitySupported = \(liveSupported); window.__munibinPrayerLiveActivityEnabled = \(liveEnabled);",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    ))

    // Restore update-resistant prayer/notification/Quran planning preferences before React boots.
    if let raw = UserDefaults.standard.string(forKey: "munibin.persistent.web-state.v1"),
       let data = raw.data(using: .utf8) {
        let encoded = data.base64EncodedString()
        let persistentStateScript = WKUserScript(
            source: """
            try {
              const bytes = Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0));
              window.__munibinNativePersistentState = JSON.parse(new TextDecoder().decode(bytes));
            } catch (_) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(persistentStateScript)
    }

    // Keep a saved native clock choice when a shell cache reset removes an older
    // page's storage. A current web preference always wins over this fallback.
    if let format = UserDefaults(suiteName: "group.com.motoonai.munibin")?
        .string(forKey: "munibin.prayer-time-format.v1"),
       format == "12h" || format == "24h" {
        let timeFormatScript = WKUserScript(
            source: """
            window.__munibinPrayerTimeFormat = '\(format)';
            try {
              var key = 'munibin:prayer-time-format:v1';
              var saved = window.localStorage.getItem(key);
              if (saved !== '12h' && saved !== '24h') window.localStorage.setItem(key, '\(format)');
            } catch (_) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(timeFormatScript)
    }

    // نسخة احتياطية: إذا فُتحت الويدجت بعد جلسة سابقة، أعد تمرير آخر لقطة
    // محفوظة في localStorage إلى التطبيق بمجرد عودة الصفحة من الخلفية.
    let replayWidgetSnapshotScript = WKUserScript(
        source: """
        window.addEventListener('pageshow', function() {
          try {
            var raw = window.localStorage.getItem('munibin-prayer-widget-snapshot-v1');
            var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers['munibin-widget'];
            if (raw && bridge) bridge.postMessage(JSON.parse(raw));
          } catch (_) {}
        });
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
    userContentController.addUserScript(replayWidgetSnapshotScript)

    // iOS background/foreground Quran-audio recovery. Quran audio can keep
    // playing correctly while the app is backgrounded, then receive a transient
    // WebKit pause exactly as the scene becomes active again. Preserve the
    // playback intent across that foreground transition and resume only when the
    // pause was system-generated. Explicit in-app pauses still remain paused.
    let quranAudioForegroundRecoveryScript = WKUserScript(
        source: """
        (function () {
          if (window.__munibinIOSAudioRecoveryInstalled) return;
          window.__munibinIOSAudioRecoveryInstalled = true;

          var activeAudio = null;
          var wantsPlayback = false;
          var wasHidden = document.visibilityState === 'hidden';
          var hiddenAt = wasHidden ? Date.now() : 0;
          var foregroundGraceUntil = 0;
          var recoveryGeneration = 0;

          // Distinguish a real app/user pause() call from the transient pause event
          // WebKit can emit while an iPhone scene is returning to the foreground.
          // The latter does not call the JavaScript pause() method first.
          try {
            var originalPause = HTMLMediaElement.prototype.pause;
            if (!HTMLMediaElement.prototype.__munibinPauseWrapped) {
              Object.defineProperty(HTMLMediaElement.prototype, '__munibinPauseWrapped', {
                value: true, configurable: false
              });
              HTMLMediaElement.prototype.pause = function () {
                try { this.__munibinExplicitPauseAt = Date.now(); } catch (_) {}
                return originalPause.apply(this, arguments);
              };
            }
          } catch (_) {}

          function isExplicitPause(audio, now) {
            var at = Number(audio && audio.__munibinExplicitPauseAt) || 0;
            return at > 0 && now - at < 500;
          }

          document.addEventListener('play', function (event) {
            if (!(event.target instanceof HTMLAudioElement)) return;
            activeAudio = event.target;
            wantsPlayback = true;
          }, true);

          document.addEventListener('pause', function (event) {
            if (!(event.target instanceof HTMLAudioElement) || event.target !== activeAudio) return;
            var now = Date.now();

            // A pause explicitly requested by the app/user must always win, even
            // if it happens immediately after foregrounding.
            if (isExplicitPause(event.target, now)) {
              wantsPlayback = false;
              return;
            }

            if (document.visibilityState === 'hidden') {
              // A later system/remote pause while already in the background is a
              // genuine pause (for example lock-screen controls). A pause close to
              // the lifecycle edge is treated as WebKit transition noise.
              if (hiddenAt && now - hiddenAt > 1200) wantsPlayback = false;
              return;
            }

            // On iOS the foreground transition itself can emit a pause after the
            // document is already visible. Keep the previous playback intent and
            // let the recovery loop restart it.
            if (wasHidden || now <= foregroundGraceUntil) {
              scheduleRecovery();
              return;
            }
            wantsPlayback = false;
          }, true);

          document.addEventListener('ended', function (event) {
            if (!(event.target instanceof HTMLAudioElement) || event.target !== activeAudio) return;
            wantsPlayback = false;
            wasHidden = false;
          }, true);

          function markHidden() {
            wasHidden = true;
            hiddenAt = Date.now();
            recoveryGeneration += 1;
          }

          function markForeground() {
            // Keep wasHidden=true until the foreground transition has actually
            // settled. The audio may still be playing for a short moment and then
            // be paused by WebKit; clearing wasHidden too early was the cause of
            // the previous recovery attempt missing the real pause.
            foregroundGraceUntil = Date.now() + 5200;
          }

          function finishRecoveryWhenStable(audio, generation) {
            window.setTimeout(function () {
              if (generation !== recoveryGeneration) return;
              if (document.visibilityState !== 'visible') return;
              if (!audio || audio.paused || audio.ended) return;
              wasHidden = false;
            }, 900);
          }

          function recoverPlayback() {
            if (!wasHidden || !wantsPlayback || !activeAudio) return;
            if (document.visibilityState !== 'visible') return;

            var audio = activeAudio;
            var generation = recoveryGeneration;
            if (audio.ended || !audio.src) {
              wantsPlayback = false;
              wasHidden = false;
              return;
            }
            if (Number.isFinite(audio.duration) && audio.duration > 0 &&
                audio.currentTime >= audio.duration - 0.12) return;

            if (!audio.paused) {
              // Do NOT clear wasHidden here. iOS can pause the element slightly
              // later in the same foreground transition.
              finishRecoveryWhenStable(audio, generation);
              return;
            }

            var promise;
            try { promise = audio.play(); } catch (_) { promise = null; }

            // Fallback through the app's audio bridge as well. It points to the
            // currently active Quran HTMLAudioElement and keeps React state in sync.
            try {
              var bridge = window.__munibinAudioPlayerBridge;
              if (bridge && typeof bridge.resume === 'function') bridge.resume();
            } catch (_) {}

            if (promise && typeof promise.then === 'function') {
              promise.then(function () {
                finishRecoveryWhenStable(audio, generation);
              }).catch(function () {});
            }
          }

          function scheduleRecovery() {
            if (!wasHidden || !wantsPlayback) return;
            markForeground();
            [40, 140, 320, 650, 1100, 1800, 2800, 4200].forEach(function (delay) {
              window.setTimeout(recoverPlayback, delay);
            });
          }

          document.addEventListener('visibilitychange', function () {
            if (document.visibilityState === 'hidden') {
              markHidden();
            } else {
              scheduleRecovery();
            }
          }, true);

          // Native sends this only after sceneDidBecomeActive. Do not fire a
          // recovery from sceneWillEnterForeground while the audio is still
          // playing, because doing so can finish the cycle before WebKit emits the
          // actual foreground pause.
          window.addEventListener('munibin-native-resume', scheduleRecovery, true);
          window.addEventListener('pageshow', function () {
            if (wasHidden) scheduleRecovery();
          }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    userContentController.addUserScript(quranAudioForegroundRecoveryScript)

    // Native v137 guard: remove the obsolete setup-menu playback-speed row even if
    // WebKit briefly serves an older cached app shell during an update.
    let hideQuranSetupSpeedScript = WKUserScript(
        source: """
        (function() {
          if (window.__munibinHideSetupSpeedInstalled) return;
          window.__munibinHideSetupSpeedInstalled = true;
          function hideSetupSpeed() {
            document.querySelectorAll('.qcf1441-reciter-settings--speed').forEach(function(el) { el.style.display = 'none'; el.setAttribute('aria-hidden', 'true'); });
          }
          hideSetupSpeed();
          new MutationObserver(hideSetupSpeed).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
    userContentController.addUserScript(hideQuranSetupSpeedScript)
    // ─── iOS Theme Bridge ────────────────────────────────────────────────────────────────────
    // يحقن window.__iosTheme قبل تحميل أي JavaScript في الصفحة
    // هذا يضمن أن ThemeContext في React يقرأ الثيم الصحيح من أول لحظة
    let currentStyle = UITraitCollection.current.userInterfaceStyle
    let themeName = currentStyle == .dark ? "dark" : "light"
    let themeScript = WKUserScript(
        source: "window.__iosTheme = '\(themeName)';",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    userContentController.addUserScript(themeScript)
    // ────────────────────────────────────────────────────────────────────────────

    config.userContentController = userContentController

    // Service Workers and native message handlers in WKWebView rely on App-Bound
    // mode. WebKit treats localhost/loopback as app-bound local content, while
    // our navigation delegate moves unrelated external links to Safari.
    config.limitsNavigationsToAppBoundDomains = true;
    config.allowsInlineMediaPlayback = true
    // Listening begins after an async range lookup/cache check; keep the user-started
    // playback eligible after that await chain finishes.
    config.mediaTypesRequiringUserActionForPlayback = []
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.preferences.setValue(true, forKey: "standalone")
    // ─── Service Worker / Offline Cache ──────────────────────────────────────────────────────
    // استخدام persistent data store لحفظ Service Worker cache بين الجلسات
    // هذا ضروري لكي يعمل التطبيق offline بعد أول فتح مع الإنترنت
    config.websiteDataStore = WKWebsiteDataStore.default()
    // ────────────────────────────────────────────────────────────────────────────
    let webView = WKWebView(frame: calcWebviewFrame(webviewView: container, toolbarView: nil), configuration: config)
    setCustomCookie(webView: webView)

    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isHidden = true;
    webView.navigationDelegate = WKND
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.allowsBackForwardNavigationGestures = true
    
    // Check if macCatalyst 16.4+ is available and if so, enable web inspector.
    // This allows the web app to be inspected using Safari Web Inspector. Supported on iOS 16.4+ and macOS 13.3+
    if #available(iOS 16.4, macOS 13.3, *) {
        webView.isInspectable = true
    }
    
    let deviceModel = UIDevice.current.model
    let osVersion = UIDevice.current.systemVersion
    webView.configuration.applicationNameForUserAgent = "Safari/604.1"
    webView.customUserAgent = "Mozilla/5.0 (\(deviceModel); CPU \(deviceModel) OS \(osVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1 PWAShell"

    webView.addObserver(NSO, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: NSKeyValueObservingOptions.new, context: nil)
    
    #if DEBUG
    if #available(iOS 16.4, *) {
        webView.isInspectable = true
    }
    #endif
    
    return webView
}

func setAppStoreAsReferrer(contentController: WKUserContentController) {
    let scriptSource = "document.referrer = `app-info://platform/ios-store`;"
    let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    contentController.addUserScript(script);
}

func setCustomCookie(webView: WKWebView) {
    let _platformCookie = HTTPCookie(properties: [
        .domain: rootUrl.host!,
        .path: "/",
        .name: platformCookie.name,
        .value: platformCookie.value,
        .secure: "FALSE",
        .expires: NSDate(timeIntervalSinceNow: 31556926)
    ])!

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(_platformCookie)

}

func calcWebviewFrame(webviewView: UIView, toolbarView: UIToolbar?) -> CGRect{
    if ((toolbarView) != nil) {
        return CGRect(x: 0, y: toolbarView!.frame.height, width: webviewView.frame.width, height: webviewView.frame.height - toolbarView!.frame.height)
    }
    else {
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 0

        switch displayMode {
        case "fullscreen":
            #if targetEnvironment(macCatalyst)
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
            #endif
            return CGRect(x: 0, y: 0, width: webviewView.frame.width, height: webviewView.frame.height)
        default:
            #if targetEnvironment(macCatalyst)
            statusBarHeight = 29
            #endif
            let windowHeight = webviewView.frame.height - statusBarHeight
            return CGRect(x: 0, y: statusBarHeight, width: webviewView.frame.width, height: windowHeight)
        }
    }
}

private func hostMatchesAllowedOrigin(_ host: String, origins: [String]) -> Bool {
    let normalizedHost = host.lowercased()
    return origins.contains { origin in
        let normalizedOrigin = origin.lowercased()
        return normalizedHost == normalizedOrigin || normalizedHost.hasSuffix("." + normalizedOrigin)
    }
}

extension ViewController: WKUIDelegate, WKDownloadDelegate {
    // redirect new tabs to main webview
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if (navigationAction.targetFrame == nil) {
            webView.load(navigationAction.request)
        }
        return nil
    }
    // restrict navigation to target host, open external links in 3rd party apps
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if (navigationAction.request.url?.scheme == "about") {
            return decisionHandler(.allow)
        }
        if (navigationAction.shouldPerformDownload || navigationAction.request.url?.scheme == "blob") {
            return decisionHandler(.download)
        }

        if let requestUrl = navigationAction.request.url{
            if let requestHost = requestUrl.host {
                // The packaged app itself lives on loopback. Keep all local SPA routes
                // inside the primary WebView without showing an external-link toolbar.
                if requestHost == "127.0.0.1" || requestHost == "localhost" {
                    decisionHandler(.allow)
                    if (!toolbarView.isHidden) {
                        toolbarView.isHidden = true
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
                    }
                    return
                }

                // NOTE: Match auth origin first, because host origin may be a subset of auth origin and may therefore always match
                let matchingAuthOrigin = hostMatchesAllowedOrigin(requestHost, origins: authOrigins)
                if matchingAuthOrigin {
                    decisionHandler(.allow)
                    if (toolbarView.isHidden) {
                        toolbarView.isHidden = false
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: toolbarView)
                    }
                    return
                }

                let matchingHostOrigin = hostMatchesAllowedOrigin(requestHost, origins: allowedOrigins)
                if matchingHostOrigin {
                    // Public Munibin links/deep links are rewritten to the packaged local UI.
                    // This prevents an in-app link from accidentally returning to the website.
                    if let localUrl = NativeAppServer.shared.localURL(for: requestUrl), localUrl.host != requestHost {
                        decisionHandler(.cancel)
                        webView.load(URLRequest(url: localUrl))
                    } else {
                        decisionHandler(.allow)
                    }
                    if (!toolbarView.isHidden) {
                        toolbarView.isHidden = true
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
                    }
                    return
                }
                let syntheticClickType = navigationAction.value(forKey: "syntheticClickType") as? Int ?? -1
                if (navigationAction.navigationType == .other &&
                    syntheticClickType == 0 &&
                    (navigationAction.targetFrame != nil) &&
                    // no error here, fake warning
                    (navigationAction.sourceFrame != nil)
                ) {
                    decisionHandler(.allow)
                    return
                }
                else {
                    decisionHandler(.cancel)
                }


                if ["http", "https"].contains(requestUrl.scheme?.lowercased() ?? "") {
                    // Can open with SFSafariViewController
                    let safariViewController = SFSafariViewController(url: requestUrl)
                    self.present(safariViewController, animated: true, completion: nil)
                } else {
                    // Scheme is not supported or no scheme is given, use openURL
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
            } else {
                decisionHandler(.cancel)
                if (navigationAction.request.url?.scheme == "tel" || navigationAction.request.url?.scheme == "mailto" ){
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
                else {
                    if requestUrl.isFileURL {
                        // not tested
                        downloadAndOpenFile(url: requestUrl.absoluteURL)
                    }
                    // if (requestUrl.absoluteString.contains("base64")){
                    //     downloadAndOpenBase64File(base64String: requestUrl.absoluteString)
                    // }
                }
            }
        }
        else {
            decisionHandler(.cancel)
        }

    }
    // Handle javascript: `window.alert(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler()
            }
        )
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.confirm(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(false)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler(true)
            }
        )
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.prompt(prompt: String, defaultText: String?)`
    func webView(_ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: prompt,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(nil)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler with Alert input
                if let input = alert.textFields?.first?.text {
                    completionHandler(input)
                }
            }
        )

        alert.addTextField { textField in
            textField.placeholder = defaultText
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }

    func downloadAndOpenFile(url: URL){

        let destinationFileUrl = url
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)
        let request = URLRequest(url:url)
        let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, error == nil {
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    print("Successfully download. Status code: \(statusCode)")
                }
                do {
                    try FileManager.default.copyItem(at: tempLocalUrl, to: destinationFileUrl)
                    self.openFile(url: destinationFileUrl)
                } catch (let writeError) {
                    print("Error creating a file \(destinationFileUrl) : \(writeError)")
                }
            } else {
                print("Error took place while downloading a file. Error description: \(error?.localizedDescription ?? "N/A") ")
            }
        }
        task.resume()
    }

    // func downloadAndOpenBase64File(base64String: String) {
    //     // Split the base64 string to extract the data and the file extension
    //     let components = base64String.components(separatedBy: ";base64,")

    //     // Make sure the base64 string has the correct format
    //     guard components.count == 2, let format = components.first?.split(separator: "/").last else {
    //         print("Invalid base64 string format")
    //         return
    //     }

    //     // Remove the data type prefix to get the base64 data
    //     let dataString = components.last!

    //     if let imageData = Data(base64Encoded: dataString) {
    //         let documentsUrl: URL  =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    //         let destinationFileUrl = documentsUrl.appendingPathComponent("image.\(format)")

    //         do {
    //             try imageData.write(to: destinationFileUrl)
    //             self.openFile(url: destinationFileUrl)
    //         } catch {
    //             print("Error writing image to file url: \(destinationFileUrl): \(error)")
    //         }
    //     }
    // }

    func openFile(url: URL) {
        self.documentController = UIDocumentInteractionController(url: url)
        self.documentController?.delegate = self
        self.documentController?.presentPreview(animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void) {

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(suggestedFilename)

        // Remove existing file if it exists, otherwise it may show an old file/content just by having the same name.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        self.openFile(url: fileURL)
        completionHandler(fileURL)
    }
}

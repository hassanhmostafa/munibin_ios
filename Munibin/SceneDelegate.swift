import UIKit
import AVFoundation

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var nativeServerNeedsForegroundRefresh = false

    // If our app is launched with a universal link, we'll store it in this variable
    static var universalLinkToLaunch: URL? = nil; 
    static var shortcutLinkToLaunch: URL? = nil
    static var notificationLinkToLaunch: URL? = nil

    /// Navigate an already-running WKWebView without replacing its document.
    /// Replacing the document destroys WebKit audio, which made Quran/Mutoon playback
    /// stop whenever the prayer widget (a universal link) was opened.
    private func navigateWarmAppLinkWithoutReload(_ publicURL: URL) -> Bool {
        guard let webView = Munibin.webView, webView.url != nil,
              let host = publicURL.host?.lowercased(),
              host == "munibin.com" || host.hasSuffix(".munibin.com") else {
            return false
        }

        var route = publicURL.path.isEmpty ? "/" : publicURL.path
        if let query = publicURL.query, !query.isEmpty { route += "?" + query }
        if let fragment = publicURL.fragment, !fragment.isEmpty { route += "#" + fragment }
        guard let literalData = try? JSONEncoder().encode(route),
              let routeLiteral = String(data: literalData, encoding: .utf8) else {
            return false
        }

        let js = """
        (function(){try{
          var p=\(routeLiteral);
          var c=location.pathname+location.search+location.hash;
          if(c!==p){history.pushState({},'',p);window.dispatchEvent(new PopStateEvent('popstate',{state:history.state}));}
          return true;
        }catch(e){return false;}})();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        return true
    }


    // This function is called when your app launches.
    // Check to see if we were launched via a universal link or a shortcut.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // See if our app is being launched via universal link.
        // If so, store that link so we can navigate to it once our webView is initialized.
        for userActivity in connectionOptions.userActivities {
            if let universalLink = userActivity.webpageURL {
                SceneDelegate.universalLinkToLaunch = universalLink;
                break
            }
        }

        // See if we were launched via shortcut
        if let shortcutUrl = connectionOptions.shortcutItem?.type {            
            SceneDelegate.shortcutLinkToLaunch = URL.init(string: shortcutUrl)
        }
        
        // See if we were launched via scheme URL
        if let schemeUrl = connectionOptions.urlContexts.first?.url {
            // Convert scheme://url to a https://url
            var comps = URLComponents(url: schemeUrl, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            
            if let url = comps?.url {
                SceneDelegate.universalLinkToLaunch = url;
            }
        }
    }
    
    // This function is called when our app is already running and the user clicks a custom scheme URL
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let scheme = URLContexts.first?.url {
            // Convert scheme://url to a https://url and navigate to it
            var comps = URLComponents(url: scheme, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"

            if let url = comps?.url {
                if navigateWarmAppLinkWithoutReload(url) { return }
                if let localUrl = NativeAppServer.shared.localURL(for: url) {
                    Munibin.webView.load(URLRequest(url: localUrl))
                }
            }
        }
    }

    // This function is called when our app is already running and the user clicks a universal link.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // Handle universal links into our app when the app is already running.
        // This allows your PWA to open links to your domain, rather than opening in a browser tab.
        // For more info about universal links, see https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app
        
        // Ensure we're trying to launch a link.
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let universalLink = userActivity.webpageURL else {
            return
        }

        if navigateWarmAppLinkWithoutReload(universalLink) { return }
        if let localUrl = NativeAppServer.shared.localURL(for: universalLink) {
            Munibin.webView.load(URLRequest(url: localUrl))
        }
    }

    // This function is called if our app is already loaded and the user activates the app via shortcut
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        if let shortcutUrl = URL.init(string: shortcutItem.type) {
            if navigateWarmAppLinkWithoutReload(shortcutUrl) {
                completionHandler(true)
                return
            }
            if let localUrl = NativeAppServer.shared.localURL(for: shortcutUrl) {
                Munibin.webView.load(URLRequest(url: localUrl))
                completionHandler(true)
                return
            }
        }
        completionHandler(false)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // The WKWebView audio is already using the app's playback session. Do not
        // call setActive(true) here: on some iPhones re-activating the native
        // session while WebKit is finishing its own foreground transition causes
        // the currently playing HTMLAudioElement to receive a pause event.
        // Genuine AVAudioSession interruptions are handled in AppDelegate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Munibin.webView?.evaluateJavaScript(
                "window.dispatchEvent(new Event('munibin-native-resume'));",
                completionHandler: nil
            )
        }
        // A second signal covers devices where WebKit's pause lands a little later
        // than scene activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            Munibin.webView?.evaluateJavaScript(
                "window.dispatchEvent(new Event('munibin-native-resume'));",
                completionHandler: nil
            )
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Keep the audio-resume signalling in sceneDidBecomeActive, but refresh
        // the app's loopback HTTP listener here. On some iPhones the listener can
        // be left stale after a long sleep while WKWebView remains alive, which
        // makes the next tRPC/audio-download request fail with "Load failed".
        guard nativeServerNeedsForegroundRefresh else { return }
        nativeServerNeedsForegroundRefresh = false

        Munibin.webView?.evaluateJavaScript(
            "window.__munibinNativeServerRefreshing=true;",
            completionHandler: nil
        )
        NativeAppServer.shared.restartForForeground { result in
            switch result {
            case .success:
                Munibin.webView?.evaluateJavaScript(
                    "window.__munibinNativeServerRefreshing=false;window.dispatchEvent(new Event('munibin-native-server-ready'));",
                    completionHandler: nil
                )
            case .failure(let error):
                print("Unable to refresh native app server after foreground: \(error.localizedDescription)")
                Munibin.webView?.evaluateJavaScript(
                    "window.__munibinNativeServerRefreshing=false;window.dispatchEvent(new Event('munibin-native-server-ready'));",
                    completionHandler: nil
                )
            }
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        nativeServerNeedsForegroundRefresh = true
    }


}


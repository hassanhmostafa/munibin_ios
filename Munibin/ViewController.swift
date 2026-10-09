import UIKit
import WebKit
import WidgetKit
import UserNotifications
import MediaPlayer
import AVFoundation
import Speech
import CoreLocation
import AuthenticationServices
import Security

var webView: WKWebView! = nil

class ViewController: UIViewController, WKNavigationDelegate, UIDocumentInteractionControllerDelegate {
    enum LoadingMode {
        case defaultCachePolicy
        case forceCache
    }

    var documentController: UIDocumentInteractionController?
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    @IBOutlet weak var loadingView: UIView!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var connectionProblemView: UIImageView!
    @IBOutlet weak var webviewView: UIView!
    var toolbarView: UIToolbar!
    
    var htmlIsLoaded = false;
    private var loadingMode = LoadingMode.defaultCachePolicy

    // Native launch animation. This sits above the hidden WKWebView, so the
    // opening motion is identical online and offline and never waits on React.
    private weak var launchBackgroundView: UIView?
    private var launchGlowView: UIView?
    private var launchLogoView: UIImageView?
    private var launchTitleLabel: UILabel?
    private var launchAccentView: UIView?
    private var launchStartedAt: CFTimeInterval = 0
    private let launchMinimumDuration: CFTimeInterval = 1.05
    private var launchExitScheduled = false
    private var initialLaunchCompleted = false
    private var keyboardOverlap: CGFloat = 0
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA"))
    private var speechAudioEngine = AVAudioEngine()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRequestId = ""
    private var speechShouldContinue = false
    private var speechTapInstalled = false
    // A request identifies the user's mic session. An utterance identifies one
    // cumulative transcript within that session, including automatic restarts.
    private var speechSessionGeneration = 0
    private var speechTaskGeneration = 0
    private var speechUtteranceId = 0
    private var speechConsecutiveErrors = 0
    private var speechRestartWorkItem: DispatchWorkItem?
    private var speechFinishWorkItem: DispatchWorkItem?
    private var speechAudioSessionOwned = false
    private var speechPreviousAudioCategory: AVAudioSession.Category?
    private var speechPreviousAudioMode: AVAudioSession.Mode?
    private var speechPreviousAudioOptions: AVAudioSession.CategoryOptions = []
    // The Quran model consumes microphone PCM, independently of Apple's
    // ordinary dictation recognizer. A generation also guards permission and
    // audio-tap callbacks after a canceled or replaced recording session.
    private var quranAudioEngine = AVAudioEngine()
    private var quranAudioStream: QuranPCM16Stream?
    private var quranAudioRequestId = ""
    private var quranAudioShouldContinue = false
    private var quranAudioGeneration = 0
    private var quranAudioTapInstalled = false
    private var quranAudioSessionOwned = false
    private var quranPreviousAudioCategory: AVAudioSession.Category?
    private var quranPreviousAudioMode: AVAudioSession.Mode?
    private var quranPreviousAudioOptions: AVAudioSession.CategoryOptions = []
    private var socialAuthSession: ASWebAuthenticationSession?
    private var passwordAuthorizationController: ASAuthorizationController?
    private lazy var qiblaLocationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.headingFilter = 1.0
        return manager
    }()
    
    private var themeObservation: NSKeyValueObservation?
    var currentWebViewTheme: UIUserInterfaceStyle = .unspecified
    override var preferredStatusBarStyle : UIStatusBarStyle {
        if #available(iOS 13, *), overrideStatusBar{
            if #available(iOS 15, *) {
                return .default
            } else {
                return statusBarTheme == "dark" ? .lightContent : .darkContent
            }
        }
        return .default
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        initWebView()
        initToolbarView()
        setupLaunchAnimation()

        // This build modifies packaged JavaScript bundles. Previous native
        // releases marked JS/CSS immutable for one year, so WKWebView may otherwise
        // reuse an older main bundle from disk. Remove only WebKit's HTTP resource
        // caches once; localStorage, IndexedDB, cookies, service-worker Cache Storage
        // and downloaded audio remain intact.
        let frontendCacheResetVersion = "v423-prayer-format-iqama-1"
        let frontendCacheResetKey = "munibinFrontendHttpCacheResetVersion"
        if UserDefaults.standard.string(forKey: frontendCacheResetKey) != frontendCacheResetVersion {
            URLCache.shared.removeAllCachedResponses()
            let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
            WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { [weak self] in
                UserDefaults.standard.set(frontendCacheResetVersion, forKey: frontendCacheResetKey)
                DispatchQueue.main.async { self?.loadRootUrl() }
            }
        } else {
            loadRootUrl()
        }
    
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        speechRecognizer?.delegate = self
        speechRecognizer?.queue = OperationQueue.main
        NotificationCenter.default.addObserver(self, selector: #selector(speechApplicationDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(speechAudioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(speechAudioRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(speechMediaServicesReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWebViewForKeyboard()
    }

    private func layoutWebViewForKeyboard() {
        guard Munibin.webView != nil else { return }
        var frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
        if keyboardOverlap > 0 {
            frame.size.height = max(1, frame.size.height - keyboardOverlap)
        }
        Munibin.webView.frame = frame
    }

    private func keepFocusedInputAboveKeyboard() {
        guard Munibin.webView != nil else { return }
        let js = """
            (() => {
              const active = document.activeElement;
              if (!active || !['INPUT', 'TEXTAREA'].includes(active.tagName)) return;
              requestAnimationFrame(() => active.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' }));
            })();
        """
        Munibin.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func keyboardWillChangeFrame(_ notification: NSNotification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let keyboardFrame = webviewView.convert(value.cgRectValue, from: nil)
        keyboardOverlap = max(0, webviewView.bounds.maxY - keyboardFrame.minY)

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        var options = UIView.AnimationOptions(rawValue: curve << 16)
        options.insert(.beginFromCurrentState)
        options.insert(.allowUserInteraction)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.layoutWebViewForKeyboard()
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.keepFocusedInputAboveKeyboard()
        }
    }
    
    @objc func keyboardWillHide(_ notification: NSNotification) {
        keyboardOverlap = 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutWebViewForKeyboard()
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - iOS Theme Bridge
    // يُرسل ثيم الجهاز الحقيقي للـ WebView عبر JavaScript
    // يُستدعى بعد اكتمال تحميل الصفحة وعند تغيير ثيم الجهاز
    func sendThemeToWebView() {
        guard htmlIsLoaded else { return }
        let style = UITraitCollection.current.userInterfaceStyle
        let themeName = style == .dark ? "dark" : "light"
        let js = """
            window.__iosTheme = '\(themeName)';
            window.dispatchEvent(new CustomEvent('ios-theme-change', { detail: '\(themeName)' }));
        """
        DispatchQueue.main.async {
            Munibin.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // يُراقب تغيير ثيم الجهاز في الوقت الفعلي
    // مثلاً: المستخدم يغير من light إلى dark في إعدادات الجهاز أثناء فتح التطبيق
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            sendThemeToWebView()
        }
    }

    func initWebView() {
        Munibin.webView = createWebView(container: webviewView, WKSMH: self, WKND: self, NSO: self, VC: self)
        webviewView.addSubview(Munibin.webView);
        
        Munibin.webView.uiDelegate = self;
        
        Munibin.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        if(pullToRefresh){
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(refreshWebView(_:)), for: UIControl.Event.valueChanged)
            Munibin.webView.scrollView.addSubview(refreshControl)
            Munibin.webView.scrollView.bounces = true
        }

        if #available(iOS 15.0, *), adaptiveUIStyle {
            themeObservation = Munibin.webView.observe(\.themeColor) { [unowned self] webView, _ in
                let backgroundColor = Munibin.webView.underPageBackgroundColor;
                let themeColor = Munibin.webView.themeColor;
                currentWebViewTheme = themeColor?.isLight() ?? backgroundColor?.isLight() ?? true ? .light : .dark
                self.overrideUIStyle()
                // Rotation briefly exposes the native container around WKWebView.
                // Use the page background, not the brand-colored toolbar tint.
                view.backgroundColor = backgroundColor;
                webviewView.backgroundColor = backgroundColor;
            }
        }
    }

    private var launchCream: UIColor {
        return UIColor(red: 253.0 / 255.0, green: 248.0 / 255.0, blue: 240.0 / 255.0, alpha: 1)
    }

    private var munibinBrown: UIColor {
        return UIColor(red: 146.0 / 255.0, green: 64.0 / 255.0, blue: 14.0 / 255.0, alpha: 1)
    }

    private var munibinGold: UIColor {
        return UIColor(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0, alpha: 1)
    }

    // Exact opaque brown used by the drawing inside LaunchMark.png: #9E4005.
    private var launchMarkBrown: UIColor {
        return UIColor(red: 158.0 / 255.0, green: 64.0 / 255.0, blue: 5.0 / 255.0, alpha: 1)
    }

    /// Builds the animated continuation of LaunchScreen.storyboard.
    /// The storyboard owns the static first frame; this view takes over as soon
    /// as UIKit hands control to the application.
    private func setupLaunchAnimation() {
        guard let background = loadingView.superview else { return }
        launchBackgroundView = background
        launchStartedAt = CACurrentMediaTime()
        launchExitScheduled = false

        view.backgroundColor = launchCream
        webviewView.backgroundColor = launchCream
        background.backgroundColor = launchCream
        background.alpha = 1
        background.isHidden = false
        loadingView.isHidden = false

        // Keep the full wordmark composition centered, with the title and accent
        // visually contained inside the soft circular halo on every iPhone size.
        let originalCenter = loadingView.center
        loadingView.bounds = CGRect(x: 0, y: 0, width: 250, height: 260)
        loadingView.center = originalCenter
        loadingView.backgroundColor = .clear

        // Retire the old square launch image. The transparent mark below blends
        // perfectly into the cream background and can be animated cleanly.
        for imageView in loadingView.subviews.compactMap({ $0 as? UIImageView }) {
            if imageView !== connectionProblemView {
                imageView.isHidden = true
            }
        }

        progressView.frame = CGRect(x: 75, y: 228, width: 100, height: 2)
        progressView.progressTintColor = launchMarkBrown
        progressView.trackTintColor = launchMarkBrown.withAlphaComponent(0.10)
        progressView.alpha = 0
        connectionProblemView.frame = CGRect(x: 109, y: 220, width: 32, height: 30)

        let glow = UIView(frame: CGRect(x: 25, y: 1, width: 200, height: 200))
        glow.backgroundColor = munibinGold.withAlphaComponent(0.075)
        glow.layer.cornerRadius = 100
        glow.isUserInteractionEnabled = false
        loadingView.addSubview(glow)
        launchGlowView = glow

        let logo = UIImageView(image: UIImage(named: "LaunchMark"))
        logo.frame = CGRect(x: 65, y: 12, width: 120, height: 130)
        logo.contentMode = .scaleAspectFit
        logo.isUserInteractionEnabled = false
        loadingView.addSubview(logo)
        launchLogoView = logo

        let title = UILabel(frame: CGRect(x: 25, y: 134, width: 200, height: 38))
        title.text = "منيبين"
        title.textAlignment = .center
        title.textColor = munibinBrown
        title.font = .systemFont(ofSize: 29, weight: .semibold)
        loadingView.addSubview(title)
        launchTitleLabel = title

        let accent = UIView(frame: CGRect(x: 105, y: 179, width: 40, height: 3))
        accent.backgroundColor = launchMarkBrown
        accent.layer.cornerRadius = 1.5
        loadingView.addSubview(accent)
        launchAccentView = accent

        // Match the static launch-screen mark first, then grow it subtly into its
        // final resting size. This prevents the common "second splash" flash.
        logo.transform = CGAffineTransform(scaleX: 0.80, y: 0.80)
        glow.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)
        glow.alpha = 0
        title.alpha = 0
        title.transform = CGAffineTransform(translationX: 0, y: 8)
        accent.alpha = 0
        accent.transform = CGAffineTransform(scaleX: 0.01, y: 1)

        // The WKWebView was added programmatically after the storyboard. Keep the
        // native launch layer above it until the page is actually ready.
        webviewView.bringSubviewToFront(background)

        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.62, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                glow.alpha = 1
                glow.transform = .identity
            }
            UIView.animate(
                withDuration: 0.66,
                delay: 0.04,
                usingSpringWithDamping: 0.72,
                initialSpringVelocity: 0.35,
                options: [.allowUserInteraction]
            ) {
                logo.transform = .identity
            }
            UIView.animate(withDuration: 0.34, delay: 0.28, options: [.curveEaseOut, .allowUserInteraction]) {
                title.alpha = 1
                title.transform = .identity
            }
            UIView.animate(withDuration: 0.30, delay: 0.44, options: [.curveEaseOut, .allowUserInteraction]) {
                accent.alpha = 1
                accent.transform = .identity
            }
        }

        // Only show loading progress if startup actually takes long enough to
        // need it; on normal launches the user sees only the clean brand motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self, !self.htmlIsLoaded, !self.loadingView.isHidden else { return }
            UIView.animate(withDuration: 0.22) {
                self.progressView.alpha = 1.0
            }
        }
    }

    private func finishLaunchAnimation() {
        // Later reloads still use the legacy loading/error surface. Do not replay
        // the branded intro; simply reveal the successfully reloaded WebView.
        if initialLaunchCompleted {
            Munibin.webView.isHidden = false
            loadingView.isHidden = true
            launchBackgroundView?.alpha = 1
            if let background = launchBackgroundView {
                webviewView.sendSubviewToBack(background)
            }
            overrideUIStyle()
            sendThemeToWebView()
            return
        }

        guard !launchExitScheduled else { return }
        launchExitScheduled = true
        let elapsed = CACurrentMediaTime() - launchStartedAt
        let delay = max(0, launchMinimumDuration - elapsed)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let background = self.launchBackgroundView else { return }

            // Reveal the fully loaded app underneath before dissolving the native
            // layer, giving a true crossfade instead of a hard swap.
            Munibin.webView.isHidden = false
            self.overrideUIStyle()
            self.sendThemeToWebView()

            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.progressView.alpha = 0
                self.launchTitleLabel?.alpha = 0
                self.launchTitleLabel?.transform = CGAffineTransform(translationX: 0, y: -6)
                self.launchAccentView?.alpha = 0
                self.launchAccentView?.transform = CGAffineTransform(scaleX: 0.55, y: 1)
                self.launchLogoView?.alpha = 0
                self.launchLogoView?.transform = CGAffineTransform(scaleX: 1.075, y: 1.075)
                self.launchGlowView?.alpha = 0
                self.launchGlowView?.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
            }

            UIView.animate(withDuration: 0.30, delay: 0.06, options: [.curveEaseOut]) {
                background.alpha = 0
            } completion: { _ in
                self.initialLaunchCompleted = true
                self.loadingView.isHidden = true
                background.alpha = 1
                self.webviewView.sendSubviewToBack(background)
            }
        }
    }

    private func prepareLoadingOverlayForRetry() {
        guard initialLaunchCompleted, let background = launchBackgroundView else { return }
        background.alpha = 1
        webviewView.bringSubviewToFront(background)
        loadingView.isHidden = false
        launchLogoView?.alpha = 1
        launchLogoView?.transform = .identity
        launchTitleLabel?.alpha = 1
        launchTitleLabel?.transform = .identity
        launchAccentView?.alpha = 1
        launchAccentView?.transform = .identity
        launchGlowView?.alpha = 1
        launchGlowView?.transform = .identity
        progressView.alpha = 1.0
    }

    @objc func refreshWebView(_ sender: UIRefreshControl) {
        Munibin.webView?.reload()
        sender.endRefreshing()
    }

    func createToolbarView() -> UIToolbar{
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 60
        
        #if targetEnvironment(macCatalyst)
        if (statusBarHeight == 0){
            statusBarHeight = 30
        }
        #endif
        
        let toolbarView = UIToolbar(frame: CGRect(x: 0, y: 0, width: webviewView.frame.width, height: 0))
        toolbarView.sizeToFit()
        toolbarView.frame = CGRect(x: 0, y: 0, width: webviewView.frame.width, height: toolbarView.frame.height + statusBarHeight)
//        toolbarView.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleWidth]
        
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(loadRootUrl))
        toolbarView.setItems([close,flex], animated: true)
        
        toolbarView.isHidden = true
        
        return toolbarView
    }
    
    func overrideUIStyle(toDefault: Bool = false) {
        if #available(iOS 15.0, *), adaptiveUIStyle {
            if (((htmlIsLoaded && !Munibin.webView.isHidden) || toDefault) && self.currentWebViewTheme != .unspecified) {
                UIApplication
                    .shared
                    .connectedScenes
                    .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                    .first { $0.isKeyWindow }?.overrideUserInterfaceStyle = toDefault ? .unspecified : self.currentWebViewTheme;
            }
        }
    }
    
    func initToolbarView() {
        toolbarView =  createToolbarView()
        
        webviewView.addSubview(toolbarView)
    }
    
    @objc func loadRootUrl(cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) {
        let launchUrl = SceneDelegate.notificationLinkToLaunch
            ?? SceneDelegate.universalLinkToLaunch
            ?? SceneDelegate.shortcutLinkToLaunch
            ?? rootUrl
        SceneDelegate.notificationLinkToLaunch = nil
        SceneDelegate.universalLinkToLaunch = nil
        SceneDelegate.shortcutLinkToLaunch = nil

        // The native app renders the packaged frontend from a loopback origin.
        // Only /api and /manus-storage requests are allowed to reach munibin.com.
        NativeAppServer.shared.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard let localUrl = NativeAppServer.shared.localURL(for: launchUrl) else {
                    self.animateConnectionProblem(true)
                    return
                }

                // v145-v147 could keep rendering a cached older index because the old
                // Service Worker controlled the stable loopback origin before the new
                // bundled page loaded. Use an /api same-origin escape hatch once for
                // v148; old workers pass it through, allowing the native server to
                // unregister them while preserving IndexedDB/localStorage/audio caches.
                let resetVersion = "v423-prayer-format-iqama-1"
                let resetKey = "munibinNativeShellResetVersion"
                if UserDefaults.standard.string(forKey: resetKey) != resetVersion,
                   let base = NativeAppServer.shared.baseURL {
                    UserDefaults.standard.set(resetVersion, forKey: resetKey)
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
                    components?.path = "/api/__native-shell-reset-v196"
                    components?.queryItems = [URLQueryItem(name: "next", value: localUrl.absoluteString)]
                    if let resetURL = components?.url {
                        Munibin.webView.load(URLRequest(url: resetURL, cachePolicy: .reloadIgnoringLocalCacheData))
                        return
                    }
                }
                Munibin.webView.load(URLRequest(url: localUrl, cachePolicy: cachePolicy))
            case .failure(let error):
                print("[NativeAppServer] failed to start: \(error)")
                self.animateConnectionProblem(true)
            }
        }
    }
    
    func reloadWebview(
        loadingMode: LoadingMode = LoadingMode.defaultCachePolicy
    ) {
        switch loadingMode {
        case LoadingMode.defaultCachePolicy:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);

        case LoadingMode.forceCache:
            // عند بداية التطبيق دون شبكة، Safari WebView قد يحاول التحقق من الخادم
            // رغم وجود Service Worker مخزن. سياسة الكاش الفعلية تسمح باستعادة الغلاف
            // المحفوظ كي تفتح صفحة المواقيت وتقويمها المحلي فوراً.
            loadRootUrl(cachePolicy: .returnCacheDataElseLoad);
        }

        self.loadingMode = loadingMode
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if speechShouldContinue {
            stopSpeechEngine()
            emitSpeech(isFinal: true, state: "stopped")
        }
        if quranAudioShouldContinue {
            stopQuranAudioCapture()
            emitQuranAudio(state: "stopped")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopSpeechEngine()
        stopQuranAudioCapture()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!){
        htmlIsLoaded = true
        
        self.setProgress(1.0, true)
        self.animateConnectionProblem(false)
        self.finishLaunchAnimation()
        self.restorePrayerWidgetSnapshotFromWebStorage()
    }

    private func restorePrayerWidgetSnapshotFromWebStorage() {
        let script = """
        (function() {
          try { return window.localStorage.getItem('munibin-prayer-widget-snapshot-v1') || ''; }
          catch (_) { return ''; }
        })();
        """

        Munibin.webView.evaluateJavaScript(script) { result, _ in
            guard let serialized = result as? String,
                  let data = serialized.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(body) else { return }
            PrayerWidgetBridge.save(snapshotBody: body)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        htmlIsLoaded = false;
        
        if (error as NSError)._code == (-999) { return }
        if (error as NSError)._code == 102 { return }
        
        self.overrideUIStyle(toDefault: true);
        webView.isHidden = true;
        loadingView.isHidden = false;
        prepareLoadingOverlayForRetry()

        if loadingMode == LoadingMode.defaultCachePolicy {
            DispatchQueue.main.async {
                self.reloadWebview(loadingMode: LoadingMode.forceCache)
            }
        } else {
            animateConnectionProblem(true);
            setProgress(0.05, true);
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.setProgress(0.1, true);
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.reloadWebview()
                }
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {

        if (keyPath == #keyPath(WKWebView.estimatedProgress) &&
            Munibin.webView.isLoading &&
                !self.loadingView.isHidden &&
                !self.htmlIsLoaded) {
                    var progress = Float(Munibin.webView.estimatedProgress);
                    
                    if (progress >= 0.8) { progress = 1.0; };
                    if (progress >= 0.3) { self.animateConnectionProblem(false); }
                    
                    self.setProgress(progress, true);
        }
    }
    
    func setProgress(_ progress: Float, _ animated: Bool) {
        self.progressView.setProgress(progress, animated: animated);
    }
    
    
    func animateConnectionProblem(_ show: Bool) {
        if (show) {
            self.connectionProblemView.isHidden = false;
            self.connectionProblemView.alpha = 0
            UIView.animate(withDuration: 0.7, delay: 0, options: [.repeat, .autoreverse], animations: {
                self.connectionProblemView.alpha = 1
            })
        }
        else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [], animations: {
                self.connectionProblemView.alpha = 0 // Here you will get the animation you want
            }, completion: { _ in
                self.connectionProblemView.isHidden = true;
                self.connectionProblemView.layer.removeAllAnimations();
            })
        }
    }
        
    private func emitNativeEvent(_ name: String, detail: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(detail),
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            Munibin.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(name)', {detail:\(json)}));", completionHandler: nil)
        }
    }

    private func emitSpeech(text: String = "", isFinal: Bool = false, error: String? = nil,
                            state: String? = nil, recoverable: Bool = false,
                            requestId: String? = nil, utteranceId: Int? = nil,
                            alternatives: [[String: Any]]? = nil, confidence: Double? = nil) {
        var detail: [String: Any] = [
            "requestId": requestId ?? speechRequestId,
            "utteranceId": utteranceId ?? speechUtteranceId,
            "text": text,
            "isFinal": isFinal
        ]
        if let error { detail["error"] = error; detail["recoverable"] = recoverable }
        if let state { detail["state"] = state }
        if let alternatives { detail["alternatives"] = alternatives }
        if let confidence, confidence.isFinite { detail["confidence"] = confidence }
        emitNativeEvent("munibin-native-speech", detail: detail)
    }

    private func speechConfidence(_ transcription: SFTranscription) -> Double? {
        guard !transcription.segments.isEmpty else { return nil }
        let value = transcription.segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(transcription.segments.count)
        // Apple commonly leaves confidence unset (zero) on interim results.
        return value > 0 && value.isFinite ? value : nil
    }

    private func failSpeech(_ error: String) {
        stopSpeechEngine()
        emitSpeech(isFinal: true, error: error, state: "error")
    }

    private func beginSpeechRecognition() {
        guard speechShouldContinue else { return }
        guard UIApplication.shared.applicationState != .background else { failSpeech("background"); return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { failSpeech("unavailable"); return }

        stopSpeechEngine(keepIntent: true)
        speechUtteranceId += 1
        let sessionGeneration = speechSessionGeneration
        let taskGeneration = speechTaskGeneration
        let requestId = speechRequestId
        let utteranceId = speechUtteranceId
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Do not supply the expected verse as contextualStrings. That can bias
        // ordinary dictation toward words that the user did not actually recite.
        speechRequest = request
        do {
            let session = AVAudioSession.sharedInstance()
            if !speechAudioSessionOwned {
                speechPreviousAudioCategory = session.category
                speechPreviousAudioMode = session.mode
                speechPreviousAudioOptions = session.categoryOptions
                speechAudioSessionOwned = true
            }
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            guard session.isInputAvailable else { failSpeech("audio-capture"); return }
            // Activate the audio session before obtaining the hardware format.
            // A pre-activation input format can have zero channels/sample rate.
            let inputNode = speechAudioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { failSpeech("audio-capture"); return }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            speechTapInstalled = true
            speechAudioEngine.prepare()
            try speechAudioEngine.start()
        } catch {
            failSpeech("start-failed")
            return
        }

        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.speechShouldContinue,
                      self.speechSessionGeneration == sessionGeneration,
                      self.speechTaskGeneration == taskGeneration,
                      self.speechRequestId == requestId else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.speechConsecutiveErrors = 0 }
                    let alternatives: [[String: Any]] = result.transcriptions.prefix(4).map { transcription in
                        var item: [String: Any] = ["text": transcription.formattedString]
                        if let confidence = self.speechConfidence(transcription) { item["confidence"] = confidence }
                        return item
                    }
                    self.emitSpeech(text: text, isFinal: result.isFinal,
                                    state: result.isFinal ? "processing" : "listening",
                                    requestId: requestId, utteranceId: utteranceId,
                                    alternatives: alternatives, confidence: self.speechConfidence(result.bestTranscription))
                    if result.isFinal {
                        self.scheduleSpeechRestart(after: 0.2)
                        return
                    }
                }
                if error != nil {
                    self.speechConsecutiveErrors += 1
                    guard self.speechConsecutiveErrors <= 3, recognizer.isAvailable else {
                        self.failSpeech(recognizer.isAvailable ? "recognition-error" : "unavailable")
                        return
                    }
                    self.scheduleSpeechRestart(after: Double(self.speechConsecutiveErrors) * 0.5, error: "recognition-error")
                }
            }
        }
        emitSpeech(state: "listening", requestId: requestId, utteranceId: utteranceId)

        // Apple limits the duration of individual requests. Finish this one
        // before that limit, accept its final result, then begin a new utterance.
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.speechShouldContinue,
                  self.speechSessionGeneration == sessionGeneration,
                  self.speechTaskGeneration == taskGeneration else { return }
            self.stopSpeechCapture()
            self.speechRequest?.endAudio()
            self.speechTask?.finish()
            self.emitSpeech(state: "processing", requestId: requestId, utteranceId: utteranceId)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.speechShouldContinue,
                      self.speechSessionGeneration == sessionGeneration,
                      self.speechTaskGeneration == taskGeneration else { return }
                self.scheduleSpeechRestart(after: 0.2)
            }
            self.speechFinishWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        }
        speechFinishWorkItem = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: finish)
    }

    private func scheduleSpeechRestart(after delay: Double, error: String? = nil) {
        guard speechShouldContinue else { return }
        stopSpeechEngine(keepIntent: true)
        let generation = speechSessionGeneration
        let taskGeneration = speechTaskGeneration
        let requestId = speechRequestId
        emitSpeech(error: error, state: "restarting", recoverable: true)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.speechShouldContinue,
                  self.speechSessionGeneration == generation,
                  self.speechTaskGeneration == taskGeneration,
                  self.speechRequestId == requestId else { return }
            self.speechRestartWorkItem = nil
            self.beginSpeechRecognition()
        }
        speechRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopSpeechCapture() {
        if speechAudioEngine.isRunning { speechAudioEngine.stop() }
        if speechTapInstalled {
            speechAudioEngine.inputNode.removeTap(onBus: 0)
            speechTapInstalled = false
        }
    }

    private func stopSpeechEngine(keepIntent: Bool = false) {
        if !keepIntent {
            speechShouldContinue = false
            speechSessionGeneration += 1
        }
        // Invalidate the callback before cancel(), which may itself deliver an
        // error. Old callbacks must never stop or restart a newer mic session.
        speechTaskGeneration += 1
        speechRestartWorkItem?.cancel()
        speechRestartWorkItem = nil
        speechFinishWorkItem?.cancel()
        speechFinishWorkItem = nil
        stopSpeechCapture()
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechTask = nil
        speechRequest = nil
        if !keepIntent && speechAudioSessionOwned {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let category = speechPreviousAudioCategory, let mode = speechPreviousAudioMode {
                try? session.setCategory(category, mode: mode, options: speechPreviousAudioOptions)
            }
            speechAudioSessionOwned = false
            speechPreviousAudioCategory = nil
            speechPreviousAudioMode = nil
        }
    }

    private func emitQuranAudio(state: String? = nil, error: String? = nil,
                                sequence: Int? = nil, pcm: Data? = nil) {
        // This method runs on the main thread. Frames are checked against the
        // active generation immediately before evaluating JS, so a queued tap
        // cannot deliver audio to a stopped or navigated-away WebView session.
        var detail: [String: Any] = ["requestId": quranAudioRequestId]
        if let state { detail["state"] = state }
        if let error { detail["error"] = error }
        if let sequence, let pcm {
            detail["sequence"] = sequence
            detail["sampleRate"] = 16_000
            detail["pcmBase64"] = pcm.base64EncodedString()
        }
        guard JSONSerialization.isValidJSONObject(detail),
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        Munibin.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('munibin-native-quran-audio', {detail:\(json)}));", completionHandler: nil)
    }

    private func failQuranAudio(_ error: String) {
        stopQuranAudioCapture()
        emitQuranAudio(state: "error", error: error)
    }

    private func beginQuranAudioCapture() {
        guard quranAudioShouldContinue else { return }
        guard UIApplication.shared.applicationState != .background else { failQuranAudio("background"); return }
        let generation = quranAudioGeneration
        let requestId = quranAudioRequestId
        do {
            let session = AVAudioSession.sharedInstance()
            quranPreviousAudioCategory = session.category
            quranPreviousAudioMode = session.mode
            quranPreviousAudioOptions = session.categoryOptions
            quranAudioSessionOwned = true
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            guard session.isInputAvailable else { failQuranAudio("audio-capture"); return }
            // The physical input rate is commonly 44.1 or 48 kHz. Obtain it only
            // after activation and resample it instead of forcing the tap to a
            // format that does not match the input node's hardware format.
            let inputNode = quranAudioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard let stream = QuranPCM16Stream(inputFormat: format) else { failQuranAudio("audio-format"); return }
            quranAudioStream = stream
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, stream] buffer, _ in
                guard let frames = stream.consume(buffer) else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.quranAudioShouldContinue,
                              self.quranAudioGeneration == generation,
                              self.quranAudioRequestId == requestId else { return }
                        self.failQuranAudio("audio-conversion")
                    }
                    return
                }
                guard !frames.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.quranAudioShouldContinue,
                          self.quranAudioGeneration == generation,
                          self.quranAudioRequestId == requestId else { return }
                    for (sequence, data) in frames {
                        self.emitQuranAudio(sequence: sequence, pcm: data)
                    }
                }
            }
            quranAudioTapInstalled = true
            quranAudioEngine.prepare()
            try quranAudioEngine.start()
            emitQuranAudio(state: "listening")
        } catch {
            failQuranAudio("start-failed")
        }
    }

    private func stopQuranAudioCapture() {
        quranAudioShouldContinue = false
        quranAudioGeneration += 1
        // Invalidate the converter before stopping the engine: a tap already
        // running on the audio thread must not enqueue additional PCM frames.
        quranAudioStream?.cancel()
        if quranAudioEngine.isRunning { quranAudioEngine.stop() }
        if quranAudioTapInstalled {
            quranAudioEngine.inputNode.removeTap(onBus: 0)
            quranAudioTapInstalled = false
        }
        quranAudioStream = nil
        if quranAudioSessionOwned {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let category = quranPreviousAudioCategory, let mode = quranPreviousAudioMode {
                try? session.setCategory(category, mode: mode, options: quranPreviousAudioOptions)
            }
            quranAudioSessionOwned = false
            quranPreviousAudioCategory = nil
            quranPreviousAudioMode = nil
        }
    }

    private func handleQuranAudio(_ action: String, requestId: String?) {
        if action == "stopAudio" {
            if let requestId, !requestId.isEmpty, requestId != quranAudioRequestId { return }
            stopQuranAudioCapture()
            emitQuranAudio(state: "stopped")
            return
        }
        let id = requestId.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        if quranAudioShouldContinue && quranAudioRequestId == id { return }
        // Capture and ordinary dictation may never own the microphone together.
        let stoppedSpeech = speechShouldContinue
        stopSpeechEngine()
        if stoppedSpeech { emitSpeech(isFinal: true, state: "stopped") }
        stopQuranAudioCapture()
        quranAudioRequestId = id
        quranAudioShouldContinue = true
        let generation = quranAudioGeneration
        emitQuranAudio(state: "starting")
        // Raw PCM requires microphone authorization only. The backend Quran
        // recognizer does not depend on Apple's Speech Recognition permission.
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.quranAudioShouldContinue,
                      self.quranAudioGeneration == generation,
                      self.quranAudioRequestId == id else { return }
                guard granted else { self.failQuranAudio("permission-denied"); return }
                self.beginQuranAudioCapture()
            }
        }
    }

    func handleMunibinSpeech(_ body: Any) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.handleMunibinSpeech(body) }
            return
        }
        guard let payload = body as? [String: Any], let action = payload["action"] as? String else { return }
        let suppliedRequestId = (payload["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "startAudio" || action == "stopAudio" {
            handleQuranAudio(action, requestId: suppliedRequestId)
            return
        }
        if action == "stop" {
            if let suppliedRequestId, !suppliedRequestId.isEmpty, suppliedRequestId != speechRequestId { return }
            stopSpeechEngine()
            emitSpeech(isFinal: true, state: "stopped")
            return
        }
        guard action == "start" else { return }
        let requestId = suppliedRequestId.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        if speechShouldContinue && speechRequestId == requestId { return }
        let stoppedQuranAudio = quranAudioShouldContinue
        stopQuranAudioCapture()
        if stoppedQuranAudio { emitQuranAudio(state: "stopped") }
        stopSpeechEngine()
        speechRequestId = requestId
        speechUtteranceId = 0
        speechConsecutiveErrors = 0
        speechShouldContinue = true
        let generation = speechSessionGeneration
        emitSpeech(state: "starting")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.speechShouldContinue,
                      self.speechSessionGeneration == generation, self.speechRequestId == requestId else { return }
                guard status == .authorized else { self.failSpeech("permission-denied"); return }
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.speechShouldContinue,
                              self.speechSessionGeneration == generation, self.speechRequestId == requestId else { return }
                        guard granted else { self.failSpeech("permission-denied"); return }
                        self.beginSpeechRecognition()
                    }
                }
            }
        }
    }

    @objc private func speechApplicationDidEnterBackground(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.speechApplicationDidEnterBackground(notification) }
            return
        }
        if quranAudioShouldContinue { failQuranAudio("background") }
        if speechShouldContinue { failSpeech("background") }
    }

    @objc private func speechAudioInterrupted(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.speechAudioInterrupted(notification) }
            return
        }
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
        if quranAudioShouldContinue { failQuranAudio("interrupted") }
        if speechShouldContinue { failSpeech("interrupted") }
    }

    @objc private func speechAudioRouteChanged(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.speechAudioRouteChanged(notification) }
            return
        }
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
        if quranAudioShouldContinue && quranAudioEngine.isRunning {
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .noSuitableRouteForCategory:
                // A changed physical input format needs a fresh converter. Stop
                // cleanly and let the user restart instead of mixing formats.
                failQuranAudio("audio-route-changed")
            default:
                break
            }
        }
        guard speechShouldContinue, speechAudioEngine.isRunning else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
            scheduleSpeechRestart(after: 0.4)
        case .noSuitableRouteForCategory:
            failSpeech("audio-capture")
        default:
            break
        }
    }

    @objc private func speechMediaServicesReset(_ notification: Notification) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.speechMediaServicesReset(notification) }
            return
        }
        let wasListening = speechShouldContinue
        let wasCapturingQuran = quranAudioShouldContinue
        stopSpeechEngine()
        stopQuranAudioCapture()
        speechAudioEngine = AVAudioEngine()
        quranAudioEngine = AVAudioEngine()
        if wasListening { emitSpeech(isFinal: true, error: "audio-capture", state: "error") }
        if wasCapturingQuran { emitQuranAudio(state: "error", error: "audio-capture") }
    }

    func handleMunibinCompass(_ body: Any) {
        guard let payload = body as? [String: Any], let action = payload["action"] as? String else { return }
        if action == "start" {
            guard CLLocationManager.headingAvailable() else { return }
            qiblaLocationManager.startUpdatingHeading()
        } else if action == "stop" {
            qiblaLocationManager.stopUpdatingHeading()
        }
    }

    func savePersistentWebState(_ body: Any) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              data.count < 2_000_000,
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: "munibin.persistent.web-state.v1")
        UserDefaults.standard.synchronize()
    }

    private func handleMunibinSocialAuth(_ body: Any) {
        guard let payload = body as? [String: Any],
              let provider = payload["provider"] as? String,
              provider == "google" || provider == "apple",
              let url = URL(string: "https://munibin.com/api/auth/\(provider)?native=1") else { return }

        socialAuthSession?.cancel()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "munibin") { [weak self] callbackURL, error in
            guard let self else { return }
            defer { self.socialAuthSession = nil }
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
            if let callbackURL,
               let parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
                let code = parts.queryItems?.first(where: { $0.name == "code" })?.value
                let callbackError = parts.queryItems?.first(where: { $0.name == "error" })?.value
                if let code, !code.isEmpty {
                    self.emitNativeEvent("munibin-native-social-auth", detail: ["code": code])
                    return
                }
                if let callbackError, !callbackError.isEmpty {
                    self.emitNativeEvent("munibin-native-social-auth", detail: ["error": callbackError])
                    return
                }
            }
            self.emitNativeEvent("munibin-native-social-auth", detail: ["error": error?.localizedDescription ?? "تعذر إكمال تسجيل الدخول."])
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        socialAuthSession = session
        if !session.start() {
            socialAuthSession = nil
            emitNativeEvent("munibin-native-social-auth", detail: ["error": "تعذر فتح تسجيل الدخول."])
        }
    }

    private func requestPasswordCredential(_ body: Any) {
        if #available(iOS 13.0, *) {
            let request = ASAuthorizationPasswordProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            passwordAuthorizationController = controller
            controller.performRequests()
            return
        }

        SecRequestSharedWebCredential("munibin.com" as CFString, nil) { [weak self] credentials, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.emitNativeEvent("munibin-native-password-autofill", detail: ["error": error.localizedDescription])
                }
                return
            }
            guard let rows = credentials as? [[String: Any]],
                  let credential = rows.first,
                  let account = credential[kSecAttrAccount as String] as? String,
                  let password = credential[kSecSharedPassword as String] as? String,
                  !account.isEmpty, !password.isEmpty else {
                DispatchQueue.main.async {
                    self.emitNativeEvent("munibin-native-password-autofill", detail: ["error": "لم يتم العثور على كلمة سر محفوظة لـ munibin.com."])
                }
                return
            }
            DispatchQueue.main.async {
                self.emitNativeEvent("munibin-native-password-autofill", detail: ["account": account, "password": password])
            }
        }
    }

    private func savePasswordCredential(_ body: Any) {
        guard let payload = body as? [String: Any],
              let account = (payload["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let password = payload["password"] as? String,
              !account.isEmpty, !password.isEmpty else { return }
        SecAddSharedWebCredential("munibin.com" as CFString, account as CFString, password as CFString) { error in
            if let error {
                print("[Passwords] Shared credential save was not completed: \(error)")
            }
        }
    }

    deinit {
        stopSpeechEngine()
        stopQuranAudioCapture()
        NotificationCenter.default.removeObserver(self)
        qiblaLocationManager.stopUpdatingHeading()
        Munibin.webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
}

// A tap is called on an audio thread while stop/navigation runs on the main
// thread. The lock makes converter state and cancellation indivisible. Tap
// buffers are converted before returning; they are never retained for later use.
private final class QuranPCM16Stream {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let inputChannelCount: AVAudioChannelCount
    private var active = true
    private var failed = false
    private var pending = Data()
    private var sequence = 0
    private let frameByteCount = 8_000 // 250 ms * 16,000 samples/s * 2 bytes

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.outputFormat = output
        self.converter = converter
        converter.downmix = true
        self.inputSampleRate = inputFormat.sampleRate
        self.inputChannelCount = inputFormat.channelCount
    }

    // nil denotes a conversion failure; an empty array denotes insufficient
    // buffered audio or a session that has already been canceled.
    func consume(_ input: AVAudioPCMBuffer) -> [(Int, Data)]? {
        lock.lock()
        defer { lock.unlock() }
        guard active, !failed else { return [] }
        guard input.format.sampleRate == inputSampleRate,
              input.format.channelCount == inputChannelCount else {
            failed = true
            return nil
        }
        guard input.frameLength > 0 else { return [] }
        // Extra capacity accommodates the resampler's filter state. The pull
        // converter is required here: convert(to:from:) cannot change rates.
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / inputSampleRate) + 128)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            failed = true
            return nil
        }
        var suppliedInput = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            guard !suppliedInput else {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, result != .error else {
            failed = true
            return nil
        }
        if output.frameLength > 0 {
            guard let samples = output.int16ChannelData?[0] else {
                failed = true
                return nil
            }
            // Encode signed PCM16 explicitly in little-endian byte order.
            let encoded = UnsafeBufferPointer(start: samples, count: Int(output.frameLength)).map { $0.littleEndian }
            encoded.withUnsafeBytes { pending.append(contentsOf: $0) }
        }
        var frames: [(Int, Data)] = []
        while pending.count >= frameByteCount {
            sequence += 1
            frames.append((sequence, Data(pending.prefix(frameByteCount))))
            pending.removeFirst(frameByteCount)
        }
        return frames
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        pending.removeAll(keepingCapacity: false)
        converter.reset()
    }
}

extension ViewController: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !available, !speechRecognizer.isAvailable, self.speechShouldContinue else { return }
            self.failSpeech("unavailable")
        }
    }
}

extension ViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        emitNativeEvent("munibin-native-heading", detail: ["heading": heading, "accuracy": newHeading.headingAccuracy])
    }
}

extension ViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? UIApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}


@available(iOS 13.0, *)
extension ViewController: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return view.window ?? UIApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        passwordAuthorizationController = nil
        guard let credential = authorization.credential as? ASPasswordCredential,
              !credential.user.isEmpty, !credential.password.isEmpty else {
            emitNativeEvent("munibin-native-password-autofill", detail: ["error": "لم يتم العثور على كلمة سر محفوظة لـ munibin.com."])
            return
        }
        emitNativeEvent("munibin-native-password-autofill", detail: ["account": credential.user, "password": credential.password])
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        passwordAuthorizationController = nil
        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
            emitNativeEvent("munibin-native-password-autofill", detail: ["error": "canceled"])
            return
        }
        emitNativeEvent("munibin-native-password-autofill", detail: ["error": error.localizedDescription])
    }
}

extension UIColor {
    // Check if the color is light or dark, as defined by the injected lightness threshold.
    // Some people report that 0.7 is best. I suggest to find out for yourself.
    // A nil value is returned if the lightness couldn't be determined.
    func isLight(threshold: Float = 0.5) -> Bool? {
        let originalCGColor = self.cgColor

        // Now we need to convert it to the RGB colorspace. UIColor.white / UIColor.black are greyscale and not RGB.
        // If you don't do this then you will crash when accessing components index 2 below when evaluating greyscale colors.
        let RGBCGColor = originalCGColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        guard let components = RGBCGColor?.components else {
            return nil
        }
        guard components.count >= 3 else {
            return nil
        }

        let brightness = Float(((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000)
        return (brightness > threshold)
    }
}

extension ViewController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "print" {
            printView(webView: Munibin.webView)
        }
        if message.name == "push-subscribe" {
            handleSubscribeTouch(message: message)
        }
        if message.name == "push-permission-request" {
            handlePushPermission()
        }
        if message.name == "push-permission-state" {
            handlePushState()
        }
        if message.name == "push-token" {
            handleFCMToken()
        }
        if message.name == "munibin-apns" {
            handleNativeApnsRegistration()
        }
        if message.name == "munibin-chat" {
            handleNativeChatNotification(message.body)
        }
        if message.name == "munibin-widget" {
            PrayerWidgetBridge.save(snapshotBody: message.body)
        }
        if message.name == "prayer-time-format" {
            PrayerWidgetBridge.setTimeFormat(message.body)
        }
        if message.name == "prayer-theme" {
            PrayerWidgetBridge.setTheme(message.body)
        }
        if message.name == "munibin-prayer-live-activity" {
            if #available(iOS 16.2, *) {
                Task { @MainActor in PrayerLiveActivityCoordinator.shared.handle(message.body) }
            } else {
                sendNativeApnsEvent(name: "munibin-prayer-live-activity-status", detail: [
                    "enabled": false, "supported": false, "authorized": false, "active": false
                ])
            }
        }
        if message.name == "munibin-prayer-permission" {
            // Local reminders do not need APNs registration or an internet connection.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    self.emitNativeEvent("munibin-prayer-permission-result", detail: ["granted": granted])
                }
            }
        }
        if message.name == "munibin-now-playing" {
            NativeNowPlayingBridge.update(body: message.body)
        }
        if message.name == "munibin-speech" {
            handleMunibinSpeech(message.body)
        }
        if message.name == "munibin-compass" {
            handleMunibinCompass(message.body)
        }
        if message.name == "munibin-persistence" {
            savePersistentWebState(message.body)
        }
        if message.name == "munibin-social-auth" {
            handleMunibinSocialAuth(message.body)
        }
        if message.name == "munibin-password" {
            savePasswordCredential(message.body)
        }
        if message.name == "munibin-password-autofill" {
            requestPasswordCredential(message.body)
        }
  }
}

private enum NativeNowPlayingBridge {
    private static var artwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "AppIcon") ?? UIImage(named: "munibin_launch_mark") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    private static func number(_ value: Any?, fallback: Double = 0) -> Double {
        guard let value = value as? NSNumber, value.doubleValue.isFinite else { return fallback }
        return max(0, value.doubleValue)
    }

    static func update(body: Any) {
        guard let payload = body as? [String: Any] else { return }
        let state = (payload["state"] as? String) ?? "stopped"
        let center = MPNowPlayingInfoCenter.default()
        if state == "stopped" && payload["title"] == nil {
            center.nowPlayingInfo = nil
            return
        }
        let title = ((payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "القرآن الكريم"
        let artist = ((payload["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "القارئ"
        let album = ((payload["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "القرآن الكريم"
        let rate = max(0.01, number(payload["playbackRate"], fallback: 1))
        let duration = number(payload["duration"])
        let elapsed = number(payload["elapsedTime"])
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyPlaybackRate: state == "playing" ? rate : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: duration > 0 ? min(elapsed, duration) : elapsed
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let trackId = payload["trackId"] as? String {
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] = trackId
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        // Supply one complete snapshot. iOS advances elapsed time from the rate;
        // reapplying a captured dictionary on a timer resets that clock. WebKit
        // owns remote controls; playbackState is the macOS-specific state API.
        center.nowPlayingInfo = info
    }
}


private enum PrayerWidgetBridge {
    private static let appGroup = "group.com.motoonai.munibin"
    private static let snapshotKey = "munibin.prayer-widget.snapshot.v1"
    private static let snapshotFileName = "munibin.prayer-widget.snapshot.v1.json"
    private static let timeFormatKey = "munibin.prayer-time-format.v1"
    private static let themeKey = "munibin.prayer-widget.theme.v1"
    private static let queue = DispatchQueue(label: "com.motoonai.prayer-widget-save")
    private static var lastSnapshotIdentity: Data?

    private static func validTimeFormat(_ value: Any?) -> String? {
        guard let format = value as? String, format == "12h" || format == "24h" else { return nil }
        return format
    }

    static func setTimeFormat(_ body: Any) {
        let value = (body as? [String: Any])?["timeFormat"] ?? body
        guard let format = validTimeFormat(value),
              let defaults = UserDefaults(suiteName: appGroup) else { return }
        let previous = validTimeFormat(defaults.string(forKey: timeFormatKey)) ?? "24h"
        if defaults.string(forKey: timeFormatKey) == format { return }
        if (body as? [String: Any])?["explicit"] as? Bool == true, previous != format {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { notifications in
                let identifiers = notifications.map(\.request.identifier)
                    .filter { $0.hasPrefix("munibin.local-prayer.") }
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
        defaults.set(format, forKey: timeFormatKey)
        defaults.synchronize()
        if let data = defaults.data(forKey: snapshotKey),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           var snapshot = decoded as? [String: Any] {
            snapshot["timeFormat"] = format
            save(snapshotBody: snapshot)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func setTheme(_ body: Any) {
        guard let payload = body as? [String: Any],
              let theme = payload["theme"] as? String, ["light", "dark"].contains(theme),
              let palette = payload["backgroundPalette"] as? String,
              ["cream", "gold", "olive", "wood", "blue", "monochrome"].contains(palette),
              let colors = payload["themeColors"] as? [String: String],
              ["backgroundStart", "backgroundEnd", "accent", "primary", "secondary", "border", "highlight", "iqama", "iconBackground"]
                .allSatisfy({ key in colors[key]?.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let defaults = UserDefaults(suiteName: appGroup) else { return }
        if let previous = defaults.data(forKey: themeKey),
           let decoded = try? JSONSerialization.jsonObject(with: previous),
           let existing = try? JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys]),
           existing == data { return }
        defaults.set(data, forKey: themeKey)
        defaults.synchronize()
        if let old = defaults.data(forKey: snapshotKey),
           let decoded = try? JSONSerialization.jsonObject(with: old),
           let snapshot = decoded as? [String: Any] {
            save(snapshotBody: snapshot)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func save(snapshotBody: Any) {
        guard let snapshot = snapshotBody as? [String: Any] else { return }
        // Annual schedule serialization, App Group persistence and file writes
        // must not block WKWebView's main-thread message handling.
        queue.async { saveOnQueue(snapshotBody: snapshot) }
    }

    private static func saveOnQueue(snapshotBody: Any) {
        guard var snapshot = snapshotBody as? [String: Any],
              (snapshot["version"] as? Int ?? 0) >= 1,
              let prayerTimesEnabled = snapshot["prayerTimesEnabled"] as? Bool,
              let timings = snapshot["timings"] as? [[String: Any]],
              (!prayerTimesEnabled || !timings.isEmpty),
              JSONSerialization.isValidJSONObject(snapshotBody),
              let defaults = UserDefaults(suiteName: appGroup) else {
            return
        }

        // The explicit format bridge owns the preference once initialized. A
        // queued old snapshot (even one carrying a valid older choice) must not
        // undo the user's latest selection. The initial payload still migrates
        // legacy clients that have never saved a native choice.
        let format = validTimeFormat(defaults.string(forKey: timeFormatKey))
            ?? validTimeFormat(snapshot["timeFormat"]) ?? "24h"
        snapshot["timeFormat"] = format
        if defaults.string(forKey: timeFormatKey) != format { defaults.set(format, forKey: timeFormatKey) }
        if let themeData = defaults.data(forKey: themeKey),
           let decoded = try? JSONSerialization.jsonObject(with: themeData),
           let theme = decoded as? [String: Any] {
            snapshot["theme"] = theme["theme"]
            snapshot["backgroundPalette"] = theme["backgroundPalette"]
            snapshot["themeColors"] = theme["themeColors"]
        }
        var content = snapshot
        content.removeValue(forKey: "updatedAt")
        guard let identity = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) else { return }
        let changed = identity != lastSnapshotIdentity
        if changed {
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }

            defaults.set(data, forKey: snapshotKey)
            // Synchronization and the atomic fallback stay ordered on this queue.
            defaults.synchronize()

            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
                let url = container.appendingPathComponent(snapshotFileName)
                try? data.write(to: url, options: .atomic)
            }
            lastSnapshotIdentity = identity
            PrayerLocalNotificationScheduler.sync(snapshotBody: snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Clock-only snapshots still reach the coordinator so offline foreground
        // sessions transition at prayer/iqama boundaries without a push delivery.
        if #available(iOS 16.2, *) {
            Task { @MainActor in PrayerLiveActivityCoordinator.shared.sync(snapshot: snapshot) }
        }
    }
}

private enum PrayerLocalNotificationScheduler {
    private static let identifierPrefix = "munibin.local-prayer."
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func displayedClock(_ date: Date, snapshot: [String: Any]) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let raw = snapshot["notificationConfigKey"] as? String,
           let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let config = decoded as? [String: Any],
           let identifier = config["timeZone"] as? String,
           let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return "—" }
        if snapshot["timeFormat"] as? String != "12h" {
            return String(format: "%02d:%02d", hour, minute)
        }
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12,
                      minute, hour < 12 ? "ص" : "م")
    }

    private static let queue = DispatchQueue(label: "com.munibin.prayer-notification-schedule")
    private static var generation = 0
    private static var lastConfigKey = ""
    private static var scheduledDates: [Date] = []

    static func sync(snapshotBody: Any) {
        guard let snapshot = snapshotBody as? [String: Any] else { return }
        queue.async {
            generation += 1
            let rawConfigKey = snapshot["notificationConfigKey"] as? String ?? ""
            // Include presentation in the queue identity so changing the format
            // also replaces already-pending notification titles.
            let configKey = rawConfigKey.isEmpty ? "" : rawConfigKey + "|" +
                ((snapshot["timeFormat"] as? String) == "12h" ? "12h" : "24h")
            // Preserve imminent requests during clock-only refreshes. A settings or
            // location change still cancels/replaces the old queue immediately.
            if snapshot["prayerTimesEnabled"] as? Bool == true,
               snapshot["notificationsEnabled"] as? Bool == true,
               !configKey.isEmpty, configKey == lastConfigKey,
               scheduledDates.contains(where: { abs($0.timeIntervalSinceNow) <= 90 }) {
                return
            }
            let revision = generation
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                center.getPendingNotificationRequests { requests in
                    queue.async {
                        // Ignore an older permission/pending-request callback after a settings edit.
                        guard revision == generation else { return }
                        let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
                        center.removePendingNotificationRequests(withIdentifiers: identifiers)
                        scheduledDates = []
                        lastConfigKey = ""
                        guard snapshot["prayerTimesEnabled"] as? Bool == true,
                              snapshot["notificationsEnabled"] as? Bool == true,
                              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                              let prayers = snapshot["upcomingPrayers"] as? [[String: Any]] else { return }

                        // iOS allows 64 pending notifications. Keep space for other app alerts.
                        let otherCount = requests.count - identifiers.count
                        let capacity = max(0, min(60, 64 - otherCount))
                        let sortedPrayers = prayers.sorted {
                            (Self.date(from: $0["at"] as? String ?? "") ?? .distantFuture) <
                            (Self.date(from: $1["at"] as? String ?? "") ?? .distantFuture)
                        }
                        var scheduled = 0
                        for prayer in sortedPrayers {
                            if scheduled >= capacity { break }
                            guard let rawDate = prayer["at"] as? String,
                                  let alertDate = Self.date(from: rawDate),
                                  alertDate.timeIntervalSinceNow > 0,
                                  let label = prayer["label"] as? String else { continue }
                            let eventKind = prayer["kind"] as? String ?? prayer["type"] as? String ?? "prayer"
                            let reminder = eventKind == "pre-prayer"
                            let iqama = eventKind == "iqama"
                            let key = prayer["key"] as? String ?? "prayer"
                            // Sunrise has no iqama; reject it even if an old or
                            // malformed snapshot publishes an iqama event for it.
                            if iqama && !["fajr", "dhuhr", "asr", "maghrib", "isha"].contains(key.lowercased()) {
                                continue
                            }
                            let minutes = prayer["minutesBefore"] as? Int ?? 0
                            if reminder && !(1...120).contains(minutes) { continue }
                            let alertMode = prayer["alertMode"] as? String ?? "notification"
                            guard alertMode != "off" else { continue }
                            let prayerDate = Self.date(from: prayer["prayerAt"] as? String ?? rawDate) ?? alertDate
                            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alertDate)
                            components.second = 0
                            let time = Self.displayedClock(iqama ? alertDate : prayerDate, snapshot: snapshot)
                            let content = UNMutableNotificationContent()
                            content.title = iqama ? "إقامة \(label) \(time)"
                                : (reminder ? "تذكير بصلاة \(label) \(time)" : "\(label) \(time)")
                            content.body = iqama ? "حان وقت إقامة صلاة \(label)"
                                : (reminder ? "تبقى \(minutes) دقيقة على صلاة \(label)" : "حان وقت صلاة \(label)")
                            // Iqama and advance reminders use the iOS notification
                            // sound. Adhan audio remains exclusive to prayer alerts.
                            content.sound = !reminder && !iqama && alertMode == "audio"
                                ? UNNotificationSound(named: UNNotificationSoundName("mecca_adhan.caf"))
                                : .default
                            let kind = iqama ? "iqama" : (reminder ? "pre-prayer" : "prayer")
                            content.userInfo = ["route": "/prayer-times", "prayer": key, "kind": kind]
                            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                            let identifier = "\(identifierPrefix)\(key)-\(kind)-\(Int(alertDate.timeIntervalSince1970))"
                            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                            scheduledDates.append(alertDate)
                            scheduled += 1
                        }
                        lastConfigKey = configKey
                    }
                }
            }
        }
    }
}

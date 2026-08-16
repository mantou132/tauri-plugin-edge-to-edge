import SwiftRs
import Tauri
import UIKit
import WebKit
import Darwin

// MARK: - Edge-to-Edge Plugin
// 为 iOS 提供全屏沉浸式体验支持
// 借鉴 Capacitor 官方 Keyboard 插件的实现逻辑

class EdgeToEdgePlugin: Plugin, UIScrollViewDelegate {
    private var isSetup = false
    private weak var webviewRef: WKWebView?
    private var keyboardHeight: CGFloat = 0
    private var isKeyboardVisible = false
    private var hideTimer: Timer?
    private var stageManagerOffset: CGFloat = 0  // iPad Stage Manager 支持
    private var keyboardStateVersion: Int = 0  // 状态版本号，用于取消过期的回调
    private var periodicInjectionCompleted = false  // 周期性注入是否完成
    private lazy var deviceScreenCornerRadius = Self.screenCornerRadius(
        for: Self.hardwareModelIdentifier()
    )
    
    // MARK: - Lifecycle
    
    @objc public override func load(webview: WKWebView) {
        guard !isSetup else { return }
        isSetup = true
        webviewRef = webview
        
        // 设置 Edge-to-Edge
        setupEdgeToEdge(webview: webview)
        
        // 注册键盘监听（借鉴 Capacitor 官方 Keyboard 插件）
        registerKeyboardObservers(webview: webview)
        
        // 移除 WebView 默认的键盘监听（借鉴 Capacitor Keyboard 插件）
        removeDefaultKeyboardObservers(webview: webview)
        
        // 周期性注入安全区域（覆盖页面加载过程）
        startPeriodicInjection(webview: webview)
        
        NSLog("[EdgeToEdge] Plugin loaded successfully (Capacitor Keyboard style)")
    }
    
    // MARK: - Setup
    
    private func setupEdgeToEdge(webview: WKWebView) {
        // 1. 设置 WebView 背景透明
        webview.isOpaque = false
        webview.backgroundColor = .clear
        webview.scrollView.backgroundColor = .clear
        
        // 2. 关键设置：使用 .never 禁用系统自动调整
        // 这样可以防止键盘隐藏后系统重置 Edge-to-Edge 设置
        if #available(iOS 11.0, *) {
            webview.scrollView.contentInsetAdjustmentBehavior = .never
        }
        
        // 3. 禁用滚动视图的自动 inset 调整
        webview.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        
        // 4. 参考 eunjios/ios-webview-keyboard-demo：防止键盘跳动
        webview.scrollView.bounces = false
        webview.scrollView.delegate = self
        
        // 5. 设置窗口背景色（支持深色模式）
        DispatchQueue.main.async {
            self.setupWindowBackground(webview: webview)
        }
        
        NSLog("[EdgeToEdge] Edge-to-edge mode enabled with scroll lock")
    }
    
    /// 设置窗口背景色
    private func setupWindowBackground(webview: WKWebView) {
        guard let window = webview.window else { return }
        
        if #available(iOS 13.0, *) {
            window.backgroundColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark
                    ? UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
                    : UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1)
            }
        } else {
            window.backgroundColor = UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1)
        }
        window.rootViewController?.view.backgroundColor = window.backgroundColor
    }
    
    /// 移除 WebView 默认的键盘监听（借鉴 Capacitor Keyboard 插件）
    private func removeDefaultKeyboardObservers(webview: WKWebView) {
        NotificationCenter.default.removeObserver(webview, name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.removeObserver(webview, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(webview, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(webview, name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NSLog("[EdgeToEdge] Removed default WebView keyboard observers")
    }
    
    // MARK: - Keyboard Observers (借鉴 Capacitor 官方 Keyboard 插件)
    
    private func registerKeyboardObservers(webview: WKWebView) {
        let nc = NotificationCenter.default
        
        nc.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardWillShow(webview: wv, notification: notification)
        }
        
        nc.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardDidShow(webview: wv, notification: notification)
        }
        
        nc.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardWillHide(webview: wv, notification: notification)
        }
        
        nc.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardDidHide(webview: wv, notification: notification)
        }
        
        NSLog("[EdgeToEdge] Keyboard observers registered (Capacitor Keyboard official approach)")
    }
    
    /// 重置 ScrollView（借鉴 Capacitor Keyboard 插件的 resetScrollView）
    private func resetScrollView(webview: WKWebView) {
        webview.scrollView.contentInset = .zero
        webview.scrollView.scrollIndicatorInsets = .zero
    }
    
    /// 键盘将要显示（借鉴 Capacitor Keyboard 插件）
    private func handleKeyboardWillShow(webview: WKWebView, notification: Notification) {
        // 取消隐藏定时器
        hideTimer?.invalidate()
        hideTimer = nil
        
        // 增加状态版本号，取消之前的延迟回调
        keyboardStateVersion += 1
        let currentVersion = keyboardStateVersion
        
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        
        var height = keyboardFrame.height
        
        // iPad Stage Manager 支持（借鉴 Capacitor Keyboard 插件）
        if UIDevice.current.userInterfaceIdiom == .pad {
            if stageManagerOffset > 0 {
                height = stageManagerOffset
            } else if let window = webview.window {
                let screen = window.screen
                let webViewAbsolute = webview.convert(webview.frame, to: screen.coordinateSpace)
                height = (webViewAbsolute.size.height + webViewAbsolute.origin.y) - (screen.bounds.size.height - keyboardFrame.size.height)
                if height < 0 {
                    height = 0
                }
                stageManagerOffset = height
            }
        }
        
        keyboardHeight = height
        isKeyboardVisible = true
        
        // 立即重置 ScrollView
        resetScrollView(webview: webview)
        
        NSLog("[EdgeToEdge] Keyboard will show - Height: \(height)")
        injectSafeAreaInsets(webview: webview, keyboardHeight: height, keyboardVisible: true)
        
        // 延迟再次重置，防止系统覆盖（修复跳动问题）
        // 使用版本号检查，如果状态已改变则取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak webview] in
            guard let self = self, let wv = webview else { return }
            guard self.keyboardStateVersion == currentVersion else { return }  // 状态已改变，取消
            self.resetScrollView(webview: wv)
        }
    }
    
    /// 键盘已经显示
    private func handleKeyboardDidShow(webview: WKWebView, notification: Notification) {
        // 重置 ScrollView
        resetScrollView(webview: webview)
        
        NSLog("[EdgeToEdge] Keyboard did show - Final height: \(keyboardHeight)")
        // 只在键盘确实显示时注入一次
        if isKeyboardVisible {
            injectSafeAreaInsets(webview: webview, keyboardHeight: keyboardHeight, keyboardVisible: true)
        }
    }
    
    /// 键盘将要隐藏（借鉴 Capacitor Keyboard 插件）
    private func handleKeyboardWillHide(webview: WKWebView, notification: Notification) {
        // 增加状态版本号，取消之前的延迟回调
        keyboardStateVersion += 1
        
        keyboardHeight = 0
        isKeyboardVisible = false
        
        // 重置 ScrollView
        resetScrollView(webview: webview)
        
        NSLog("[EdgeToEdge] Keyboard will hide")
        injectSafeAreaInsets(webview: webview, keyboardHeight: 0, keyboardVisible: false)
    }
    
    /// 键盘已经隐藏 - 关键：重新恢复 Edge-to-Edge 设置
    private func handleKeyboardDidHide(webview: WKWebView, notification: Notification) {
        let currentVersion = keyboardStateVersion
        
        // 重置 Stage Manager offset
        stageManagerOffset = 0
        
        // 重置 ScrollView（借鉴 Capacitor Keyboard 插件）
        resetScrollView(webview: webview)
        
        // 重新应用 Edge-to-Edge 设置
        restoreEdgeToEdge(webview: webview)
        
        NSLog("[EdgeToEdge] Keyboard did hide - Edge-to-Edge restored")
        
        // 只在键盘确实隐藏时注入
        if !isKeyboardVisible {
            injectSafeAreaInsets(webview: webview, keyboardHeight: 0, keyboardVisible: false)
        }
        
        // 延迟恢复，使用版本号检查
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webview] in
            guard let self = self, let wv = webview else { return }
            guard self.keyboardStateVersion == currentVersion else { return }  // 状态已改变，取消
            self.resetScrollView(webview: wv)
            self.restoreEdgeToEdge(webview: wv)
        }
    }
    
    /// 重新恢复 Edge-to-Edge 设置
    private func restoreEdgeToEdge(webview: WKWebView) {
        // 重新设置关键属性
        if #available(iOS 11.0, *) {
            webview.scrollView.contentInsetAdjustmentBehavior = .never
        }
        webview.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        
        // 重置 scrollView 的 contentInset
        webview.scrollView.contentInset = .zero
        webview.scrollView.scrollIndicatorInsets = .zero
    }
    
    // MARK: - Periodic Injection
    
    private func startPeriodicInjection(webview: WKWebView) {
        // 只在前5秒进行周期性注入，之后停止
        for i in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self, weak webview] in
                guard let self = self, let wv = webview else { return }
                // 只在周期性注入未完成且键盘未显示时注入
                guard !self.periodicInjectionCompleted && !self.isKeyboardVisible else { return }
                self.injectSafeAreaInsets(webview: wv, keyboardHeight: self.keyboardHeight, keyboardVisible: self.isKeyboardVisible)
                
                // 最后一次注入后标记完成
                if i == 10 {
                    self.periodicInjectionCompleted = true
                }
            }
        }
    }
    
    // MARK: - Safe Area Injection
    
    private func injectSafeAreaInsets(webview: WKWebView, keyboardHeight: CGFloat, keyboardVisible: Bool) {
        guard #available(iOS 11.0, *) else { return }
        
        let safeArea = webview.window?.safeAreaInsets ?? .zero
        let top = safeArea.top
        let right = safeArea.right
        let bottom = safeArea.bottom
        let left = safeArea.left
        let screenCornerRadius = deviceScreenCornerRadius
        
        // 键盘显示时，底部安全区域为0（键盘已覆盖Home Indicator）
        // 键盘隐藏时，确保最小安全区域（iPhone X 等有 Home Indicator）
        let computedBottom: CGFloat
        if keyboardVisible {
            // 键盘显示时：紧贴输入框，底部安全区域为0
            computedBottom = 0
        } else {
            // 键盘隐藏时：确保最小安全区域
            computedBottom = max(bottom, 34.0)
        }
        
        let jsCode = """
        (function() {
            var style = document.documentElement.style;
            style.setProperty('--safe-area-inset-top', '\(top)px');
            style.setProperty('--safe-area-inset-right', '\(right)px');
            style.setProperty('--safe-area-inset-bottom', '\(computedBottom)px');
            style.setProperty('--safe-area-inset-left', '\(left)px');
            style.setProperty('--safe-area-top', '\(top)px');
            style.setProperty('--safe-area-right', '\(right)px');
            style.setProperty('--safe-area-bottom', '\(computedBottom)px');
            style.setProperty('--safe-area-left', '\(left)px');
            style.setProperty('--safe-area-bottom-computed', '\(computedBottom)px');
            style.setProperty('--safe-area-bottom-min', '\(keyboardVisible ? 0 : 34)px');
            style.setProperty('--content-bottom-padding', '\(computedBottom)px');
            style.setProperty('--keyboard-height', '\(keyboardHeight)px');
            style.setProperty('--keyboard-visible', '\(keyboardVisible ? "1" : "0")');
            style.setProperty('--screen-corner-radius', '\(screenCornerRadius)px');
            window.dispatchEvent(new CustomEvent('safeAreaChanged', {
                detail: { top: \(top), right: \(right), bottom: \(computedBottom), left: \(left), screenCornerRadius: \(screenCornerRadius), keyboardHeight: \(keyboardHeight), keyboardVisible: \(keyboardVisible) }
            }));
        })();
        """
        
        webview.evaluateJavaScript(jsCode, completionHandler: nil)
    }

    // MARK: - Screen Corner Radius

    /// `UIScreen` does not expose a public display-corner-radius API. Use the
    /// stable hardware identifier instead of the private `_displayCornerRadius`
    /// selector so this remains safe for App Store distribution. Values are in
    /// points, which match WebKit CSS pixels on iOS.
    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        #else
        return machine
        #endif
    }

    /// Returns the device display corner radius in points for known iPhones.
    /// Unknown devices deliberately return zero until their geometry is verified.
    private static func screenCornerRadius(for model: String) -> CGFloat {
        switch model {
        // iPhone X, XS, XS Max, 11 Pro, 11 Pro Max
        case "iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone12,3", "iPhone12,5":
            return 39

        // iPhone XR, 11
        case "iPhone11,8", "iPhone12,1":
            return 41.5

        // iPhone 12 mini, 13 mini
        case "iPhone13,1", "iPhone14,4":
            return 44

        // iPhone 12, 12 Pro, 13, 13 Pro, 14, 16e
        case "iPhone13,2", "iPhone13,3", "iPhone14,5", "iPhone14,2", "iPhone14,7", "iPhone17,5":
            return 47.33

        // iPhone 12 Pro Max, 13 Pro Max, 14 Plus
        case "iPhone13,4", "iPhone14,3", "iPhone14,8":
            return 53.33

        // iPhone 14 Pro, 14 Pro Max, iPhone 15 series, iPhone 16, 16 Plus
        case "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2", "iPhone17,3", "iPhone17,4":
            return 55

        // iPhone 16 Pro, 16 Pro Max, iPhone 17 series, iPhone Air
        case "iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4":
            return 62

        default:
            return 0
        }
    }

    // MARK: - Commands
    
    @objc public func getSafeAreaInsets(_ invoke: Invoke) throws {
        guard #available(iOS 11.0, *) else {
            invoke.resolve(["top": 0, "right": 0, "bottom": 0, "left": 0])
            return
        }
        
        DispatchQueue.main.async {
            let safeArea = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero
            invoke.resolve([
                "top": safeArea.top,
                "right": safeArea.right,
                "bottom": safeArea.bottom,
                "left": safeArea.left
            ])
        }
    }
    
    @objc public func getKeyboardInfo(_ invoke: Invoke) throws {
        invoke.resolve([
            "keyboardHeight": self.keyboardHeight,
            "isVisible": self.isKeyboardVisible
        ])
    }
    
    @objc public func enable(_ invoke: Invoke) throws {
        if let wv = webviewRef {
            setupEdgeToEdge(webview: wv)
        }
        invoke.resolve()
    }
    
    @objc public func disable(_ invoke: Invoke) throws {
        invoke.resolve()
    }
    
    @objc public func showKeyboard(_ invoke: Invoke) throws {
        // iOS 不支持编程方式显示键盘
        invoke.resolve()
    }
    
    @objc public func hideKeyboard(_ invoke: Invoke) throws {
        DispatchQueue.main.async { [weak self] in
            self?.webviewRef?.endEditing(true)
        }
        invoke.resolve()
    }
    
    // MARK: - UIScrollViewDelegate (参考 eunjios/ios-webview-keyboard-demo)
    
    /// 锁定 WebView 滚动位置，防止键盘跳动
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 将滚动位置锁定为 (0, 0)，防止键盘引起的页面跳动
        if scrollView.contentOffset != .zero {
            scrollView.contentOffset = .zero
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

@_cdecl("init_plugin_edge_to_edge")
func initPlugin() -> Plugin {
    return EdgeToEdgePlugin()
}

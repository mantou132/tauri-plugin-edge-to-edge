import SwiftRs
import Tauri
import UIKit
import WebKit
import Darwin

private let edgeToEdgeBridgeName = "__TAURI_EDGE_TO_EDGE_NATIVE__"
private let edgeToEdgeInternalApiName = "__TAURI_EDGE_TO_EDGE_INTERNAL__"

private final class EdgeToEdgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var plugin: EdgeToEdgePlugin?

    init(plugin: EdgeToEdgePlugin) {
        self.plugin = plugin
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == edgeToEdgeBridgeName, message.frameInfo.isMainFrame else { return }
        DispatchQueue.main.async { [weak plugin] in
            plugin?.injectCurrentState()
        }
    }
}

// MARK: - Edge-to-Edge Plugin
// 为 iOS 提供全屏沉浸式体验支持

class EdgeToEdgePlugin: Plugin, UIScrollViewDelegate {
    private var isSetup = false
    private weak var webviewRef: WKWebView?
    private var keyboardHeight: CGFloat = 0
    private var isKeyboardVisible = false
    private var stageManagerOffset: CGFloat = 0  // iPad Stage Manager 支持
    private var originalInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior?
    private var originalScrollIndicatorAdjustment: Bool?
    private var originalBounces: Bool?
    private var isResettingScroll = false
    private lazy var deviceScreenCornerRadius = Self.screenCornerRadius(
        for: Self.hardwareModelIdentifier()
    )
    private var messageHandler: EdgeToEdgeMessageHandler?
    private var observerTokens: [NSObjectProtocol] = []
    
    // MARK: - Lifecycle
    
    @objc public override func load(webview: WKWebView) {
        guard !isSetup else { return }
        isSetup = true
        webviewRef = webview
        originalInsetAdjustmentBehavior = webview.scrollView.contentInsetAdjustmentBehavior
        originalScrollIndicatorAdjustment = webview.scrollView.automaticallyAdjustsScrollIndicatorInsets
        originalBounces = webview.scrollView.bounces

        // document-start 脚本会在首次加载、刷新和导航时请求最新状态。
        let handler = EdgeToEdgeMessageHandler(plugin: self)
        messageHandler = handler
        webview.configuration.userContentController.add(handler, name: edgeToEdgeBridgeName)

        // 设置 Edge-to-Edge
        setupEdgeToEdge(webview: webview)
        
        // 注册键盘和窗口状态监听。
        registerKeyboardObservers(webview: webview)

        // 不等待下一次系统通知，首个主线程周期就补发真实值。
        DispatchQueue.main.async { [weak self] in
            self?.injectCurrentState()
        }
        
        NSLog("[EdgeToEdge] Plugin loaded successfully")
    }
    
    // MARK: - Setup
    
    private func setupEdgeToEdge(webview: WKWebView) {
        if #available(iOS 11.0, *) {
            webview.scrollView.contentInsetAdjustmentBehavior = .never
        }
        webview.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        webview.scrollView.bounces = false
        webview.scrollView.delegate = self

        // 移除 WebKit 内部针对键盘的自动滚动和窗口移动监听
        removeDefaultKeyboardObservers(webview: webview)

        resetScrollView(webview: webview)
        NSLog("[EdgeToEdge] Edge-to-edge mode enabled")
    }

    private func removeDefaultKeyboardObservers(webview: WKWebView) {
        let nc = NotificationCenter.default
        let keyboardNotifications = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification
        ]
        for name in keyboardNotifications {
            nc.removeObserver(webview, name: name, object: nil)
        }
    }

    private func resetScrollView(webview: WKWebView) {
        let scrollView = webview.scrollView
        if scrollView.contentInset != .zero {
            scrollView.contentInset = .zero
        }
        if scrollView.scrollIndicatorInsets != .zero {
            scrollView.scrollIndicatorInsets = .zero
        }
        if scrollView.contentOffset != .zero {
            scrollView.contentOffset = .zero
        }
    }

    // MARK: - UIScrollViewDelegate

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isResettingScroll else { return }
        if scrollView.contentOffset != .zero || scrollView.contentInset != .zero {
            isResettingScroll = true
            scrollView.contentOffset = .zero
            scrollView.contentInset = .zero
            isResettingScroll = false
        }
    }
    
    // MARK: - Keyboard Observers (借鉴 Capacitor 官方 Keyboard 插件)
    
    private func registerKeyboardObservers(webview: WKWebView) {
        let nc = NotificationCenter.default
        
        observerTokens.append(nc.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardWillShow(webview: wv, notification: notification)
        })
        
        observerTokens.append(nc.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardDidShow(webview: wv, notification: notification)
        })
        
        observerTokens.append(nc.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardWillHide(webview: wv, notification: notification)
        })
        
        observerTokens.append(nc.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak webview] notification in
            guard let self = self, let wv = webview else { return }
            self.handleKeyboardDidHide(webview: wv, notification: notification)
        })

        observerTokens.append(nc.addObserver(
            forName: UIApplication.didChangeStatusBarFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.injectCurrentState()
            }
        })

        observerTokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.injectCurrentState()
        })
        
        NSLog("[EdgeToEdge] Keyboard observers registered (Capacitor Keyboard official approach)")
    }
    
    private func keyboardHeight(webview: WKWebView, notification: Notification) -> CGFloat? {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return nil
        }

        var height = keyboardFrame.height

        // Floating windows need the keyboard overlap with this WebView rather
        // than the keyboard's full screen height.
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

        return height
    }

    private func handleKeyboardWillShow(webview: WKWebView, notification: Notification) {
        resetScrollView(webview: webview)
        guard let height = keyboardHeight(webview: webview, notification: notification) else { return }
        keyboardHeight = height
        isKeyboardVisible = true

        NSLog("[EdgeToEdge] Keyboard will show - Height: \(height)")
        injectSafeAreaInsets(webview: webview, keyboardHeight: height, keyboardVisible: true)
    }

    private func handleKeyboardDidShow(webview: WKWebView, notification: Notification) {
        resetScrollView(webview: webview)
        if let height = keyboardHeight(webview: webview, notification: notification) {
            keyboardHeight = height
        }
        isKeyboardVisible = true
        NSLog("[EdgeToEdge] Keyboard did show - Final height: \(keyboardHeight)")
        injectSafeAreaInsets(webview: webview, keyboardHeight: keyboardHeight, keyboardVisible: true)
    }

    private func handleKeyboardWillHide(webview: WKWebView, notification _: Notification) {
        resetScrollView(webview: webview)
        keyboardHeight = 0
        isKeyboardVisible = false

        NSLog("[EdgeToEdge] Keyboard will hide")
        injectSafeAreaInsets(webview: webview, keyboardHeight: 0, keyboardVisible: false)
    }

    private func handleKeyboardDidHide(webview: WKWebView, notification _: Notification) {
        resetScrollView(webview: webview)
        stageManagerOffset = 0
        keyboardHeight = 0
        isKeyboardVisible = false

        NSLog("[EdgeToEdge] Keyboard did hide")
        injectSafeAreaInsets(webview: webview, keyboardHeight: 0, keyboardVisible: false)
    }
    
    // MARK: - Safe Area Injection

    fileprivate func injectCurrentState() {
        guard let webview = webviewRef, let window = webview.window else { return }
        window.layoutIfNeeded()
        webview.layoutIfNeeded()
        injectSafeAreaInsets(
            webview: webview,
            keyboardHeight: keyboardHeight,
            keyboardVisible: isKeyboardVisible
        )
    }
    
    private func injectSafeAreaInsets(webview: WKWebView, keyboardHeight: CGFloat, keyboardVisible: Bool) {
        guard #available(iOS 11.0, *) else { return }
        
        guard let safeArea = webview.window?.safeAreaInsets else { return }
        let top = safeArea.top
        let right = safeArea.right
        let bottom = safeArea.bottom
        let left = safeArea.left
        let screenCornerRadius = deviceScreenCornerRadius
        let computedBottom: CGFloat = keyboardVisible ? 0 : bottom
        let currentKeyboardHeight: CGFloat = keyboardVisible ? max(keyboardHeight, 0) : 0

        let payload: [String: Any] = [
            "top": top,
            "right": right,
            "bottom": bottom,
            "left": left,
            "bottomComputed": computedBottom,
            "contentBottomPadding": computedBottom,
            "screenCornerRadius": screenCornerRadius,
            "keyboardHeight": currentKeyboardHeight,
            "keyboardVisible": keyboardVisible
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let jsCode = """
        (function() {
            var api = window.\(edgeToEdgeInternalApiName);
            if (api) api.update(\(json));
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
            let safeArea = self.webviewRef?.window?.safeAreaInsets ?? .zero
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
        if let webview = webviewRef {
            if let behavior = originalInsetAdjustmentBehavior {
                webview.scrollView.contentInsetAdjustmentBehavior = behavior
            }
            if let adjustsIndicators = originalScrollIndicatorAdjustment {
                webview.scrollView.automaticallyAdjustsScrollIndicatorInsets = adjustsIndicators
            }
            if let bounces = originalBounces {
                webview.scrollView.bounces = bounces
            }
            webview.scrollView.delegate = nil
        }
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
    
    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        webviewRef?.scrollView.delegate = nil
        webviewRef?.configuration.userContentController.removeScriptMessageHandler(
            forName: edgeToEdgeBridgeName
        )
    }
}

@_cdecl("init_plugin_edge_to_edge")
func initPlugin() -> Plugin {
    return EdgeToEdgePlugin()
}

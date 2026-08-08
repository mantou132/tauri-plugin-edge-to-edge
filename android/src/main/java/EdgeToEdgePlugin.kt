package com.plugin.edgetoedge

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsAnimationCompat
import app.tauri.annotation.Command
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import app.tauri.plugin.Invoke

/**
 * Edge-to-Edge 插件 - Android 实现
 * 完美复制 Capacitor 版本的实现逻辑
 * 为 Android 提供全屏沉浸式体验支持
 */
@TauriPlugin
class EdgeToEdgePlugin(private val activity: Activity) : Plugin(activity) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var cachedInsets = SafeAreaInsets(0, 0, 0, 0)
    private var lastKeyboardHeight = 0
    private var lastKeyboardVisible = false
    private var periodicInjectionCompleted = false  // 周期性注入是否完成

    data class SafeAreaInsets(val top: Int, val right: Int, val bottom: Int, val left: Int)

    override fun load(webView: WebView) {
        super.load(webView)
        this.webView = webView

        activity.runOnUiThread {
            // 1. 启用 Edge-to-Edge 模式
            enable()

            // 2. 设置透明系统栏
            setTransparentSystemBars()

            // 3. 设置系统栏图标颜色
            setSystemBarAppearance()

            // 4. 设置键盘动画监听器 (Capacitor 官方 Keyboard 插件方式)
            setupKeyboardAnimationListener()

            // 5. 设置 WindowInsets 监听器
            setupWindowInsetsListener()

            // 6. 周期性注入安全区域（覆盖页面加载过程，iOS 对齐）
            startPeriodicInjection()
        }

        println("[EdgeToEdge] Plugin loaded successfully (Capacitor style)")
    }

    /**
     * 启用 Edge-to-Edge 模式 (内容绘制到系统栏后面)
     * 复制自 Capacitor EdgeToEdge.enable()
     */
    private fun enable() {
        val window = activity.window
        WindowCompat.setDecorFitsSystemWindows(window, false)
        println("[EdgeToEdge] Edge-to-edge mode enabled")
    }

    /**
     * 设置透明系统栏
     * 复制自 Capacitor EdgeToEdge.setTransparentSystemBars()
     */
    private fun setTransparentSystemBars() {
        val window = activity.window

        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT

        // Android 10+ 禁用导航栏对比度保护
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }

        println("[EdgeToEdge] System bars set to transparent")
    }

    /**
     * 设置系统栏图标颜色 (亮色/暗色)
     * 复制自 Capacitor EdgeToEdge.setSystemBarAppearance()
     */
    private fun setSystemBarAppearance() {
        val window = activity.window
        val decorView = window.decorView

        // 根据当前主题设置系统栏图标颜色
        val isDarkTheme = (activity.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES

        WindowCompat.getInsetsController(window, decorView)?.apply {
            // 暗色主题 = 亮色图标, 亮色主题 = 暗色图标
            isAppearanceLightStatusBars = !isDarkTheme
            isAppearanceLightNavigationBars = !isDarkTheme
        }

        println("[EdgeToEdge] System bar appearance set (isDark: $isDarkTheme)")
    }

    /**
     * 周期性注入安全区域（覆盖页面加载过程）
     * 与 iOS 的 startPeriodicInjection 对齐，前 5 秒每 0.5 秒注入一次，之后停止
     */
    private fun startPeriodicInjection() {
        for (i in 1..10) {
            mainHandler.postDelayed({
                // 只在周期性注入未完成且键盘未显示时注入
                if (!periodicInjectionCompleted && !lastKeyboardVisible) {
                    injectSafeAreaToWebView(cachedInsets, false, 0)
                }
                // 最后一次注入后标记完成
                if (i == 10) {
                    periodicInjectionCompleted = true
                }
            }, i * 500L)
        }
    }

    /**
     * 设置键盘动画监听器 (Capacitor 官方 Keyboard 插件方式)
     * 使用 WindowInsetsAnimationCompat.Callback 实现精确的键盘动画追踪
     * 完美复制自 Capacitor EdgeToEdge.setupKeyboardListener()
     */
    private fun setupKeyboardAnimationListener() {
        val content = activity.window.decorView.findViewById<FrameLayout>(android.R.id.content)
        val rootView = content.rootView

        ViewCompat.setWindowInsetsAnimationCallback(
            rootView,
            object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_STOP) {
                override fun onProgress(
                    insets: WindowInsetsCompat,
                    runningAnimations: MutableList<WindowInsetsAnimationCompat>
                ): WindowInsetsCompat {
                    return insets
                }

                override fun onStart(
                    animation: WindowInsetsAnimationCompat,
                    bounds: WindowInsetsAnimationCompat.BoundsCompat
                ): WindowInsetsAnimationCompat.BoundsCompat {
                    val windowInsets = ViewCompat.getRootWindowInsets(rootView)
                    val showingKeyboard = windowInsets?.isVisible(WindowInsetsCompat.Type.ime()) ?: false
                    val imeHeightPx = windowInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0

                    // 转换为 DP
                    val density = activity.resources.displayMetrics.density
                    val imeHeightDp = Math.round(imeHeightPx / density)

                    if (showingKeyboard) {
                        println("[EdgeToEdge] Keyboard will show - Height: ${imeHeightDp}dp")
                        // 键盘将要显示时注入
                        injectSafeAreaToWebView(cachedInsets, true, imeHeightPx)
                    } else {
                        println("[EdgeToEdge] Keyboard will hide")
                        // 键盘将要隐藏时注入
                        injectSafeAreaToWebView(cachedInsets, false, 0)
                    }

                    return super.onStart(animation, bounds)
                }

                override fun onEnd(animation: WindowInsetsAnimationCompat) {
                    super.onEnd(animation)
                    val windowInsets = ViewCompat.getRootWindowInsets(rootView)
                    val showingKeyboard = windowInsets?.isVisible(WindowInsetsCompat.Type.ime()) ?: false
                    val imeHeightPx = windowInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0

                    // 转换为 DP
                    val density = activity.resources.displayMetrics.density
                    val imeHeightDp = Math.round(imeHeightPx / density)

                    lastKeyboardVisible = showingKeyboard
                    lastKeyboardHeight = imeHeightPx

                    if (showingKeyboard) {
                        println("[EdgeToEdge] Keyboard did show - Height: ${imeHeightDp}dp")
                    } else {
                        println("[EdgeToEdge] Keyboard did hide")
                    }

                    // 键盘动画结束后再次注入确保状态正确
                    injectSafeAreaToWebView(cachedInsets, showingKeyboard, imeHeightPx)
                }
            }
        )

        println("[EdgeToEdge] Keyboard animation listener setup complete (Capacitor Keyboard official approach)")
    }

    /**
     * 设置 WindowInsets 监听器
     * 用于获取系统栏 insets 并注入到 WebView
     */
    private fun setupWindowInsetsListener() {
        ViewCompat.setOnApplyWindowInsetsListener(activity.window.decorView) { view, windowInsets ->
            val systemBarsInsets = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars())
            val imeInsets = windowInsets.getInsets(WindowInsetsCompat.Type.ime())
            val imeHeight = imeInsets.bottom
            val isKeyboardVisible = windowInsets.isVisible(WindowInsetsCompat.Type.ime())

            val newInsets = SafeAreaInsets(
                top = systemBarsInsets.top,
                right = systemBarsInsets.right,
                bottom = systemBarsInsets.bottom,
                left = systemBarsInsets.left
            )

            // 缓存 insets
            cachedInsets = newInsets

            // 注入安全区域 (键盘状态由 animation callback 处理，这里只处理系统栏)
            if (!isKeyboardVisible) {
                injectSafeAreaToWebView(cachedInsets, false, 0)
            }

            println("[EdgeToEdge] WindowInsets - Top:${newInsets.top}, Bottom:${newInsets.bottom}, Keyboard:$isKeyboardVisible($imeHeight)")

            windowInsets
        }
    }

    /**
     * 注入安全区域到 WebView
     */
    private fun injectSafeAreaToWebView(
        insets: SafeAreaInsets,
        isKeyboardVisible: Boolean = false,
        keyboardHeight: Int = 0
    ) {
        webView?.let { wv ->
            // 页面尚未加载完成时跳过（documentElement 可能为 null）
            val url = wv.url
            if (url == null || url.isEmpty()) return@let
            val density = activity.resources.displayMetrics.density
            val topDp = insets.top / density
            val rightDp = insets.right / density
            val bottomDp = insets.bottom / density
            val leftDp = insets.left / density
            val keyboardDp = keyboardHeight / density
            val computedBottom = maxOf(bottomDp, 48f)

            val jsCode = """
                (function() {
                    var style = document.documentElement.style;
                    style.setProperty('--safe-area-inset-top', '${topDp}px');
                    style.setProperty('--safe-area-inset-right', '${rightDp}px');
                    style.setProperty('--safe-area-inset-bottom', '${bottomDp}px');
                    style.setProperty('--safe-area-inset-left', '${leftDp}px');
                    style.setProperty('--safe-area-top', '${topDp}px');
                    style.setProperty('--safe-area-right', '${rightDp}px');
                    style.setProperty('--safe-area-bottom', '${bottomDp}px');
                    style.setProperty('--safe-area-left', '${leftDp}px');
                    style.setProperty('--safe-area-bottom-computed', '${computedBottom}px');
                    style.setProperty('--safe-area-bottom-min', '48px');
                    style.setProperty('--content-bottom-padding', '${computedBottom + 16}px');
                    style.setProperty('--keyboard-height', '${keyboardDp}px');
                    style.setProperty('--keyboard-visible', '${if (isKeyboardVisible) "1" else "0"}');
                    window.dispatchEvent(new CustomEvent('safeAreaChanged', {
                        detail: {
                            top: $topDp,
                            right: $rightDp,
                            bottom: $bottomDp,
                            left: $leftDp,
                            keyboardHeight: $keyboardDp,
                            keyboardVisible: $isKeyboardVisible
                        }
                    }));
                })();
            """.trimIndent()

            wv.evaluateJavascript(jsCode, null)
        }
    }

    /**
     * 获取安全区域 insets
     */
    @Command
    fun getSafeAreaInsets(invoke: Invoke) {
        val density = activity.resources.displayMetrics.density
        val decorView = activity.window.decorView
        val windowInsets = ViewCompat.getRootWindowInsets(decorView)

        val result = JSObject()

        if (windowInsets != null) {
            val systemBars = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars())
            val statusBars = windowInsets.getInsets(WindowInsetsCompat.Type.statusBars())
            val navigationBars = windowInsets.getInsets(WindowInsetsCompat.Type.navigationBars())

            result.put("statusBar", statusBars.top / density)
            result.put("navigationBar", navigationBars.bottom / density)
            result.put("top", systemBars.top / density)
            result.put("bottom", systemBars.bottom / density)
            result.put("left", systemBars.left / density)
            result.put("right", systemBars.right / density)
        } else {
            result.put("statusBar", 0)
            result.put("navigationBar", 0)
            result.put("top", cachedInsets.top / density)
            result.put("bottom", cachedInsets.bottom / density)
            result.put("left", cachedInsets.left / density)
            result.put("right", cachedInsets.right / density)
        }

        invoke.resolve(result)
    }

    /**
     * 获取键盘信息
     * 复制自 Capacitor EdgeToEdge.getKeyboardInfo()
     */
    @Command
    fun getKeyboardInfo(invoke: Invoke) {
        val decorView = activity.window.decorView
        val windowInsets = ViewCompat.getRootWindowInsets(decorView)

        val result = JSObject()

        if (windowInsets != null) {
            val imeVisible = windowInsets.isVisible(WindowInsetsCompat.Type.ime())
            val imeHeightPx = windowInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val density = activity.resources.displayMetrics.density
            val imeHeightDp = Math.round(imeHeightPx / density)

            result.put("keyboardHeight", imeHeightDp)
            result.put("isVisible", imeVisible)
        } else {
            result.put("keyboardHeight", 0)
            result.put("isVisible", false)
        }

        invoke.resolve(result)
    }

    @Command
    fun enable(invoke: Invoke) {
        activity.runOnUiThread {
            enable()
            setTransparentSystemBars()
        }
        invoke.resolve()
    }

    @Command
    fun disable(invoke: Invoke) {
        activity.runOnUiThread {
            WindowCompat.setDecorFitsSystemWindows(activity.window, true)
            println("[EdgeToEdge] Edge-to-edge mode disabled")
        }
        invoke.resolve()
    }

    /**
     * 显示键盘
     * 复制自 Capacitor EdgeToEdge.showKeyboard()
     */
    @Command
    fun showKeyboard(invoke: Invoke) {
        activity.runOnUiThread {
            val currentFocus = activity.currentFocus
            if (currentFocus != null) {
                val imm = activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as InputMethodManager
                imm.showSoftInput(currentFocus, 0)
                println("[EdgeToEdge] Keyboard show requested")
            } else {
                println("[EdgeToEdge] Cannot show keyboard - no focused view")
            }
        }
        invoke.resolve()
    }

    /**
     * 隐藏键盘
     * 复制自 Capacitor EdgeToEdge.hideKeyboard()
     */
    @Command
    fun hideKeyboard(invoke: Invoke) {
        activity.runOnUiThread {
            val imm = activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as InputMethodManager
            val currentFocus = activity.currentFocus
            if (currentFocus != null) {
                imm.hideSoftInputFromWindow(currentFocus.windowToken, InputMethodManager.HIDE_NOT_ALWAYS)
                println("[EdgeToEdge] Keyboard hide requested")
            } else {
                println("[EdgeToEdge] Cannot hide keyboard - no focused view")
            }
        }
        invoke.resolve()
    }
}

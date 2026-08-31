package com.plugin.edgetoedge

import android.app.Activity
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.RoundedCorner
import android.view.inputmethod.InputMethodManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsAnimationCompat
import app.tauri.annotation.Command
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import app.tauri.plugin.Invoke
import org.json.JSONObject

private class EdgeToEdgeStateBridge(
    private val onGetState: () -> String,
    private val onRequestState: () -> Unit
) {
    @JavascriptInterface
    fun getState(): String {
        return onGetState.invoke()
    }

    @JavascriptInterface
    fun requestState() {
        onRequestState.invoke()
    }
}

/**
 * Edge-to-Edge 插件 - Android 实现
 * 为 Android 提供全屏沉浸式体验支持
 */
@TauriPlugin
class EdgeToEdgePlugin(private val activity: Activity) : Plugin(activity) {
    companion object {
        private const val NATIVE_BRIDGE_NAME = "__TAURI_EDGE_TO_EDGE_NATIVE__"
        private const val INTERNAL_API_NAME = "__TAURI_EDGE_TO_EDGE_INTERNAL__"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val density = activity.resources.displayMetrics.density
    private val javascriptBridge = EdgeToEdgeStateBridge(::getCachedStateJson, ::injectCurrentState)
    private var webView: WebView? = null

    data class SafeAreaInsets(val top: Int, val right: Int, val bottom: Int, val left: Int)

    private data class NativeState(
        val insets: SafeAreaInsets,
        val keyboardHeight: Int,
        val keyboardVisible: Boolean,
        val screenCornerRadius: Int
    )

    // JavascriptInterface methods run on WebView's bridge thread. A single
    // immutable volatile snapshot prevents mixed values during a refresh.
    @Volatile
    private var cachedState: NativeState? = null

    override fun load(webView: WebView) {
        super.load(webView)
        this.webView = webView

        activity.runOnUiThread {
            // document-start 脚本会在首次加载、刷新和导航时请求最新状态。
            webView.addJavascriptInterface(javascriptBridge, NATIVE_BRIDGE_NAME)

            // 1. 启用 Edge-to-Edge 模式
            enable()

            // 2. 设置透明系统栏
            setTransparentSystemBars()

            // 3. 设置系统栏图标颜色
            setSystemBarAppearance()

            // 4. 设置键盘动画监听器 (Capacitor 官方 Keyboard 插件方式)
            setupKeyboardAnimationListener(webView)

            // 5. 设置 WindowInsets 监听器
            setupWindowInsetsListener(webView)

            // 6. 不等待下一次系统回调，立即读取一次当前状态。
            injectCurrentState()
        }

        println("[EdgeToEdge] Plugin loaded successfully")
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

        WindowCompat.getInsetsController(window, decorView).apply {
            // 暗色主题 = 亮色图标, 亮色主题 = 暗色图标
            isAppearanceLightStatusBars = !isDarkTheme
            isAppearanceLightNavigationBars = !isDarkTheme
        }

        println("[EdgeToEdge] System bar appearance set (isDark: $isDarkTheme)")
    }

    /**
     * 设置键盘动画监听器 (Capacitor 官方 Keyboard 插件方式)
     * 使用 WindowInsetsAnimationCompat.Callback 实现精确的键盘动画追踪
     * 完美复制自 Capacitor EdgeToEdge.setupKeyboardListener()
     */
    private fun setupKeyboardAnimationListener(webView: WebView) {
        ViewCompat.setWindowInsetsAnimationCallback(
            webView,
            object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsetsCompat,
                    runningAnimations: MutableList<WindowInsetsAnimationCompat>
                ): WindowInsetsCompat {
                    publishWindowInsets(insets)
                    return insets
                }

                override fun onStart(
                    animation: WindowInsetsAnimationCompat,
                    bounds: WindowInsetsAnimationCompat.BoundsCompat
                ): WindowInsetsAnimationCompat.BoundsCompat {
                    val windowInsets = ViewCompat.getRootWindowInsets(webView)
                    val showingKeyboard = windowInsets?.isVisible(WindowInsetsCompat.Type.ime()) ?: false
                    val imeHeightPx = windowInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0

                    // 转换为 DP
                    val density = activity.resources.displayMetrics.density
                    val imeHeightDp = Math.round(imeHeightPx / density)

                    if (showingKeyboard) {
                        println("[EdgeToEdge] Keyboard will show - Height: ${imeHeightDp}dp")
                    } else {
                        println("[EdgeToEdge] Keyboard will hide")
                    }

                    if (windowInsets != null) publishWindowInsets(windowInsets)

                    return super.onStart(animation, bounds)
                }

                override fun onEnd(animation: WindowInsetsAnimationCompat) {
                    super.onEnd(animation)
                    val windowInsets = ViewCompat.getRootWindowInsets(webView)
                    val showingKeyboard = windowInsets?.isVisible(WindowInsetsCompat.Type.ime()) ?: false
                    val imeHeightPx = windowInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0

                    // 转换为 DP
                    val density = activity.resources.displayMetrics.density
                    val imeHeightDp = Math.round(imeHeightPx / density)

                    if (showingKeyboard) {
                        println("[EdgeToEdge] Keyboard did show - Height: ${imeHeightDp}dp")
                    } else {
                        println("[EdgeToEdge] Keyboard did hide")
                    }

                    // 动画结束后强制补发最终状态。
                    if (windowInsets != null) publishWindowInsets(windowInsets, force = true)
                }
            }
        )

        println("[EdgeToEdge] Keyboard animation listener setup complete (Capacitor Keyboard official approach)")
    }

    /**
     * 设置 WindowInsets 监听器
     * 用于获取系统栏 insets 并注入到 WebView
     */
    private fun setupWindowInsetsListener(webView: WebView) {
        ViewCompat.setOnApplyWindowInsetsListener(webView) { _, windowInsets ->
            val state = publishWindowInsets(windowInsets)
            println(
                "[EdgeToEdge] WindowInsets - Top:${state.insets.top}, " +
                    "Bottom:${state.insets.bottom}, " +
                    "Keyboard:${state.keyboardVisible}(${state.keyboardHeight})"
            )

            windowInsets
        }

        ViewCompat.requestApplyInsets(webView)
    }

    /**
     * 读取当前窗口状态并注入。document-start bridge 会在每次页面刷新时调用它。
     */
    private fun injectCurrentState() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(::injectCurrentState)
            return
        }

        val decorView = activity.window.decorView
        val windowInsets = ViewCompat.getRootWindowInsets(decorView)
        if (windowInsets == null) {
            // 首次布局尚未完成；系统将在布局时调用上面的 listener。
            ViewCompat.requestApplyInsets(decorView)
            return
        }

        publishWindowInsets(windowInsets, force = true)
    }

    private fun stateFromWindowInsets(windowInsets: WindowInsetsCompat): NativeState {
        // systemBars alone misses a landscape display cutout on some devices.
        val safeInsets = windowInsets.getInsets(
            WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
        )
        val keyboardVisible = windowInsets.isVisible(WindowInsetsCompat.Type.ime())
        val keyboardHeight = if (keyboardVisible) {
            windowInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom
        } else {
            0
        }

        return NativeState(
            insets = SafeAreaInsets(
                top = safeInsets.top,
                right = safeInsets.right,
                bottom = safeInsets.bottom,
                left = safeInsets.left
            ),
            keyboardHeight = keyboardHeight,
            keyboardVisible = keyboardVisible,
            screenCornerRadius = getScreenCornerRadiusPx()
        )
    }

    private fun publishWindowInsets(
        windowInsets: WindowInsetsCompat,
        force: Boolean = false
    ): NativeState {
        val next = stateFromWindowInsets(windowInsets)
        val changed = next != cachedState
        cachedState = next
        if (changed || force) injectStateToWebView(next)
        return next
    }

    /**
     * Android JavascriptInterface 的返回值是同步的。刷新页面时可在 HTML 解析继续前
     * 直接恢复上一次系统确认过的状态。
     */
    private fun getCachedStateJson(): String {
        return cachedState?.let(::createStatePayload)?.toString() ?: ""
    }

    private fun createStatePayload(state: NativeState): JSONObject {
        val topDp = state.insets.top / density
        val rightDp = state.insets.right / density
        val bottomDp = state.insets.bottom / density
        val leftDp = state.insets.left / density
        val keyboardDp = state.keyboardHeight / density
        val computedBottom = if (state.keyboardVisible) 0f else bottomDp
        val screenCornerRadiusDp = state.screenCornerRadius / density

        return JSONObject()
            .put("top", topDp.toDouble())
            .put("right", rightDp.toDouble())
            .put("bottom", bottomDp.toDouble())
            .put("left", leftDp.toDouble())
            .put("bottomComputed", computedBottom.toDouble())
            .put("contentBottomPadding", computedBottom.toDouble())
            .put("screenCornerRadius", screenCornerRadiusDp.toDouble())
            .put("keyboardHeight", keyboardDp.toDouble())
            .put("keyboardVisible", state.keyboardVisible)
    }

    /**
     * Native updates only call the document-start receiver. The receiver owns
     * DOM timing, validation, deduplication and event dispatch.
     */
    private fun injectStateToWebView(state: NativeState) {
        webView?.let { wv ->
            val payload = createStatePayload(state)

            val jsCode = """
                (function() {
                    var api = window.$INTERNAL_API_NAME;
                    if (api && typeof api.update === 'function') api.update($payload);
                })();
            """.trimIndent()

            val evaluate = {
                if (webView === wv) wv.evaluateJavascript(jsCode, null)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) evaluate() else wv.post { evaluate() }
        }
    }

    override fun onResume() {
        super.onResume()
        setSystemBarAppearance()
        injectCurrentState()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        setSystemBarAppearance()
        injectCurrentState()
    }

    override fun onDestroy(activity: AppCompatActivity) {
        mainHandler.removeCallbacksAndMessages(null)
        webView?.let { webView ->
            webView.removeJavascriptInterface(NATIVE_BRIDGE_NAME)
            ViewCompat.setOnApplyWindowInsetsListener(webView, null)
            ViewCompat.setWindowInsetsAnimationCallback(webView, null)
        }
        webView = null
        super.onDestroy(activity)
    }

    /**
     * 读取当前窗口内的设备物理圆角半径（px）。
     *
     * `WindowInsets.getRoundedCorner` 从 Android 12（API 31）开始提供；
     * 更低版本没有公开的等价 API，因此回退为 0。
     */
    private fun getScreenCornerRadiusPx(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return 0
        }

        val windowInsets = activity.window.decorView.rootWindowInsets ?: return 0
        return listOf(
            RoundedCorner.POSITION_TOP_LEFT,
            RoundedCorner.POSITION_TOP_RIGHT,
            RoundedCorner.POSITION_BOTTOM_RIGHT,
            RoundedCorner.POSITION_BOTTOM_LEFT
        ).mapNotNull { position ->
            windowInsets.getRoundedCorner(position)?.radius
        }.maxOrNull() ?: 0
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
            val safeInsets = windowInsets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            )
            val statusBars = windowInsets.getInsets(WindowInsetsCompat.Type.statusBars())
            val navigationBars = windowInsets.getInsets(WindowInsetsCompat.Type.navigationBars())

            result.put("statusBar", statusBars.top / density)
            result.put("navigationBar", navigationBars.bottom / density)
            result.put("top", safeInsets.top / density)
            result.put("bottom", safeInsets.bottom / density)
            result.put("left", safeInsets.left / density)
            result.put("right", safeInsets.right / density)
        } else {
            val fallback = cachedState?.insets ?: SafeAreaInsets(0, 0, 0, 0)
            result.put("statusBar", 0)
            result.put("navigationBar", 0)
            result.put("top", fallback.top / density)
            result.put("bottom", fallback.bottom / density)
            result.put("left", fallback.left / density)
            result.put("right", fallback.right / density)
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
            val imeHeightPx = if (imeVisible) {
                windowInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            } else {
                0
            }
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
            setSystemBarAppearance()
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

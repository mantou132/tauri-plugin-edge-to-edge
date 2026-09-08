# Tauri Plugin Edge-to-Edge

为 Tauri iOS/Android 应用提供 **Edge-to-Edge 全屏沉浸式体验**。

## 功能

- **iOS**: 让 WKWebView 忽略安全区域，内容延伸到状态栏和底部，禁用原生手势导航（防止返回到空白页）
- **Android**: 启用 Edge-to-Edge 模式，透明系统栏
- **首帧 CSS 变量**: 在 HTML 解析前自动注入 `--safe-area-inset-*` 等 CSS 变量
- **刷新自动恢复**: 页面刷新或导航后自动重新读取并注入当前原生 Insets
- **键盘支持**: 监听键盘显示/隐藏，动态更新键盘高度变量

## 安装

### 1. Rust 依赖 (src-tauri/Cargo.toml)

```toml
[dependencies]
tauri-plugin-edge-to-edge = { path = "../tauri-plugin-edge-to-edge" }
```

### 2. 初始化插件 (src-tauri/src/lib.rs)

```rust
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_edge_to_edge::init())
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

## 使用

插件会在 document-start 阶段确保 viewport 含有 `viewport-fit=cover`，让 WebView 在
原生值返回前直接使用浏览器提供的安全区域值。仍建议在应用 HTML 中显式声明：

```html
<meta
  name="viewport"
  content="width=device-width, initial-scale=1.0, viewport-fit=cover"
/>
```

无需在前端调用初始化 API。插件的 document-start 脚本会在首次加载、刷新和导航时先
写入 CSS `env(safe-area-inset-*)`，随后用原生精确值更新。Android 会同步恢复上一次
缓存的原生状态；iOS 首帧先使用 WebKit 的 `env()`，然后通过原生 bridge 更新圆角和
键盘状态。原生值尚未到达时 `--edge-to-edge-ready` 为 `0`，更新完成后为 `1`。

`--safe-area-inset-*` 和 `--safe-area-*` 始终表示未经加工的系统安全区。键盘显示时，
只有用于内容布局的 `--safe-area-bottom-computed` 和 `--content-bottom-padding` 变为
`0px`；插件不再内置 `34px`、`48px` 或额外 `16px` 这类应用层间距。

### CSS 变量

插件自动注入以下 CSS 变量：

| 变量名 | 描述 |
|--------|------|
| `--safe-area-inset-top` | 顶部安全区域 (状态栏) |
| `--safe-area-inset-right` | 右侧安全区域 |
| `--safe-area-inset-bottom` | 底部安全区域 (Home Indicator) |
| `--safe-area-inset-left` | 左侧安全区域 |
| `--safe-area-top/right/bottom/left` | 上述四个值的短别名 |
| `--safe-area-bottom-computed` | 键盘感知的底部安全区 |
| `--content-bottom-padding` | 当前建议的内容底部 padding |
| `--screen-corner-radius` | 屏幕物理圆角半径 |
| `--keyboard-height` | 键盘高度 |
| `--keyboard-visible` | 键盘是否可见 (1/0) |
| `--edge-to-edge-ready` | 是否已收到原生精确值 (1/0) |

### CSS 示例

```css
.app-container {
  padding-top: var(--safe-area-top, 0px);
  padding-bottom: var(--safe-area-bottom-computed, 0px);
}

.bottom-input {
  position: fixed;
  bottom: 0;
  padding-bottom: var(--safe-area-bottom, 0px);
}

.screen-corner-aware {
  border-radius: var(--screen-corner-radius, 0px);
}
```

### 事件监听

```javascript
window.addEventListener('safeAreaChanged', (event) => {
  const {
    top,
    bottom,
    bottomComputed,
    screenCornerRadius,
    keyboardHeight,
    keyboardVisible,
  } = event.detail;
  console.log('Safe area changed:', event.detail);
});
```

首次 `safeAreaChanged` 会延迟到 `DOMContentLoaded`，以便页面模块有时间注册监听器；
后续系统栏和键盘变化会立即触发。

如果需要命令式 API，可使用 npm 包导出的真实插件方法（不再包含脚手架的 `ping`）：

```ts
import {
  getSafeAreaInsets,
  getKeyboardInfo,
  onSafeAreaChanged,
} from 'tauri-plugin-edge-to-edge-api'

const stop = onSafeAreaChanged((state) => console.log(state))
const insets = await getSafeAreaInsets()
```

## 平台支持

| 平台 | 支持 |
|------|------|
| iOS | 按硬件型号注入已验证 iPhone 的圆角半径；未知型号为 `0px`（不使用私有 API） |
| Android | Android 12+ 注入设备圆角半径；低版本为 `0px` |
| macOS/Windows/Linux | (返回默认值)

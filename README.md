# Tauri Plugin Edge-to-Edge

为 Tauri iOS/Android 应用提供 **Edge-to-Edge 全屏沉浸式体验**。

## 功能

- **iOS**: 让 WKWebView 忽略安全区域，内容延伸到状态栏和底部
- **Android**: 启用 Edge-to-Edge 模式，透明系统栏
- **CSS 变量注入**: 自动注入 `--safe-area-inset-*` 等 CSS 变量
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

### CSS 变量

插件自动注入以下 CSS 变量：

| 变量名 | 描述 |
|--------|------|
| `--safe-area-inset-top` | 顶部安全区域 (状态栏) |
| `--safe-area-inset-bottom` | 底部安全区域 (Home Indicator) |
| `--safe-area-top` | 同上（别名） |
| `--safe-area-bottom` | 同上（别名） |
| `--safe-area-bottom-computed` | 计算后的底部区域 |
| `--keyboard-height` | 键盘高度 |
| `--keyboard-visible` | 键盘是否可见 (1/0) |
| `--screen-corner-radius` | 屏幕物理圆角半径（Android 12+；取四个角中的最大值） |

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
  const { top, bottom, screenCornerRadius, keyboardHeight, keyboardVisible } = event.detail;
  console.log('Safe area changed:', event.detail);
});
```

## 平台支持

| 平台 | 支持 |
|------|------|
| iOS | 按硬件型号注入已验证 iPhone 的圆角半径；未知型号为 `0px`（不使用私有 API） |
| Android | Android 12+ 注入设备圆角半径；低版本为 `0px` |
| macOS/Windows/Linux | (返回默认值)

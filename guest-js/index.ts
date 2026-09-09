import { convertFileSrc, invoke } from '@tauri-apps/api/core'

export interface SafeAreaInsets {
  top: number
  right: number
  bottom: number
  left: number
}

export interface KeyboardInfo {
  keyboardHeight: number
  isVisible: boolean
}

export interface EdgeToEdgeState extends SafeAreaInsets {
  bottomComputed: number
  contentBottomPadding: number
  screenCornerRadius: number
  keyboardHeight: number
  keyboardVisible: boolean
}

export const SAFE_AREA_CHANGED_EVENT = 'safeAreaChanged'


/**
 * Converts an HTTPS URL into the host-preserving `webproxy` URL understood by
 * the native protocol handler.
 *
 * Relative URLs inside a proxied HTML document keep working because only the
 * scheme changes logically: `https://example.com/a` -> `webproxy://example.com/a`.
 * On Android/Windows Wry exposes custom protocols through its http(s) workaround
 * (`http(s)://webproxy.example.com/a`); `convertFileSrc` is used only to discover
 * which outer protocol the current WebView was configured to use.
 */
export function toWebproxyUrl(url: string): string {
  const target = new URL(url)
  if (target.protocol !== 'https:') {
    throw new TypeError(`webproxy only supports HTTPS URLs, got ${target.protocol}`)
  }
  if (target.username || target.password) {
    throw new TypeError('webproxy URLs must not contain credentials')
  }
  if (target.hostname.includes(':')) {
    throw new TypeError('webproxy does not currently support IPv6 literal hosts')
  }

  const suffix = `${target.pathname}${target.search}${target.hash}`
  const probe = new URL(convertFileSrc('', 'webproxy'))

  // macOS / iOS / Linux register the real custom scheme.
  if (probe.protocol === 'webproxy:') {
    return `webproxy://${target.host}${suffix}`
  }

  // Android / Windows use Wry's http(s) custom-protocol workaround:
  // webproxy://example.com/a <-> http(s)://webproxy.example.com/a
  return `${probe.protocol}//webproxy.${target.host}${suffix}`
}

export function getSafeAreaInsets(): Promise<SafeAreaInsets> {
  return invoke<SafeAreaInsets>('plugin:edge-to-edge|get_safe_area_insets')
}

export function getKeyboardInfo(): Promise<KeyboardInfo> {
  return invoke<KeyboardInfo>('plugin:edge-to-edge|get_keyboard_info')
}

export function enable(): Promise<void> {
  return invoke<void>('plugin:edge-to-edge|enable')
}

export function disable(): Promise<void> {
  return invoke<void>('plugin:edge-to-edge|disable')
}

export function showKeyboard(): Promise<void> {
  return invoke<void>('plugin:edge-to-edge|show_keyboard')
}

export function hideKeyboard(): Promise<void> {
  return invoke<void>('plugin:edge-to-edge|hide_keyboard')
}

export function onSafeAreaChanged(listener: (state: EdgeToEdgeState) => void): () => void {
  const eventListener: EventListener = (event) => {
    listener((event as CustomEvent<EdgeToEdgeState>).detail)
  }
  window.addEventListener(SAFE_AREA_CHANGED_EVENT, eventListener)
  return () => window.removeEventListener(SAFE_AREA_CHANGED_EVENT, eventListener)
}

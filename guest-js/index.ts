import { invoke } from '@tauri-apps/api/core'

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

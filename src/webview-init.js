// Runs in the main frame at document start on every navigation.
// Native code calls `update` whenever platform geometry changes.
(function () {
  var internalApiName = '__TAURI_EDGE_TO_EDGE_INTERNAL__';
  var nativeBridgeName = '__TAURI_EDGE_TO_EDGE_NATIVE__';
  var safeTop = 'env(safe-area-inset-top, 0px)';
  var safeRight = 'env(safe-area-inset-right, 0px)';
  var safeBottom = 'env(safe-area-inset-bottom, 0px)';
  var safeLeft = 'env(safe-area-inset-left, 0px)';
  var numericKeys = [
    'top',
    'right',
    'bottom',
    'left',
    'bottomComputed',
    'contentBottomPadding',
    'screenCornerRadius',
    'keyboardHeight',
  ];

  var state = {
    top: safeTop,
    right: safeRight,
    bottom: safeBottom,
    left: safeLeft,
    bottomComputed: safeBottom,
    contentBottomPadding: safeBottom,
    screenCornerRadius: 0,
    keyboardHeight: 0,
    keyboardVisible: false,
    ready: false,
  };
  var lastNativeState = null;
  var rootObserver = null;
  var viewportObserver = null;
  var initialNotificationPending = false;

  function cssLength(value) {
    return typeof value === 'number' ? value + 'px' : value;
  }

  function applyState() {
    var root = document.documentElement;
    if (!root) return false;

    var style = root.style;
    style.setProperty('--safe-area-inset-top', cssLength(state.top));
    style.setProperty('--safe-area-inset-right', cssLength(state.right));
    style.setProperty('--safe-area-inset-bottom', cssLength(state.bottom));
    style.setProperty('--safe-area-inset-left', cssLength(state.left));
    style.setProperty('--safe-area-top', cssLength(state.top));
    style.setProperty('--safe-area-right', cssLength(state.right));
    style.setProperty('--safe-area-bottom', cssLength(state.bottom));
    style.setProperty('--safe-area-left', cssLength(state.left));
    style.setProperty('--safe-area-bottom-computed', cssLength(state.bottomComputed));
    style.setProperty('--content-bottom-padding', cssLength(state.contentBottomPadding));
    style.setProperty('--screen-corner-radius', cssLength(state.screenCornerRadius));
    style.setProperty('--keyboard-height', cssLength(state.keyboardHeight));
    style.setProperty('--keyboard-visible', state.keyboardVisible ? '1' : '0');
    style.setProperty('--edge-to-edge-ready', state.ready ? '1' : '0');
    return true;
  }

  function ensureRootState() {
    if (applyState()) {
      if (rootObserver) {
        rootObserver.disconnect();
        rootObserver = null;
      }
      return;
    }

    if (!rootObserver) {
      rootObserver = new MutationObserver(ensureRootState);
      rootObserver.observe(document, { childList: true });
    }
  }

  function ensureViewportFit() {
    if (!document.head) return;

    var candidates = document.head.querySelectorAll('meta[name]');
    var found = false;
    for (var i = 0; i < candidates.length; i += 1) {
      var meta = candidates[i];
      if ((meta.getAttribute('name') || '').toLowerCase() !== 'viewport') continue;

      found = true;
      var content = meta.getAttribute('content') || '';
      if (/viewport-fit\s*=/i.test(content)) {
        var next = content.replace(/viewport-fit\s*=\s*[^,\s]+/gi, 'viewport-fit=cover');
        if (next !== content) meta.setAttribute('content', next);
      } else {
        meta.setAttribute('content', content ? content + ', viewport-fit=cover' : 'viewport-fit=cover');
      }
    }

    if (!found) {
      var viewport = document.createElement('meta');
      viewport.setAttribute('name', 'viewport');
      viewport.setAttribute('content', 'width=device-width, initial-scale=1.0, viewport-fit=cover');
      document.head.insertBefore(viewport, document.head.firstChild);
    }
  }

  function observeViewport() {
    ensureViewportFit();
    viewportObserver = new MutationObserver(ensureViewportFit);
    viewportObserver.observe(document, {
      attributes: true,
      attributeFilter: ['content', 'name'],
      childList: true,
      subtree: true,
    });
    document.addEventListener(
      'DOMContentLoaded',
      function () {
        ensureViewportFit();
        viewportObserver.disconnect();
        viewportObserver = null;
      },
      { once: true }
    );
  }

  function dispatchChange() {
    if (!lastNativeState) return;
    window.dispatchEvent(
      new CustomEvent('safeAreaChanged', {
        detail: Object.freeze({
          top: lastNativeState.top,
          right: lastNativeState.right,
          bottom: lastNativeState.bottom,
          left: lastNativeState.left,
          bottomComputed: lastNativeState.bottomComputed,
          contentBottomPadding: lastNativeState.contentBottomPadding,
          screenCornerRadius: lastNativeState.screenCornerRadius,
          keyboardHeight: lastNativeState.keyboardHeight,
          keyboardVisible: lastNativeState.keyboardVisible,
        }),
      })
    );
  }

  function notifyChange() {
    // Give application modules a chance to register their initial listener.
    if (document.readyState === 'loading') {
      if (!initialNotificationPending) {
        initialNotificationPending = true;
        document.addEventListener(
          'DOMContentLoaded',
          function () {
            initialNotificationPending = false;
            Promise.resolve().then(dispatchChange);
          },
          { once: true }
        );
      }
    } else {
      dispatchChange();
    }
  }

  function isFiniteNumber(value) {
    return typeof value === 'number' && isFinite(value);
  }

  function update(next) {
    if (!next || typeof next !== 'object') return;
    for (var i = 0; i < numericKeys.length; i += 1) {
      if (!isFiniteNumber(next[numericKeys[i]])) return;
    }
    if (typeof next.keyboardVisible !== 'boolean') return;

    var changed = !lastNativeState;
    if (!changed) {
      for (var j = 0; j < numericKeys.length; j += 1) {
        var key = numericKeys[j];
        if (lastNativeState[key] !== next[key]) {
          changed = true;
          break;
        }
      }
      if (lastNativeState.keyboardVisible !== next.keyboardVisible) changed = true;
    }

    lastNativeState = {
      top: next.top,
      right: next.right,
      bottom: next.bottom,
      left: next.left,
      bottomComputed: next.bottomComputed,
      contentBottomPadding: next.contentBottomPadding,
      screenCornerRadius: next.screenCornerRadius,
      keyboardHeight: next.keyboardHeight,
      keyboardVisible: next.keyboardVisible,
    };
    state = {
      top: next.top,
      right: next.right,
      bottom: next.bottom,
      left: next.left,
      bottomComputed: next.bottomComputed,
      contentBottomPadding: next.contentBottomPadding,
      screenCornerRadius: next.screenCornerRadius,
      keyboardHeight: next.keyboardHeight,
      keyboardVisible: next.keyboardVisible,
      ready: true,
    };
    ensureRootState();
    if (changed) notifyChange();
  }

  Object.defineProperty(window, internalApiName, {
    value: Object.freeze({ update: update }),
    configurable: false,
    enumerable: false,
    writable: false,
  });

  function requestNativeState() {
    try {
      var androidBridge = window[nativeBridgeName];
      if (androidBridge) {
        if (typeof androidBridge.getState === 'function') {
          var cachedState = androidBridge.getState();
          if (cachedState) update(JSON.parse(cachedState));
        }
        if (typeof androidBridge.requestState === 'function') androidBridge.requestState();
      }
    } catch (_) {
      // The bridge can be absent during the first native setup tick.
    }

    try {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var iosBridge = handlers && handlers[nativeBridgeName];
      if (iosBridge) iosBridge.postMessage('requestState');
    } catch (_) {
      // The bridge can be absent during the first native setup tick.
    }
  }

  observeViewport();
  ensureRootState();
  requestNativeState();
  document.addEventListener('DOMContentLoaded', requestNativeState, { once: true });
  window.addEventListener('pageshow', requestNativeState);
})();

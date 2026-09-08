import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../src/webview-init.js', import.meta.url), 'utf8');

function start(platform, readyState = 'loading') {
  const listeners = new Map();
  const messages = [];
  const window = {
    addEventListener(name, callback, options) { listeners.set(name, { callback, options }); },
  };
  if (platform === 'android') {
    window.__TAURI_EDGE_TO_EDGE_NATIVE__ = {
      requestState() {},
      pageLoaded() { messages.push('pageLoaded'); },
    };
  } else {
    window.webkit = { messageHandlers: {
      __TAURI_EDGE_TO_EDGE_NATIVE__: { postMessage(value) { messages.push(value); } },
    } };
  }
  const document = {
    readyState,
    documentElement: { style: { setProperty() {} } },
    head: { querySelectorAll() { return [{
      getAttribute(name) { return name === 'name' ? 'viewport' : 'viewport-fit=cover'; },
    }]; } },
    addEventListener() {},
  };
  runInNewContext(source, {
    window, document,
    MutationObserver: class { observe() {} disconnect() {} },
  });
  return { messages, fire(name) {
    const listener = listeners.get(name);
    if (!listener) return;
    if (listener.options?.once) listeners.delete(name);
    listener.callback();
  } };
}

for (const platform of ['android', 'ios']) {
  test(`${platform}: launch screen waits for load and is dismissed once`, () => {
    const page = start(platform);
    const loaded = () => page.messages.filter((message) => message === 'pageLoaded');
    assert.equal(loaded().length, 0);
    page.fire('pageshow');
    assert.equal(loaded().length, 0);
    page.fire('load');
    assert.equal(loaded().length, 1);
    page.fire('load');
    page.fire('pageshow');
    assert.equal(loaded().length, 1);
  });
  test(`${platform}: an already loaded page dismisses the launch screen`, () => {
    const page = start(platform, 'complete');
    assert.equal(page.messages.filter((message) => message === 'pageLoaded').length, 1);
  });
}

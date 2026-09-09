
(() => {
  if (window.__webproxyStateBridgeInstalled) return;
  Object.defineProperty(window, "__webproxyStateBridgeInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
    writable: false,
  });

  const toWebproxyUrl = (value) => {
    try {
      const url = new URL(value, document.baseURI);
      if (url.protocol === "https:" && location.protocol === "webproxy:") {
        return `webproxy://${url.host}${url.pathname}${url.search}${url.hash}`;
      }
      return url.href;
    } catch {
      return String(value);
    }
  };

  const postState = (url, target) => {
    if (parent === window) return;
    parent.postMessage(
      {
        type: "next_state",
        state: {
          url: toWebproxyUrl(url),
          title: document.title,
          target,
        },
      },
      "*",
    );
  };

  const resolveUrl = (value) => {
    try {
      return new URL(value, document.baseURI).href;
    } catch {
      return String(value);
    }
  };

  window.open = function (url, target) {
    const normalizedTarget = !target || target === "_self" ? "" : "_blank";
    postState(resolveUrl(url == null ? "about:blank" : String(url)), normalizedTarget);
    return null;
  };

  addEventListener(
    "click",
    (event) => {
      const path = typeof event.composedPath === "function" ? event.composedPath() : [];
      const anchor =
        path.find(
          (node) =>
            node instanceof HTMLAnchorElement &&
            node.hasAttribute("href"),
        ) ||
        (event.target instanceof Element
          ? event.target.closest('a[href]')
          : null);

      if (!anchor) return;

      const target = !anchor.target || anchor.target === "_self" ? "" : "_blank";
      event.preventDefault();
      postState(anchor.href, target);
    },
    true,
  );

  let lastTitle = document.title;
  const observeTitle = () => {
    const title = document.title;
    if (title === lastTitle) return;
    lastTitle = title;
    postState(location.href, "");
  };

  const observer = new MutationObserver(observeTitle);
  const head = document.head;
  if (head) {
    observer.observe(head, {
      subtree: true,
      childList: true,
      characterData: true,
    });
  }
})();

(() => {
  const route = /^\/a\/chat\/s\/([0-9a-f-]{36})$/i;
  const stopLabel = /停止生成|停止回答|停止响应|Stop generating|Stop response/i;
  let conversationID = null;
  let sawWorking = false;
  let missingSince = 0;
  let lastFingerprint = "";
  let lastSent = 0;
  let scheduled = false;

  function hasVisibleStopControl() {
    return [...document.querySelectorAll('[role="button"],button')].some(element => {
      if (!element.getClientRects().length) return false;
      const label = ["aria-label", "title", "data-tooltip"].map(name => element.getAttribute(name) || "").join(" ");
      return stopLabel.test(label + " " + (element.textContent || ""));
    });
  }

  function currentTitle(id) {
    const link = [...document.querySelectorAll('a[href*="/a/chat/s/"]')].find(element => {
      try { return new URL(element.getAttribute("href"), location.href).pathname.endsWith("/" + id); }
      catch { return false; }
    });
    return (link?.textContent || "DeepSeek 会话").trim().slice(0, 100);
  }

  function emit() {
    scheduled = false;
    const match = location.pathname.match(route);
    const nextID = match?.[1] || null;
    if (nextID !== conversationID) {
      if (conversationID) chrome.runtime.sendMessage({ kind: "close" });
      conversationID = nextID;
      sawWorking = false;
      missingSince = 0;
      lastFingerprint = "";
    }
    if (!conversationID) return;

    const running = hasVisibleStopControl();
    let state = "unknown";
    if (running) {
      sawWorking = true;
      missingSince = 0;
      state = "working";
    } else if (sawWorking) {
      if (!missingSince) missingSince = Date.now();
      state = Date.now() - missingSince >= 1500 ? "ended" : "working";
    }

    const title = currentTitle(conversationID);
    const fingerprint = `${conversationID}:${title}:${state}`;
    if (fingerprint !== lastFingerprint || Date.now() - lastSent > 10000) {
      lastFingerprint = fingerprint;
      lastSent = Date.now();
      chrome.runtime.sendMessage({ kind: "snapshot", conversationID, title, state });
    }
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(emit, 150);
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true, childList: true, attributes: true,
    attributeFilter: ["aria-label", "title", "class", "style"]
  });
  setInterval(emit, 1000);
  schedule();
})();

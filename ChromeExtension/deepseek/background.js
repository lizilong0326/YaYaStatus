const host = "com.local.yayastatus.deepseek";

chrome.runtime.onMessage.addListener((message, sender) => {
  if (!sender.tab?.id || sender.origin !== "https://chat.deepseek.com") return;
  if (message?.kind !== "snapshot" && message?.kind !== "close") return;
  const payload = { ...message, tabID: sender.tab.id };
  chrome.runtime.sendNativeMessage(host, payload, () => {
    // The app reports a missing bridge until its native host is installed.
    void chrome.runtime.lastError;
  });
});

chrome.tabs.onRemoved.addListener(tabID => {
  chrome.runtime.sendNativeMessage(host, { kind: "close", tabID }, () => {
    void chrome.runtime.lastError;
  });
});

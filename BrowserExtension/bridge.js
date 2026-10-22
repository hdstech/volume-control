// Isolated-world relay: page.js can't reach extension APIs, so gain changes arrive here and are
// forwarded to it as a DOM event. Injecting it twice is harmless; both copies forward the same value.
(() => {
  const forwardGain = (gain) => {
    document.dispatchEvent(new CustomEvent("volumecontrol:gain", { detail: gain }));
  };

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "gain") return false;
    forwardGain(message.gain);
    sendResponse({ applied: true });
    return false;
  });

  chrome.runtime
    .sendMessage({ type: "hello" })
    .then((response) => {
      if (typeof response?.gain === "number" && response.gain !== 1) forwardGain(response.gain);
    })
    .catch(() => {});
})();

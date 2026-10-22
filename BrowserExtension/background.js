// Keeps a native-messaging connection to the Volume Control app, reports audible tabs to it,
// and applies the per-tab volume and mute changes it sends back.
const HOST_NAME = "com.hdstech.volumecontrol";
const MAX_RECONNECT_DELAY = 30_000;

let port = null;
let reconnectDelay = 1_000;
let publishTimer = null;

// Slider position (0...1) per tab. Tabs at 1 are not stored. Session storage survives the service
// worker being suspended but not a browser restart, which matches tab lifetimes.
const volumes = new Map();
const loaded = chrome.storage.session.get("volumes").then(({ volumes: saved }) => {
  for (const [tabId, volume] of Object.entries(saved ?? {})) volumes.set(Number(tabId), volume);
});

const saveVolumes = () => chrome.storage.session.set({ volumes: Object.fromEntries(volumes) });
const sliderValue = (tabId) => volumes.get(tabId) ?? 1;
// Same square taper as the app's own sliders.
const gainFor = (tabId) => sliderValue(tabId) ** 2;

const hostOf = (url) => {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
};

const usableFavicon = (url) => (url && /^(https?|data):/.test(url) ? url : null);

async function publish() {
  publishTimer = null;
  if (!port) return;
  await loaded;
  const tabs = await chrome.tabs.query({});
  const listed = tabs
    .filter((tab) => tab.audible || volumes.has(tab.id))
    .map((tab) => ({
      id: tab.id,
      title: tab.title || hostOf(tab.url) || "Untitled",
      host: hostOf(tab.url),
      audible: Boolean(tab.audible),
      muted: Boolean(tab.mutedInfo?.muted),
      volume: sliderValue(tab.id),
      favIconUrl: usableFavicon(tab.favIconUrl),
    }));
  port?.postMessage({ type: "tabs", tabs: listed });
}

function schedulePublish() {
  if (publishTimer) return;
  publishTimer = setTimeout(publish, 100);
}

async function setVolume(tabId, volume) {
  await loaded;
  const clamped = Math.min(1, Math.max(0, Number(volume)));
  if (!Number.isFinite(clamped)) return;
  if (clamped === 1) volumes.delete(tabId);
  else volumes.set(tabId, clamped);
  saveVolumes();
  await sendGain(tabId);
  schedulePublish();
}

// Content scripts only load into pages opened after the extension was installed or reloaded,
// so tabs that predate it get the scripts injected here.
async function injectInto(tabId) {
  const target = { tabId, allFrames: true };
  await chrome.scripting.executeScript({ target, files: ["page.js"], world: "MAIN", injectImmediately: true });
  await chrome.scripting.executeScript({ target, files: ["bridge.js"], injectImmediately: true });
}

async function sendGain(tabId) {
  const message = { type: "gain", gain: gainFor(tabId) };
  try {
    await chrome.tabs.sendMessage(tabId, message);
  } catch {
    try {
      await injectInto(tabId);
      await chrome.tabs.sendMessage(tabId, message);
    } catch (error) {
      console.warn(`Volume Control: can't adjust tab ${tabId}`, error);
    }
  }
}

async function injectIntoOpenTabs() {
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*", "file://*/*"] });
  await Promise.allSettled(tabs.map((tab) => injectInto(tab.id)));
}

function handleAppMessage(message) {
  switch (message?.type) {
    case "requestState":
      schedulePublish();
      break;
    case "setVolume":
      setVolume(message.tabId, message.volume);
      break;
    case "setMuted":
      chrome.tabs.update(message.tabId, { muted: Boolean(message.muted) }).catch(() => {});
      break;
  }
}

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch {
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener((message) => {
    reconnectDelay = 1_000;
    handleAppMessage(message);
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = null;
    scheduleReconnect();
  });
  schedulePublish();
}

function scheduleReconnect() {
  setTimeout(connect, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "hello" || !sender.tab) return false;
  loaded.then(() => sendResponse({ gain: gainFor(sender.tab.id) }));
  return true;
});

chrome.tabs.onUpdated.addListener((_tabId, change) => {
  if ("audible" in change || "mutedInfo" in change || "title" in change || "favIconUrl" in change) {
    schedulePublish();
  }
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  await loaded;
  if (volumes.delete(tabId)) saveVolumes();
  schedulePublish();
});

chrome.tabs.onReplaced.addListener(() => schedulePublish());
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(() => {
  connect();
  injectIntoOpenTabs();
});
connect();

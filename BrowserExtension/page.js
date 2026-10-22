// Runs in the page's own JavaScript world so it can scale every sound source in the tab:
// - <audio>/<video>: the page keeps seeing the volume it set; the element plays at pageVolume × gain.
// - Web Audio: anything connected to a context's destination goes through one gain node per context.
(() => {
  if (window.__volumeControlInstalled) return;
  Object.defineProperty(window, "__volumeControlInstalled", { value: true });

  let gain = 1;

  const volume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
  const pageVolumes = new WeakMap();
  const mediaElements = new Set();

  const track = (element) => {
    if (pageVolumes.has(element)) return;
    pageVolumes.set(element, volume.get.call(element));
    mediaElements.add(new WeakRef(element));
  };

  const apply = (element) => {
    const pageVolume = pageVolumes.get(element) ?? volume.get.call(element);
    volume.set.call(element, Math.min(1, Math.max(0, pageVolume * gain)));
  };

  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    enumerable: volume.enumerable,
    get() {
      return pageVolumes.has(this) ? pageVolumes.get(this) : volume.get.call(this);
    },
    set(value) {
      const number = Number(value);
      if (!(number >= 0 && number <= 1)) {
        volume.set.call(this, value); // Let the browser throw its usual error.
        return;
      }
      track(this);
      pageVolumes.set(this, number);
      apply(this);
    },
  });

  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    track(this);
    apply(this);
    return play.apply(this, args);
  };

  // Autoplaying elements start without a play() call.
  document.addEventListener(
    "play",
    (event) => {
      if (event.target instanceof HTMLMediaElement) {
        track(event.target);
        apply(event.target);
      }
    },
    true
  );

  const masters = new WeakMap();
  const contexts = new Set();
  const connect = AudioNode.prototype.connect;
  const disconnect = AudioNode.prototype.disconnect;
  const isLive = (context) => typeof OfflineAudioContext === "undefined" || !(context instanceof OfflineAudioContext);

  const masterFor = (context) => {
    let node = masters.get(context);
    if (!node) {
      node = context.createGain();
      node.gain.value = gain;
      connect.call(node, context.destination);
      masters.set(context, node);
      contexts.add(new WeakRef(context));
    }
    return node;
  };

  AudioNode.prototype.connect = function (destination, ...rest) {
    if (destination instanceof AudioDestinationNode && isLive(destination.context)) {
      connect.call(this, masterFor(destination.context), ...rest);
      return destination;
    }
    return connect.call(this, destination, ...rest);
  };

  AudioNode.prototype.disconnect = function (destination, ...rest) {
    if (destination instanceof AudioDestinationNode && masters.has(destination.context)) {
      return disconnect.call(this, masters.get(destination.context), ...rest);
    }
    return disconnect.apply(this, arguments);
  };

  const setGain = (value) => {
    if (!Number.isFinite(value) || value < 0) return;
    gain = value;
    // Picks up elements that existed before this script was injected into an already-open page.
    for (const element of document.querySelectorAll("audio, video")) track(element);
    for (const ref of mediaElements) {
      const element = ref.deref();
      if (element) apply(element);
      else mediaElements.delete(ref);
    }
    for (const ref of contexts) {
      const context = ref.deref();
      const node = context && masters.get(context);
      if (node) node.gain.setTargetAtTime(gain, context.currentTime, 0.015);
      else contexts.delete(ref);
    }
  };

  document.addEventListener("volumecontrol:gain", (event) => setGain(Number(event.detail)));
})();

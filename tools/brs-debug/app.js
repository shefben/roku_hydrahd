/*
 * HydraHD brs-engine debug harness - boot logic + automation hooks.
 *
 * Everything the Chrome-driving skill needs is exposed on `window`:
 *   window.__brsStatus    - "booting" | "loaded" | "started" | "closed" | "error:<msg>"
 *   window.__brsReady     - true once the channel's MainScene has started
 *   window.__brsEvents    - [{ id, data, t }]   every engine lifecycle event
 *   window.__brsConsole   - ring buffer of console output (BrightScript print + errors)
 *   window.brsKey(name, delayMs)   - send one remote keypress (returns true/false)
 *   window.brsKeys(seq, gapMs)     - send a sequence (array or "up up select"), returns Promise
 *   window.brsShot()      - returns a full-resolution PNG data URL of the current frame (or null)
 *   window.brsState()     - returns { status, ready, lastError, eventCount, consoleTail }
 *   window.brsErrors()    - returns array of captured error/crash lines
 *
 * Remote key names accepted (aliases map to brs-engine ECP names):
 *   up down left right | select/ok/enter | back/esc | home |
 *   info/options/star | play/pause | rev/rewind | fwd/forward | replay/instantreplay
 */
(function () {
  "use strict";

  // ---- console capture (BrightScript print + engine errors land here) ----------
  var CONSOLE_MAX = 2000;
  window.__brsConsole = [];
  (function patchConsole() {
    ["log", "info", "warn", "error", "debug"].forEach(function (level) {
      var orig = console[level] ? console[level].bind(console) : function () {};
      console[level] = function () {
        try {
          var line =
            "[" + level + "] " +
            Array.prototype.map
              .call(arguments, function (a) {
                if (typeof a === "string") return a;
                try { return JSON.stringify(a); } catch (e) { return String(a); }
              })
              .join(" ");
          window.__brsConsole.push(line);
          if (window.__brsConsole.length > CONSOLE_MAX) window.__brsConsole.shift();
        } catch (e) { /* never let logging throw */ }
        orig.apply(null, arguments);
      };
    });
  })();

  window.addEventListener("error", function (e) {
    window.__brsConsole.push("[window.error] " + (e && e.message ? e.message : String(e)));
  });
  window.addEventListener("unhandledrejection", function (e) {
    window.__brsConsole.push("[promise.reject] " + (e && e.reason ? e.reason : String(e)));
  });

  // ---- state ------------------------------------------------------------------
  window.__brsStatus = "booting";
  window.__brsReady = false;
  window.__brsEvents = [];
  window.__brsLastError = "";

  var statusEl = document.getElementById("status");
  function setStatus(s) {
    window.__brsStatus = s;
    if (statusEl) statusEl.textContent = s;
  }

  var params = new URLSearchParams(location.search);
  if (params.get("status") === "1") document.body.classList.add("show-status");
  var ZIP_URL = params.get("zip") || "channel/HydraHD.zip";

  if (typeof window.brs === "undefined") {
    setStatus("error: brs.api.js failed to load");
    return;
  }
  var brs = window.brs;
  window.__brs = brs;

  // ---- remote key name normalisation -----------------------------------------
  var KEY_ALIASES = {
    up: "up", down: "down", left: "left", right: "right",
    ok: "select", enter: "select", select: "select",
    esc: "back", back: "back",
    home: "home",
    info: "info", options: "info", star: "info", "*": "info",
    play: "play", pause: "play",
    rev: "rev", rewind: "rev",
    fwd: "fwd", forward: "fwd",
    replay: "instantreplay", instantreplay: "instantreplay",
  };
  function normKey(name) {
    if (!name) return null;
    var k = String(name).toLowerCase().trim();
    return KEY_ALIASES[k] || k;
  }

  window.brsKey = function (name, delayMs) {
    var k = normKey(name);
    if (!k) return false;
    try {
      brs.sendKeyPress(k, typeof delayMs === "number" ? delayMs : 300);
      window.__brsConsole.push("[key] " + k);
      return true;
    } catch (e) {
      window.__brsConsole.push("[key.error] " + name + " -> " + e);
      return false;
    }
  };

  window.brsKeys = function (seq, gapMs) {
    var list = Array.isArray(seq) ? seq.slice() : String(seq).split(/\s+/);
    var gap = typeof gapMs === "number" ? gapMs : 600;
    return new Promise(function (resolve) {
      var i = 0;
      (function step() {
        if (i >= list.length) return resolve(true);
        window.brsKey(list[i++]);
        setTimeout(step, gap);
      })();
    });
  };

  // ---- screenshot (full internal resolution, independent of CSS scale) --------
  window.brsShot = function () {
    try {
      var img = brs.getScreenshot();
      if (!img) return null;
      var c = document.createElement("canvas");
      c.width = img.width;
      c.height = img.height;
      c.getContext("2d").putImageData(img, 0, 0);
      return c.toDataURL("image/png");
    } catch (e) {
      window.__brsConsole.push("[shot.error] " + e);
      return null;
    }
  };

  window.brsErrors = function () {
    return window.__brsConsole.filter(function (l) {
      return /\[error\]|\[window\.error\]|\[promise\.reject\]|BRIGHTSCRIPT|runtime error|Syntax Error|crash|\berror\b/i.test(l);
    });
  };

  window.brsState = function () {
    return {
      status: window.__brsStatus,
      ready: window.__brsReady,
      lastError: window.__brsLastError,
      eventCount: window.__brsEvents.length,
      consoleTail: window.__brsConsole.slice(-40),
    };
  };

  // ---- boot the engine --------------------------------------------------------
  function record(id, data) {
    window.__brsEvents.push({ id: id, data: data, t: Date.now() });
  }

  brs.subscribe("harness", function (id, data) {
    record(id, data);
    switch (id) {
      case "loaded":
        setStatus("loaded");
        break;
      case "started":
        window.__brsReady = true;
        setStatus("started");
        break;
      case "closed":
        setStatus("closed" + (data ? ": " + data : ""));
        break;
      case "error":
        window.__brsLastError = String(data);
        setStatus("error: " + data);
        break;
      default:
        // resolution / redraw / control / debug / icon / registry ... kept in __brsEvents
        break;
    }
  });

  var SG = (brs.SupportedExtension && brs.SupportedExtension.SceneGraph) || "brs-scenegraph";

  // deviceData mirrors the known-good wiring from the official simulator
  // (lvcabral.com/brs/). developerId + execSource:"auto-run-dev" are what make
  // the engine AUTO-RUN the package instead of just registering it.
  var deviceData = {
    developerId: "hydrahd-debug",
    locale: "en_US",
    displayMode: "1080p",            // channel manifest is ui_resolutions=fhd
    maxFps: 30,
    appList: [],
    extensions: new Map([[SG, "./brs-sg.js"]]),
  };

  // CORS proxy lets the emulated channel fetch real hydrahd data so rows,
  // posters and detail pages render (needed to debug navigation/layout with
  // real content). Served by serve.js at /proxy/. Disable with ?proxy=0.
  if (params.get("proxy") !== "0") {
    deviceData.corsProxy = location.origin + "/proxy/";
  }

  function waitFor(predicate, timeoutMs, intervalMs) {
    return new Promise(function (resolve) {
      var deadline = performance.now() + (timeoutMs || 15000);
      (function poll() {
        var ok = false;
        try { ok = !!predicate(); } catch (e) {}
        if (ok) return resolve(true);
        if (performance.now() > deadline) return resolve(false);
        setTimeout(poll, intervalMs || 100);
      })();
    });
  }

  (async function run() {
    try {
      setStatus("initializing engine…");
      await brs.initialize(deviceData, {
        debugToConsole: true,
        disableKeys: false,           // let real keyboard events drive the remote
        showStats: false,
      });
      try { if (brs.setDisplayMode) brs.setDisplayMode("1080p"); } catch (e) {}

      // initialize() kicks off an ASYNC fetch of assets/common.zip but does not
      // await it. Executing before the common: volume (fonts, etc.) is loaded
      // crashes the channel ("Error setting up file system / -22 ... default-fonts.json").
      // Wait until deviceData.assets is populated before running.
      setStatus("loading engine assets (common.zip)…");
      var assetsOk = await waitFor(function () {
        return brs.deviceData && brs.deviceData.assets && brs.deviceData.assets.byteLength > 0;
      }, 15000, 100);
      window.__brsConsole.push("[harness] engine assets ready: " + assetsOk +
        " (" + (brs.deviceData && brs.deviceData.assets ? brs.deviceData.assets.byteLength : 0) + " bytes)");

      setStatus("fetching channel: " + ZIP_URL);
      var resp = await fetch(ZIP_URL, { cache: "no-store" });
      if (!resp.ok) throw new Error("fetch " + ZIP_URL + " -> HTTP " + resp.status);
      var buf = await resp.arrayBuffer();   // raw ArrayBuffer - engine expects this, NOT a typed array
      window.__brsConsole.push("[harness] channel zip bytes: " + buf.byteLength);

      setStatus("executing channel…");
      try { if (brs.setDebugState) brs.setDebugState(true); } catch (e) {}
      brs.execute("HydraHD.zip", buf, {
        clearDisplayOnExit: false,
        muteSound: true,
        execSource: "auto-run-dev",   // <-- auto-run the package (the missing piece)
        debugOnCrash: true,
      });
      // engine fires "loaded" then "started" via the subscription above.
    } catch (e) {
      window.__brsLastError = String(e && e.stack ? e.stack : e);
      setStatus("error: " + (e && e.message ? e.message : e));
      window.__brsConsole.push("[harness.error] " + window.__brsLastError);
    }
  })();
})();

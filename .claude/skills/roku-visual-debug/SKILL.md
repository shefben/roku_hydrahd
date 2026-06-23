---
name: roku-visual-debug
description: >
  Run the HydraHD Roku channel in a real Chrome browser via the brs-engine
  simulator, navigate it like a remote, and screenshot every view to find
  visual bugs, text overlaps/clipping, layout inconsistencies, broken
  navigation/focus, and BrightScript runtime errors. Use this when asked to
  visually debug the channel, verify a UI/navigation fix, check a screen's
  layout, or develop/QA a new view without a physical Roku device.
---

# Roku Visual Debug (brs-engine + Chrome)

This skill renders the channel in [brs-engine](https://github.com/lvcabral/brs-engine)
inside Chrome (driven with the Playwright MCP tools), so you can navigate the UI
with the remote, screenshot each view, read BrightScript runtime errors, and
report visual/navigation problems. Harness lives in `tools/brs-debug/`.

It is useful for **both debugging and feature development**: render the current
state, make a change, run `rebuild.ps1`, refresh, and screenshot the result.

## 0. Prerequisites (one-time)

```bash
cd tools/brs-debug && npm install     # installs brs-engine + brs-scenegraph
```
If `tools/brs-debug/lib/brs.api.js` and `assets/common.zip` already exist, skip this.

## 1. Build + serve

```powershell
# from tools/brs-debug
./rebuild.ps1          # builds channel zip + stages it into channel/HydraHD.zip
```
Start the server in the background (leave it running for the whole session):
```bash
# Bash tool, run_in_background: true  — from tools/brs-debug
node serve.js
```
It serves `http://127.0.0.1:6502/` with the COOP/COEP isolation headers the
engine needs, plus a `/proxy/` CORS proxy so the channel loads real hydrahd data.

> After editing any `source/` or `components/` file: re-run `./rebuild.ps1` and
> refresh the browser tab. No server restart needed (zip is served no-cache).
> Only restart `node serve.js` if you change `serve.js` / `app.js` / `index.html`.

## 2. Open it in Chrome (Playwright MCP)

If the `mcp__playwright__*` tools are deferred, load them first with ToolSearch.

1. `mcp__playwright__browser_navigate` → `http://127.0.0.1:6502/?status=1`
2. `mcp__playwright__browser_wait_for` → ~8 seconds (SceneGraph parse + first fetch)
3. Confirm it booted: `mcp__playwright__browser_evaluate` with
   `() => window.brsState()` → expect `status:"started"`, `ready:true`.
   If `status` is still `"loaded"`, wait longer; if `closed: EXIT_BRIGHTSCRIPT_CRASH`,
   read the worker console (step 4) for the backtrace.

URL flags: `?status=1` shows the status line · `?proxy=0` runs offline ·
`?zip=channel/<other>.zip` loads a different package.

## 3. Navigate like a remote

Drive with `browser_evaluate` calling the hooks `app.js` exposes:

```js
() => { window.brsKey("right"); }                 // single key
async () => { await window.brsKeys("down down select", 600); }  // a sequence
```

Keys: `up down left right · select`(=OK) `· back · home · info`(=`*`/options)
`· play · rev fwd · replay`. Real keyboard events also work (`browser_press_key`).

**Reliable navigation paths in this engine build** (see quirks below):
- **BACK** on any root view opens the side drawer (Close / Search / Favorites /
  Browse Movies / Browse TV Shows / Options / Home / Exit).
- Inside the **Movies/TV/Trending grid**, **LEFT at the first column** opens the
  drawer too.
- The drawer's **ButtonGroup** selection works; switch tabs via the drawer
  rather than the top-bar buttons (standalone `Button.buttonSelected` is flaky
  in this alpha build).
- From a poster, **OK** opens DetailsView; **UP** lifts focus to the top bar.

A good tour: Home rows → Movies grid → open a poster (DetailsView) → BACK →
drawer → Browse TV Shows → Search → Favorites → Options(Settings).

## 4. Capture evidence

- **Screenshot:** `mcp__playwright__browser_take_screenshot`
  (`filename:"screenshots/<view>.png"`). For pixel-exact full-res frames use
  `browser_evaluate` → `() => window.brsShot()` (returns a 1920×1080 PNG dataURL).
- **Runtime errors / `print` output:** `mcp__playwright__browser_console_messages`
  with `all:true` (and a `filter` regex). BrightScript runs on the **worker**
  thread, so its output appears here, NOT in `window.__brsConsole`.
  Watch for: `BRIGHTSCRIPT: ERROR`, `Type Mismatch`, `Error creating XML
  component`, `EXIT_BRIGHTSCRIPT_CRASH`.

## 5. What to inspect & report

For each view, screenshot and check:
- **Text overlap / clipping** — labels colliding, truncated, or running past
  their container/screen edge (e.g. a panel narrower than its longest label).
- **Off-screen / peeking elements** — anything partially visible at an edge that
  should be fully hidden or fully on-screen (overscan: keep content inside
  ~1920×1080 with a safe margin).
- **Layout inconsistency** — misaligned rows, wrong spacing, wrong colors,
  posters/labels not lining up between views.
- **Navigation / focus** — can you reach every control? Does focus get stuck
  (e.g. a list that eats a direction key at an edge)? Does focus return sensibly
  after closing an overlay/drawer? Are there dead keys?
- **Runtime errors** — anything in the worker console while interacting.

Produce a concise report grouped as: **Visual/Text**, **Navigation/Focus**,
**Runtime errors**, **Other** — each with the view, what's wrong, and the
screenshot filename. When fixing, edit `source/`/`components/`, `rebuild.ps1`,
refresh, and screenshot the before/after.

## Engine quirks — don't misdiagnose these

- **Boot:** the engine auto-runs only with `execSource:"auto-run-dev"` and only
  after `deviceData.assets` (common.zip) loads. Both are handled in `app.js`;
  missing either causes "splash but no menu" or a `-22 / default-fonts.json`
  crash. If you copy this harness elsewhere, preserve that.
- **`MarkupGrid` bubbles LEFT at column 0; `RowList` does not.** So a left-edge
  drawer trigger belongs in grid views (ListView), and for RowList views use
  BACK / top-bar-LEFT instead.
- **`itemFocused` is `-1`** before the grid first reports a focused item (it's
  `0` on a real device). Treat `invalid`/`-1`/`col 0` all as "left edge".
- **Standalone `Button.buttonSelected` may not fire** here — use the drawer.
- **Benign console noise:** `[sound] Error unzipping audio files`, `[core]
  Invalid message received: [object Object]`, the PlayReady/DRM warnings, and a
  `favicon.ico` 404.
- **Redeclaring a built-in node field** (e.g. `<field id="id">` on a node that
  already has `id`) throws `Error creating XML component ... duplicate field` in
  the engine. Real Roku tolerates it, but it's a latent bug — remove the
  redeclaration and use the built-in field.
- **Network limits:** the `/proxy/` proxy loads real hydrahd listing/detail
  pages, but stream playback, Cloudflare-Turnstile and WASM-PoW providers won't
  resolve in-browser, and exact on-device font metrics differ. This harness is
  for layout/focus/navigation/runtime debugging, not playback or perf.

See also the project memories on Roku focus/callFunc/ContentNode quirks.

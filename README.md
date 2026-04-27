# HydraHD - Roku Channel

A Roku channel that browses and plays movies + TV shows from
[hydrahd.ru](https://hydrahd.ru). All catalog data (home rows, search,
details, seasons/episodes, mirrors) is scraped directly from HydraHD's
public HTML at runtime; no API key needed.

A small Python sidecar (the "resolver") turns each provider's iframe
embed into a direct HLS / MP4 stream the Roku Video node can play, and
also handles per-device session isolation so multiple Rokus on the
same LAN don't trample each other.

---

## Features

### Browsing & discovery
- **Home page** with Trending, Latest, Top Rated, Popular TV rows
  scraped from the HydraHD index page (titles, posters, year, rating).
- **Continue Watching** row pinned to the top of Home for any title
  you've started but not finished. Tapping a tile goes straight into
  playback at the position you left off (no extra clicks).
- **My List row** on Home plus a dedicated **My List** tab for titles
  you've manually starred from the Details page.
- **Catalog tabs** for Movies, TV Shows, Trending - paginated grids
  that keep loading more as you scroll.
- **Resume bars on every poster** - a thin red progress bar at the
  bottom of any poster the user has started shows how far through it
  they are.
- **Search** with an on-screen keyboard, debounced live results, and a
  row of recent-query chips above the keyboard so you can re-run a
  past search with one click. A Clear chip wipes the history.
- **Side drawer** on Home / Movies / TV / Trending: press LEFT at the
  leftmost column to highlight the thin red strip at the screen edge,
  then OK to slide out a vertical menu (Search, Favorites, Browse
  Movies, Browse TV Shows, Options, Home, Exit). Press the top
  "< Close" button or LEFT/BACK/RIGHT to dismiss.

### Watching
- **Details page** - synopsis, year, runtime, rating, genres, cast,
  poster, backdrop, plus a Save-to-List toggle.
- **Seasons & Episodes** - season chip row + episode grid. The
  episode you should watch next is highlighted with a "Resume HH:MM"
  or "Up next" badge; finished episodes show a green "Watched" badge;
  partially-watched ones show "In progress".
- **Mirror picker** - lists every server HydraHD has for the title
  (vidsrc.cc, videasy.net, vidfast.pro, embed.su, primesrc, peachify,
  autoembed, vidrock, moviesapi, lookmovie, xpass, airflix, ...) with
  host, quality hint, and a reliability score (% success / total).
  Mirrors are auto-sorted so the most reliable for your device come
  first.
- **Player** - HLS / MP4 playback with on-demand panels (open via OK
  or UP) for:
  - **Quality** (Auto + every variant the master playlist exposes)
  - **Subtitles** (any track the resolver returned)
  - **CC styling** - text size, color, and background opacity presets
  - **Audio track** picker
  - **Resume / Stop** controls
- **Auto-resume** - playback always starts where you left off (movies
  and individual TV episodes), unless you pick "Restart" from the
  Details page.
- **Auto-advance** - finishing a TV episode launches the next one
  through the same mirror.
- **Skip Intro / Skip Credits** - when the upstream provider exposes
  chapter data (HLS DATERANGE markers or JSON-style player config),
  a "Skip Intro - press OK" or "Skip Credits - press OK" banner
  appears at bottom-right during the window. OK fires the skip; for
  TV outros, OK auto-advances to the next episode. The banner only
  appears when real chapter data is present, so you never see it for
  streams that don't support it.

### Reliability
- **Mirror reliability scoring** - the channel records every resolve
  success/failure per mirror host and sorts the picker accordingly,
  so flaky mirrors drift to the bottom over time.
- **Per-Roku session isolation** in the resolver - each device gets
  its own cookie jar (CF clearance, anti-abuse tokens, provider
  session keys) so two Rokus on the same LAN never share session
  state.
- **Persistent cookie cache** - cookie jars are saved to disk every
  60s and on shutdown, so a resolver restart doesn't dump every
  device back to a cold session.

### Settings
- Edit base URL, configure the stream-resolver URL, set caption
  defaults that apply to every video.

---

## Layout

```
manifest                       Roku channel manifest
source/                        BrightScript helpers loaded by every screen
  main.brs                     Entry point + exit hook
  Utils.brs                    Strings, regex, registry, URL helpers
  Watchlist.brs                Resume positions, favorites, search history,
                               mirror reliability, context cache
  HydraApi.brs                 All HydraHD scraping
components/                    SceneGraph components
  MainScene.{xml,brs}          Top bar + view router + global loading spinner
  SideMenu.{xml,brs}           Slide-out left-edge nav drawer
  HomeView.{xml,brs}           Home rows (Continue Watching + My List + scraped)
  ListView.{xml,brs}           Paginated grid for movies / tv / trending
  FavoritesView.{xml,brs}      My List grid
  SearchView.{xml,brs}         Keyboard + history chips + result grid
  DetailsView.{xml,brs}        Movie/TV detail + season + episode grid
  MirrorPicker.{xml,brs}       Server / mirror grid with live resolve
  PlayerView.{xml,brs}         Video + Quality / CC / Audio / Skip banner
  SettingsView.{xml,brs}       Base URL, resolver URL, caption defaults
  PosterItem.{xml}             Poster cell with resume bar
  EpisodeItem.{xml}             Episode cell with watched/current badge
  MirrorItem.{xml}              Mirror cell
  SeasonChip.{xml}              Season selector chip
  tasks/
    HomeTask.{xml,brs}          Background scrape of /
    ListTask.{xml,brs}          Background scrape of /movies/, /tv-shows/, ...
    SearchTask.{xml,brs}        Background search
    DetailsTask.{xml,brs}       Background detail scrape
    ServersTask.{xml,brs}       Background mirror list scrape
    ResolveTask.{xml,brs}       Resolve embed URL -> direct stream
images/                         Channel art (add your own - see below)
resolver/
  server.py                     Python sidecar: turns embeds into HLS/MP4
                                URLs and proxies segments through per-Roku
                                cookie jars
  state/                        Persisted cookie cache (auto-created)
tools/
  build_zip.bat                 One-shot Windows builder - auto-detects LAN
                                IP, bakes it as the default resolver URL,
                                and writes HydraHD.zip to the project root
  build_zip.ps1                 PowerShell stage + patch + zip helper
  detect_lan_ip.ps1             LAN IPv4 detection (prefers RFC1918)
```

---

## Required art

Drop these PNGs into `images/` before sideloading. Sizes are HD/FHD/SD
per Roku's spec.

- `splash_hd.png`        1280x720
- `splash_fhd.png`       1920x1080
- `splash_sd.png`        720x480
- `icon_focus_hd.png`    336x210
- `icon_focus_sd.png`    248x140
- `icon_side_hd.png`     108x69
- `icon_side_sd.png`     108x69
- `placeholder.png`      Any 220x330 dark image used while posters load.

Without them sideloading still works but the Roku menu shows a grey
square. There is no other build step.

---

## Sideloading

1. Enable Developer Mode on the Roku (`Home Home Home Up Up Right Left
   Right Left Right`) and note its IP address and the password you set.

2. Build `HydraHD.zip`. Either run the helper (Windows):

   ```
   tools\build_zip.bat                    auto-detect LAN IP, port 8787
   tools\build_zip.bat 192.168.1.50       explicit IP, port 8787
   tools\build_zip.bat 192.168.1.50 9000  explicit IP and port
   ```

   The script stages a copy of the channel, patches the
   `' build:resolver-url` line in `source/Utils.brs` with
   `http://<your-LAN-IP>:<port>`, and writes `HydraHD.zip` to the
   project root. The working tree is never modified.

   Or zip manually: put `manifest`, `source/`, `components/`, and
   `images/` at the **root** of the zip (don't zip the parent
   directory). Skip `resolver/` and `tools/` - the Roku doesn't need
   them.

3. Visit `http://<roku-ip>` in a browser, log in with `rokudev` and
   your dev password, and upload the zip via the Development
   Application Installer.

4. Launch from the Home screen.

---

## Stream playback - important

HydraHD doesn't host video itself; it links out to third-party iframe
players. Each provider ships a small HTML page containing a JavaScript
player and the actual (often encrypted) video URL.

The Roku Video node only accepts direct **HLS** (`.m3u8`),
**MPEG-DASH** (`.mpd`), or **MP4** URLs - not arbitrary HTML players.

When you press OK on a mirror, the channel:

1. If the mirror URL is itself a direct stream, plays it as-is.
2. Otherwise, calls `GET <resolver>/resolve?embed=...` and plays
   whatever stream comes back.
3. If no resolver is set, falls back to a best-effort scrape of the
   iframe HTML for any `.m3u8` / `.mp4` it can find (works for the
   most permissive providers, fails for the rest).

### Running the resolver

A Python resolver lives in `resolver/server.py`. Standard library only,
no `pip install` needed.

```bash
cd resolver
python3 server.py --port 8787
```

Useful flags:

- `--port 8787` - listen port (default 8787).
- `--host 0.0.0.0` - bind address (default 0.0.0.0 = all interfaces).
- `--state-dir ./state` - where the persistent cookie cache lives
  (default: `<resolver>/state/`).
- `--no-cookie-cache` - disable cross-restart cookie persistence.
- `--verbose` - DEBUG logging.

Then in the Roku channel: **Settings -> Set Resolver...** and enter
`http://<machine-ip>:8787`. If you built the zip with `build_zip.bat`,
that URL is already baked in - hitting **Clear** in Settings drops the
override.

The resolver currently handles vidsrc (.xyz/.cc/.in/.pm/.io/.net/
.ru), cloudnestra rcpvip/prorcp, vidsrc.cc /api/source chain, vidrock /
vidsrc.vip, 2embed.cc / .org -> lookmovie2.skin, lookmovie2 direct,
moviesapi.club -> vidora.stream, vidora generic JWPlayer,
autoembed.cc, airflix1 -> brightpathsignals -> vaplayer.ru, xpass.top,
plus a generic .m3u8/.mp4 scraper for anything else and a TMDB-id
fallback that retries unsupported mirrors through the working
backends.

### Multi-Roku setup

The resolver hands every Roku its own cookie jar, keyed by an opaque
client id the channel sends on every request. Three Rokus all watching
different shows through the same resolver will not see each other's
session state, CF clearance, or signed segment URLs.

Cookie jars are saved to `state/cookies.pickle` every 60s and on
shutdown so a resolver restart doesn't invalidate everyone.

---

## Personalisation & data

All persistent data lives in Roku registry sections, scoped per device:

- `HydraHD` - settings (base URL, resolver URL, caption defaults,
  search history, client id).
- `HydraHD_Progress` - per-movie / per-episode resume positions and
  the per-series "last watched episode" pointer that drives Continue
  Watching and the auto-resume buttons.
- `HydraHD_Favorites` - your My List entries.
- `HydraHD_MirrorStats` - per-mirror success / failure counts that
  drive the reliability scoring in MirrorPicker.

Nothing leaves the device.

---

## Customising data sources

Everything HydraHD-specific lives in `source/HydraApi.brs`. To swap
providers or add new categories, edit the `HA_*` functions there. The
UI components only ever see the normalised dicts the API helpers return
(`{ id, kind, title, year, rating, poster, href, ... }`).

To add a new provider to the resolver, write a `resolve_<host>` Python
function in `resolver/server.py` that takes `(embed_url, refer)` and
returns either `None` or a dict like:

```python
{
    "url": "https://cdn/.../master.m3u8",
    "streamFormat": "hls",
    "qualities": [...],
    "subtitles": [...],
    "chapters": [{"kind": "intro", "start": 60.0, "end": 90.0}],
    "referer": "https://provider/",
    "userAgent": "...",
}
```

Then add `("hostname", resolve_<host>)` to the `PROVIDERS` list near
the bottom of the file.

---

## Keys and shortcuts

In the browse / list / search / details views:

- `OK` - open / play / select
- `Back` - previous view
- `Up` from content - jump to top nav bar
- `Left` from leftmost column on Home / Movies / TV / Trending -
  highlight the side drawer; OK to expand
- `*` (Options) - jump to Settings from anywhere

In the player:

- `OK` or `Up` - show overlay (Resume / Quality / CC / CC Style /
  Audio / Stop). When a Skip Intro/Credits banner is showing, `OK`
  fires the skip instead.
- `Back` - stop playback and return to MirrorPicker.

In the side drawer:

- `OK` on the strip - expand
- `Right` on the strip - cancel back to grid
- `Up`/`Down` between buttons (vertical ButtonGroup)
- `Left` / `Back` / `Right` while expanded - close
- Top `< Close` button - close

---

## License

MIT-style - do whatever; just don't pretend you wrote `HydraApi.brs`.

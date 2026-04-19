# HydraHD — Roku Channel

A Roku channel that browses and plays movies + TV shows from
[hydrahd.ru](https://hydrahd.ru). All catalog data (home rows, search,
details, seasons/episodes, mirrors) is scraped directly from HydraHD's
public HTML at runtime; no API key needed.

## Features

- **Home page** — Trending, Latest, Top Rated, and Popular TV rows
  pulled from the HydraHD index page (titles, posters, year, rating).
- **Catalog** — Paginated grids for *Movies*, *TV Shows*, *Trending*.
- **Search** — On-screen keyboard, debounced live results.
- **Details** — Synopsis, year, runtime, rating, genres, cast, poster
  + backdrop, all from the HydraHD page.
- **Seasons & Episodes** — Picker for every season; grid of episodes
  with their names. Pick one to play.
- **Mirror selection** — Lists every server HydraHD knows about for the
  movie or episode (e.g. vidsrc.cc, videasy.net, vidfast.pro, embed.su,
  primesrc, peachify, autoembed, …) with host and quality hint.
- **Player** — HLS / MP4 playback with on-demand panels for:
  - Quality (Auto + every variant the master playlist exposes)
  - Closed captions (any subtitle track from the resolver, plus a
    full styling editor: text size, text color, background opacity).
  - Audio track selection.
- **Settings** — Edit base URL, configure the stream-resolver URL,
  set caption defaults that apply to every video.

## Layout

```
manifest                       Roku channel manifest
source/                        BrightScript helpers loaded by every screen
  main.brs                     Entry point
  Utils.brs                    Strings, regex, registry, URL helpers
  HydraApi.brs                 All HydraHD scraping
components/                    SceneGraph components
  MainScene.{xml,brs}          Top bar + view router + global loading spinner
  HomeView.{xml,brs}           Home (RowList of categories)
  ListView.{xml,brs}           Paginated grid for movies / tv / trending
  SearchView.{xml,brs}         Keyboard + result grid
  DetailsView.{xml,brs}        Movie/TV detail + season + episode grid
  MirrorPicker.{xml,brs}       Server / mirror grid with live resolve
  PlayerView.{xml,brs}         Video + Quality / CC / Audio panels
  SettingsView.{xml,brs}       Base URL, resolver URL, caption defaults
  PosterItem.{xml}             Custom RowList / MarkupGrid poster cell
  EpisodeItem.{xml}            Episode grid cell
  MirrorItem.{xml}             Mirror grid cell
  tasks/
    HomeTask.{xml,brs}         Background scrape of /
    ListTask.{xml,brs}         Background scrape of /movies/, /tv-shows/, ...
    SearchTask.{xml,brs}       Background search
    DetailsTask.{xml,brs}      Background detail scrape
    ServersTask.{xml,brs}      Background mirror list scrape
    ResolveTask.{xml,brs}      Resolve embed URL → direct stream
images/                        Channel art (add your own — see below)
resolver/
  server.py                    Optional Python helper that turns embed
                               iframes into HLS / MP4 URLs Roku can play
```

## Required art

Drop these PNGs into `images/` before sideloading. Sizes are
HD/FHD/SD per Roku's spec; the manifest lists the names it expects.

- `splash_hd.png`        1280×720
- `splash_fhd.png`       1920×1080
- `splash_sd.png`        720×480
- `icon_focus_hd.png`    336×210
- `icon_focus_sd.png`    248×140
- `icon_side_hd.png`     108×69
- `icon_side_sd.png`     108×69
- `placeholder.png`      Any 220×330 dark image used while posters load.

Without them sideloading still works but the Roku menu will show a grey
square. There is no other build step.

## Sideloading

1. Enable Developer Mode on the Roku (`Home ×3 ↑ ↑ → ← → ← →`) and note
   its IP address and password.
2. Zip the contents of this directory (don't zip the directory itself —
   `manifest`, `source/`, `components/`, `images/`, `resolver/` should
   all be at the root of the zip).
3. Visit `http://<roku-ip>` in a browser, log in with `rokudev` and the
   password you set, and upload the zip via the Development Application
   Installer.
4. Launch from the Home screen.

## Stream playback — important

HydraHD doesn't host video itself; it links out to third-party iframe
players (vidsrc.cc, videasy.net, vidfast.pro, embed.su, peachify.top,
primesrc.me, vidup.to, autoembed, ythd, kllamrd, frembed, …). Those
iframes ship a small HTML page that contains a JavaScript player and
the actual encrypted video URL.

The Roku Video node only accepts direct **HLS** (`.m3u8`), **MPEG-DASH**
(`.mpd`), or **MP4** URLs — not arbitrary HTML players.

Three things happen when you press OK on a mirror:

1. If the mirror URL is itself a direct stream (rare, but a few
   providers do this), the channel plays it as-is.
2. Otherwise, if you've configured a **Resolver URL** in Settings, the
   channel calls `GET <resolver>/resolve?embed=…` and uses whatever
   stream it returns.
3. If no resolver is set, the channel does a best-effort scrape of the
   iframe HTML for any `.m3u8` / `.mp4` it can find. This works for the
   most permissive providers and fails for the rest.

### Running the resolver

A starter Python resolver is in `resolver/server.py`. It has zero
dependencies (stdlib only) and supports the simplest providers
out of the box.

```bash
cd resolver
python3 server.py --port 8787
```

Then in the Roku channel: **Settings → Set Resolver…** and enter
`http://<machine-ip>:8787`. The Roku will start sending embed URLs to
your machine for resolution.

The shipped resolver intentionally only handles the easy cases — the
heavily-obfuscated providers change weekly and need per-provider code.
The handler map at the bottom of `server.py` is where to plug those in.

## Customising data sources

Everything HydraHD-specific lives in `source/HydraApi.brs`. To swap
providers or add new categories, edit the `HA_*` functions there. The
UI components only ever see the normalised dicts the API helpers return
(`{ id, kind, title, year, rating, poster, href, ... }`).

## Keys and shortcuts

- `OK` — open / play / toggle player overlay
- `◀` — back
- `▲▼` — show overlay during playback
- `*` — jump to Search from anywhere
- `#` or **Options** — jump to Settings from anywhere

## License

MIT-style — do whatever; just don't pretend you wrote `HydraApi.brs`.

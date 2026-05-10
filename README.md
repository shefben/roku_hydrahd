# HydraHD - Roku Channel

A Roku channel that browses and plays movies + TV shows from
[hydrahd.ru](https://hydrahd.ru). All catalog data (home rows, search,
details, seasons / episodes, mirrors) is scraped directly from
HydraHD's public HTML at runtime; no API key needed.

The channel ships an **in-channel stream resolver** that turns each
provider's iframe embed into a direct HLS / MP4 stream the Roku Video
node can play. No host computer is required for normal use - the
optional Python resolver in `resolver/` only exists as a fallback for
the few mirrors the in-channel path can't crack and for cross-device
state sync.

---

## Features

### Browsing & discovery
- **Home page** with Trending, Latest, Top Rated, Popular TV rows
  scraped from the HydraHD index page (titles, posters, year, rating).
- **Continue Watching** row pinned to the top of Home for any title
  you've started but not finished. For TV, the show stays here until
  you finish the **last episode of the last season** - finishing one
  episode and stopping doesn't drop the show off, the tile just
  advances to the next episode.
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
  with host, quality hint, and a reliability score (% success / total).
  Mirrors are auto-sorted so the most reliable for your device come
  first. Mirrors known to be unresolvable (Cloudflare-Turnstile-gated,
  zstd-anti-bot, etc.) are filtered out before they reach the picker
  so the user never sees a dead row - see `docs/BLOCKED_MIRRORS.md`.
- **Resume Picker** - opening a partially-watched title from Continue
  Watching offers Resume on the previous mirror, Pick a different
  mirror, or Pick a different episode without bouncing through Details.
- **Player** - HLS / MP4 playback with on-demand panels (open via OK
  or UP) for:
  - **Quality** - real resolutions parsed from the master playlist
    (1080p / 720p / 480p / etc.), not just "Auto". The top variant is
    picked automatically on play; "Auto" stays available so the player
    can drop back to ABR if your bandwidth can't sustain it.
  - **Subtitles** - tracks the resolver returned, plus a free fallback
    fetched from sub.wyzie.io when the mirror itself didn't ship any.
  - **CC styling** - text size, color, and background opacity presets.
  - **Audio track** picker.
  - **Resume / Stop** controls.
- **Auto-resume** - playback always starts where you left off (movies
  and individual TV episodes), unless you pick "Restart" from the
  Details page.
- **Auto-advance** - finishing a TV episode launches the next one
  through the same mirror. Crosses **season boundaries** automatically:
  S1 finale -> S2E1, S2 finale -> S3E1, etc. Mirror is reused first,
  then the channel cascades through alternates if that mirror doesn't
  have the next episode.
- **Skip Intro / Skip Recap / Skip Credits** - banner appears at
  bottom-right during the chapter window. OK fires the skip; for TV
  outros, OK auto-advances to the next episode (across seasons too).
  Chapter data comes from four sources, in priority order:
  1. `#EXT-X-DATERANGE` markers in the HLS master playlist itself.
  2. JSON skip-config blobs (`introStart`/`introEnd`,
     `"skipIntro":{"start":..,"end":..}`) in the embed page HTML.
  3. **TheIntroDB** community database - keyed by TMDB or IMDB id.
  4. **IntroDB** community database - keyed by IMDB id (backup).
  5. **AniSkip** - anime fallback. Looks up the show's MAL id via
     Jikan (primary) or AniList GraphQL (backup), then asks AniSkip
     for opening / ending times.
  All four are free and need no API key. The banner only appears
  when real chapter data is present, so you never see it for streams
  that don't have any.

### Reliability
- **Mirror reliability scoring** - the channel records every resolve
  success/failure per mirror host and sorts the picker accordingly,
  so flaky mirrors drift to the bottom over time.
- **Auto-cascade** - first failed mirror prompts "Try the rest
  automatically?". Yes silently iterates remaining untried mirrors
  until one plays or the list is exhausted.
- **Per-resolve session isolation** - every resolve gets its own
  cookie-jar wrapping a single `roUrlTransfer` so iframe -> API hops
  on a single embed share state but don't leak across embeds.
- **HLS segment header forwarding** - PlayerView attaches per-stream
  Referer / User-Agent / Origin via `roHttpAgent` (not the buggy
  `cn.httpHeaders` path), so CDNs that segment-check the Referer
  serve every chunk instead of 403'ing after the first.

### Settings
- **In-Channel Resolver** toggle (default ON). When on, the channel
  resolves embeds itself; when off, every Play press forwards the
  embed to the optional external resolver URL below.
- **External Resolver URL** (optional fallback). LAN auto-discovery
  on UDP 1901, manual entry, or Clear. Used as a fallback if the
  in-channel path can't resolve a mirror.
- **Captions** - default text size, color, and background opacity
  applied to every video. Live preview.
- **Settings page scrolls** - rows below the visible area are
  reachable via Down arrow; the whole page slides as needed.

---

## Layout

```
manifest                       Roku channel manifest
source/                        BrightScript helpers loaded by every screen
  main.brs                     Entry point + exit hook + boot sync
  Utils.brs                    Strings, regex, registry, URL helpers
  Watchlist.brs                Resume positions, favorites, search history,
                               mirror reliability, context cache, and the
                               TV "stay in Continue Watching until series
                               finale" tracking
  Sync.brs                     Optional snapshot push/pull to external
                               resolver's /state endpoint (no-op when no
                               resolver URL is configured)
  HydraApi.brs                 All HydraHD HTML scraping
  -- in-channel stream resolver --
  HttpClient.brs               Per-resolve roUrlTransfer session with
                               cookie continuity, async + 8s deadlines,
                               base64-URL helpers
  JsUnpack.brs                 Dean Edwards eval(p,a,c,k,e,d) unpacker
                               (base 2-62)
  Resolver.brs                 Dispatcher: host -> provider, iframe chain
                               walker (depth-3), TMDB-id fallback, result
                               normaliser, post-resolve enrichment
  ResolverProviders.brs        Per-provider resolvers (15+ providers, see
                               below)
  HlsMeta.brs                  Master-playlist quality parsing,
                               #EXT-X-DATERANGE chapter parsing, free
                               subtitle and skip-time API integrations
  Bytes.brs                    Byte-level XOR / hex / decimal-string
                               conversion shared by the crypto modules
  Rc4.brs                      RC4 stream cipher for the Vidking / Videasy
                               WASM-equivalent decryption pipeline
  EvpBytesToKey.brs            OpenSSL EVP_BytesToKey (MD5/1-iter) - the
                               KDF CryptoJS's Salted__ envelope uses
  AesGcm256.brs                AES-256-GCM via roEVPCipher AES-256-ECB
                               primitives (Roku has no native GCM-256);
                               used by the Peachify decryption path
components/                    SceneGraph components
  MainScene.{xml,brs}          Top bar + view router + global loading spinner
  SideMenu.{xml,brs}           Slide-out left-edge nav drawer
  HomeView.{xml,brs}           Home rows (Continue Watching + My List + scraped)
  ListView.{xml,brs}           Paginated grid for movies / tv / trending
  FavoritesView.{xml,brs}      My List grid
  SearchView.{xml,brs}         Keyboard + history chips + result grid
  DetailsView.{xml,brs}        Movie/TV detail + season + episode grid
  MirrorPicker.{xml,brs}       Server / mirror grid with live resolve
                               + auto-cascade
  ResumePicker.{xml,brs}       Quick-action menu for Continue Watching
                               (resume on saved mirror / pick another /
                               pick a different episode)
  PlayerView.{xml,brs}         Video + Quality / CC / Audio / Skip banner
                               + cross-season episode auto-advance
  SettingsView.{xml,brs}       In-channel toggle, external resolver URL,
                               base URL, caption defaults, scroll-on-focus
  PosterItem.{xml}             Poster cell with resume bar + favorite star
  EpisodeItem.{xml}            Episode cell with watched/current badge
  MirrorItem.{xml}             Mirror cell with reliability score
  SeasonChip.{xml}             Season selector chip
  KbCell.{xml}                 Keyboard cell
  tasks/
    HomeTask.{xml,brs}         Background scrape of /
    ListTask.{xml,brs}         Background scrape of /movies/, /tv-shows/, ...
    SearchTask.{xml,brs}       Background search
    DetailsTask.{xml,brs}      Background detail scrape
    ServersTask.{xml,brs}      Background mirror list scrape
    ResolveTask.{xml,brs}      Embed -> direct stream pipeline:
                               in-channel resolver -> external resolver ->
                               best-effort regex scrape
    DiscoverTask.{xml,brs}     LAN-discovery probe for the resolver
    SyncTask.{xml,brs}         Push/pull state snapshots to/from the
                               external resolver (when configured)
docs/
  BLOCKED_MIRRORS.md           Why each filtered host (vidup, embedmaster,
                               vidfast, kllamrd, frembed) is hidden, plus
                               re-enable steps when one becomes portable
  RESOLVER_SETUP.md            Optional: hosting resolver/server.py on a
                               LAN box or a free cloud VPS (Oracle A1, etc.)
images/                        Channel art (add your own - see below)
resolver/
  server.py                    Optional Python sidecar fallback resolver
                               + state-sync server (stdlib only)
  state/                       Persisted cookie cache (auto-created)
tools/
  build_zip.bat                Windows builder. No args = no IP baked in
                               (channel auto-discovers); auto / IP /
                               IP+port flag a fallback URL into Utils.brs
  build_zip.ps1                PowerShell stage + patch + zip helper
  detect_lan_ip.ps1            LAN IPv4 detection (prefers RFC1918)
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

2. Build `HydraHD.zip` with the included Windows helper:

   ```
   tools\build_zip.bat                    no IP baked in (recommended)
   tools\build_zip.bat auto               auto-detect LAN IP, port 8787
   tools\build_zip.bat 192.168.1.50       explicit IP, port 8787
   tools\build_zip.bat 192.168.1.50 9000  explicit IP and port
   ```

   The script stages a copy of the channel, optionally patches the
   `' build:resolver-url` line in `source/Utils.brs` with
   `http://<your-LAN-IP>:<port>` if you passed one, and writes
   `HydraHD.zip` to the project root. The working tree is never
   modified.

   **You don't need to bake in an IP.** The in-channel resolver runs
   on every Play press, and the external-resolver URL (when used) is
   either auto-discovered on the LAN at runtime or set by hand in
   Settings. No-arg `build_zip.bat` is the simplest path.

3. Visit `http://<roku-ip>` in a browser, log in with `rokudev` and
   your dev password, and upload the zip via the Development
   Application Installer.

4. Launch from the Home screen.

---

## How playback works

HydraHD doesn't host video itself; it links out to third-party iframe
players. Each provider ships a small HTML page containing a JavaScript
player and the actual (often encrypted) video URL. The Roku Video node
only accepts direct **HLS** (`.m3u8`), **MPEG-DASH** (`.mpd`), or
**MP4** URLs - not arbitrary HTML players.

When you press OK on a mirror, `ResolveTask` runs this cascade:

1. **Direct passthrough** - if the mirror URL is itself a `.m3u8` /
   `.mp4`, hand it straight to the Video node.
2. **In-channel resolver** (`source/Resolver.brs`) - dispatches the
   embed host to its specific provider in `ResolverProviders.brs`,
   walks any iframe chain, parses any encrypted payload, and returns
   the direct stream URL. Default ON; can be toggled in Settings.
3. **External resolver** (optional) - GET to whatever URL is set in
   Settings, expecting the same `{ url, streamFormat, qualities,
   subtitles, chapters, referer, userAgent }` shape.
4. **Best-effort regex scrape** - last-resort `.m3u8` / `.mp4` hunt
   inside the iframe HTML. Catches the most permissive providers,
   fails for the rest.

The result is then **enriched** by `HlsMeta.brs`:

- The master m3u8 is fetched and parsed for `#EXT-X-STREAM-INF`
  variants - real resolutions populate the Quality picker.
- `#EXT-X-DATERANGE` entries become Skip Intro / Outro / Recap
  chapters.
- If the upstream gave no chapters, the channel queries TheIntroDB
  -> IntroDB -> AniSkip in turn for community-curated skip times.
- If the upstream gave no subtitles, sub.wyzie.io is queried for a
  free aggregated subtitle list.

### Providers the in-channel resolver handles

Direct providers (matched by embed host substring):

- `airflix1.com` - vaplayer.ru API + #EXTM3U variant validation
- `play.xpass.top` - playlist.json + var backups + suburl
- `peachify.top` - AES-256-GCM with hardcoded key
- `moviesapi.club` / `.to` - iframe chain to vidora / ww*
- `ythd.org` - cloudnestra wrapper
- `vidking.net` - RC4 + glibc LCG + AES-128-CBC chain (WASM cracked)
- `2embed.cc` / `.org` - swish iframe -> lookmovie2.skin
- `player.videasy.net` - same WASM/algorithm as vidking
- `vidsrc.vip` / `vidrock.net` - JSON API + tree walk
- `player.autoembed.cc` - iframe chain to vidsrc / cloudnestra
- `vidsrc.cc` - /api/episode/.../servers + /api/source JSON chain
- `vidsrc.xyz` family (`.in` / `.pm` / `.io` / `.net` / `vsembed.ru`)
  - iframe to cloudnestra
- `cloudnestra.com` - rcpvip -> prorcp -> tmstr1.<host> with `{v1}`/
  `{v2}` placeholder substitution
- `lookmovie2.skin` - Dean Edwards-packed JWPlayer with hls2/3/4 keys
- `vidora.stream` - JWPlayer with eval-pack
- `primesrc.me` - catalog only (CF blocks link resolution)

Downstream extractors (reachable via iframe chains from primesrc /
frembed-style aggregators):

- `streamtape` - 'robotlink' substring chain
- `uqload` - jwplayer `sources: [...]` regex
- `doodstream` / `dood.*` / `d000d.*` / `d0000d.*` / `ds2play` /
  `ds2video` - /pass_md5 hop + random-base62 token append
- `voe.*` - rot13 + 7-pair replace + base64 + char-shift -3 + reverse
  + base64 + JSON
- `streamsb` / `watchsb` - hex-encoded id sandwiched in static prefix
  + suffix
- `mixdrop` / `mxdrop` - Dean Edwards unpacker (base 62) + Core.wurl

Filtered (hidden from picker UI - see `docs/BLOCKED_MIRRORS.md`):
`vidup.to`, `embedmaster.link`, `vidfast.pro`, `kllamrd.org`,
`frembed.bond`. All five also failed in the external resolver, so
hiding them is a UX win, not a regression.

If the matched provider fails AND the embed has TMDB / IMDB ids, the
resolver retries the same content through every other working
provider via a fallback URL list (`R_FallbackByContentIds`), so a
single dead provider doesn't take the title down with it.

---

## Optional: external resolver

Some users want the external Python resolver back in the loop - for
the few CF-protected mirrors the in-channel path can't crack, for an
HLS-proxy that rewrites segment Referer headers when a CDN is strict,
or for cross-device state sync (favorites and Continue Watching that
survive a full channel uninstall).

Full setup guide is in `docs/RESOLVER_SETUP.md`. The short version:

```bash
cd resolver
python3 server.py --port 8787
```

Standard library only, no `pip install`. Run on any always-on box on
your LAN (Pi / NAS / desktop) or on a free cloud VM (Oracle
Always-Free A1, GCP e2-micro, etc.). The channel auto-discovers a
LAN-running resolver via UDP 1901; for cloud, paste the URL into
**Settings -> External Resolver URL -> Set Manually...**.

Useful flags:

- `--port 8787` - listen port (default 8787).
- `--host 0.0.0.0` - bind address (default 0.0.0.0 = all interfaces).
- `--state-dir ./state` - where the persistent cookie cache lives
  (default: `<resolver>/state/`).
- `--no-cookie-cache` - disable cross-restart cookie persistence.
- `--no-discovery` - disable the LAN auto-discovery responder.
- `--verbose` - DEBUG logging.

The external resolver hands every Roku its own cookie jar, keyed by
an opaque client id the channel sends on every request, so multiple
Rokus on one resolver don't collide. Cookies are saved to
`state/cookies.pickle` every 60s and on shutdown.

---

## Personalisation & data

All persistent data lives in Roku registry sections, scoped per device:

- `HydraHD` - settings (base URL, in-channel-resolver toggle,
  external-resolver URL, caption defaults, search history, client id).
- `HydraHD_Progress` - per-movie / per-episode resume positions and
  the per-series "last watched + show structure" pointer that drives
  Continue Watching, the auto-resume buttons, and the
  "stay-in-list-until-finale" logic.
- `HydraHD_Favorites` - your My List entries.
- `HydraHD_MirrorStats` - per-mirror success / failure counts that
  drive the reliability scoring in MirrorPicker.

Nothing leaves the device unless you've configured an external
resolver URL. With one set, the channel pushes a JSON snapshot of
those four sections to the resolver's `/state` endpoint on each
relevant write so a freshly-reinstalled channel can repopulate from it.

---

## Customising data sources

Everything HydraHD-specific lives in `source/HydraApi.brs`. To swap
providers or add new categories, edit the `HA_*` functions there. The
UI components only ever see the normalised dicts the API helpers return
(`{ id, kind, title, year, rating, poster, href, ... }`).

To filter additional mirrors out of the picker, extend
`HA_IsMirrorBlocked` in `HydraApi.brs` and document the rationale in
`docs/BLOCKED_MIRRORS.md`.

To add a new in-channel provider:

1. Implement `RP_Resolve<Name>(embedUrl, refer, session)` in
   `source/ResolverProviders.brs`. Return `{ url, streamFormat,
   qualities, subtitles, chapters, referer, userAgent }` or `invalid`.
2. Wire host substring -> function in `R_DispatchByHost` in
   `source/Resolver.brs`.

To add a new provider to the optional external Python resolver, write
a `resolve_<host>` function in `resolver/server.py` and add
`("hostname", resolve_<host>)` to the `PROVIDERS` list near the
bottom of the file.

---

## Keys and shortcuts

In the browse / list / search / details views:

- `OK` - open / play / select
- `Back` - previous view
- `Up` from content - jump to top nav bar
- `Left` from leftmost column on Home / Movies / TV / Trending -
  highlight the side drawer; OK to expand
- `*` (Options) - toggle favorite on the focused poster (or, on the
  Details page, equivalent to Save-to-List). A gold star appears on
  every cell where that title shows up.

In the player:

- `OK` or `Up` - show overlay (Resume / Quality / CC / CC Style /
  Audio / Stop). When a Skip Intro / Recap / Credits banner is
  showing, `OK` fires the skip instead.
- `Back` - stop playback and return to MirrorPicker. During the outro
  countdown, `Back` cancels the auto-advance so you can sit through
  the credits manually.

In the side drawer:

- `OK` on the strip - expand
- `Right` on the strip - cancel back to grid
- `Up`/`Down` between buttons (vertical ButtonGroup)
- `Left` / `Back` / `Right` while expanded - close
- Top `< Close` button - close

In Settings:

- `Up` / `Down` - move between rows (page scrolls automatically when
  the focused row would be off-screen).
- `Left` / `Right` - move between buttons within a row.
- `OK` - apply / open URL keyboard / start auto-discover.

---

## License

MIT-style - do whatever; just don't pretend you wrote `HydraApi.brs`.

# Blocked Mirrors Reference

This document tracks HydraHD mirrors that are intentionally **hidden from the picker** because they cannot be resolved either by the in-channel resolver (`source/Resolver.brs`) or by the external Python resolver (`resolver/server.py`). All five already returned 204 / "Forbidden" / empty body in production prior to being filtered, so hiding them is a UX win, not a regression.

The filter lives in `source/HydraApi.brs::HA_IsMirrorBlocked` and is called from `HA_ParseMirrors`. To unhide a mirror once it's been cracked, remove the host from that list.

## Filtered hosts

| Host | Why it's blocked | Re-investigate when |
|---|---|---|
| `vidup.to` | Confirmed clone of `vidfast.pro` (identical Next.js chunk hashes `4bd1b696-21f374d1156f834a.js`, `aaea2bcf-18613745c71632cf.js`, `687-8e9f24493e814e00.js`). Same Faststream player, same multi-host meta-aggregator, same blockers. | Vidfast architecture changes (e.g., loses the runtime-derived URL pattern) |
| `embedmaster.link` | Cloudflare Turnstile-gated. Page HTML is just the Turnstile widget; no `data-link` / `data-hash` / iframe references on the page. CF research confirmed no Roku-side bypass (no JS engine, no JA3/JA4 control, `cf_clearance` is IP+UA+TLS-bound). | Site removes Turnstile, OR Roku gains JA3 / WebView capability |
| `vidfast.pro` | Multi-host meta-aggregator that cycles through `flixbaba.is`, `flixbaba.mov`, `flixmomo.org`, `flixmomo.tv`, `cinegram.net`, `cinegram.tv`, `cinemaflix.one`, `boredflix.com`, `ythd.org`. Each upstream has its own protocol; vidfast just coordinates. The fetch URL is `fetch(("/APA91us-..../q/1000025805044766/vacjeoki/Ilz-gRcqmnc/" + l.data))` — a long FCM-token-format path with multiple SHA1 / SHA256 / UUID segments and a runtime-derived `l.data` field that cannot be reconstructed statically. CF differentiates by automation fingerprints (Playwright got HTTP 403, plain curl got 200 — JA3-style heuristic). | Vidfast switches to a stable static API, OR each upstream gets its own port |
| `kllamrd.org` | CF-fronted with custom anti-bot. Returns HTTP 200 with empty body to plain HTTP clients (sets `PHPSESSID` cookie, encodes response with zstd which Roku can't decompress, returns 0-byte content even with Chrome-like UA + cookie jar). `cf-cache-status: DYNAMIC` confirms Cloudflare-fronted. Page content unreadable from script. | Site stops requiring zstd / drops the anti-bot header check |
| `frembed.bond` | API endpoints return 403 "Invalid Referer" / "Forbidden" to script clients. Even when it occasionally responds, the catalog redirects to VOE / uqload / divxplayer — each needing its own resolver port (they're in the Phase 4 downstream-extractor plan). | Phase 4 downstream extractors (VOE, Uqload, Doodstream, Mixdrop) are implemented; revisit if frembed's anti-bot loosens |

## Mirror status, 2026-11 sweep

Run `python tools/check_live_mirrors.py` to redo this. It pulls HydraHD's current list for one movie and one episode, runs each embed through the channel's own resolver in brs-node, parses qualities, and probes every URL.

| Mirror (picker name) | Resolver | Notes |
|---|---|---|
| `1src.org` (HydraVip), `www.1src.org` (Alfa) | `RP_ResolveOnesrc` | Page's own `?action=sources&provider=` JSON. No Referer needed. |
| `vidfast.vc` (Charlie) | `RP_ResolveVidfast` | See below. Individual servers 404 per title. |
| `vixsrc.to` (Hydra2) | `RP_ResolveVixsrc` | Audio is a separate rendition: qualities are pinned by bitrate on the master, never played as bare variant URLs. |
| `airflix1.com` (Bravo), `ythd.org` (Hydra1) | `RP_ResolveVaplayer` | Stream list is ChaCha20; key lifted from a WASM module that rotates every 5 minutes. Token is single-use and IP-bound. |
| `play.xpass.top` (Whiskey) | `RP_ResolveXpass` | Source list is AES-GCM behind `/data`; build id read from the player script. Most of its ~30 sources are dead or PNG-wrapped, so each is checked down to the first segment. |
| `www.vidy.st` (Beta) | `RP_ResolveVidy` (`ResolverVidy.brs`) | api.wecollege.net `/seed` + `/<server>/sources?...&enc=2`, XOR with a custom keystream keyed by (seed, tmdb), plaintext `mvm1`+JSON. miami/boise give 480p-2160p H.264 fMP4 ladders and ~25 subtitle tracks; others are single-HLS backups. Everything needs `Referer: https://www.vidy.st/`. |
| `www.2embed.cc` (Echo) | `RP_ResolveVsrcPlayer` via `RP_Resolve2embed` | Page lazy-loads vidsrc.buzz (`data-src`); `var Q` token + `pl/api.php?a=sources&pf=1` / `a=play`. Only server VNH serves plain TS; VNY/VNR wrap segments in a PNG and are skipped. Single rendition. |
| `moviesapi.to` (Golf) | `RP_ResolveMoviesapiTo` (`ResolverMoviesapi.brs`) | `/api/vidora/v1/...` with `x-player-key` from the page bundle (AES-128 HLS, needs moviesapi.to Referer); else cdn.vidspark.to's same API with `?source=`. Many movies have only PNG-wrapped or blocked sources there, so they fall back to the pool. |
| `primesrc.me` (Hotel) | none | Server list is open (`/api/v1/s`), but every link (`/api/v1/l?key=`) is behind a Cloudflare managed challenge (403 "Just a moment...") and the page uses a Turnstile widget (sitekey `0x4AAAAAACox-LngVREu55Y4`). Plays via the fallback pool. |
| `vidup.to`, `embedmaster.link` | none | Hidden (see table above). |

The fallback pool in `R_BuildFallbackCandidates` now holds only the mirrors above. The old pool (vidlove, vidsrc.cc, videasy, vidking, vidrock, 2embed, moviesapi.club, autoembed) was unreachable or empty.

## vidfast.vc is resolved, not blocked

HydraHD now lists `vidfast.vc`. It is the same Faststream player as `vidfast.pro` / `vidup.to`, and it is handled by `source/ResolverVidfast.brs` (dispatch in `R_DispatchByHost`). What changed since the row above was written: the "runtime-derived" request path turned out to be a sealed copy of the page's one-time `en` token, and the client is a virtualized script whose constants can be read out of an XOR-masked descriptor in the player chunk.

- The page picks one of 20 player variants (`variantIndex`), each with a different transport. Only **variant 16** is ported; it is the only one the server has been seen to serve.
- The path, CSRF token, endpoint ids and key material are hardcoded in `RP_VidfastConfig()` and tied to one chunk file name. When vidfast redeploys, the resolver logs `player chunk changed` and returns nothing, so the fallback chain takes over. Refresh with `python tools/vidfast_constants.py` and paste the output into `RP_VidfastConfig()`.
- Offline checks: `python tools/test_vidfast.py` (fixtures in `tools/fixtures/vidfast`).
- The stream CDN returns 403 without `Referer: https://vidfast.vc/`.

`vidfast.pro` and `vidup.to` stay filtered: same player, but not verified against this resolver.

## Coverage impact

After filtering, the user sees **10 of the original 16 HydraHD mirrors** in the picker (plus chains those mirrors expose):

**Visible / portable**: `airflix1.com`, `play.xpass.top`, `peachify.top`, `moviesapi.club`, `ythd.org`, `vidking.net`, `2embed.cc`, `player.videasy.net`, `vidsrc.vip` / `vidrock.net`, `player.autoembed.cc`

**Visible / partial**: `primesrc.me` (catalog only — link resolution is CF-Turnstile-gated; future routing to Phase 4 downstream extractors would unlock the named upstream)

**Filtered (this list)**: `vidup.to`, `embedmaster.link`, `vidfast.pro`, `kllamrd.org`, `frembed.bond`

The five filtered mirrors all already failed in the Python resolver — the user has been getting by with the other 10-12 for a long time. Hiding them removes a UX dead-end without losing any content.

## Re-enabling a mirror

1. Verify the new resolver works (manual `curl` from a non-LAN host or write a Phase 4-style port).
2. Remove the host from `HA_IsMirrorBlocked` in `source/HydraApi.brs`.
3. If the mirror needs a real provider implementation (not just generic regex scrape), add a stub or full `RP_Resolve<Name>` in `source/ResolverProviders.brs` and wire it into `R_DispatchByHost` in `source/Resolver.brs`.
4. Sideload + test on a real Roku before merging to master.

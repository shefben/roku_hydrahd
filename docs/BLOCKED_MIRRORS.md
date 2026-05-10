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

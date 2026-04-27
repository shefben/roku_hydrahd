#!/usr/bin/env python3
"""Companion stream resolver for the HydraHD Roku channel.

HydraHD aggregates third-party iframe embeds (vidsrc.xyz, vidsrc.cc,
videasy.net, vidfast.pro, 2embed.cc, embed.su, peachify.top, primesrc.me,
vidup.to, vidking.net, autoembed, ythd, kllamrd, frembed, ...). The
Roku Video node can only play direct HLS / DASH / MP4 streams, so this
small Python service takes an embed URL and returns:

    { "url": "<m3u8 or mp4>", "streamFormat": "hls|mp4|dash",
      "qualities": [ { "label": "1080p", "height": 1080,
                        "bandwidth": 5000000, "url": "..." }, ... ],
      "subtitles": [ { "url": "...", "language": "en", "name": "English" } ] }

Run:  python3 server.py --port 8787
Then in the Roku channel Settings > Stream Resolver URL, set
http://<this-machine-ip>:8787

Implemented providers (working as of 2026-04):
  * vidsrc.xyz / .in / .pm / .io / .net / vsembed.ru — full chain through
                   cloudnestra rcpvip / prorcp
  * cloudnestra  — direct rcpvip / prorcp pages
  * vidsrc.cc    — /api/episode/{id}/[s/e/]servers + /api/source/{hash}
                   JSON chain (independent of the cloudnestra Turnstile
                   gate — works when vidsrc.xyz is challenged)
  * vidrock.net / vidsrc.vip — /api/movie/{tmdb} + /api/tv/{tmdb}/{s}/{e}
                   JSON chain (vidsrc.vip is just a vidrock shell)
  * 2embed.cc / .org — chain through streamsrcs.2embed.cc swish →
                   lookmovie2.skin
  * lookmovie2.skin — direct (jwplayer eval-packed source)
  * moviesapi.club / .to — iframe chain → vidora.stream / ww*.moviesapi.to
                   → JWPlayer eval-packed
  * vidora.stream — generic JWPlayer with eval(p,a,c,k,e,d) unpack
  * autoembed.cc / player.autoembed.cc — iframe chain (usually lands on
                   vidsrc.xyz; covered through follow_known_iframes)
  * airflix1.com — chains through brightpathsignals.com whose CONFIG
                   exposes streamdata.vaplayer.ru/api.php; that API
                   returns a list of master .m3u8 URLs directly
  * xpass.top    — direct .m3u8 from /mdata/{hash}/{n}/playlist.json,
                   plus subtitle search via sub.wyzie.io
  * generic      — best-effort .m3u8 / .mp4 scrape for everything else

Coverage net: every other host falls through to the TMDB-id fallback
chain (`fallback_via_known_providers`) which retries the same content
through xpass, vidsrc.cc, vidrock, moviesapi, vidsrc.xyz mirrors,
2embed, and autoembed in sequence — so unsupported mirrors still play
as long as the title is on at least one of the working backends.

Stub providers (need cloudflare bypass, AES decryption, or JS execution
that we can't do from a plain urllib client):
  * vidfast.pro      — encrypted player bundle
  * videasy.net      — encrypted player bundle
  * vidking.net      — videasy-derived player (lazy-loaded chunk)
  * primesrc.me      — /api/v1/s catalog works, /api/v1/l blocked by CF
  * embed.su         — DNS-blocked from many test environments
  * peachify.top     — heavy JS player
  * embedmaster.link — pako/AES-encrypted player payload
  * vidup.to         — heavy JS bundle
  * ythd.org         — webpack-bundled obfuscated player
  * kllamrd.org      — anti-bot challenge before player loads
  * frembed.bond     — /api/films catalog works, links redirect to
                       VOE / uqload / divxplayer (each needs own resolver)
"""

from __future__ import annotations

import argparse
import atexit
import http.cookiejar
import json
import logging
import os
import pickle
import re
import sys
import tempfile
import threading
import time
import urllib.parse as urlparse
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import HTTPCookieProcessor, OpenerDirector, Request, build_opener

LOG = logging.getLogger("hydrahd-resolver")


# --- Per-client session isolation ------------------------------------
#
# Multiple Roku devices on the same LAN can hit one resolver at the same
# time. Many upstream providers track Set-Cookie / session state (CF
# clearance, anti-abuse tokens, "current playing" session keys), and if
# we share a single cookie jar between devices then device A's resolve
# will overwrite cookies device B is mid-playback with - causing 403s,
# stalls, and "stream from wrong title" mix-ups.
#
# We give every device its own cookie jar, keyed by an opaque "cid"
# (client id) that the Roku channel sends on every /resolve and /stream
# request. The cid is forwarded into proxied URLs so HLS segment fetches
# stay on the same jar that resolved the master playlist.

_CLIENTS_LOCK = threading.Lock()
_CLIENTS: "OrderedDict[str, OpenerDirector]" = OrderedDict()
_MAX_CLIENTS = 64

# Thread-local opener picked up by fetch() / proxy fetches so we don't
# have to thread the opener through every helper signature.
_LOCAL = threading.local()


def _build_opener() -> OpenerDirector:
    jar = http.cookiejar.CookieJar()
    return build_opener(HTTPCookieProcessor(jar))


# Anonymous fallback opener for callers that don't carry a cid.
_DEFAULT_OPENER = _build_opener()


def _opener_for(cid: str) -> OpenerDirector:
    if not cid:
        return _DEFAULT_OPENER
    with _CLIENTS_LOCK:
        op = _CLIENTS.get(cid)
        if op is None:
            op = _build_opener()
            _CLIENTS[cid] = op
            # LRU eviction so a long-running resolver doesn't grow the
            # client table unbounded as Rokus come and go.
            while len(_CLIENTS) > _MAX_CLIENTS:
                _CLIENTS.popitem(last=False)
        else:
            _CLIENTS.move_to_end(cid)
        return op


def _set_active_opener(opener: OpenerDirector) -> None:
    _LOCAL.opener = opener


def _clear_active_opener() -> None:
    _LOCAL.opener = None


def _active_opener() -> OpenerDirector:
    return getattr(_LOCAL, "opener", None) or _DEFAULT_OPENER


# --- Persistent cookie cache -----------------------------------------
#
# CF clearance, anti-abuse tokens, and provider session cookies take
# real time to acquire (and sometimes a Turnstile retry). Saving them
# to disk so a resolver restart doesn't dump every Roku back to a cold
# session means the next playback after reboot still resumes quickly.
#
# We snapshot the per-cid cookie jars to a single pickle file, replaced
# atomically. A background daemon thread re-saves every CACHE_FLUSH_S
# seconds; atexit fires on graceful shutdown.

CACHE_FLUSH_S = 60
_COOKIE_CACHE_PATH: str | None = None
_COOKIE_CACHE_LOCK = threading.Lock()
_COOKIE_FLUSH_THREAD: threading.Thread | None = None
_COOKIE_FLUSH_STOP = threading.Event()


def _jar_of(opener: OpenerDirector) -> http.cookiejar.CookieJar | None:
    for h in opener.handlers:
        if isinstance(h, HTTPCookieProcessor):
            return h.cookiejar
    return None


def _snapshot_cookies() -> list[tuple[str, list[http.cookiejar.Cookie]]]:
    out: list[tuple[str, list[http.cookiejar.Cookie]]] = []
    with _CLIENTS_LOCK:
        items = list(_CLIENTS.items())
    for cid, opener in items:
        jar = _jar_of(opener)
        if jar is None:
            continue
        # CookieJar is iterable but uses an internal lock; copy under that lock.
        try:
            cookies = list(jar)
        except Exception:
            continue
        out.append((cid, cookies))
    return out


def _save_cookie_cache() -> None:
    if not _COOKIE_CACHE_PATH:
        return
    try:
        snapshot = _snapshot_cookies()
        if not snapshot:
            return
        with _COOKIE_CACHE_LOCK:
            d = os.path.dirname(_COOKIE_CACHE_PATH) or "."
            os.makedirs(d, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix="cookies-", suffix=".tmp", dir=d)
            try:
                with os.fdopen(fd, "wb") as f:
                    pickle.dump({"version": 1, "saved_at": time.time(),
                                 "clients": snapshot}, f,
                                protocol=pickle.HIGHEST_PROTOCOL)
                os.replace(tmp, _COOKIE_CACHE_PATH)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
    except Exception as exc:  # noqa: BLE001
        LOG.warning("cookie cache save failed: %s", exc)


def _load_cookie_cache() -> None:
    if not _COOKIE_CACHE_PATH or not os.path.exists(_COOKIE_CACHE_PATH):
        return
    try:
        with open(_COOKIE_CACHE_PATH, "rb") as f:
            data = pickle.load(f)
    except Exception as exc:  # noqa: BLE001
        LOG.warning("cookie cache load failed (%s); starting fresh", exc)
        return
    clients = data.get("clients") if isinstance(data, dict) else None
    if not clients:
        return
    restored = 0
    with _CLIENTS_LOCK:
        for cid, cookies in clients:
            if not cid:
                continue
            opener = _build_opener()
            jar = _jar_of(opener)
            if jar is None:
                continue
            for c in cookies:
                # Defensively skip already-expired cookies on load so we
                # don't resurrect garbage and immediately discard it.
                try:
                    if c.is_expired(time.time()):
                        continue
                    jar.set_cookie(c)
                except Exception:
                    continue
            _CLIENTS[cid] = opener
            restored += 1
            if len(_CLIENTS) > _MAX_CLIENTS:
                _CLIENTS.popitem(last=False)
    LOG.info("restored %d client cookie jar(s) from %s",
             restored, _COOKIE_CACHE_PATH)


def _flush_loop() -> None:
    while not _COOKIE_FLUSH_STOP.wait(CACHE_FLUSH_S):
        _save_cookie_cache()


def _start_cookie_persistence(path: str) -> None:
    global _COOKIE_CACHE_PATH, _COOKIE_FLUSH_THREAD
    _COOKIE_CACHE_PATH = path
    _load_cookie_cache()
    atexit.register(_save_cookie_cache)
    _COOKIE_FLUSH_THREAD = threading.Thread(
        target=_flush_loop, name="cookie-cache-flush", daemon=True
    )
    _COOKIE_FLUSH_THREAD.start()

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

HLS_RE = re.compile(r"https?://[^\s\"'<>\\]+\.m3u8[^\s\"'<>\\]*")
MP4_RE = re.compile(r"https?://[^\s\"'<>\\]+\.mp4[^\s\"'<>\\]*")
SUB_RE = re.compile(r"https?://[^\s\"'<>\\]+\.(?:vtt|srt)")


# --- HTTP helper -----------------------------------------------------

def fetch(url: str, headers: dict[str, str] | None = None,
          method: str = "GET", body: bytes | None = None) -> tuple[str, dict[str, str], str]:
    headers = dict(headers or {})
    headers.setdefault("User-Agent", UA)
    headers.setdefault("Accept", "*/*")
    headers.setdefault("Accept-Language", "en-US,en;q=0.9")
    req = Request(url, headers=headers, data=body, method=method)
    try:
        with _active_opener().open(req, timeout=20) as resp:
            data = resp.read()
            ctype = resp.headers.get("Content-Type", "")
            text = data.decode("utf-8", "replace")
            final_url = resp.geturl()
            return text, dict(resp.headers), final_url
    except HTTPError as e:
        LOG.warning("HTTP %s on %s", e.code, url)
        try:
            text = e.read().decode("utf-8", "replace")
        except Exception:
            text = ""
        return text, {}, url
    except URLError as e:
        LOG.warning("URL error on %s: %s", url, e)
        return "", {}, url


def host_of(url: str) -> str:
    try:
        h = urlparse.urlparse(url).netloc.lower()
        if h.startswith("www."):
            h = h[4:]
        return h
    except Exception:
        return ""


def absolute(url: str, base: str) -> str:
    if not url:
        return ""
    if url.startswith("http://") or url.startswith("https://"):
        return url
    if url.startswith("//"):
        return "https:" + url
    return urlparse.urljoin(base, url)


# --- HLS helpers -----------------------------------------------------

def parse_master_playlist(text: str, base_url: str) -> list[dict[str, Any]]:
    qualities: list[dict[str, Any]] = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF"):
            continue
        attrs: dict[str, str] = {}
        for kv in re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line):
            attrs[kv[0]] = kv[1].strip('"')
        bw = int(attrs.get("BANDWIDTH", "0") or 0)
        res = attrs.get("RESOLUTION", "")
        height = 0
        if res and "x" in res:
            try:
                height = int(res.split("x", 1)[1])
            except ValueError:
                height = 0
        var_url = ""
        for j in range(i + 1, len(lines)):
            if lines[j].strip() and not lines[j].startswith("#"):
                var_url = lines[j].strip()
                break
        if not var_url:
            continue
        var_url = absolute(var_url, base_url)
        label = f"{height}p" if height else (f"{bw // 1000}kbps" if bw else "Variant")
        qualities.append({
            "label": label,
            "height": height,
            "bandwidth": bw,
            "url": var_url,
        })
    qualities.sort(key=lambda q: q.get("height") or 0, reverse=True)
    return qualities


def collect_subtitles(html: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for url in dict.fromkeys(SUB_RE.findall(html)):
        lang = "en"
        m = re.search(r"[/_-]([a-z]{2})[/._-]", url, re.IGNORECASE)
        if m:
            lang = m.group(1).lower()
        out.append({"url": url, "language": lang, "name": lang.upper()})
    return out


# --- Chapter / "skip intro" detection -------------------------------
#
# We never *invent* skip data - if a provider doesn't ship it, no
# button shows up. We do scan two real places where skip info shows up
# in the wild:
#
#   1. Player config in the iframe HTML. Common shapes are:
#        "skipIntro":{"start":60,"end":90}
#        "intro":{"start":...,"end":...}
#        "outro":{"start":...,"end":...}
#        introStart / introEnd numeric pairs
#
#   2. The HLS playlist's #EXT-X-DATERANGE markers (RFC 8216), when
#      the upstream tags chapters with CLASS containing intro / outro /
#      recap / credits and supplies X-START / X-END or DURATION.
#
# Result is a list of {kind: "intro"|"outro"|"recap", start: float,
# end: float}. Order doesn't matter; the channel just looks for the
# first one that contains the current playhead.

_CHAPTER_KIND_MAP = {
    "intro": "intro", "opening": "intro",
    "outro": "outro", "credits": "outro", "ending": "outro",
    "recap": "recap",
}


def _coerce_kind(label: str) -> str | None:
    s = label.lower()
    for needle, kind in _CHAPTER_KIND_MAP.items():
        if needle in s:
            return kind
    return None


def extract_chapters_from_html(html: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not html:
        return out
    seen: set[str] = set()

    # JSON-style "(skip)?(intro|outro|credits|recap|opening|ending)":{"start":N,"end":N}
    json_re = re.compile(
        r'"(?:skip)?(intro|outro|credits|recap|opening|ending)"\s*:\s*'
        r'\{\s*"start"\s*:\s*(\d+(?:\.\d+)?)\s*,\s*"end"\s*:\s*(\d+(?:\.\d+)?)',
        re.IGNORECASE,
    )
    for m in json_re.finditer(html):
        kind = _coerce_kind(m.group(1))
        if not kind or kind in seen:
            continue
        try:
            start = float(m.group(2))
            end = float(m.group(3))
        except ValueError:
            continue
        if end > start:
            out.append({"kind": kind, "start": start, "end": end})
            seen.add(kind)

    # Numeric pair fallback (introStart=60, introEnd=90)
    pair_re = re.compile(
        r'(intro|outro|credits|recap|opening|ending)[_\-]?start["\s:=,]+(\d+(?:\.\d+)?)'
        r'[\s\S]{0,200}?'
        r'(?:\1)[_\-]?end["\s:=,]+(\d+(?:\.\d+)?)',
        re.IGNORECASE,
    )
    for m in pair_re.finditer(html):
        kind = _coerce_kind(m.group(1))
        if not kind or kind in seen:
            continue
        try:
            start = float(m.group(2))
            end = float(m.group(3))
        except ValueError:
            continue
        if end > start:
            out.append({"kind": kind, "start": start, "end": end})
            seen.add(kind)

    return out


def extract_chapters_from_hls(stream_url: str, refer: str) -> list[dict[str, Any]]:
    """Look for HLS DATERANGE entries that the upstream tagged as a
    skippable section. The HLS spec lets servers attach arbitrary
    X-attributes; many "skip-aware" CDNs use X-START / X-END or
    DURATION alongside a CLASS hint."""
    out: list[dict[str, Any]] = []
    if not stream_url:
        return out
    try:
        text, _, _ = fetch(stream_url, {"Referer": refer or stream_url})
    except Exception:
        return out
    if not text or "#EXT-X-DATERANGE" not in text:
        return out
    # If this was a master playlist, dive into the first variant for
    # DATERANGE info (master playlists rarely carry chapters).
    if "#EXT-X-STREAM-INF" in text and "#EXT-X-DATERANGE" not in text.split(
        "#EXT-X-STREAM-INF", 1
    )[0]:
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            try:
                text, _, _ = fetch(absolute(s, stream_url),
                                   {"Referer": refer or stream_url})
            except Exception:
                return out
            break
    seen: set[str] = set()
    for line in text.splitlines():
        if not line.startswith("#EXT-X-DATERANGE"):
            continue
        attrs: dict[str, str] = {}
        for kv in re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line):
            attrs[kv[0]] = kv[1].strip('"')
        cls = attrs.get("CLASS", "")
        kind = _coerce_kind(cls) or _coerce_kind(attrs.get("ID", ""))
        if not kind or kind in seen:
            continue
        try:
            cstart = float(attrs.get("X-START", attrs.get("X-COM-INTRO-START", "0")) or 0)
            x_end = attrs.get("X-END", attrs.get("X-COM-INTRO-END", ""))
            if x_end:
                cend = float(x_end)
            else:
                cend = cstart + float(attrs.get("DURATION", "0") or 0)
        except ValueError:
            continue
        if cend > cstart:
            out.append({"kind": kind, "start": cstart, "end": cend})
            seen.add(kind)
    return out


def make_result(url: str, refer: str = "", html: str = "",
                stream_format: str | None = None) -> dict[str, Any] | None:
    if not url:
        return None
    fmt = stream_format
    if fmt is None:
        if ".m3u8" in url:
            fmt = "hls"
        elif ".mpd" in url:
            fmt = "dash"
        else:
            fmt = "mp4"
    qualities: list[dict[str, Any]] = []
    if fmt == "hls":
        try:
            text, _, _ = fetch(url, {"Referer": refer or url})
            if "#EXT-X-STREAM-INF" in text:
                qualities = parse_master_playlist(text, url)
        except Exception as exc:
            LOG.debug("master fetch failed for %s: %s", url, exc)
    # Many of these CDNs reject requests without a Referer matching the
    # original embed page. Default to the embed origin so Roku's Video
    # node can pass the right header.
    refer_origin = ""
    if refer:
        try:
            p = urlparse.urlparse(refer)
            if p.scheme and p.netloc:
                refer_origin = f"{p.scheme}://{p.netloc}/"
        except Exception:
            pass

    chapters = extract_chapters_from_html(html) if html else []
    if fmt == "hls" and not chapters:
        try:
            chapters = extract_chapters_from_hls(url, refer)
        except Exception as exc:  # noqa: BLE001
            LOG.debug("hls chapter probe failed for %s: %s", url, exc)
            chapters = []

    return {
        "url": url,
        "streamFormat": fmt,
        "qualities": qualities,
        "subtitles": collect_subtitles(html) if html else [],
        "chapters": chapters,
        "referer": refer_origin,
        "userAgent": UA,
    }


# --- eval(p,a,c,k,e,d) unpacker -------------------------------------

def _to_base(n: int, base: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n < base:
        return digits[n]
    return _to_base(n // base, base) + digits[n % base]


def unpack_packed(packed: str) -> str:
    """Decode the classic Dean Edwards eval(p,a,c,k,e,d) packer."""
    m = re.search(
        r"\}\('([\s\S]*?)',(\d+),(\d+),'([\s\S]*?)'\.split\('\|'\)",
        packed,
    )
    if not m:
        return ""
    p, a, c, k = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4).split("|")
    out = p
    for i in range(c - 1, -1, -1):
        if i < len(k) and k[i]:
            out = re.sub(r"\b" + _to_base(i, a) + r"\b", k[i], out)
    return out


# --- Provider resolvers ---------------------------------------------

def resolve_generic(embed_url: str, refer: str) -> dict[str, Any] | None:
    """Pull the first .m3u8 / .mp4 we can find in the iframe HTML."""
    html, _, _ = fetch(embed_url, {"Referer": refer or embed_url})
    if not html:
        return None
    m = HLS_RE.search(html)
    if m:
        return make_result(m.group(0), embed_url, html, "hls")
    m = MP4_RE.search(html)
    if m:
        return make_result(m.group(0), embed_url, html, "mp4")
    return None


def resolve_cloudnestra(rcpvip_url: str, refer: str) -> dict[str, Any] | None:
    """Follow cloudnestra rcpvip → prorcp → tmstr1.<host> chain."""
    page1, _, final = fetch(rcpvip_url, {"Referer": refer or rcpvip_url})
    if not page1:
        return None

    # Step 1 — find /prorcp/<hash>
    m = re.search(r"src:\s*['\"](/prorcp/[^'\"]+)['\"]", page1)
    if not m:
        m = re.search(r"['\"]/(prorcp/[^'\"]+)['\"]", page1)
    if not m:
        return resolve_generic(rcpvip_url, refer)
    prorcp_url = absolute(m.group(1) if m.group(1).startswith("/")
                          else "/" + m.group(1), final)

    page2, _, final2 = fetch(prorcp_url, {"Referer": final})
    if not page2:
        return None

    # Step 2 — extract the file: "..." string from Playerjs config
    fm = re.search(r'file:\s*"([^"]+)"', page2)
    if not fm:
        return None
    file_field = fm.group(1)

    # The string is "url1 or url2 or url3 ..." with placeholders {v1}, {v2}.
    # Collect the candidate hosts the player tests.
    hosts = re.findall(r'"https://(tmstr1\.[a-z0-9.-]+\.[a-z]+)"', page2)
    hosts = list(dict.fromkeys(hosts))
    if not hosts:
        hosts = ["tmstr1.cloudnestra.com"]

    raw_urls = [u.strip() for u in file_field.split(" or ") if u.strip()]
    candidates: list[str] = []
    for raw in raw_urls:
        if "{v" in raw:
            for h in hosts:
                candidates.append(re.sub(r"\{v\d+\}", h.split(".", 1)[1], raw))
        else:
            candidates.append(raw)

    seen = set()
    uniq: list[str] = []
    for u in candidates:
        if u not in seen:
            seen.add(u)
            uniq.append(u)

    for u in uniq:
        try:
            text, _, _ = fetch(u, {"Referer": final2})
            if text.startswith("#EXTM3U"):
                return make_result(u, final2, page2, "hls")
        except Exception:
            pass

    return None


def resolve_vidsrc_xyz(embed_url: str, refer: str) -> dict[str, Any] | None:
    """vidsrc.xyz / vidsrc.in / vidsrc.pm / vsembed.* — iframe to cloudnestra."""
    html, _, final = fetch(embed_url, {"Referer": refer or "https://vidsrc.xyz/"})
    if not html:
        return None
    m = re.search(r'<iframe[^>]+id=["\']player_iframe["\'][^>]+src=["\']([^"\']+)["\']', html)
    if not m:
        m = re.search(r'src=["\'](//[^"\']*cloudnestra[^"\']+)["\']', html)
    if not m:
        return None
    rcp = absolute(m.group(1), final)
    return resolve_cloudnestra(rcp, final)


def resolve_lookmovie(embed_url: str, refer: str) -> dict[str, Any] | None:
    """lookmovie2.skin /e/<id> — packed jwplayer config with hls2/3/4 keys."""
    html, _, final = fetch(embed_url, {"Referer": refer or embed_url})
    if not html:
        return None
    m = re.search(r"eval\(function\(p,a,c,k,e,d\)[\s\S]*?</script>", html)
    if not m:
        return None
    unpacked = unpack_packed(m.group(0))
    if not unpacked:
        return None
    # links={"hls3":"...","hls2":"...","hls4":"..."}
    links = {}
    for key, val in re.findall(r'"(hls[234])"\s*:\s*"([^"]+)"', unpacked):
        links[key] = val.replace("\\/", "/")
    # Player picks hls4 || hls3 || hls2
    candidates = [links.get(k) for k in ("hls4", "hls3", "hls2") if links.get(k)]
    base = final
    for u in candidates:
        if not u:
            continue
        u = absolute(u, base)
        try:
            text, _, _ = fetch(u, {"Referer": base})
            if text.startswith("#EXTM3U"):
                return make_result(u, base, "", "hls")
        except Exception:
            pass
    return None


def resolve_2embed(embed_url: str, refer: str) -> dict[str, Any] | None:
    """2embed.cc /embed/<tmdb> — finds a streamsrcs.2embed.cc swish iframe and follows it."""
    html, _, final = fetch(embed_url, {"Referer": refer or "https://hydrahd.ru/"})
    if not html:
        return None
    # data-src="https://streamsrcs.2embed.cc/swish?id=...&ref=..."
    m = re.search(r'(?:data-src|src)=["\'](https?://streamsrcs\.2embed\.cc/swish\?[^"\']+)["\']', html)
    if not m:
        # Fallback: any 2embed swish URL
        m = re.search(r'(https?://streamsrcs\.2embed\.cc/swish\?[^\s"\'<>]+)', html)
        if not m:
            return None
    swish_url = m.group(1).replace("&amp;", "&")

    # The swish page contains <iframe src="<id>"> which a tiny script
    # rewrites to "https://lookmovie2.skin/e/<id>".
    swish_html, _, swish_final = fetch(swish_url, {"Referer": final})
    if not swish_html:
        return None
    fm = re.search(r'<iframe[^>]+src=["\']([^"\']+)["\']', swish_html)
    if not fm:
        return None
    inner = fm.group(1)
    if inner.startswith("http"):
        target = inner
    else:
        target = f"https://lookmovie2.skin/e/{inner}"
    return resolve_lookmovie(target, swish_final)


def resolve_xpass(embed_url: str, refer: str) -> dict[str, Any] | None:
    """play.xpass.top /e/movie/{id} or /e/tv/{id}/{s}/{e}.

    The HTML page exposes:
      var data = { "playlist": "/mdata/<hash>/<n>/playlist.json", ... }
      var backups = [ { "id":..., "name":..., "url":..., "dl":bool }, ... ]
      var suburl = "https://sub.wyzie.io/search?id=<tmdb>&..."

    Each playlist.json returns
      { "playlist": [ { "sources": [ { "file": "<m3u8>", "type": "hls", "label": ... } ] } ] }

    We try the primary playlist first, then walk the backups list.
    """
    html, _, final = fetch(embed_url, {"Referer": refer or "https://hydrahd.ru/"})
    if not html:
        return None

    candidates: list[tuple[str, str]] = []  # (label, absolute url)

    primary = re.search(r'"playlist"\s*:\s*"([^"]+)"', html)
    if primary:
        candidates.append(("TIK primary", absolute(primary.group(1), final)))

    backups = _parse_xpass_backups(html)
    for entry in backups:
        url = entry.get("url")
        if url:
            candidates.append((entry.get("name") or "backup",
                               absolute(url, final)))

    seen: set[str] = set()
    uniq: list[tuple[str, str]] = []
    for label, url in candidates:
        if url not in seen:
            seen.add(url)
            uniq.append((label, url))

    # Order so we try non-steganographic sources first. The TIK / mdata
    # backend wraps segments inside PNG files (image/png Content-Type)
    # which Roku can't decode. MOV / VIP / SFY return real MPEG-TS.
    def src_rank(item: tuple[str, str]) -> int:
        label = item[0].upper()
        url = item[1].lower()
        if "tik" in label or "/mdata/" in url:
            return 100
        if "mov" in label or "mov.1x2" in url:
            return 0
        if "vip" in label or "/vip/" in url:
            return 1
        if "sfy" in label or "/sfy/" in url:
            return 2
        return 50
    uniq.sort(key=src_rank)

    subtitles = _fetch_xpass_subs(html)

    for label, playlist_url in uniq:
        try:
            text, _, _ = fetch(playlist_url, {"Referer": final})
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                continue
            stream_url = _xpass_first_source(data)
            if not stream_url:
                continue
            stream_url = absolute(stream_url, playlist_url)
            verify_text, verify_headers, _ = fetch(stream_url, {"Referer": final})
            if not verify_text.startswith("#EXTM3U"):
                continue
            if not _xpass_segments_look_like_video(verify_text, stream_url, final):
                LOG.debug("xpass %s: segments are not video (image/?), skip", label)
                continue
            result = make_result(stream_url, final, "", "hls")
            if result is None:
                continue
            result["subtitles"] = subtitles
            LOG.info("xpass: resolved via %s", label)
            return result
        except Exception as exc:  # noqa: BLE001
            LOG.debug("xpass %s failed: %s", label, exc)
    return None


def _parse_xpass_backups(html: str) -> list[dict[str, Any]]:
    """Pull the `var backups = [...]` array out of the page.

    The previous regex (`\\[[\\s\\S]*?\\]\\s*;`) was greedy-by-laziness:
    it would match the leading `[` and then the *first* `];` it found
    on the page — usually inside an unrelated inline script — capturing
    the wrong block. Walk brackets manually instead.
    """
    m = re.search(r"var\s+backups\s*=\s*\[", html)
    if not m:
        return []
    start = m.end() - 1  # position of `[`
    depth = 0
    in_str = False
    esc = False
    quote = ""
    end = -1
    for i in range(start, len(html)):
        ch = html[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_str = False
            continue
        if ch in ('"', "'"):
            in_str = True
            quote = ch
            continue
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end < 0:
        return []
    raw = html[start:end]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        LOG.debug("xpass backups JSON parse failed: %s", exc)
        return []
    return data if isinstance(data, list) else []


def _xpass_segments_look_like_video(master_text: str, master_url: str,
                                     refer: str) -> bool:
    """Validate a variant by probing several segments end-to-end.

    Some xpass backends (VIP for unreleased / poorly-seeded movies)
    serve only the first 1-2 segments and return HTTP 500 for the rest.
    Others (TIK) serve the full file but as PNG steganography — Roku
    can't decode that. We probe multiple segments at different positions
    and reject the source if either symptom is present.
    """
    variant_url = master_url
    if "#EXT-X-STREAM-INF" in master_text:
        for line in master_text.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            variant_url = absolute(s, master_url)
            break
        try:
            text, _, _ = fetch(variant_url, {"Referer": refer})
        except Exception:
            return True  # be permissive on errors
    else:
        text = master_text

    segs: list[str] = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        segs.append(absolute(s, variant_url))
    if not segs:
        return True

    # Probe segments spread across the playlist so we catch sources
    # that only seed a few seconds at the start.
    if len(segs) <= 4:
        sample_idx = list(range(len(segs)))
    else:
        sample_idx = [0, len(segs) // 4, len(segs) // 2,
                      (3 * len(segs)) // 4, len(segs) - 1]

    ok = 0
    bad = 0
    for idx in sample_idx:
        seg_url = segs[idx]
        try:
            req = Request(
                seg_url,
                headers={"User-Agent": UA, "Referer": refer,
                         "Range": "bytes=0-15"},
            )
            with _active_opener().open(req, timeout=10) as resp:
                head = resp.read(16)
                ctype = (resp.headers.get("Content-Type") or "").lower()
        except Exception:
            bad += 1
            continue

        # Reject steganography (PNG/JPEG)
        if head[:8] == b"\x89PNG\r\n\x1a\n" or head[:3] == b"\xff\xd8\xff":
            return False
        if "image/" in ctype and head[:1] != b"\x47":
            return False

        # Accept: MPEG-TS sync, fMP4 box, video/* type.
        if head[:1] == b"\x47":
            ok += 1
            continue
        if len(head) >= 8 and head[4:8] in (b"ftyp", b"moof", b"styp"):
            ok += 1
            continue
        if "video" in ctype or "octet-stream" in ctype or "mpegurl" in ctype:
            ok += 1
            continue
        # Non-video, non-image — count as bad.
        bad += 1

    # Need a clear majority of working samples — broken sources usually
    # only return the first 1-2 segments.
    if ok == 0:
        return False
    return ok >= max(2, len(sample_idx) - 1)


def _xpass_first_source(data: Any) -> str:
    if not isinstance(data, dict):
        return ""
    pl = data.get("playlist") or []
    for entry in pl:
        for src in (entry or {}).get("sources", []) or []:
            file = (src or {}).get("file")
            if file:
                return file
    return ""


def _fetch_xpass_subs(html: str) -> list[dict[str, Any]]:
    subs: list[dict[str, Any]] = []
    suburl_match = re.search(r'var\s+suburl\s*=\s*"([^"]+)"', html)
    if not suburl_match:
        return subs
    try:
        text, _, _ = fetch(suburl_match.group(1))
        items = json.loads(text)
    except Exception as exc:
        LOG.debug("xpass subs fetch failed: %s", exc)
        return subs
    if not isinstance(items, list):
        return subs
    for it in items[:30]:
        url = it.get("url")
        if not url:
            continue
        subs.append({
            "url": url,
            "language": (it.get("language") or "en").lower(),
            "name": it.get("display") or (it.get("language") or "EN").upper(),
        })
    return subs


def resolve_jwplayer_page(html: str, page_url: str,
                           refer: str = "") -> dict[str, Any] | None:
    """Generic JWPlayer / Playerjs resolver.

    Many pirate embeds (vidora.stream, xupload, streamtape mirrors, etc.)
    are minimal pages around a JWPlayer setup. The stream URL ends up in:
      * jwplayer().setup({file: "..."})
      * sources: [{file: "..."}]
      * an eval(p,a,c,k,e,d) packed wrapper around either of those
    Try each shape, then fall back to scraping the raw HTML for the first
    .m3u8 / .mp4 we can spot.
    """
    if not html:
        return None
    candidates: list[tuple[str, str]] = []   # (url, fmt)

    def consume(text: str) -> None:
        for pat in (
            r'file\s*:\s*[\'"]([^\'"]{8,})[\'"]',
            r'source\s*:\s*[\'"]([^\'"]{8,})[\'"]',
            r'src\s*:\s*[\'"]([^\'"]{8,}\.(?:m3u8|mp4)[^\'"]*)[\'"]',
            r'playUrl\s*:\s*[\'"]([^\'"]{8,})[\'"]',
        ):
            m = re.search(pat, text, re.IGNORECASE)
            if m:
                u = m.group(1).replace("\\/", "/")
                fmt = "hls" if ".m3u8" in u else ("mp4" if ".mp4" in u else "hls")
                candidates.append((u, fmt))
        m = HLS_RE.search(text)
        if m:
            candidates.append((m.group(0), "hls"))
        m = MP4_RE.search(text)
        if m:
            candidates.append((m.group(0), "mp4"))

    consume(html)
    packed = re.search(r"eval\(function\(p,a,c,k,e,d\)[\s\S]+?</script>", html)
    if packed:
        unpacked = unpack_packed(packed.group(0))
        if unpacked:
            consume(unpacked)

    seen: set[str] = set()
    for url, fmt in candidates:
        u = absolute(url, page_url)
        if u in seen:
            continue
        seen.add(u)
        try:
            text, _, _ = fetch(u, {"Referer": refer or page_url})
            if fmt == "hls" and not text.startswith("#EXTM3U"):
                continue
        except Exception:
            continue
        return make_result(u, refer or page_url, html, fmt)
    return None


# A best-effort registry mapping host substrings to the providers we
# support. Built lazily because the actual resolvers are defined below.
_IFRAME_FOLLOW_HOSTS: tuple[str, ...] = (
    "vidsrc.xyz", "vidsrc.in", "vidsrc.pm", "vidsrc.io", "vidsrc.net",
    "vsembed.ru", "cloudnestra.com", "2embed.cc", "2embed.org",
    "lookmovie2.skin", "play.xpass.top", "xpass.top", "vidsrc.cc",
    "vidrock.net", "vidsrc.vip", "moviesapi.club", "moviesapi.to",
    "vidora.stream", "autoembed.cc", "airflix1.com",
    "brightpathsignals.com",
)


def follow_known_iframes(html: str, page_url: str, refer: str,
                          depth: int = 0) -> dict[str, Any] | None:
    """Walk every <iframe src=...> in the HTML, dispatch each one back
    through the provider table, and return the first playable result.

    This single helper is what makes "moviesapi.club -> ww2.moviesapi.to
    -> vidora.stream" and "autoembed.cc -> vidsrc.xyz" work without
    bespoke chain code per provider.
    """
    if depth >= 3 or not html:
        return None
    iframes = re.findall(
        r'<iframe[^>]+(?:data-src|src)=["\']([^"\']+)["\']', html, re.I,
    )
    seen: set[str] = set()
    for src in iframes:
        if not src or src.startswith(("#", "javascript:", "about:")):
            continue
        url = absolute(src.replace("&amp;", "&"), page_url)
        if url in seen:
            continue
        seen.add(url)
        host = host_of(url)
        if not any(needle in host for needle in _IFRAME_FOLLOW_HOSTS):
            # Try a generic JWPlayer scrape — many no-name iframes
            # are just thin wrappers around a Playerjs config.
            try:
                ihtml, _, ifinal = fetch(url, {"Referer": refer or page_url})
            except Exception:
                continue
            if not ihtml:
                continue
            res = resolve_jwplayer_page(ihtml, ifinal, page_url)
            if res:
                return res
            # Recurse one more level into nested iframes.
            res = follow_known_iframes(ihtml, ifinal, page_url, depth + 1)
            if res:
                return res
            continue
        for needle, fn in PROVIDERS:
            if needle in host:
                try:
                    res = fn(url, page_url)
                except Exception as exc:  # noqa: BLE001
                    LOG.debug("iframe provider %s raised: %s", needle, exc)
                    res = None
                if res and res.get("url"):
                    return res
                break
    return None


def resolve_vidsrc_cc(embed_url: str, refer: str) -> dict[str, Any] | None:
    """vidsrc.cc /v2/embed/{movie|tv}/{tmdb}[/{s}/{e}].

    The page itself is Cloudflare-protected and useless to scrape, but
    the player has a stable JSON API:
      GET /api/episode/{tmdb}/servers           (movies)
      GET /api/episode/{tmdb}/{s}/{e}/servers   (tv)
        -> { "data": [ { "name": "...", "hash": "..." }, ... ] }
      GET /api/source/{hash}
        -> { "success": true,
             "data": { "stream": "https://...m3u8",
                       "subtitles": [ { "file":..., "label":..., "language":... }, ... ] } }
    The endpoints accept (and require, depending on the day) a Referer
    matching the embed origin and a same-site fetch UA.
    """
    parsed = urlparse.urlparse(embed_url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    pmatch = re.search(
        r"/(?:v2/)?embed/(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?",
        parsed.path,
    )
    if not pmatch:
        return None
    kind = pmatch.group(1)
    cid = pmatch.group(2)
    season = pmatch.group(3)
    episode = pmatch.group(4)

    if kind == "tv" and season and episode:
        servers_url = f"{origin}/api/episode/{cid}/{season}/{episode}/servers"
    else:
        servers_url = f"{origin}/api/episode/{cid}/servers"

    api_headers = {
        "Referer": embed_url,
        "Origin": origin,
        "Accept": "application/json, text/plain, */*",
        "X-Requested-With": "XMLHttpRequest",
    }

    try:
        text, _, _ = fetch(servers_url, api_headers)
    except Exception as exc:  # noqa: BLE001
        LOG.debug("vidsrc.cc servers fetch failed: %s", exc)
        return None
    if not text:
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None

    servers = payload.get("data") or payload.get("servers") or []
    if not isinstance(servers, list):
        return None

    for srv in servers:
        if not isinstance(srv, dict):
            continue
        srv_hash = srv.get("hash") or srv.get("data_id") or srv.get("id")
        if not srv_hash:
            continue
        source_url = f"{origin}/api/source/{srv_hash}"
        try:
            stext, _, _ = fetch(source_url, api_headers)
        except Exception:
            continue
        try:
            sdata = json.loads(stext)
        except json.JSONDecodeError:
            continue
        data = sdata.get("data") if isinstance(sdata, dict) else None
        if not isinstance(data, dict):
            data = sdata if isinstance(sdata, dict) else {}
        stream = (data.get("stream") or data.get("source")
                  or data.get("file") or data.get("url"))
        if isinstance(stream, list) and stream:
            stream = stream[0].get("file") if isinstance(stream[0], dict) else stream[0]
        if not stream:
            continue
        subs: list[dict[str, Any]] = []
        for s in (data.get("subtitles") or data.get("captions") or []):
            if not isinstance(s, dict):
                continue
            url = s.get("file") or s.get("url") or s.get("src")
            if not url:
                continue
            subs.append({
                "url": url,
                "language": (s.get("language") or s.get("lang")
                             or s.get("label") or "en").lower()[:2],
                "name": s.get("label") or s.get("language") or "Subtitles",
            })
        fmt = "hls" if ".m3u8" in stream else "mp4"
        result = make_result(stream, embed_url, "", fmt)
        if not result:
            continue
        if subs:
            result["subtitles"] = subs
        srv_name = srv.get("name", "?")
        LOG.info("vidsrc.cc resolved via %s", srv_name)
        return result
    return None


def resolve_moviesapi(embed_url: str, refer: str) -> dict[str, Any] | None:
    """moviesapi.club / moviesapi.to /movie/{tmdb} or /tv/{tmdb}-{s}-{e}.

    The page just iframes ww2.moviesapi.to which in turn iframes a real
    player (vidora.stream, ww1, etc.). Walk the iframe chain and let the
    generic JWPlayer / known-provider handlers do the real work.
    """
    html, _, final = fetch(
        embed_url,
        {"Referer": refer or "https://hydrahd.ru/"},
    )
    if not html:
        return None
    res = follow_known_iframes(html, final, refer or final)
    if res:
        return res
    # Some episodes embed the player URL directly.
    return resolve_jwplayer_page(html, final, refer or final)


def resolve_vidora(embed_url: str, refer: str) -> dict[str, Any] | None:
    """vidora.stream / ww*.moviesapi.* — JWPlayer with eval(p,a,c,k,e,d)."""
    html, _, final = fetch(embed_url, {"Referer": refer or "https://moviesapi.to/"})
    if not html:
        return None
    return resolve_jwplayer_page(html, final, refer or final)


def resolve_vidrock(embed_url: str, refer: str) -> dict[str, Any] | None:
    """vidrock.net / vidsrc.vip — Cloudflare-fronted SPA with a JSON API.

    Documented endpoint shape:
      POST /api/movie/{tmdb}      (movies)
      POST /api/tv/{tmdb}/{s}/{e} (tv)
    Returns either {sources:[{file,..}],subtitle:[...]} or a base64-
    encoded payload that decodes to the same structure.
    """
    parsed = urlparse.urlparse(embed_url)
    pmatch = re.search(
        r"/embed/(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?",
        parsed.path,
    )
    if not pmatch:
        return None
    kind, cid, season, episode = pmatch.groups()

    # vidsrc.vip is just a thin shell that redirects to vidrock — make
    # sure we hit vidrock directly so the API origin matches.
    api_origin = "https://vidrock.net"
    if kind == "tv" and season and episode:
        api_url = f"{api_origin}/api/tv/{cid}/{season}/{episode}"
    else:
        api_url = f"{api_origin}/api/movie/{cid}"

    headers = {
        "Referer": f"{api_origin}/embed/{kind}/{cid}",
        "Origin": api_origin,
        "Accept": "application/json, text/plain, */*",
        "X-Requested-With": "XMLHttpRequest",
    }

    try:
        text, _, _ = fetch(api_url, headers)
    except Exception as exc:  # noqa: BLE001
        LOG.debug("vidrock api fetch failed: %s", exc)
        return None
    if not text:
        return None

    payload: Any = None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        # Some deployments return base64-encoded JSON in plain text.
        try:
            decoded = base64_decode(text.strip())
            if decoded:
                payload = json.loads(decoded)
        except Exception:
            pass
    if not isinstance(payload, dict):
        return None

    # Walk the response for the first stream URL we recognize.
    streams: list[str] = []
    def walk(obj: Any) -> None:
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, str) and (".m3u8" in v or ".mp4" in v):
                    streams.append(v)
                else:
                    walk(v)
        elif isinstance(obj, list):
            for it in obj:
                walk(it)
    walk(payload)
    if not streams:
        return None

    subs: list[dict[str, Any]] = []
    raw_subs = (payload.get("subtitle") or payload.get("subtitles")
                or payload.get("captions") or [])
    if isinstance(raw_subs, list):
        for s in raw_subs:
            if not isinstance(s, dict):
                continue
            url = s.get("file") or s.get("url")
            if not url:
                continue
            subs.append({
                "url": url,
                "language": (s.get("language") or s.get("lang")
                             or "en").lower()[:2],
                "name": s.get("label") or s.get("language") or "Subtitles",
            })

    stream = streams[0]
    fmt = "hls" if ".m3u8" in stream else "mp4"
    result = make_result(stream, embed_url, "", fmt)
    if not result:
        return None
    if subs:
        result["subtitles"] = subs
    LOG.info("vidrock resolved via %s", api_url)
    return result


def base64_decode(s: str) -> str:
    import base64 as _b64
    pad = "=" * (-len(s) % 4)
    try:
        return _b64.b64decode(s + pad).decode("utf-8", "replace")
    except Exception:
        return ""


def resolve_autoembed(embed_url: str, refer: str) -> dict[str, Any] | None:
    """autoembed.cc / player.autoembed.cc — typically iframes vidsrc.xyz
    or one of its mirrors. Walk the iframe chain through our existing
    provider table.
    """
    html, _, final = fetch(embed_url, {"Referer": refer or "https://hydrahd.ru/"})
    if not html:
        return None
    res = follow_known_iframes(html, final, refer or final)
    if res:
        return res
    return resolve_jwplayer_page(html, final, refer or final)


def resolve_airflix(embed_url: str, refer: str) -> dict[str, Any] | None:
    """airflix1.com /embed/{movie|tv}/{tmdb}[/{s}/{e}].

    The airflix1 page is a thin wrapper that iframes
    brightpathsignals.com/embed/... Both pages are protected by a
    devtools-disabled JS shell, but the player config is plain JSON
    inlined into the bps page and exposes:

      CONFIG.streamDataApiUrl = "https://streamdata.vaplayer.ru/api.php"
      CONFIG.idType           = "tmdb" | "imdb"
      CONFIG.mediaType        = "movie" | "tv"

    `availableSources: ["justhd"]` is the default — calling that API
    with `?tmdb=<id>&type=movie` (or
    `?tmdb=<id>&type=tv&season=X&episode=Y`) returns a JSON envelope:

      { "status_code":"200",
        "data": {
          "title": ...,
          "stream_urls": [ "https://.../master.m3u8", ... ],
          "default_subs": [ ... ]
        } }

    The stream_urls list is several CDN backends in priority order
    (the first few are the active mirror domains, the last is
    tmstrd.justhd.tv). Try each one until we find a real master
    playlist.
    """
    parsed = urlparse.urlparse(embed_url)
    path = parsed.path

    m = re.search(r"/embed/(movie|tv)/(tt\d+|\d+)(?:/(\d+)/(\d+))?", path)
    if not m:
        return None
    media_type = m.group(1)
    media_id = m.group(2)
    season = m.group(3)
    episode = m.group(4)

    id_param = "imdb" if media_id.startswith("tt") else "tmdb"

    api_url = (
        f"https://streamdata.vaplayer.ru/api.php"
        f"?{id_param}={urlparse.quote(media_id)}"
        f"&type={media_type}"
    )
    if media_type == "tv" and season and episode:
        api_url += f"&season={season}&episode={episode}"

    # The bps origin is what the real player ships; vaplayer.ru only
    # responds when both Referer and Origin match.
    api_referer = "https://brightpathsignals.com/"
    text, _, _ = fetch(api_url, {
        "Referer": api_referer,
        "Origin": "https://brightpathsignals.com",
    })
    if not text:
        return None
    try:
        envelope = json.loads(text)
    except json.JSONDecodeError:
        return None
    if str(envelope.get("status_code")) != "200":
        return None
    payload = envelope.get("data") or {}
    streams = payload.get("stream_urls") or []
    if not streams:
        return None

    subs: list[dict[str, Any]] = []
    for s in payload.get("default_subs") or []:
        if not isinstance(s, dict):
            continue
        url = s.get("url") or s.get("file")
        if not url:
            continue
        subs.append({
            "url": url,
            "language": (s.get("lang") or s.get("language") or "en").lower(),
            "name": s.get("label") or (s.get("lang") or "EN").upper(),
        })

    for stream_url in streams:
        try:
            playlist, _, _ = fetch(stream_url, {"Referer": api_referer})
        except Exception:
            continue
        if not playlist.startswith("#EXTM3U"):
            continue
        result = make_result(stream_url, api_referer, "", "hls")
        if result is None:
            continue
        if subs:
            result["subtitles"] = subs
        LOG.info("airflix1 resolved via %s", host_of(stream_url))
        return result

    return None


def stub_provider(name: str) -> Callable[[str, str], dict[str, Any] | None]:
    def _fn(embed_url: str, refer: str) -> dict[str, Any] | None:
        LOG.info("provider %s not implemented for %s", name, embed_url)
        return None
    return _fn


# Map host substrings → resolver. First match wins. Order matters.
PROVIDERS: list[tuple[str, Callable[[str, str], dict[str, Any] | None]]] = [
    ("cloudnestra.com",     resolve_cloudnestra),
    ("vidsrc.xyz",          resolve_vidsrc_xyz),
    ("vidsrc.in",           resolve_vidsrc_xyz),
    ("vidsrc.pm",           resolve_vidsrc_xyz),
    ("vidsrc.io",           resolve_vidsrc_xyz),
    ("vidsrc.net",          resolve_vidsrc_xyz),
    ("vsembed.ru",          resolve_vidsrc_xyz),
    ("vidsrc.cc",           resolve_vidsrc_cc),
    ("vidsrc.vip",          resolve_vidrock),
    ("vidrock.net",         resolve_vidrock),
    ("2embed.cc",           resolve_2embed),
    ("2embed.org",          resolve_2embed),
    ("lookmovie2.skin",     resolve_lookmovie),
    ("moviesapi.club",      resolve_moviesapi),
    ("moviesapi.to",        resolve_moviesapi),
    ("vidora.stream",       resolve_vidora),
    ("autoembed.cc",        resolve_autoembed),
    ("xpass.top",           resolve_xpass),
    ("play.xpass.top",      resolve_xpass),
    ("airflix1.com",        resolve_airflix),
    ("brightpathsignals.com", resolve_airflix),
    ("vidfast.pro",         stub_provider("vidfast.pro")),
    ("videasy.net",         stub_provider("videasy.net")),
    ("embed.su",            stub_provider("embed.su")),
    ("peachify.top",        stub_provider("peachify.top")),
    ("primesrc.me",         stub_provider("primesrc.me")),
    ("vidup.to",            stub_provider("vidup.to")),
    ("vidking.net",         stub_provider("vidking.net")),
    ("embedmaster.link",    stub_provider("embedmaster.link")),
    ("ythd.org",            stub_provider("ythd.org")),
    ("kllamrd.org",         stub_provider("kllamrd.org")),
    ("frembed.bond",        stub_provider("frembed.bond")),
]


def extract_content_ids(embed_url: str, kind: str = "",
                         imdb: str = "", tmdb: str = "",
                         season: str = "", episode: str = "") -> dict[str, str]:
    """Pull tmdb/imdb/season/episode out of an embed URL when not given.

    Most provider URLs contain a TMDB id or IMDB id and (for TV) season/
    episode in the path. The exact shape varies — we cover the common
    permutations: /movie/<id>, /movie/tt<id>, /tv/<id>/<s>/<e>,
    /tv/<id>-<s>-<e>, ?tmdb=<id>, ?imdb=tt<id>, etc.
    """
    out = {
        "kind": kind or "",
        "tmdb": tmdb or "",
        "imdb": imdb or "",
        "season": season or "",
        "episode": episode or "",
    }

    parsed = urlparse.urlparse(embed_url)
    path = parsed.path
    qs = dict(urlparse.parse_qsl(parsed.query))

    if not out["tmdb"] and "tmdb" in qs:
        out["tmdb"] = qs["tmdb"]
    if not out["imdb"] and "imdb" in qs:
        out["imdb"] = qs["imdb"]
    if not out["imdb"] and "id" in qs and qs["id"].startswith("tt"):
        out["imdb"] = qs["id"]
    if not out["tmdb"] and "id" in qs and qs["id"].isdigit():
        out["tmdb"] = qs["id"]
    if not out["season"] and "season" in qs:
        out["season"] = qs["season"]
    if not out["episode"] and "episode" in qs:
        out["episode"] = qs["episode"]

    if not out["kind"]:
        if "/movie/" in path:
            out["kind"] = "movie"
        elif "/tv/" in path or "/series/" in path or "/episode" in path:
            out["kind"] = "tv"

    # /movie/<id> or /movie/tt<id>
    m = re.search(r"/movie/(tt\d+|\d+)", path)
    if m:
        token = m.group(1)
        if token.startswith("tt"):
            out["imdb"] = out["imdb"] or token
        else:
            out["tmdb"] = out["tmdb"] or token

    # /tv/<id>/<season>/<episode> or /tv/<id>-<season>-<episode>
    for pat in [
        r"/tv/(tt\d+|\d+)[/_-](\d+)[/_-](\d+)",
        r"/series/(tt\d+|\d+)[/_-](\d+)[/_-](\d+)",
        r"/embed/tv/(tt\d+|\d+)/(\d+)/(\d+)",
    ]:
        m = re.search(pat, path)
        if m:
            tok = m.group(1)
            if tok.startswith("tt"):
                out["imdb"] = out["imdb"] or tok
            else:
                out["tmdb"] = out["tmdb"] or tok
            out["season"] = out["season"] or m.group(2)
            out["episode"] = out["episode"] or m.group(3)
            break

    # /embed/<imdb> bare
    m = re.search(r"/embed/(tt\d+)", path)
    if m and not out["imdb"]:
        out["imdb"] = m.group(1)

    # /embed/<tmdb> bare numeric
    m = re.search(r"/embed/(\d{2,})(?:[/?]|$)", path)
    if m and not out["tmdb"]:
        out["tmdb"] = m.group(1)

    return out


def fallback_via_known_providers(ids: dict[str, str],
                                  refer: str) -> dict[str, Any] | None:
    """If we have a TMDB id but the requested provider is unsupported or
    broken, exhaustively try every working provider chain we know about
    until one returns a stream that survives the playable-segment check.
    """
    tmdb = ids.get("tmdb")
    imdb = ids.get("imdb")
    if not tmdb and not imdb:
        return None
    kind = ids.get("kind") or "movie"
    season = ids.get("season") or "1"
    episode = ids.get("episode") or "1"
    is_tv = (kind == "tv")

    candidates: list[tuple[str, str, Callable[[str, str], dict[str, Any] | None]]] = []

    # airflix1 — declared the default high-quality mirror by hydrahd; the
    # vaplayer.ru API returns a fresh master.m3u8 for almost any title
    # without a token, so try this first.
    primary_id = tmdb or imdb
    if primary_id:
        if is_tv:
            candidates.append((
                "airflix1",
                f"https://airflix1.com/embed/tv/{primary_id}/{season}/{episode}",
                resolve_airflix,
            ))
        else:
            candidates.append((
                "airflix1", f"https://airflix1.com/embed/movie/{primary_id}",
                resolve_airflix,
            ))

    # xpass.top — best provider when MOV/MEG seeds the title; segments
    # come back as real video/mp2t most of the time.
    if tmdb:
        if is_tv:
            candidates.append((
                "xpass", f"https://play.xpass.top/e/tv/{tmdb}/{season}/{episode}",
                resolve_xpass,
            ))
        else:
            candidates.append((
                "xpass", f"https://play.xpass.top/e/movie/{tmdb}",
                resolve_xpass,
            ))

    # 2embed.cc — chains to lookmovie2.skin. Works for older / popular
    # titles; the lookmovie chain is rejected for new titles where it
    # hands back PNG steganography.
    if tmdb:
        if is_tv:
            candidates.append((
                "2embed.cc", f"https://www.2embed.cc/embedtv/{tmdb}&s={season}&e={episode}",
                resolve_2embed,
            ))
        else:
            candidates.append((
                "2embed.cc", f"https://www.2embed.cc/embed/{tmdb}",
                resolve_2embed,
            ))

    # Multiple vidsrc.xyz mirror domains — they share the same backend
    # but Turnstile rollout is per-domain, so any of them might be the
    # one that's currently un-gated.
    vidsrc_hosts = ["vidsrc.xyz", "vidsrc.in", "vidsrc.pm", "vidsrc.io",
                    "vidsrc.net", "vsembed.ru"]
    for host in vidsrc_hosts:
        if tmdb:
            if is_tv:
                candidates.append((
                    host, f"https://{host}/embed/tv/{tmdb}/{season}-{episode}",
                    resolve_vidsrc_xyz,
                ))
            else:
                candidates.append((
                    host, f"https://{host}/embed/movie/{tmdb}",
                    resolve_vidsrc_xyz,
                ))
        if imdb:
            if is_tv:
                candidates.append((
                    f"{host}-imdb",
                    f"https://{host}/embed/tv/{imdb}/{season}-{episode}",
                    resolve_vidsrc_xyz,
                ))
            else:
                candidates.append((
                    f"{host}-imdb", f"https://{host}/embed/movie/{imdb}",
                    resolve_vidsrc_xyz,
                ))

    # 2embed.org alternate.
    if tmdb:
        if is_tv:
            candidates.append((
                "2embed.org",
                f"https://2embed.org/embed/tv/{tmdb}/{season}/{episode}",
                resolve_2embed,
            ))
        else:
            candidates.append((
                "2embed.org", f"https://2embed.org/embed/{tmdb}",
                resolve_2embed,
            ))

    # vidsrc.cc — uses its own /api/source/{hash} chain. Independent of
    # the cloudnestra Turnstile rollout that gates vidsrc.xyz, so often
    # the only working option for unreleased / new titles.
    if tmdb:
        if is_tv:
            candidates.append((
                "vidsrc.cc",
                f"https://vidsrc.cc/v2/embed/tv/{tmdb}/{season}/{episode}",
                resolve_vidsrc_cc,
            ))
        else:
            candidates.append((
                "vidsrc.cc",
                f"https://vidsrc.cc/v2/embed/movie/{tmdb}",
                resolve_vidsrc_cc,
            ))

    # vidrock / vidsrc.vip — direct JSON API.
    if tmdb:
        if is_tv:
            candidates.append((
                "vidrock",
                f"https://vidrock.net/embed/tv/{tmdb}/{season}/{episode}",
                resolve_vidrock,
            ))
        else:
            candidates.append((
                "vidrock",
                f"https://vidrock.net/embed/movie/{tmdb}",
                resolve_vidrock,
            ))

    # moviesapi.club -> ww*.moviesapi.to -> vidora.stream chain.
    if tmdb:
        if is_tv:
            candidates.append((
                "moviesapi",
                f"https://moviesapi.club/tv/{tmdb}-{season}-{episode}",
                resolve_moviesapi,
            ))
        else:
            candidates.append((
                "moviesapi",
                f"https://moviesapi.club/movie/{tmdb}",
                resolve_moviesapi,
            ))

    # autoembed.cc — usually iframes vidsrc.xyz, but occasionally has
    # an independent chain. Prefer IMDB id if we have one.
    if imdb:
        if is_tv:
            candidates.append((
                "autoembed",
                f"https://player.autoembed.cc/embed/tv/{imdb}/{season}/{episode}",
                resolve_autoembed,
            ))
        else:
            candidates.append((
                "autoembed",
                f"https://player.autoembed.cc/embed/movie/{imdb}",
                resolve_autoembed,
            ))

    seen_urls: set[str] = set()
    for label, url, fn in candidates:
        if url in seen_urls:
            continue
        seen_urls.add(url)
        LOG.info("fallback try %s: %s", label, url)
        try:
            res = fn(url, refer)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("fallback %s raised: %s", label, exc)
            continue
        if not res or not res.get("url"):
            continue
        if _stream_is_playable(res["url"], res.get("referer") or refer):
            LOG.info("fallback %s succeeded", label)
            return res
        LOG.info("fallback %s returned a URL but it isn't playable", label)
    LOG.warning("all fallback providers exhausted for tmdb=%s imdb=%s", tmdb, imdb)
    return None


# Backwards-compat alias for any older callers.
fallback_via_vidsrc_xyz = fallback_via_known_providers


def _stream_is_playable(stream_url: str, refer: str) -> bool:
    """Validate a master m3u8 + a couple of segments end-to-end.

    Catches sources that pass the page-level scrape but actually serve
    PNG/JPEG steganography, error pages, or only the first 1-2 seconds
    of real content (the "Universal logo only" pattern).
    """
    if not stream_url or not stream_url.lower().endswith((".m3u8",)):
        # Direct mp4 / unknown — let it through.
        return True
    try:
        text, _, _ = fetch(stream_url, {"Referer": refer or stream_url})
    except Exception:
        return False
    if not text.startswith("#EXTM3U"):
        return False

    variant_text = text
    variant_url = stream_url
    if "#EXT-X-STREAM-INF" in text:
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            variant_url = absolute(s, stream_url)
            try:
                variant_text, _, _ = fetch(variant_url, {"Referer": refer})
            except Exception:
                return False
            break

    segs: list[str] = []
    for line in variant_text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        segs.append(absolute(s, variant_url))
    if not segs:
        return False

    if len(segs) <= 3:
        sample_idx = list(range(len(segs)))
    else:
        sample_idx = [0, len(segs) // 2, len(segs) - 1]
    ok = 0
    bad = 0
    for idx in sample_idx:
        try:
            req = Request(segs[idx], headers={"User-Agent": UA, "Referer": refer,
                                              "Range": "bytes=0-15"})
            with _active_opener().open(req, timeout=10) as resp:
                head = resp.read(16)
                ctype = (resp.headers.get("Content-Type") or "").lower()
        except Exception:
            bad += 1
            continue
        if head[:8] == b"\x89PNG\r\n\x1a\n" or head[:3] == b"\xff\xd8\xff":
            return False
        if "image/" in ctype and head[:1] != b"\x47":
            return False
        if (head[:1] == b"\x47"
                or (len(head) >= 8 and head[4:8] in (b"ftyp", b"moof", b"styp"))
                or "video" in ctype or "octet-stream" in ctype):
            ok += 1
        else:
            bad += 1
    if ok == 0:
        return False
    return ok >= max(2, len(sample_idx) - 1) if len(sample_idx) > 1 else ok > 0


def resolve_embed(embed_url: str, refer: str,
                  kind: str = "", imdb: str = "", tmdb: str = "",
                  season: str = "", episode: str = "") -> dict[str, Any] | None:
    h = host_of(embed_url)
    handler_matched = False
    for needle, fn in PROVIDERS:
        if needle in h:
            handler_matched = True
            try:
                res = fn(embed_url, refer)
                if res and res.get("url") and _stream_is_playable(res["url"], res.get("referer") or refer):
                    return res
                if res:
                    LOG.info("provider %s returned %s but stream not playable",
                              needle, res.get("url", "")[:80])
            except Exception as exc:  # noqa: BLE001
                LOG.exception("provider %s raised on %s: %s", needle, embed_url, exc)
            break

    # Generic best-effort scrape (only if no specific handler matched —
    # named handlers already do their own scraping).
    if not handler_matched:
        try:
            res = resolve_generic(embed_url, refer)
            if res and res.get("url") and _stream_is_playable(res["url"], res.get("referer") or refer):
                return res
        except Exception as exc:  # noqa: BLE001
            LOG.warning("generic fallback failed for %s: %s", embed_url, exc)

    # TMDB-id fallback through other working providers so unsupported
    # mirrors still play.
    ids = extract_content_ids(embed_url, kind, imdb, tmdb, season, episode)
    return fallback_via_known_providers(ids, refer)


# --- Subtitle conversion --------------------------------------------

_SRT_TS_RE = re.compile(
    r"(\d{2}:\d{2}:\d{2})[,.](\d{1,3})\s*-->\s*(\d{2}:\d{2}:\d{2})[,.](\d{1,3})"
)


def _to_webvtt(text: str) -> str:
    """Convert SRT (or WebVTT) subtitle text to canonical WebVTT.

    Already-WebVTT input is returned with a normalized header. SRT input
    has its `,` decimal separator rewritten to `.` and gets a `WEBVTT`
    header prepended.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    has_header = text.lstrip().upper().startswith("WEBVTT")

    def fix_ts(m: re.Match[str]) -> str:
        a, ms_a, b, ms_b = m.group(1), m.group(2), m.group(3), m.group(4)
        ms_a = ms_a.ljust(3, "0")[:3]
        ms_b = ms_b.ljust(3, "0")[:3]
        return f"{a}.{ms_a} --> {b}.{ms_b}"

    body = _SRT_TS_RE.sub(fix_ts, text)
    if has_header:
        return body
    return "WEBVTT\n\n" + body.lstrip("\n")


# --- HTTP server -----------------------------------------------------

# Forwarded/Hop-by-hop headers we never copy back to the Roku client.
_SKIP_RESP_HEADERS = {
    "transfer-encoding", "connection", "keep-alive",
    "proxy-authenticate", "proxy-authorization", "te",
    "trailers", "upgrade", "content-encoding",
    "content-length",  # we set our own
}


class Handler(BaseHTTPRequestHandler):
    server_version = "HydraHDResolver/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("%s - " + fmt, self.address_string(), *args)

    # ---- routing -------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse.urlparse(self.path)
        if parsed.path == "/health":
            self._respond(200, {"ok": True})
            return
        if parsed.path == "/providers":
            self._respond(200, {"providers": [needle for needle, _ in PROVIDERS]})
            return
        params = dict(urlparse.parse_qsl(parsed.query))
        # Per-Roku cookie jar so concurrent devices don't trample each
        # other's session state. cid falls back to the client's TCP peer
        # address so older channel builds still get *some* isolation.
        cid = params.get("cid") or self.client_address[0]
        self._cid = cid
        _set_active_opener(_opener_for(cid))
        try:
            if parsed.path == "/stream":
                self._serve_stream(params)
                return
            if parsed.path != "/resolve":
                self._respond(404, {"error": "not found"})
                return
            self._serve_resolve(params)
        finally:
            _clear_active_opener()

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    # ---- /resolve ------------------------------------------------------

    def _serve_resolve(self, params: dict[str, str]) -> None:
        embed = params.get("embed", "")
        refer = params.get("refer", "")
        if not embed:
            self._respond(400, {"error": "missing embed"})
            return
        try:
            result = resolve_embed(
                embed, refer,
                kind=params.get("kind", ""),
                imdb=params.get("imdb", ""),
                tmdb=params.get("tmdb", ""),
                season=params.get("season", ""),
                episode=params.get("episode", ""),
            )
        except Exception as exc:  # noqa: BLE001
            LOG.exception("resolve failed for %s", embed)
            self._respond(500, {"error": str(exc)})
            return
        if not result:
            # Roku ResolveTask treats 204 as "try another mirror".
            self._respond(204, {"url": ""})
            return

        # Wrap the upstream stream/subtitle URLs in /stream so the
        # resolver's IP + headers are what actually reaches the CDN.
        # Many providers (lookmovie2, tmstr, xpass) IP-lock or
        # Referer-lock segment fetches and would otherwise return 403/414
        # to the Roku.
        upstream_url = result.get("url", "")
        upstream_referer = result.get("referer", "") or ""
        upstream_ua = result.get("userAgent", "") or UA
        if upstream_url:
            result["url"] = self._proxy(upstream_url, upstream_referer, upstream_ua)
        for q in result.get("qualities") or []:
            if q.get("url"):
                q["url"] = self._proxy(q["url"], upstream_referer, upstream_ua)
        for s in result.get("subtitles") or []:
            if s.get("url"):
                s["url"] = self._proxy(s["url"], upstream_referer, upstream_ua)
        # Roku no longer needs to set Referer itself — the proxy does it.
        result["referer"] = ""
        result["userAgent"] = ""
        self._respond(200, result)

    # ---- /stream proxy -------------------------------------------------

    def _serve_stream(self, params: dict[str, str]) -> None:
        target = params.get("u", "")
        refer = params.get("r", "")
        ua = params.get("ua", "") or UA
        if not target:
            self._respond(400, {"error": "missing u"})
            return

        headers: dict[str, str] = {"User-Agent": ua, "Accept": "*/*"}
        if refer:
            headers["Referer"] = refer
            try:
                p = urlparse.urlparse(refer)
                if p.scheme and p.netloc:
                    headers["Origin"] = f"{p.scheme}://{p.netloc}"
            except Exception:
                pass
        rng = self.headers.get("Range")
        if rng:
            headers["Range"] = rng

        req = Request(target, headers=headers, method=self.command)
        try:
            resp = _active_opener().open(req, timeout=30)
        except HTTPError as e:
            LOG.warning("proxy HTTP %s on %s", e.code, target)
            self.send_response(e.code)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        except URLError as e:
            LOG.warning("proxy URL error on %s: %s", target, e)
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        try:
            ctype = (resp.headers.get("Content-Type") or "").lower()
            final_url = resp.geturl()
            looks_hls = (
                ".m3u8" in target.lower()
                or ".m3u8" in final_url.lower()
                or "mpegurl" in ctype
            )
            if looks_hls:
                raw = resp.read()
                text = raw.decode("utf-8", "replace")
                rewritten = self._rewrite_hls(text, final_url, refer, ua)
                body = rewritten.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                if self.command == "GET":
                    self.wfile.write(body)
                return

            # Subtitle handling: most providers (wyzie, opensubtitles,
            # subdl) return SRT regardless of the format= query param,
            # often with Content-Type text/plain. Roku's Video node only
            # plays WebVTT — so detect SRT and convert.
            looks_subtitle = (
                "wyzie" in target.lower()
                or "subtitle" in target.lower()
                or ".srt" in target.lower()
                or ".vtt" in target.lower()
                or "format=srt" in target.lower()
                or "format=webvtt" in target.lower()
                or "format=vtt" in target.lower()
                or ctype.startswith("text/plain")
                or ctype.startswith("text/vtt")
                or ctype.startswith("application/x-subrip")
            )
            if looks_subtitle:
                raw = resp.read()
                try:
                    text = raw.decode("utf-8-sig", "replace")
                except Exception:
                    text = raw.decode("utf-8", "replace")
                vtt = _to_webvtt(text)
                body = vtt.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/vtt; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                if self.command == "GET":
                    self.wfile.write(body)
                return

            # Binary forward (segments, keys, mp4).
            # Some upstreams mislabel TS / fMP4 segments as text/html or
            # image/* (anti-hotlinking trick). Sniff the first few bytes
            # and rewrite Content-Type so Roku's HLS decoder accepts them.
            head = resp.read(8)
            sniffed_ct = ctype

            # Reject PNG / JPEG steganography — Roku can't decode video
            # data hidden inside an image container, so don't pretend it
            # can. Returning 502 lets Roku move on to the next segment
            # quickly instead of stalling on bad bytes.
            if head[:8] == b"\x89PNG\r\n\x1a\n" or head[:3] == b"\xff\xd8\xff":
                LOG.warning("proxy refused stego segment (image bytes) for %s",
                             target[:120])
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            if head[:1] == b"\x47":
                sniffed_ct = "video/mp2t"
            elif len(head) >= 8 and head[4:8] in (b"ftyp", b"moof", b"styp", b"sidx"):
                sniffed_ct = "video/mp4"
            elif not ctype or "text/html" in ctype or "image/" in ctype:
                # Unknown/wrong upstream type — assume mpeg-ts.
                sniffed_ct = "video/mp2t"

            self.send_response(resp.status)
            for h, v in resp.headers.items():
                if h.lower() in _SKIP_RESP_HEADERS:
                    continue
                if h.lower() == "content-type":
                    continue
                self.send_header(h, v)
            self.send_header("Content-Type", sniffed_ct)
            cl = resp.headers.get("Content-Length")
            if cl:
                self.send_header("Content-Length", cl)
            self.end_headers()
            if self.command != "GET":
                return
            try:
                if head:
                    self.wfile.write(head)
                while True:
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                return
        finally:
            try:
                resp.close()
            except Exception:
                pass

    def _rewrite_hls(self, text: str, base_url: str,
                     refer: str, ua: str) -> str:
        out: list[str] = []
        uri_re = re.compile(r'URI="([^"]+)"')

        def proxify(u: str) -> str:
            absu = absolute(u, base_url)
            return self._proxy(absu, refer, ua)

        for line in text.splitlines():
            stripped = line.strip()
            if not stripped:
                out.append(line)
                continue
            if stripped.startswith("#"):
                # Rewrite URI= attributes (#EXT-X-KEY, #EXT-X-MAP,
                # #EXT-X-MEDIA, etc.)
                if "URI=" in line:
                    line = uri_re.sub(
                        lambda m: 'URI="' + proxify(m.group(1)) + '"',
                        line,
                    )
                out.append(line)
            else:
                # Variant-playlist or segment URL.
                out.append(proxify(stripped))
        return "\n".join(out)

    def _proxy(self, target: str, refer: str = "",
               ua: str = "") -> str:
        # Already proxied? Don't double-wrap.
        if "/stream?" in target and target.startswith(self._public_base()):
            return target
        params: dict[str, str] = {"u": target, "r": refer or "", "ua": ua or ""}
        cid = getattr(self, "_cid", "") or ""
        if cid:
            params["cid"] = cid
        qs = urlparse.urlencode(params)
        return self._public_base() + "/stream?" + qs

    def _public_base(self) -> str:
        host = self.headers.get("Host", "")
        if not host:
            sa = self.server.server_address
            host = f"{sa[0]}:{sa[1]}"
        return f"http://{host}"

    # ---- helpers -------------------------------------------------------

    def _respond(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if status != 204:
            self.wfile.write(body)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--state-dir",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "state"),
        help="Directory for persisted resolver state (cookie cache).",
    )
    parser.add_argument(
        "--no-cookie-cache",
        action="store_true",
        help="Disable persisting per-client cookie jars across restarts.",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if not args.no_cookie_cache:
        cookie_path = os.path.join(args.state_dir, "cookies.pickle")
        _start_cookie_persistence(cookie_path)
        LOG.info("cookie cache: %s (flush every %ds)", cookie_path, CACHE_FLUSH_S)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    LOG.info("listening on http://%s:%d", args.host, args.port)
    LOG.info("providers: %s", ", ".join(needle for needle, _ in PROVIDERS))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down")
    finally:
        _COOKIE_FLUSH_STOP.set()
        _save_cookie_cache()
    return 0


if __name__ == "__main__":
    sys.exit(main())

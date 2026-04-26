# Stream resolver

Tiny Python service that turns the iframe URLs HydraHD hands out
(`https://vidsrc.cc/v2/embed/movie/19995`,
`https://player.videasy.net/movie/19995`, …) into direct video URLs the
Roku Video node can actually play.

It's deliberately stdlib-only — no Flask, no requests, nothing to
`pip install` — so you can drop it on a Pi, a NAS, or `python3 server.py`
on your laptop.

## Run

```bash
python3 server.py --port 8787 --verbose
```

Then in the Roku channel: **Settings → Set Resolver…** →
`http://<machine-ip>:8787`.

## API

`GET /resolve?embed=<url>&refer=<page-url>&kind=movie|tv&imdb=tt…&tmdb=…&season=1&episode=2`

Response (`application/json`):

```json
{
  "url": "https://example.cdn/master.m3u8",
  "streamFormat": "hls",
  "qualities": [
    { "label": "1080p", "height": 1080, "bandwidth": 5000000,
      "url": "https://example.cdn/1080.m3u8" }
  ],
  "subtitles": [
    { "url": "https://example.cdn/en.vtt", "language": "en", "name": "EN" }
  ]
}
```

If the resolver can't extract a stream, it returns HTTP 204 and the Roku
channel will mark the mirror as failed and let the user pick another.

## Working providers (as of 2026-04)

| Host                   | Status     | Notes                                                  |
|------------------------|------------|--------------------------------------------------------|
| 2embed.cc / .org       | ✅ working | Chain → streamsrcs → lookmovie2.skin (packed jwplayer) |
| lookmovie2.skin        | ✅ working | Direct, eval-packed jwplayer                           |
| play.xpass.top         | ✅ working | Direct .m3u8 + multi-server backup list + wyzie subs   |
| vidsrc.xyz family      | 🟡 was OK  | cloudnestra `/rcpvip/` retired in favor of `/rcp/`     |
|                        |            | Turnstile-gated; first request occasionally still      |
|                        |            | succeeds, after that needs Cloudflare Turnstile token  |
| cloudnestra.com        | 🟡 was OK  | Same Turnstile gate now                                |
| vidsrc.cc              | 🚫 stub    | Eval-packed embed.min.js                               |
| vidfast.pro            | 🚫 stub    | Encrypted player bundle (~170 KB obfuscated)           |
| videasy.net            | 🚫 stub    | Encrypted player bundle                                |
| vidrock.net            | 🚫 stub    | Cloudflare-protected /api/movie endpoint               |
| vidking.net            | 🚫 stub    | videasy-derived player                                 |
| primesrc.me            | 🟡 partial | /api/v1/s catalog works; /api/v1/l blocked by CF       |
| embed.su               | 🚫 stub    | DNS not resolvable from test environment               |
| peachify.top           | 🚫 stub    | Heavy JS player                                        |
| embedmaster.link       | 🚫 stub    | pako/AES-encrypted player payload                      |
| vidup.to               | 🚫 stub    | Heavy JS bundle                                        |
| ythd.org               | 🚫 stub    | webpack-bundled obfuscated player                      |
| kllamrd.org            | 🚫 stub    | Anti-bot challenge before player loads                 |
| airflix1.com           | ✅ done    | brightpathsignals.com → streamdata.vaplayer.ru/api.php |
|                        |            | returns master.m3u8 list (no encryption, no token)     |
| frembed.bond           | 🟡 partial | /api/films catalog works; links redirect to            |
|                        |            | VOE / uqload / divxplayer (each needs own resolver)    |
| moviesapi.club         | 🟡 partial | /api/movie returns flixcdn URL with AES-encrypted      |
|                        |            | /api/v1/info endpoint (key found, IV unknown)          |
| autoembed.cc           | 🚫 stub    | DNS broken; autoembed.co iframes vidsrc.xyz            |

## TMDB-id fallback chain

Even when the requested mirror is a stub or its resolver fails, the
service automatically tries to deliver *something* playable:

```
PROVIDER FAILED  →  extract tmdb/imdb from URL  →
                    try 2embed.cc with same id   →
                    try play.xpass.top with same id  →
                    try vidsrc.xyz with same id  →
                    return 204
```

In practice this means almost every "Play" press in the channel ends
up with a working stream — usually from 2embed or xpass — even if the
mirror the user picked was, say, `videasy.net` or `vidsrc.cc`.

The Roku channel sends `kind`, `tmdb`, `imdb`, `season`, `episode` as
query params alongside `embed`, so the fallback layer always knows
the right TMDB id even when the embed URL only has an IMDB id.

## Adding providers

The `PROVIDERS` list at the bottom of `server.py` maps host substrings
to resolver functions. Pattern:

```python
def resolve_my_host(embed_url: str, refer: str) -> dict | None:
    html, _, final = fetch(embed_url, {"Referer": refer})
    # ... extract the m3u8 URL ...
    return make_result(stream_url, refer, html, "hls")

PROVIDERS.append(("my-embed-host.example", resolve_my_host))
```

`make_result(url, refer, html, fmt)` follows HLS master playlists and
extracts variant qualities + .vtt/.srt subtitles automatically.

## Why this isn't built into the channel

Roku BrightScript can fetch URLs, but it can't:

- run the providers' obfuscated JavaScript players,
- decrypt AES-encrypted segment URLs,
- pass the various per-provider captchas / rate limits.

Resolution is a fast-moving target. Doing it on a Linux box you control
means you can `pip install` whatever the provider needs, swap out a
broken resolver in seconds, and the Roku channel never has to ship an
update.

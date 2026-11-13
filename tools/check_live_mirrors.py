"""Live sweep of every mirror HydraHD lists, through the channel's own BrightScript resolver.

For one movie and one TV episode this pulls the current mirror list, runs each
embed through R_DispatchByHost (the provider itself, NOT the content-id fallback
pool, so a dead provider is not masked), then does what the channel does next:
parse quality variants from the master playlist. Finally it probes the stream
and every quality URL over HTTP with the Referer the player would send.

Needs Node. The BrightScript runs in brs-node, whose HTTP client refuses to send
Referer/Origin/Cookie like a browser would; a private copy is installed under
tools/.cache and that check is switched off so requests match a real Roku.

Usage: python tools/check_live_mirrors.py [--only host-substring] [--movie-only|--tv-only]
Signed stream URLs are never printed.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import html
import json
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / 'tools' / '.cache' / 'brs-node'
WORK = ROOT / 'tools' / '.cache' / 'live'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
SOURCES = ['Resolver', 'ResolverProviders', 'ResolverVidlove', 'ResolverVidfast', 'ResolverVaplayer', 'ResolverMirrors',
           'HttpClient', 'Utils', 'HlsMeta',
           'Bytes', 'Rc4', 'EvpBytesToKey', 'AesGcm256', 'JsUnpack', 'HydraApi']
TITLES = {
    'movie': {'imdb': 'tt0133093', 'tmdb': '603', 'season': 0, 'episode': 0},
    'tv': {'imdb': 'tt5875444', 'tmdb': '95480', 'season': 1, 'episode': 1},
}

TEMPLATE = '''sub Main()
    embed = "%(embed)s"
    refer = "%(refer)s"
    session = HC_NewSession()
    clock = CreateObject("roTimespan")
    clock.mark()
    out = R_DispatchByHost(embed, refer, session)
    report = { ok: false, ms: 0 }
    if out <> invalid and out.url <> invalid and out.url <> "" then
        refUrl = ""
        if out.referer <> invalid then refUrl = out.referer
        if refUrl = "" then refUrl = refer
        quals = []
        source = "none"
        if out.qualities <> invalid and type(out.qualities) = "roArray" and out.qualities.Count() > 0 then
            quals = out.qualities
            source = "provider"
        else if U_LooksHls(out.url) or out.streamFormat = "hls" then
            quals = HM_FetchQualities(out.url, refUrl, session)
            if quals.Count() > 0 then source = "master"
        end if
        out.qualities = quals
        norm = R_NormalizeResult(out, refer)
        report = { ok: true, url: norm.url, streamFormat: norm.streamFormat, referer: norm.referer, userAgent: norm.userAgent, qualities: norm.qualities, qualitySource: source, subtitles: norm.subtitles.Count(), looksHls: U_LooksHls(norm.url) }
    end if
    report.ms = clock.totalMilliseconds()
    HC_Close(session)
    print "REPORT " + FormatJson(report)
end sub
'''


def ensure_engine():
    bin_dir = CACHE / 'node_modules' / 'brs-node' / 'bin'
    cli, engine = bin_dir / 'brs.cli.js', bin_dir / 'brs.node.js'
    if not cli.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        (CACHE / 'package.json').write_text('{"name":"live-check","private":true}')
        subprocess.run(['npm.cmd' if sys.platform == 'win32' else 'npm', 'install', '--silent', 'brs-node@2.6.2'], cwd=CACHE, check=True)
    text = engine.read_text(encoding='utf-8')
    if '_disableHeaderCheck=!1;' in text:
        engine.write_text(text.replace('_disableHeaderCheck=!1;', '_disableHeaderCheck=!0;'), encoding='utf-8')
    elif '_disableHeaderCheck=!0;' not in text:
        raise SystemExit('brs-node layout changed: cannot enable Referer/Origin headers')
    return cli


def http(url, referer, limit=65536):
    request = Request(url, headers={'User-Agent': UA, 'Referer': referer, 'Accept': '*/*'})
    with urlopen(request, timeout=25) as response:
        return response.status, response.read(limit)


def base_url():
    text = (ROOT / 'source' / 'Utils.brs').read_text(encoding='utf-8')
    return re.search(r'function U_DefaultBaseUrl\(\) as String\s+return "([^"]+)"', text).group(1)


def mirrors(kind):
    t = TITLES[kind]
    base = base_url()
    if kind == 'movie':
        url = '%s/ajax/mov_0.php?i=%s&t=%s' % (base, t['imdb'], t['tmdb'])
    else:
        url = '%s/ajax/tv_0.php?i=%s&t=%s&s=%d&e=%d' % (base, t['imdb'], t['tmdb'], t['season'], t['episode'])
    _, body = http(url, base + '/', 1 << 20)
    page = body.decode('utf-8', 'replace')
    found = re.findall(r'class="iframe-server-button[^"]*"[^>]+data-id="(\d+)"[^>]+data-link="([^"]+)"[^>]*>(.*?)</div>', page, re.S)
    out = []
    for _id, link, inner in found:
        name = re.search(r'<p[^>]*>([^<]+)</p>', inner)
        out.append((html.unescape(name.group(1)).strip() if name else 'Server ' + _id, html.unescape(link)))
    return base + '/', out


def probe(url, referer):
    """Return (status, kind) for a stream URL without keeping its body."""
    try:
        status, head = http(url, referer)
    except Exception as exc:  # noqa: BLE001 - report whatever the CDN did
        return getattr(exc, 'code', type(exc).__name__), 'error'
    if head.lstrip().startswith(b'#EXTM3U'):
        return status, 'master' if b'#EXT-X-STREAM-INF' in head else 'media'
    if head[4:8] in (b'ftyp', b'moof', b'styp'):
        return status, 'mp4'
    return status, 'not-media'


def check(cli, kind, name, embed, refer, index):
    host = urlparse(embed).netloc
    row = {'kind': kind, 'name': name, 'host': host}
    script = WORK / ('live_%s_%d.brs' % (kind, index))
    script.write_text(TEMPLATE % {'embed': embed.replace('"', ''), 'refer': refer}, encoding='utf-8')
    args = ['node', str(cli), '--root', '.', script.relative_to(ROOT).as_posix(), *['source/%s.brs' % s for s in SOURCES]]
    try:
        run = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=150, encoding='utf-8', errors='replace')
        output = run.stdout + run.stderr
    except subprocess.TimeoutExpired:
        row['verdict'] = 'TIMEOUT'
        return row
    line = re.search(r'^REPORT (.*)$', output, re.M)
    if not line:
        crash = re.search(r'(?im)^.*(runtime error|error:|exception).*$', output)
        row['verdict'] = 'CRASH ' + (crash.group(0)[:150] if crash else output[-150:].replace('\n', ' '))
        return row
    report = json.loads(line.group(1))
    row['ms'] = report.get('ms')
    if not report.get('ok'):
        row['verdict'] = 'NO STREAM'
        return row
    referer = report.get('referer') or refer
    status, media = probe(report['url'], referer)
    quals = report.get('qualities') or []
    row.update(stream_host=urlparse(report['url']).netloc, format=report['streamFormat'], http=status, media=media,
               subs=report['subtitles'], quality_source=report['qualitySource'],
               labels=[q.get('label') for q in quals], looks_hls=report['looksHls'])
    bad = []
    for q in quals:
        if not q.get('url'):
            bad.append('%s:no-url' % q.get('label'))
            continue
        q_status, q_media = probe(q['url'], referer)
        if q_media not in ('media', 'master', 'mp4'):
            bad.append('%s:%s/%s' % (q.get('label'), q_status, q_media))
    row['bad_qualities'] = bad
    playable = media in ('master', 'media', 'mp4')
    if not playable:
        row['verdict'] = 'RESOLVED BUT STREAM DEAD'
    elif bad:
        row['verdict'] = 'PLAYS, QUALITY URLS BROKEN'
    elif not quals and media == 'master':
        row['verdict'] = 'PLAYS, QUALITIES NOT PARSED'
    elif not quals:
        row['verdict'] = 'PLAYS, single rendition'
    else:
        row['verdict'] = 'OK'
    return row


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else ''
    kinds = ['movie'] if '--movie-only' in sys.argv else ['tv'] if '--tv-only' in sys.argv else ['movie', 'tv']
    cli = ensure_engine()
    shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True)
    jobs = []
    for kind in kinds:
        refer, found = mirrors(kind)
        print('%s: %d mirrors listed' % (kind, len(found)), file=sys.stderr)
        for index, (name, embed) in enumerate(found):
            if only in embed:
                jobs.append((cli, kind, name, embed, refer, index))
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows = list(pool.map(lambda job: check(*job), jobs))
    shutil.rmtree(WORK, ignore_errors=True)
    for row in rows:
        print('%-5s %-22s %-11s %-28s' % (row['kind'], row['host'][:22], row['name'][:11], row['verdict'][:28]), end=' ')
        if 'format' in row:
            print('%s http=%s %s q[%s]=%s subs=%d %sms via %s%s' % (
                row['format'], row['http'], row['media'], row['quality_source'], ','.join(row['labels']) or '-', row['subs'],
                row['ms'], row['stream_host'], ' BAD=' + ';'.join(row['bad_qualities']) if row['bad_qualities'] else ''))
        else:
            print('%sms' % row.get('ms', '?'), row['verdict'][28:])
    return 0 if all(r['verdict'].startswith(('OK', 'PLAYS, single')) for r in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())

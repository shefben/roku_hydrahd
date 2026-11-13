"""Live provider smoke probe; prints no signed URLs and reads only 32 bytes.

Usage: python tools/check_live_mirror.py vidlove [--tv]
"""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('hydra_resolver', Path(__file__).resolve().parents[1] / 'resolver/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
provider = sys.argv[1] if len(sys.argv) > 1 else 'vidlove'
tv = '--tv' in sys.argv[2:]
url = {
    'xpass': 'https://play.xpass.top/e/movie/19995?autostart=true',
    'airflix': 'https://airflix1.com/embed/movie/19995',
    '2embed': 'https://www.2embed.cc/embed/19995',
    'vidlove': 'https://player.vidlove.cc/embed/tv/95480/1/1' if tv else 'https://player.vidlove.cc/embed/movie/19995',
}[provider]
refer = 'https://hydrahd.ws/watchseries/slow-horses-online-free/season/1/episode/1' if tv else 'https://hydrahd.ws/movie/52481-watch-avatar-2009-online'
result = getattr(server, 'resolve_' + provider)(url, refer)
if not result:
    print(provider, 'NO STREAM')
    raise SystemExit(1)
request = server.Request(result['url'], headers={'Referer': result.get('referer', url), 'User-Agent': server.UA, 'Range': 'bytes=0-31'})
try:
    with server._active_opener().open(request, timeout=15) as response:
        head = response.read(32)
        valid = head.startswith(b'#EXTM3U') or head[4:8] in (b'ftyp', b'moof', b'styp')
        print(provider, 'STREAM RESOLVED', result.get('streamFormat'), 'media header valid:', valid, 'HTTP:', response.status)
        if not valid:
            raise SystemExit(1)
except Exception as exc:
    print(provider, 'MEDIA PROBE FAILED:', type(exc).__name__, getattr(exc, 'code', ''), flush=True)
    raise SystemExit(1)

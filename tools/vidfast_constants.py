"""Print a fresh RP_VidfastConfig() body for source/ResolverVidfast.brs.

vidfast.vc keeps its protocol constants inside the player-variant chunk,
most of them in an XOR-masked JSON "descriptor" for its virtualized client.
They change whenever the site redeploys. This fetches an embed page, finds
the variant chunk it references, unmasks the descriptor and prints the values.

Only variant 16's transport is ported. If the site starts serving another
variant this exits non-zero: the port itself needs redoing, not the constants.

Usage: python tools/vidfast_constants.py [embed-url]
"""
import base64
import json
import re
import sys
from urllib.request import Request, urlopen

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
PORTED_VARIANT = 16


def get(url, referer):
    with urlopen(Request(url, headers={'User-Agent': UA, 'Referer': referer}), timeout=30) as response:
        return response.read().decode('utf-8', 'replace')


def unmask(blob, key):
    raw = base64.urlsafe_b64decode(blob + '=' * (-len(blob) % 4))
    out = bytes(b ^ key[i % len(key)] ^ (((i + 17) * 157 + 16) & 255) for i, b in enumerate(raw))
    return json.loads(out.decode('utf-8'))


def strings(node, out):
    """String constants in document order."""
    if isinstance(node, dict):
        value = node.get('value')
        if node.get('kind') == 'constant' and isinstance(value, list) and value[:1] == ['string']:
            out.append(value[1])
        for child in node.values():
            strings(child, out)
    elif isinstance(node, list):
        for child in node:
            strings(child, out)
    return out


def separator(build):
    h = 0x811c9dc5
    for ch in build:
        h = ((h ^ ord(ch)) * 0x1000193) & 0xffffffff
    return '~' if h & 1 else '.'


def main():
    embed = sys.argv[1] if len(sys.argv) > 1 else 'https://vidfast.vc/movie/603'
    origin = re.match(r'https?://[^/]+', embed).group(0)
    page = get(embed, origin + '/')
    variant = int(re.search(r'variantIndex\\?":\s*(\d+)', page).group(1))
    # The page chunk maps variantIndex -> webpack chunk id; the id's file is
    # the only numeric chunk on the page that is not shared by every variant.
    page_chunk = re.search(r'static/chunks/app/(?:movie|tv)/[^"]+?page-[0-9a-f]+\.js', page).group(0)
    loader = get(origin + '/_next/' + page_chunk, embed)
    chunk_id = re.search(r'a\.e\((\d+)\)\]\)\.then\(a\.bind\(a,\d+\)\),\{loadableGenerated:\{webpack:\(\)=>\[require\.resolveWeak\("\./Player\.js\?playerVariant=%d"' % variant, loader).group(1)
    chunk = re.search(r'static/chunks/(%s\.[0-9a-f]+\.js)' % chunk_id, page).group(1)
    print('variant', variant, 'chunk', chunk, file=sys.stderr)
    if variant != PORTED_VARIANT:
        print('Site now serves variant %d; only variant %d is ported.' % (variant, PORTED_VARIANT), file=sys.stderr)
        return 2

    source = get(origin + '/_next/static/chunks/' + chunk, embed)
    # First masked descriptor in the chunk is the request-side client:
    #   }("<base64url>",new Uint8Array([k0,k1,...]))
    blob = re.search(r'\}\("([A-Za-z0-9_-]{2000,})",\s*new Uint8Array\(\[([0-9,\s]+)\]\)', source)
    consts = strings(unmask(blob.group(1), [int(n) for n in blob.group(2).split(',')]), [])
    numbers = [c for c in consts if re.fullmatch(r'\d{6,}', c)]
    ids = [c for c in consts if re.fullmatch(r'[A-Za-z0-9_-]{11}', c) and not c.isalpha()]
    build = next(c for c in consts if re.fullmatch(r'[A-Za-z0-9_-]{43}', c))
    config = {
        'chunk': chunk,
        'variant': str(variant),
        'base': next(c for c in consts if c.startswith('/') and len(c) > 100),
        'csrf': re.search(r'X-Csrf-Token\\?":\\?"([^"\\]+)', source).group(1),
        'ticketId': ids[0],
        'serversId': ids[1],
        'fetchId': re.search(r'"\)\.concat\("([A-Za-z0-9_-]{6,20})","/"\)\.concat\(\w+\.data\)', source).group(1),
        'key': next(c for c in consts if re.fullmatch(r'[0-9a-f]{64}', c)),
        'first': numbers[0],
        'second': numbers[1],
        'build': build,
        'sep': separator(build),
    }
    print('    return {')
    for name, value in config.items():
        print('        %s: "%s"' % (name, value))
    print('    }')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

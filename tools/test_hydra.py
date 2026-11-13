"""Run the production BrightScript parsers against captured HydraHD responses.

Requires Node/npm; run: python tools/test_hydra.py
"""
from pathlib import Path
import subprocess
import tempfile
import re

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='hydra-tests-') as folder:
    stage = Path(folder)
    source = (root / 'source/HydraApi.brs').read_text(encoding='utf-8')
    source = re.sub(r'function HA_Get\(.*?end function', 'function HA_Get(url as String, refer as String) as String\n    return T_Get(U_CatalogUrl(url), U_CatalogUrl(refer))\nend function', source, flags=re.S)
    (stage / 'HydraApi.brs').write_text(source, encoding='utf-8')
    utils = (root / 'source/Utils.brs').read_text(encoding='utf-8')
    utils = re.sub(r'function U_PrefDefault\(.*?end function', 'function U_PrefDefault(key as String, fallback as String) as String\n    if m.testBase <> invalid and key = "baseUrl" then return m.testBase\n    return fallback\nend function', utils, flags=re.S)
    # Native roUrlTransfer isn't implemented by the off-device interpreter.
    utils = re.sub(r'function U_UrlEncode\(.*?end function', 'function U_UrlEncode(s as String) as String\n    return s.Replace("&", "%26").Replace(" ", "%20")\nend function', utils, flags=re.S)
    (stage / 'Utils.brs').write_text(utils, encoding='utf-8')
    watchlist = (root / 'source/Watchlist.brs').read_text(encoding='utf-8')
    for function in ('W_Section', 'W_FavSection'):
        watchlist = re.sub(r'function ' + function + r'\(.*?end function', 'function ' + function + '() as Object\n    return m.testRegistry\nend function', watchlist, flags=re.S)
    (stage / 'Watchlist.brs').write_text(watchlist, encoding='utf-8')
    passed = True
    for test, sources in [('test_hydra.brs', [stage / 'HydraApi.brs', stage / 'Watchlist.brs', root / 'components/tasks/ServersTask.brs']), ('test_vidlove.brs', [root / 'source/ResolverVidlove.brs'])]:
        result = subprocess.run(
            ['npx.cmd', '--yes', '--package', 'brs@0.45.0', 'brs', str(root / 'tools' / test),
             *map(str, sources), str(stage / 'Utils.brs')], cwd=root, text=True, capture_output=True)
        print(test, result.stdout, result.stderr)
        passed = passed and result.returncode == 0 and 'FAILURES:  0' in result.stdout
    raise SystemExit(0 if passed else 1)

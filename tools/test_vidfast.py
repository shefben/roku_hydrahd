"""Run the resolver checks that need real crypto objects, off-device.

The plain `brs` interpreter used by test_hydra.py has no roHMAC / roEVPCipher /
roEVPDigest, so these run in brs-node. Requires Node/npm.

    python tools/test_vidfast.py        (runs every suite listed below)
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
SHARED = ['Resolver', 'ResolverProviders', 'ResolverVidlove', 'ResolverVidfast', 'ResolverVaplayer', 'ResolverMirrors',
          'HttpClient', 'Utils', 'HlsMeta', 'Bytes', 'Rc4', 'EvpBytesToKey', 'AesGcm256', 'JsUnpack', 'HydraApi']
passed = True
for suite in ('test_vidfast.brs', 'test_vaplayer.brs', 'test_mirrors.brs'):
    result = subprocess.run(
        # brs-node only accepts paths relative to the working directory.
        ['npx.cmd', '--yes', 'brs-node@2.6.2', '--root', '.', 'tools/' + suite, *['source/%s.brs' % name for name in SHARED]],
        cwd=root, text=True, capture_output=True, encoding='utf-8', errors='replace')
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith(('FAIL', 'FAILURES')) or 'rror' in line]
    print(suite, ' | '.join(lines) or 'NO OUTPUT')
    passed = passed and 'FAILURES:  0' in result.stdout
raise SystemExit(0 if passed else 1)

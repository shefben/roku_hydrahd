# build_zip.ps1 - Bake a resolver URL into Utils.brs and zip the channel.
#
# Invoked by build_zip.bat. The bat file detects the LAN IP and exports
# CHANNEL_DIR + RESOLVER_URL before calling this script.

$ErrorActionPreference = 'Stop'

$src      = $env:CHANNEL_DIR
$resolver = $env:RESOLVER_URL

if (-not $src) { throw 'CHANNEL_DIR env var not set' }

# Stage everything in a temp dir so the patch never touches the working tree.
$stage = Join-Path $env:TEMP ('hydrahd_stage_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null

foreach ($d in 'components','images','source') {
    Copy-Item -Recurse (Join-Path $src $d) (Join-Path $stage $d)
}
Copy-Item (Join-Path $src 'manifest') (Join-Path $stage 'manifest')

# Patch the build-tagged line in Utils.brs only when we have an IP to bake in.
# When $resolver is empty the channel relies on its built-in LAN auto-discovery.
if ($resolver) {
    $utils   = Join-Path $stage 'source\Utils.brs'
    $txt     = Get-Content -Raw -LiteralPath $utils
    $pattern = '(?m)^\s*return\s+"[^"]*"\s+''\s*build:resolver-url.*$'
    $newLine = '    return "' + $resolver + '"  '' build:resolver-url'

    if ($txt -notmatch $pattern) {
        throw "Could not find the 'build:resolver-url' marker in Utils.brs"
    }
    # Escape $ for -replace literal substitution (IPs won't contain $ but be defensive).
    $patched = [regex]::Replace($txt, $pattern, ($newLine -replace '\$','$$$$'))
    Set-Content -LiteralPath $utils -Value $patched -NoNewline
}

# Build zip.
$zip = Join-Path $src 'HydraHD.zip'
if (Test-Path $zip) { Remove-Item $zip }
$items = @('components','images','source','manifest') | ForEach-Object { Join-Path $stage $_ }
Compress-Archive -Path $items -DestinationPath $zip -Force

Remove-Item -Recurse -Force $stage

$size = (Get-Item $zip).Length
if ($resolver) {
    Write-Host "[build_zip] Built $zip ($size bytes) with fallback resolver $resolver"
} else {
    Write-Host "[build_zip] Built $zip ($size bytes); channel will auto-discover the resolver on the LAN"
}

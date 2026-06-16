# rebuild.ps1 - rebuild the channel .zip and stage it into the harness.
# Run this after editing any source/ or components/ file, then just reload
# the browser tab (the server sends the zip with no-cache, so a refresh
# always picks up the new build). Does NOT restart the server.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$env:CHANNEL_DIR = $repo
& powershell -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\build_zip.ps1') | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'HydraHD.zip') `
          -Destination (Join-Path $PSScriptRoot 'channel\HydraHD.zip') -Force
$size = (Get-Item (Join-Path $PSScriptRoot 'channel\HydraHD.zip')).Length
Write-Host "[rebuild] staged channel/HydraHD.zip ($size bytes) - reload the browser tab to pick it up"

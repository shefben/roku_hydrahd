# build_zip.ps1 - Bake a resolver URL into Utils.brs and zip the Roku channel.
#
# Invoked by build_zip.bat. The BAT file exports CHANNEL_DIR and RESOLVER_URL.
# This version deliberately avoids Compress-Archive because Roku expects ZIP
# entry names like source/main.brs, not Windows paths like source\main.brs.

$ErrorActionPreference = 'Stop'

$src      = $env:CHANNEL_DIR
$resolver = $env:RESOLVER_URL

if (-not $src) {
    # Allow the script to be run directly from the tools/scripts folder.
    $src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

if (-not (Test-Path -LiteralPath (Join-Path $src 'manifest'))) {
    throw "manifest not found at $(Join-Path $src 'manifest')"
}

foreach ($requiredDir in 'components','images','source') {
    $requiredPath = Join-Path $src $requiredDir
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Required directory missing: $requiredPath"
    }
}

# Stage everything in a temp dir so the patch never touches the working tree.
$stage = Join-Path $env:TEMP ('hydrahd_stage_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null

try {
    foreach ($d in 'components','images','source') {
        Copy-Item -Recurse -LiteralPath (Join-Path $src $d) -Destination (Join-Path $stage $d)
    }
    Copy-Item -LiteralPath (Join-Path $src 'manifest') -Destination (Join-Path $stage 'manifest')

    # Patch the build-tagged line in Utils.brs only when we have an IP to bake in.
    # When $resolver is empty the channel relies on its built-in LAN auto-discovery.
    if ($resolver) {
        $utils   = Join-Path (Join-Path $stage 'source') 'Utils.brs'
        $txt     = Get-Content -Raw -LiteralPath $utils
        $pattern = '(?m)^\s*return\s+"[^"]*"\s+''\s*build:resolver-url.*$'
        $newLine = '    return "' + $resolver + '"  '' build:resolver-url'

        if ($txt -notmatch $pattern) {
            throw "Could not find the 'build:resolver-url' marker in Utils.brs"
        }

        $patched = [regex]::Replace($txt, $pattern, ($newLine -replace '\$','$$$$'))
        Set-Content -LiteralPath $utils -Value $patched -NoNewline
    }

    # Build zip with Roku-safe forward-slash entry names.
    $zip = Join-Path $src 'HydraHD.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zipFile = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive($zipFile, [System.IO.Compression.ZipArchiveMode]::Create)

    try {
        # Manifest must be at package root.
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            (Join-Path $stage 'manifest'),
            'manifest',
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null

        foreach ($top in 'components','images','source') {
            $topPath = Join-Path $stage $top
            Get-ChildItem -LiteralPath $topPath -File -Recurse | ForEach-Object {
                $relative = $_.FullName.Substring($stage.Length).TrimStart('\','/')
                $entryName = $relative -replace '\\','/'

                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    $_.FullName,
                    $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal
                ) | Out-Null
            }
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        if ($zipFile) { $zipFile.Dispose() }
    }

    # Sanity check the generated ZIP. Roku's error message is useless enough already.
    $checkZip = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entryNames = @($checkZip.Entries | ForEach-Object { $_.FullName })
        if (-not ($entryNames -contains 'manifest')) { throw 'Generated ZIP is missing manifest at root' }
        if (-not ($entryNames | Where-Object { $_ -like 'source/*' } | Select-Object -First 1)) {
            throw 'Generated ZIP is missing source/* entries with forward slashes'
        }
        if ($entryNames | Where-Object { $_ -match '\\' } | Select-Object -First 1) {
            throw 'Generated ZIP contains backslash paths, which Roku will reject'
        }
    }
    finally {
        if ($checkZip) { $checkZip.Dispose() }
    }

    # Publish for the auto-updater: update/version.txt + update/<version>.zip.
    # Skipped when a resolver address was baked in, so a private LAN IP never
    # ends up in the repo.
    if (-not $resolver) {
        $mf = Get-Content -LiteralPath (Join-Path $src 'manifest')
        $ver = (($mf | Where-Object { $_ -match '^update_version=' }) -replace '^[^=]+=', '').Trim()
        if ($ver -notmatch '^\d+(\.\d+)*$') { throw "manifest has no usable update_version (got '$ver')" }
        $upd = Join-Path $src 'update'
        New-Item -ItemType Directory -Force -Path $upd | Out-Null
        Get-ChildItem -LiteralPath $upd -Filter '*.zip' | Remove-Item -Force
        Copy-Item -LiteralPath $zip -Destination (Join-Path $upd "$ver.zip")
        [System.IO.File]::WriteAllText((Join-Path $upd 'version.txt'), $ver)
        Write-Host "[build_zip] Published update/$ver.zip and update/version.txt"
    }

    $size = (Get-Item -LiteralPath $zip).Length
    if ($resolver) {
        Write-Host "[build_zip] Built $zip ($size bytes) with fallback resolver $resolver"
    } else {
        Write-Host "[build_zip] Built $zip ($size bytes); channel will auto-discover the resolver on the LAN"
    }
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -Recurse -Force -LiteralPath $stage
    }
}

# detect_lan_ip.ps1 - Print the most likely LAN IPv4 address to stdout.
#
# Strategy: list all IPv4 addresses, drop loopback / APIPA, and prefer
# RFC1918 private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
# over public addresses. Within the chosen tier, pick the lowest
# InterfaceMetric (i.e. the active LAN route).

function Test-Private([string]$ip) {
    if ($ip -like '10.*')      { return $true }
    if ($ip -like '192.168.*') { return $true }
    if ($ip -match '^172\.(1[6-9]|2\d|3[01])\.') { return $true }
    return $false
}

$candidates = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.PrefixOrigin -in 'Dhcp','Manual' -and
        $_.IPAddress -notlike '169.254.*'   -and
        $_.IPAddress -ne   '127.0.0.1'
    } |
    Sort-Object -Property InterfaceMetric

$private = $candidates | Where-Object { Test-Private $_.IPAddress }

if ($private) {
    Write-Output ($private | Select-Object -First 1).IPAddress
} elseif ($candidates) {
    Write-Output ($candidates | Select-Object -First 1).IPAddress
}

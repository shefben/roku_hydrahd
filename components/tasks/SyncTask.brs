' SyncTask.brs - Resolver-backed channel state sync.
'
' Roku registry is wiped when the user uninstalls the dev channel
' (clicking "Delete" from Dev Console rather than "Replace"). To survive
' that, we mirror the relevant registry sections to the resolver, which
' stores them in a per-device JSON file. On boot the channel pulls the
' snapshot back. Keyed by GetChannelClientId so the same physical Roku
' rejoins its own data after a wipe.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    mode = m.top.mode
    if mode = "pull" then
        m.top.result = doPull()
    else if mode = "push" then
        m.top.result = doPush()
    else
        m.top.result = { ok: false, error: "unknown mode" }
    end if
end sub

function doPull() as Object
    url = buildUrl()
    if url = "" then return { ok: false, error: "no resolver" }
    xfer = CreateObject("roUrlTransfer")
    xfer.SetUrl(url)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.SetMinimumTransferRate(64, 5)
    body = xfer.GetToString()
    if body = invalid or body = "" then return { ok: false, error: "empty response" }
    parsed = ParseJson(body)
    if parsed = invalid then return { ok: false, error: "bad json" }
    return { ok: true, snapshot: parsed }
end function

function doPush() as Object
    url = buildUrl()
    if url = "" then return { ok: false, error: "no resolver" }
    xfer = CreateObject("roUrlTransfer")
    xfer.SetUrl(url)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.AddHeader("Content-Type", "application/json")
    xfer.SetMinimumTransferRate(64, 5)
    body = m.top.payload
    if body = invalid then body = "{}"
    resp = xfer.PostFromString(body)
    if resp <> 200 then return { ok: false, error: "http " + resp.ToStr() }
    return { ok: true }
end function

function buildUrl() as String
    base = m.top.resolverUrl
    if base = invalid or base = "" then return ""
    if Right(base, 1) = "/" then base = Left(base, Len(base) - 1)
    did = m.top.did
    if did = invalid then did = ""
    return base + "/state?did=" + U_UrlEncode(did)
end function

' HttpClient.brs - Per-resolve HTTP session for the in-channel resolver.
'
' One session = one roUrlTransfer + one roMessagePort, reused across the
' iframe / API chain that resolves a single embed. Sharing the underlying
' transfer keeps the cookie jar coherent (provider-set cookies on hop 1
' must travel with hop 2 to make CDN clearance / "current playing"
' tokens work). Discard the session when the resolve finishes.
'
' Every request is async with a per-call deadline so a wedged hop can't
' freeze the Task thread for the OS-level 30-60s TCP timeout. The deadline
' covers connect+read combined; on expiry we AsyncCancel and return error.
'
' RetainBodyOnError(true) is set unconditionally so 4xx/5xx response
' bodies are readable. Several providers (vidrock, vidsrc.cc) return JSON
' error payloads with HTTP 403, and without retain-on-error roUrlEvent's
' GetString would come back empty per the documented Roku behaviour.

' --- Session lifecycle -----------------------------------------------

function HC_DefaultUA() as String
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
end function

function HC_NewSession() as Object
    xfer = CreateObject("roUrlTransfer")
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.AddHeader("X-Roku-Reserved-Dev-Id", "")
    xfer.InitClientCertificates()
    xfer.EnableCookies()
    xfer.RetainBodyOnError(true)
    xfer.EnableEncodings(true)
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    return {
        xfer: xfer
        port: port
    }
end function

sub HC_Close(session as Object)
    if session = invalid then return
    if session.xfer <> invalid then
        session.xfer.AsyncCancel()
        session.xfer.ClearCookies()
    end if
    session.xfer = invalid
    session.port = invalid
end sub

' --- Core request helper ---------------------------------------------

' headers: assoc-array of name->value, or invalid for defaults.
' Default Accept and User-Agent are always applied if not overridden.
function HC_Request(session as Object, method as String, url as String, headers as Object, body as String, rangeHdr as String, deadlineMs as Integer) as Object
    res = {
        ok: false
        status: 0
        body: ""
        finalUrl: url
        headers: {}
        error: ""
    }

    if session = invalid or session.xfer = invalid then
        res.error = "no session"
        return res
    end if

    xfer = session.xfer
    xfer.SetUrl(url)

    ' Reset per-request headers. roUrlTransfer accumulates AddHeader calls
    ' across SetUrl, so without this old Authorization / Referer headers
    ' would bleed into the next hop and break providers that swap auth
    ' between steps.
    xfer.SetHeaders({})

    ua = HC_DefaultUA()
    accept = "*/*"
    haveAccept = false
    haveUA = false
    if headers <> invalid then
        for each k in headers
            v = headers[k]
            if v <> invalid then
                lk = LCase(k)
                if lk = "user-agent" then
                    ua = v
                    haveUA = true
                else if lk = "accept" then
                    accept = v
                    haveAccept = true
                end if
                xfer.AddHeader(k, v)
            end if
        end for
    end if
    if not haveUA then xfer.AddHeader("User-Agent", ua)
    if not haveAccept then xfer.AddHeader("Accept", accept)
    if rangeHdr <> "" then xfer.AddHeader("Range", rangeHdr)

    if deadlineMs <= 0 then deadlineMs = 8000

    ok = false
    if method = "POST" then
        if body = invalid then body = ""
        ok = xfer.AsyncPostFromString(body)
    else if method = "HEAD" then
        ' No native AsyncHead; we approximate by issuing GET with a 1-byte
        ' Range so the server returns headers without the full body.
        if rangeHdr = "" then xfer.AddHeader("Range", "bytes=0-0")
        ok = xfer.AsyncGetToString()
    else
        ok = xfer.AsyncGetToString()
    end if
    if not ok then
        res.error = "AsyncGet/Post returned false"
        return res
    end if

    timer = CreateObject("roTimespan")
    timer.mark()
    while timer.totalMilliseconds() < deadlineMs
        remaining = deadlineMs - timer.totalMilliseconds()
        if remaining < 1 then exit while
        msg = wait(remaining, session.port)
        if msg = invalid then exit while
        if type(msg) = "roUrlEvent" then
            res.status = msg.getResponseCode()
            res.body = msg.getString()
            if res.body = invalid then res.body = ""
            url2 = msg.getFailureReason()
            ' res.finalUrl is initialized to the input url at the top of
            ' this function. Some firmwares update xfer's URL to reflect
            ' redirects, but referencing xfer.GetUrl as a method-handle
            ' (no parens) crashes at runtime on older OS, and a Location
            ' header walk is more code than this is worth. Providers that
            ' need the final URL fall back to embedUrl when finalUrl is
            ' empty, which is fine.
            hdrs = msg.getResponseHeaders()
            if hdrs <> invalid then res.headers = hdrs
            res.ok = (res.status >= 200 and res.status < 400)
            if res.status = 0 then
                ' Network/TLS failure - keep error context if any
                res.error = url2
            end if
            exit while
        end if
    end while

    if res.status = 0 and res.body = "" then
        ' Deadline expired before any roUrlEvent arrived
        xfer.AsyncCancel()
        res.error = "timeout after " + deadlineMs.ToStr() + "ms"
    end if

    return res
end function

function HC_Get(session as Object, url as String, headers as Object, deadlineMs as Integer) as Object
    return HC_Request(session, "GET", url, headers, "", "", deadlineMs)
end function

function HC_Head(session as Object, url as String, headers as Object, deadlineMs as Integer) as Object
    return HC_Request(session, "HEAD", url, headers, "", "", deadlineMs)
end function

function HC_GetRange(session as Object, url as String, headers as Object, rangeHdr as String, deadlineMs as Integer) as Object
    return HC_Request(session, "GET", url, headers, "", rangeHdr, deadlineMs)
end function

function HC_Post(session as Object, url as String, headers as Object, body as String, deadlineMs as Integer) as Object
    return HC_Request(session, "POST", url, headers, body, "", deadlineMs)
end function

' --- base64 / hex / base64-URL helpers --------------------------------
'
' roByteArray's FromBase64String is strict: it rejects whitespace, odd-
' length input, and the URL-safe `-_` substitution. Several providers
' (peachify, videasy) ship base64-URL strings with no padding, so we
' canonicalise to standard base64 here before handing off.

function HC_Base64UrlDecode(s as String) as Object
    out = CreateObject("roByteArray")
    if s = invalid or s = "" then return out
    re1 = CreateObject("roRegex", "-", "g")
    re2 = CreateObject("roRegex", "_", "g")
    s2 = re1.replaceAll(s, "+")
    s2 = re2.replaceAll(s2, "/")
    pad = Len(s2) mod 4
    if pad = 2 then s2 = s2 + "=="
    if pad = 3 then s2 = s2 + "="
    if pad = 1 then return out  ' invalid base64 length
    out.FromBase64String(s2)
    return out
end function

function HC_Base64UrlEncode(bytes as Object) as String
    if bytes = invalid then return ""
    s = bytes.ToBase64String()
    re1 = CreateObject("roRegex", "\+", "g")
    re2 = CreateObject("roRegex", "/", "g")
    re3 = CreateObject("roRegex", "=+$", "")
    s = re1.replaceAll(s, "-")
    s = re2.replaceAll(s, "_")
    s = re3.replaceAll(s, "")
    return s
end function

function HC_HexToBytes(hex as String) as Object
    out = CreateObject("roByteArray")
    if hex = invalid or hex = "" then return out
    out.FromHexString(hex)
    return out
end function

function HC_BytesToHex(bytes as Object) as String
    if bytes = invalid then return ""
    return bytes.ToHexString()
end function

function HC_StringToBytes(s as String) as Object
    out = CreateObject("roByteArray")
    if s = invalid or s = "" then return out
    out.FromAsciiString(s)
    return out
end function

' Stay in roByteArray for binary reads. ToAsciiString stops at the first
' null byte so we route binary-likely payloads through hex first and let
' callers decode as JSON / utf-8 themselves once null-free.
function HC_BytesToString(bytes as Object) as String
    if bytes = invalid then return ""
    return bytes.ToAsciiString()
end function

' --- URL helpers ------------------------------------------------------

function HC_HostOf(url as String) as String
    if url = invalid or url = "" then return ""
    re = CreateObject("roRegex", "^https?://([^/?#]+)", "i")
    m = re.match(url)
    if m <> invalid and m.Count() >= 2 then return LCase(m[1])
    return ""
end function

function HC_OriginOf(url as String) as String
    if url = invalid or url = "" then return ""
    re = CreateObject("roRegex", "^(https?://[^/?#]+)", "i")
    m = re.match(url)
    if m <> invalid and m.Count() >= 2 then return m[1]
    return ""
end function

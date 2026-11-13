' Updater.brs - self-update for the sideloaded channel.
'
' The repo hosts update/version.txt (one line, e.g. "1.0.2") and
' update/<version>.zip (the channel package). At launch the channel compares
' version.txt with its own manifest version. To install, it downloads the
' zip and uploads it to this Roku's own developer installer
' (http://<roku-ip>/plugin_install), exactly as the browser sideload page
' does. That page is protected by the developer password (HTTP digest, user
' "rokudev"), so the password has to be stored in Settings first.
' A successful install replaces and restarts the channel, so the upload
' usually never gets to report back.
' Synchronous: call from a Task.

function UP_RepoBase() as String
    return "https://raw.githubusercontent.com/shefben/roku_hydrahd/main/update/"
end function

' The published version number lives in the manifest as update_version (a
' plain number such as 501, matching update/version.txt and the zip name).
function UP_CurrentVersion() as String
    info = CreateObject("roAppInfo")
    v = info.GetValue("update_version")
    if UP_IsVersion(v) then return v
    return info.GetVersion()
end function

function UP_IsVersion(v as Dynamic) as Boolean
    if v = invalid then return false
    return CreateObject("roRegex", "^\d+(\.\d+){0,3}$", "").IsMatch(v)
end function

' >0 when a is newer than b, <0 when older, 0 when equal ("1.0.10" > "1.0.9").
function UP_Compare(a as String, b as String) as Integer
    pa = a.Tokenize(".")
    pb = b.Tokenize(".")
    n = pa.Count()
    if pb.Count() > n then n = pb.Count()
    for i = 0 to n - 1
        x = 0
        y = 0
        if i < pa.Count() then x = pa[i].ToInt()
        if i < pb.Count() then y = pb[i].ToInt()
        if x > y then return 1
        if x < y then return -1
    end for
    return 0
end function

function UP_NewTransfer(port as Object) as Object
    xfer = CreateObject("roUrlTransfer")
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.RetainBodyOnError(true)
    xfer.EnableEncodings(true)
    xfer.SetMessagePort(port)
    return xfer
end function

' Wait for the transfer's roUrlEvent. Returns invalid on timeout.
function UP_Wait(xfer as Object, port as Object, deadlineMs as Integer) as Object
    clock = CreateObject("roTimespan")
    clock.mark()
    while clock.totalMilliseconds() < deadlineMs
        msg = wait(deadlineMs - clock.totalMilliseconds(), port)
        if msg = invalid then exit while
        if type(msg) = "roUrlEvent" then return msg
    end while
    xfer.AsyncCancel()
    return invalid
end function

' { current, latest, available }. latest is "" when the check failed.
function UP_Check() as Object
    out = { current: UP_CurrentVersion(), latest: "", available: false }
    port = CreateObject("roMessagePort")
    xfer = UP_NewTransfer(port)
    ' Timestamp defeats stale copies of the file on the way.
    xfer.SetUrl(UP_RepoBase() + "version.txt?t=" + CreateObject("roDateTime").AsSeconds().ToStr())
    if not xfer.AsyncGetToString() then return out
    msg = UP_Wait(xfer, port, 8000)
    if msg = invalid or msg.GetResponseCode() <> 200 then return out
    latest = U_Trim(msg.GetString())
    if not UP_IsVersion(latest) then return out
    out.latest = latest
    out.available = (UP_Compare(latest, out.current) > 0)
    return out
end function

function UP_Md5(text as String) as String
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(text)
    digest = CreateObject("roEVPDigest")
    digest.Setup("md5")
    return LCase(digest.Process(ba))
end function

function UP_DeviceIp() as String
    addrs = CreateObject("roDeviceInfo").GetIPAddrs()
    if addrs <> invalid then
        for each name in addrs
            if addrs[name] <> invalid and addrs[name] <> "" then return addrs[name]
        end for
    end if
    return "127.0.0.1"
end function

' Authorization header value for the installer, or "" if the challenge
' could not be read.
function UP_DigestHeader(challenge as String, password as String, method as String, uri as String) as String
    q = chr(34)
    realm = U_FirstMatch(challenge, "realm=" + q + "([^" + q + "]*)" + q)
    nonce = U_FirstMatch(challenge, "nonce=" + q + "([^" + q + "]*)" + q)
    opaque = U_FirstMatch(challenge, "opaque=" + q + "([^" + q + "]*)" + q)
    if nonce = "" then return ""
    hasQop = CreateObject("roRegex", "qop=", "i").IsMatch(challenge)
    ha1 = UP_Md5("rokudev:" + realm + ":" + password)
    ha2 = UP_Md5(method + ":" + uri)
    nc = "00000001"
    cnonce = UP_Md5(CreateObject("roDateTime").AsSeconds().ToStr() + nonce).Left(16)
    if hasQop then
        response = UP_Md5(ha1 + ":" + nonce + ":" + nc + ":" + cnonce + ":auth:" + ha2)
    else
        response = UP_Md5(ha1 + ":" + nonce + ":" + ha2)
    end if
    h = "Digest username=" + q + "rokudev" + q + ", realm=" + q + realm + q + ", nonce=" + q + nonce + q
    h = h + ", uri=" + q + uri + q + ", response=" + q + response + q
    if hasQop then h = h + ", qop=auth, nc=" + nc + ", cnonce=" + q + cnonce + q
    if opaque <> "" then h = h + ", opaque=" + q + opaque + q
    return h
end function

' Download update/<version>.zip and install it on this device.
' Returns { ok, message }. ok with a restart pending may never be delivered.
function UP_Install(version as String, password as String) as Object
    if not UP_IsVersion(version) then return { ok: false, message: "Bad version number." }
    if password = invalid or password = "" then return { ok: false, message: "Developer password is not set." }

    zipPath = "tmp:/update.zip"
    bodyPath = "tmp:/update_body.bin"
    DeleteFile(zipPath)
    DeleteFile(bodyPath)

    ' 1. Download the package.
    port = CreateObject("roMessagePort")
    xfer = UP_NewTransfer(port)
    xfer.SetUrl(UP_RepoBase() + version + ".zip")
    if not xfer.AsyncGetToFile(zipPath) then return { ok: false, message: "Could not start the download." }
    msg = UP_Wait(xfer, port, 60000)
    if msg = invalid then return { ok: false, message: "Download timed out." }
    if msg.GetResponseCode() <> 200 then return { ok: false, message: "Download failed (HTTP " + msg.GetResponseCode().ToStr() + ")." }
    zip = CreateObject("roByteArray")
    zip.ReadFile(zipPath)
    ' Every zip starts with "PK"; anything else is an error page.
    if zip.Count() < 1000 or zip[0] <> 80 or zip[1] <> 75 then return { ok: false, message: "Downloaded file is not a channel package." }

    ' 2. Wrap it as the installer's upload form.
    crlf = chr(13) + chr(10)
    q = chr(34)
    boundary = "----HydraHDUpdate" + CreateObject("roDateTime").AsSeconds().ToStr()
    head = "--" + boundary + crlf
    head = head + "Content-Disposition: form-data; name=" + q + "mysubmit" + q + crlf + crlf + "Install" + crlf
    head = head + "--" + boundary + crlf
    head = head + "Content-Disposition: form-data; name=" + q + "archive" + q + "; filename=" + q + "HydraHD.zip" + q + crlf
    head = head + "Content-Type: application/octet-stream" + crlf + crlf
    body = CreateObject("roByteArray")
    body.FromAsciiString(head)
    body.Append(zip)
    tail = CreateObject("roByteArray")
    tail.FromAsciiString(crlf + "--" + boundary + "--" + crlf)
    body.Append(tail)
    if not body.WriteFile(bodyPath) then return { ok: false, message: "Could not stage the package." }

    ' 3. Ask the installer for its digest challenge.
    target = "http://" + UP_DeviceIp() + "/plugin_install"
    probe = UP_NewTransfer(port)
    probe.SetUrl(target)
    if not probe.AsyncGetToString() then return { ok: false, message: "Could not reach the Roku installer." }
    msg = UP_Wait(probe, port, 10000)
    if msg = invalid then return { ok: false, message: "Roku installer did not answer. Is Developer Mode on?" }
    challenge = ""
    headers = msg.GetResponseHeaders()
    if headers <> invalid then
        for each name in headers
            if LCase(name) = "www-authenticate" then challenge = headers[name]
        end for
    end if
    auth = UP_DigestHeader(challenge, password, "POST", "/plugin_install")
    if auth = "" then return { ok: false, message: "Roku installer gave no login challenge (HTTP " + msg.GetResponseCode().ToStr() + "). Is Developer Mode on?" }

    ' 4. Upload. On success the Roku restarts the channel mid-request.
    post = UP_NewTransfer(port)
    post.SetUrl(target)
    post.AddHeader("Authorization", auth)
    post.AddHeader("Content-Type", "multipart/form-data; boundary=" + boundary)
    if not post.AsyncPostFromFile(bodyPath) then return { ok: false, message: "Could not start the install." }
    msg = UP_Wait(post, port, 120000)
    DeleteFile(zipPath)
    DeleteFile(bodyPath)
    if msg = invalid then return { ok: false, message: "Install timed out." }
    code = msg.GetResponseCode()
    if code = 401 then return { ok: false, message: "Roku rejected the developer password." }
    text = msg.GetString()
    if text = invalid then text = ""
    if code = 200 and Instr(1, text, "Identical to previous version") > 0 then return { ok: false, message: "That version is already installed." }
    if code = 200 and Instr(1, text, "Install Failure") = 0 then return { ok: true, message: "Installed. Restarting..." }
    reason = U_FirstMatch(text, "(Install Failure[^<" + q + "]*)")
    if reason = "" then reason = "Install failed (HTTP " + code.ToStr() + ")."
    return { ok: false, message: reason }
end function

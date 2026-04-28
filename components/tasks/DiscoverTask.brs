' DiscoverTask.brs - Locate the companion resolver on the LAN without
' the user having to type an IP address.
'
' Two strategies, run in order:
'   1. SSDP / UDP-broadcast probe  (resolver replies unicast in <1s)
'   2. Subnet scan of /24 around our own IP, GET /health on :8787
'
' Each Roku that boots into the channel runs this once at startup
' (when no resolverUrl is stored in the registry), and again any time
' the user picks "Auto-discover" from Settings.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    url = trySsdp(m.top.probeMs)
    if url <> "" then
        m.top.method = "ssdp"
        m.top.resolverUrl = url
        return
    end if

    if not m.top.ssdpOnly then
        url = trySubnetScan(m.top.scanMs, m.top.defaultPort)
        if url <> "" then
            m.top.method = "scan"
            m.top.resolverUrl = url
            return
        end if
    end if

    m.top.method = "none"
    m.top.resolverUrl = ""
end sub

' --- SSDP probe ------------------------------------------------------

' Fires a UDP broadcast to 255.255.255.255:1901 with a single line of
' text ("HYDRAHD-DISCOVER\n") and waits up to timeoutMs for a unicast
' reply of the form:
'
'     HYDRAHD-RESOLVER
'     url=http://<ip>:<port>
'     version=1
'
' Returns the parsed url, or "" on timeout.
function trySsdp(timeoutMs as Integer) as String
    if timeoutMs < 200 then timeoutMs = 200

    sock = CreateObject("roDatagramSocket")
    if sock = invalid then return ""

    msgPort = CreateObject("roMessagePort")
    sock.setMessagePort(msgPort)

    bind = CreateObject("roSocketAddress")
    bind.setHostName("0.0.0.0")
    bind.setPort(0)
    ' Some Roku firmwares reject explicit binds to 0.0.0.0; on those,
    ' the socket auto-binds to an ephemeral port on first send and
    ' receives reply traffic just fine, so a failed setAddress is not
    ' fatal here.
    sock.setAddress(bind)

    sock.setBroadcast(true)
    sock.notifyReadable(true)

    payload = "HYDRAHD-DISCOVER" + chr(10)

    targets = ["255.255.255.255"]
    directed = directedBroadcastAddr()
    if directed <> "" and directed <> "255.255.255.255" then targets.Push(directed)

    sentAny = false
    for each host in targets
        target = CreateObject("roSocketAddress")
        target.setHostName(host)
        target.setPort(1901)
        sock.setSendToAddress(target)
        n = sock.sendStr(payload)
        if n > 0 then sentAny = true
    end for
    if not sentAny then return ""

    deadline = CreateObject("roTimespan")
    deadline.mark()

    while deadline.totalMilliseconds() < timeoutMs
        remaining = timeoutMs - deadline.totalMilliseconds()
        if remaining < 1 then exit while
        msg = wait(remaining, msgPort)
        if msg = invalid then exit while
        if type(msg) = "roSocketEvent" then
            if sock.isReadable() then
                text = sock.receiveStr(2048)
                if text <> invalid and Instr(1, text, "HYDRAHD-RESOLVER") > 0 then
                    re = CreateObject("roRegex", "url=([^\r\n]+)", "")
                    m2 = re.match(text)
                    if m2 <> invalid and m2.Count() >= 2 then
                        url = U_Trim(m2[1])
                        if url <> "" then return url
                    end if
                end if
            end if
        end if
    end while

    return ""
end function

' Compute the directed broadcast address (x.y.z.255) for our /24.
' Falls back to "" if we can't read a non-loopback IPv4 address.
function directedBroadcastAddr() as String
    di = CreateObject("roDeviceInfo")
    addrs = di.GetIPAddrs()
    if addrs = invalid then return ""
    for each iface in addrs
        ip = addrs[iface]
        if ip <> invalid and ip <> "" and Left(ip, 4) <> "127." then
            parts = ip.Tokenize(".")
            if parts.Count() = 4 then
                return parts[0] + "." + parts[1] + "." + parts[2] + ".255"
            end if
        end if
    end for
    return ""
end function

' --- Subnet scan fallback -------------------------------------------

' Walks the /24 around our own IP in small batches asking each host
' for /health on <port>. Roku has a tight per-channel cap on
' simultaneous TCP sockets (~10-15) and exhausting it stalls every
' subsequent HTTP call in the channel - so we cap the in-flight
' batch and clean up between rounds rather than firing 254 transfers
' at once.
function trySubnetScan(timeoutMs as Integer, defaultPort as Integer) as String
    if defaultPort < 1 then defaultPort = 8787
    if timeoutMs < 500 then timeoutMs = 500

    di = CreateObject("roDeviceInfo")
    addrs = di.GetIPAddrs()
    if addrs = invalid then return ""

    base = ""
    for each iface in addrs
        ip = addrs[iface]
        if ip <> invalid and ip <> "" and Left(ip, 4) <> "127." then
            parts = ip.Tokenize(".")
            if parts.Count() = 4 then
                base = parts[0] + "." + parts[1] + "." + parts[2] + "."
                exit for
            end if
        end if
    end for
    if base = "" then return ""

    portStr = defaultPort.ToStr()
    batchSize = 8
    perBatchMs = 350
    deadline = CreateObject("roTimespan")
    deadline.mark()

    n = 1
    while n <= 254 and deadline.totalMilliseconds() < timeoutMs
        endN = n + batchSize - 1
        if endN > 254 then endN = 254
        hit = scanBatch(base, n, endN, portStr, perBatchMs)
        if hit <> "" then return hit
        n = endN + 1
    end while
    return ""
end function

' One batch of subnet probes. Spawns a small number of async transfers,
' waits up to budgetMs for any 200, then cancels the rest and returns
' (so the next batch starts with no in-flight sockets).
function scanBatch(base as String, fromN as Integer, toN as Integer, portStr as String, budgetMs as Integer) as String
    msgPort = CreateObject("roMessagePort")
    transfers = []
    byId = {}
    for n = fromN to toN
        candidate = "http://" + base + n.ToStr() + ":" + portStr
        x = CreateObject("roUrlTransfer")
        x.setMessagePort(msgPort)
        x.setUrl(candidate + "/health")
        x.enableEncodings(true)
        x.setMinimumTransferRate(1, 1)
        if x.AsyncGetToString() then
            id = x.getIdentity()
            byId[id.ToStr()] = candidate
            transfers.Push(x)
        end if
    end for

    deadline = CreateObject("roTimespan")
    deadline.mark()
    found = ""
    while deadline.totalMilliseconds() < budgetMs
        remaining = budgetMs - deadline.totalMilliseconds()
        if remaining < 1 then exit while
        msg = wait(remaining, msgPort)
        if msg = invalid then exit while
        if type(msg) = "roUrlEvent" then
            if msg.getResponseCode() = 200 then
                idStr = msg.getSourceIdentity().ToStr()
                if byId.DoesExist(idStr) then
                    found = byId[idStr]
                    exit while
                end if
            end if
        end if
    end while

    ' Cancel everything still pending so the OS-level socket pool is
    ' clean before the next batch starts.
    for each x in transfers
        x.AsyncCancel()
    end for
    return found
end function

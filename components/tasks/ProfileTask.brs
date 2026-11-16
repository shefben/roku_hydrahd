' ProfileTask.brs - Talks to the profile server (resolver/server.py).
'
' Modes:
'   list    GET  /profiles                   -> { ok, profiles: [...] }
'   create  POST /profiles/create {name}     -> { ok, profile }
'   delete  POST /profiles/delete?id=        -> { ok }
'   push    send this TV's unsent changes    -> { ok }
'   sync    push, then replace the local cache with the server copy
'           -> { ok, offline, missing }
' On failure: { ok: false, error: "<readable message>" }.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    mode = m.top.mode
    server = m.top.server
    if server = invalid or server = "" then
        m.top.result = { mode: mode, ok: false, error: "No server address is set." }
        return
    end if
    if mode = "list" then
        res = PT_List(server)
    else if mode = "create" then
        res = PT_Create(server, m.top.name)
    else if mode = "delete" then
        res = PT_Delete(server, m.top.profileId)
    else if mode = "push" then
        res = PT_PushPending(server, m.top.profileId)
    else if mode = "sync" then
        res = PT_Sync(server, m.top.profileId)
    else
        res = { ok: false, error: "unknown mode" }
    end if
    res.mode = mode
    m.top.result = res
end sub

' { code, body, error }. code < 0 means the server was not reached.
function PT_Request(method as String, url as String, body as Dynamic, timeoutMs as Integer) as Object
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetUrl(url)
    xfer.SetMessagePort(port)
    xfer.RetainBodyOnError(true)
    if Left(LCase(url), 8) = "https://" then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if
    if method = "POST" then
        xfer.AddHeader("Content-Type", "application/json")
        if body = invalid then body = "{}"
        started = xfer.AsyncPostFromString(body)
    else
        started = xfer.AsyncGetToString()
    end if
    if not started then return { code: -1, body: "", error: "Could not start the request." }
    clock = CreateObject("roTimespan")
    clock.Mark()
    while clock.TotalMilliseconds() < timeoutMs
        msg = wait(timeoutMs - clock.TotalMilliseconds(), port)
        if msg = invalid then exit while
        if type(msg) = "roUrlEvent" then
            code = msg.GetResponseCode()
            text = msg.GetString()
            if text = invalid then text = ""
            err = ""
            if code < 0 then err = "Could not reach the server (" + msg.GetFailureReason() + ")."
            return { code: code, body: text, error: err }
        end if
    end while
    xfer.AsyncCancel()
    return { code: -1, body: "", error: "The server did not answer in time." }
end function

' Readable error for a failed response.
function PT_Error(r as Object) as String
    if r.error <> invalid and r.error <> "" then return r.error
    parsed = ParseJson(r.body)
    if parsed <> invalid and parsed.error <> invalid then return parsed.error
    if r.code = 404 then return "The server does not support user profiles. Update resolver/server.py on the server."
    return "Server error (HTTP " + r.code.ToStr() + ")."
end function

function PT_List(server as String) as Object
    r = PT_Request("GET", server + "/profiles", invalid, 6000)
    if r.code <> 200 then return { ok: false, error: PT_Error(r) }
    parsed = ParseJson(r.body)
    if parsed = invalid or parsed.profiles = invalid then return { ok: false, error: "That address answered, but it is not the HydraHD server." }
    return { ok: true, profiles: parsed.profiles }
end function

function PT_Create(server as String, name as String) as Object
    r = PT_Request("POST", server + "/profiles/create", FormatJson({ name: name }), 6000)
    if r.code <> 200 then return { ok: false, error: PT_Error(r) }
    parsed = ParseJson(r.body)
    if parsed = invalid or parsed.profile = invalid then return { ok: false, error: "Unexpected reply from the server." }
    return { ok: true, profile: parsed.profile }
end function

function PT_Delete(server as String, id as String) as Object
    r = PT_Request("POST", server + "/profiles/delete?id=" + U_UrlEncode(id), "{}", 6000)
    if r.code <> 200 then return { ok: false, error: PT_Error(r) }
    return { ok: true }
end function

' Send every change recorded in HydraHD_NetPending. A change is only
' forgotten once the server has it and the value was not changed again
' while the request was in flight.
function PT_PushPending(server as String, id as String) as Object
    if id = "" then return { ok: false, error: "No user selected." }
    pend = CreateObject("roRegistrySection", "HydraHD_NetPending")
    for iter = 1 to 5
        keys = pend.GetKeyList()
        if keys = invalid or keys.Count() = 0 then return { ok: true }
        sets = {}
        dels = {}
        sent = []
        for each pk in keys
            bar = Instr(1, pk, "|")
            if bar > 1 then
                logical = Left(pk, bar - 1)
                key = Mid(pk, bar + 1)
                cache = CreateObject("roRegistrySection", P_CacheSectionName(logical))
                if cache.Exists(key) then
                    v = cache.Read(key)
                    if sets[logical] = invalid then sets[logical] = {}
                    ' Values are JSON text. Send them parsed, so the body
                    ' never nests quoted JSON inside a string (the server
                    ' stores non-string values back as JSON text).
                    parsedValue = invalid
                    if v <> "" then parsedValue = ParseJson(v)
                    if parsedValue <> invalid then
                        sets[logical][key] = parsedValue
                    else
                        sets[logical][key] = v
                    end if
                    sent.Push({ pk: pk, logical: logical, key: key, value: v })
                else
                    if dels[logical] = invalid then dels[logical] = []
                    dels[logical].Push(key)
                    sent.Push({ pk: pk, logical: logical, key: key, value: invalid })
                end if
            else
                pend.Delete(pk)
            end if
        end for
        r = PT_Request("POST", server + "/profiles/state?id=" + U_UrlEncode(id), FormatJson({ set: sets, del: dels }), 15000)
        if r.code <> 200 then return { ok: false, error: PT_Error(r), missing: (r.code = 404) }
        for each s in sent
            cache = CreateObject("roRegistrySection", P_CacheSectionName(s.logical))
            cur = invalid
            if cache.Exists(s.key) then cur = cache.Read(s.key)
            same = false
            if cur = invalid and s.value = invalid then same = true
            if cur <> invalid and s.value <> invalid then same = (cur = s.value)
            if same then pend.Delete(s.pk)
        end for
        pend.Flush()
    end for
    return { ok: true }
end function

function PT_Sync(server as String, id as String) as Object
    if id = "" then return { ok: false, error: "No user selected." }
    push = PT_PushPending(server, id)
    if not push.ok then
        if push.missing = true then return { ok: false, missing: true, error: "This user no longer exists on the server." }
        return { ok: false, offline: true, error: push.error }
    end if
    r = PT_Request("GET", server + "/profiles/state?id=" + U_UrlEncode(id), invalid, 8000)
    if r.code = 404 then return { ok: false, missing: true, error: "This user no longer exists on the server." }
    if r.code <> 200 then return { ok: false, offline: true, error: PT_Error(r) }
    parsed = ParseJson(r.body)
    if parsed = invalid or parsed.data = invalid then return { ok: false, offline: true, error: "Unexpected reply from the server." }
    ' A change made while the GET was running stays pending; keep the
    ' cache as it is rather than overwrite it with the older copy.
    pend = CreateObject("roRegistrySection", "HydraHD_NetPending")
    keys = pend.GetKeyList()
    if keys <> invalid and keys.Count() > 0 then return { ok: true }
    P_WriteCache(parsed.data)
    if parsed.profile <> invalid and parsed.profile.name <> invalid then U_PrefSet("profileName", parsed.profile.name)
    return { ok: true }
end function

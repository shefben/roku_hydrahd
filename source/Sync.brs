' Sync.brs - Client side of resolver-backed registry persistence.
'
' Roku wipes the dev-sideload registry on a full uninstall, so favorites,
' Continue Watching progress, search history, and mirror reliability
' stats would all disappear. The companion resolver exposes /state which
' takes a JSON snapshot of those sections; we ship one on every relevant
' write and pull it back on boot. The "did" is the device's stable
' channel client id, so the same physical Roku rejoins its own data
' after the channel is reinstalled.
'
' Snapshot shape:
'   {
'     "HydraHD_Progress":  { "m:<key>": "<json>", ... },
'     "HydraHD_Favorites": { "<key>": "<json>", ... },
'     "HydraHD_MirrorStats": { "<host>": "12:3", ... },
'     "HydraHD":            { "searchHistory": "[...]" }
'   }

function S_SyncSections() as Object
    return [ "HydraHD_Progress", "HydraHD_Favorites", "HydraHD_MirrorStats" ]
end function

function S_HydraSyncKeys() as Object
    return [ "searchHistory" ]
end function

function S_BuildSnapshot() as Object
    out = {}
    for each section in S_SyncSections()
        reg = CreateObject("roRegistrySection", section)
        keys = reg.GetKeyList()
        if keys <> invalid then
            blob = {}
            for each k in keys
                blob[k] = reg.Read(k)
            end for
            out[section] = blob
        end if
    end for
    hyd = CreateObject("roRegistrySection", "HydraHD")
    hydBlob = {}
    for each k in S_HydraSyncKeys()
        if hyd.Exists(k) then hydBlob[k] = hyd.Read(k)
    end for
    if hydBlob.Count() > 0 then out["HydraHD"] = hydBlob
    return out
end function

' Apply a snapshot pulled from the resolver. Existing local entries
' "win" - we only fill in keys that are missing locally - so a freshly
' reinstalled channel rehydrates from the resolver while a partially
' populated registry on a working install isn't clobbered.
sub S_ApplySnapshot(snapshot as Object)
    if snapshot = invalid then return
    for each section in snapshot
        blob = snapshot[section]
        if blob <> invalid then
            reg = CreateObject("roRegistrySection", section)
            for each k in blob
                if not reg.Exists(k) then
                    v = blob[k]
                    if v <> invalid then reg.Write(k, v.ToStr())
                end if
            end for
            reg.Flush()
        end if
    end for
end sub

function S_ResolverUrl() as String
    resolver = U_DefaultResolverUrl()
    if resolver = "" then resolver = U_PrefDefault("resolverUrl", "")
    return resolver
end function

' Run a synchronous pull at startup. Capped at 5s so a dead resolver
' can't block boot indefinitely. Returns true if a snapshot was applied.
function S_PullOnBoot() as Boolean
    resolver = S_ResolverUrl()
    if resolver = "" then return false
    task = CreateObject("roSGNode", "SyncTask")
    if task = invalid then return false
    task.mode = "pull"
    task.resolverUrl = resolver
    task.did = U_ClientId()
    port = CreateObject("roMessagePort")
    task.observeField("result", port)
    task.control = "RUN"
    msg = wait(5000, port)
    if msg = invalid then
        task.control = "STOP"
        return false
    end if
    res = task.result
    if res = invalid or res.ok <> true then return false
    snapshot = res.snapshot
    if snapshot = invalid then return false
    S_ApplySnapshot(snapshot)
    return true
end function

' Throttled push - skip if we pushed within the last 5 seconds. Used by
' the playback heartbeat (W_Save*Progress fires roughly every 5s during
' a stream); without this we'd hit the resolver 12+ times per minute.
sub S_QueuePush()
    if m.global = invalid then return
    m.global.addField("syncLastPush", "int", false)
    m.global.addField("syncTask", "node", false)
    now = CreateObject("roDateTime").AsSeconds()
    last = m.global.syncLastPush
    if last > 0 and (now - last) < 5 then return
    S_FirePush(now)
end sub

' Force-push - bypasses the throttle. Called for user-initiated writes
' (favorite toggle, search submit) where the user expects the resolver
' to see the change before they kill the channel.
sub S_QueuePushNow()
    if m.global = invalid then return
    m.global.addField("syncLastPush", "int", false)
    m.global.addField("syncTask", "node", false)
    S_FirePush(CreateObject("roDateTime").AsSeconds())
end sub

' Fire-and-forget the actual POST. Task ref is parked on m.global so
' Roku doesn't GC it mid-flight; we deliberately don't observe `result`
' here - dropped-callback edge cases (observing component torn down
' before the task completes, e.g. user navigating out of PlayerView
' mid-push) would leave any in-flight flag stuck and stop future
' pushes. Roku keeps a running Task alive via its internal scheduler
' regardless of script-side references.
sub S_FirePush(now as Integer)
    resolver = S_ResolverUrl()
    if resolver = "" then return
    task = CreateObject("roSGNode", "SyncTask")
    if task = invalid then return
    task.mode = "push"
    task.resolverUrl = resolver
    task.did = U_ClientId()
    task.payload = FormatJson(S_BuildSnapshot())
    m.global.syncTask = task
    m.global.syncLastPush = now
    task.control = "RUN"
end sub

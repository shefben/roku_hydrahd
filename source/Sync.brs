' Sync.brs - Sends network-profile changes to the profile server.
'
' In network mode (see Profiles.brs) every write to favorites, progress
' or search history goes to the registry cache first, then the changed
' key is recorded in HydraHD_NetPending as "<logical>|<key>". A
' ProfileTask "push" sends the pending keys and forgets them only once
' the server has them. If the server is down the keys stay pending and
' go out with the next push or at the next launch, so nothing is lost.
' In local mode these calls do nothing.

sub S_MarkChanged(logical as String, key as String)
    if key = "" or not P_IsNetwork() then return
    pend = CreateObject("roRegistrySection", "HydraHD_NetPending")
    pend.Write(logical + "|" + key, "1")
    pend.Flush()
end sub

' Throttled push for the playback heartbeat, which saves every few
' seconds. Keys skipped here stay pending for the next push.
sub S_QueuePush()
    if not P_IsNetwork() or m.global = invalid then return
    m.global.addField("syncLastPush", "int", false)
    m.global.addField("syncTask", "node", false)
    now = CreateObject("roDateTime").AsSeconds()
    last = m.global.syncLastPush
    if last > 0 and (now - last) < 15 then return
    S_FirePush(now)
end sub

' Push right away. Used for user actions (favorite toggle, search, mark
' watched) and when playback stops.
sub S_QueuePushNow()
    if not P_IsNetwork() or m.global = invalid then return
    m.global.addField("syncLastPush", "int", false)
    m.global.addField("syncTask", "node", false)
    S_FirePush(CreateObject("roDateTime").AsSeconds())
end sub

' Fire and forget. The task is parked on m.global so it is not collected
' mid-request; the result is not observed because the observing view may
' be gone by the time it finishes.
sub S_FirePush(now as Integer)
    task = CreateObject("roSGNode", "ProfileTask")
    if task = invalid then return
    task.mode = "push"
    task.server = P_ServerUrl()
    task.profileId = P_ProfileId()
    m.global.syncTask = task
    m.global.syncLastPush = now
    task.control = "RUN"
end sub

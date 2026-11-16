' ProfileSetup.brs - First-run storage choice and the "Who's watching?"
' profile picker for server-stored user data.
'
' Steps:
'   mode           local or server storage (first run, or from Settings)
'   server         type the server's IP:port, then list its users
'   users          pick a user, add one, delete one, change server
'   create         type a new user's name
'   import         copy this TV's local data into the new user?
'   deletePick     choose which user to delete
'   deleteConfirm  confirm the delete
'
' MainScene sets `open` and waits for `finished`:
'   { action: "local" }    this TV only
'   { action: "network" }  a profile is active and its data was loaded
'   { action: "cancel" }   nothing changed

sub init()
    m.title = m.top.findNode("title")
    m.message = m.top.findNode("message")
    m.choices = m.top.findNode("choices")
    m.userList = m.top.findNode("userList")
    m.entry = m.top.findNode("entry")
    m.kb = m.top.findNode("kb")
    m.kbActions = m.top.findNode("kbActions")
    m.busy = m.top.findNode("busy")

    m.choices.observeField("buttonSelected", "onChoice")
    m.userList.observeField("itemSelected", "onUserSelected")
    m.kbActions.observeField("buttonSelected", "onKbAction")

    m.step = ""
    m.required = false
    m.server = ""
    m.profiles = []
    m.task = invalid
    m.top.visible = false
end sub

sub onOpen()
    req = m.top.open
    if req = invalid then return
    m.required = (req.required = true)
    m.fromMode = false
    m.server = P_ServerUrl()
    m.top.visible = true
    stepName = req.step
    if stepName = "users" and m.server <> "" then
        loadUsers("")
    else if stepName = "server" then
        showServer("")
    else
        showMode()
    end if
end sub

sub finish(action as String)
    cancelTask()
    m.top.visible = false
    m.step = ""
    m.top.finished = { action: action }
end sub

' --- widget helpers -----------------------------------------------------

sub hideAll()
    m.choices.visible = false
    m.userList.visible = false
    m.entry.visible = false
    m.busy.visible = false
    m.message.color = "0xc8c8c8ff"
end sub

sub setText(title as String, message as String)
    m.title.text = title
    m.message.text = message
end sub

sub showError(text as String)
    m.message.text = text
    m.message.color = "0xff8a8aff"
end sub

sub showChoices(buttons as Object, focusIdx as Integer)
    m.choices.buttons = buttons
    m.choices.visible = true
    m.choices.focusButton = focusIdx
    m.choices.setFocus(true)
end sub

sub showEntry(initial as String, actions as Object)
    m.kb.text = initial
    m.kbActions.buttons = actions
    m.entry.visible = true
    m.kb.setFocus(true)
end sub

sub showList(labels as Object, focusIdx as Integer)
    content = CreateObject("roSGNode", "ContentNode")
    for each l in labels
        item = content.createChild("ContentNode")
        item.title = l
    end for
    m.userList.content = content
    m.userList.visible = true
    if focusIdx >= 0 and focusIdx < labels.Count() then m.userList.jumpToItem = focusIdx
    m.userList.setFocus(true)
end sub

sub showBusy(text as String)
    hideAll()
    m.busy.text = text
    m.busy.visible = true
    m.message.text = ""
    m.top.setFocus(true)
end sub

' callFunc entry point. Roku's callFunc silently does nothing for a
' function declared with no parameter, so this takes a placeholder; the
' refocusRequest field is a second, callFunc-free way in.
function refocus(_unused as Dynamic) as Object
    doRefocus()
    return invalid
end function

sub onRefocusRequest()
    doRefocus()
end sub

sub doRefocus()
    if not m.top.visible then return
    if m.entry.visible then
        if not m.kbActions.isInFocusChain() then m.kb.setFocus(true)
    else if m.userList.visible then
        m.userList.setFocus(true)
    else if m.choices.visible then
        m.choices.setFocus(true)
    else
        m.top.setFocus(true)
    end if
end sub

' --- tasks --------------------------------------------------------------

sub runTask(mode as String, fields as Object, callback as String)
    cancelTask()
    task = CreateObject("roSGNode", "ProfileTask")
    task.mode = mode
    task.server = m.server
    if fields <> invalid then
        for each f in fields
            task[f] = fields[f]
        end for
    end if
    m.taskCallback = callback
    task.observeField("result", "onTaskResult")
    m.task = task
    task.control = "RUN"
end sub

sub cancelTask()
    if m.task <> invalid then
        m.task.unobserveField("result")
        m.task = invalid
    end if
end sub

sub onTaskResult(event as Object)
    res = event.getData()
    m.task = invalid
    if res = invalid then res = { ok: false, error: "No reply." }
    cb = m.taskCallback
    if cb = "afterList" then
        afterList(res)
    else if cb = "afterCreate" then
        afterCreate(res)
    else if cb = "afterDelete" then
        afterDelete(res)
    else if cb = "afterOldPush" then
        afterOldPush(res)
    else if cb = "afterSync" then
        afterSync(res)
    end if
end sub

' --- step: mode ---------------------------------------------------------

sub showMode()
    m.step = "mode"
    hideAll()
    setText("Where should your data be saved?", "Favorites, watch history and resume points can stay on this TV, or live on your HydraHD server so every TV in the house shares them, one user per person.")
    focusIdx = 0
    if P_Mode() = "network" then focusIdx = 1
    showChoices(["On this TV only", "On my HydraHD server"], focusIdx)
end sub

' --- step: server -------------------------------------------------------

sub showServer(errorText as String)
    m.step = "server"
    hideAll()
    setText("HydraHD server address", "Enter the IP address and port of the computer running resolver/server.py, for example 192.168.1.50:8787. The port defaults to 8787.")
    initial = m.server
    if initial = "" then initial = U_PrefDefault("resolverUrl", "")
    initial = initial.Replace("http://", "")
    showEntry(initial, ["Connect", "Back"])
    if errorText <> "" then showError(errorText)
end sub

sub connectServer()
    url = P_NormalizeServer(m.kb.text)
    if url = "" then
        showError("Enter an address such as 192.168.1.50:8787.")
        return
    end if
    m.pendingServer = url
    showBusy("Connecting to " + url + " ...")
    m.server = url
    runTask("list", invalid, "afterList")
end sub

sub afterList(res as Object)
    if res.ok <> true then
        ' The saved user's server is down: offer the copy kept on this TV.
        if P_IsNetwork() and m.server = P_ServerUrl() then
            showOffline(res.error)
            return
        end if
        if m.step = "server" then
            showServer("Could not connect: " + res.error)
        else
            showServer("Could not load the users: " + res.error)
        end if
        return
    end if
    m.profiles = res.profiles
    if m.profiles = invalid then m.profiles = []
    showUsers("")
end sub

sub loadUsers(errorText as String)
    m.step = "server"
    showBusy("Loading users from " + m.server + " ...")
    runTask("list", invalid, "afterList")
end sub

' --- step: offline ------------------------------------------------------

sub showOffline(errorText as String)
    m.step = "offline"
    hideAll()
    setText("Server not reachable", "Could not reach " + m.server + " (" + errorText + "). You can keep watching as " + P_ProfileName() + " with the copy saved on this TV; changes are sent to the server once it is back.")
    showChoices(["Continue as " + P_ProfileName(), "Try again", "Change server address", "Store data on this TV only"], 0)
end sub

' --- step: users --------------------------------------------------------

sub showUsers(errorText as String)
    if m.profiles.Count() = 0 then
        showCreate(true, "There are no users on this server yet. Create the first one.")
        return
    end if
    m.step = "users"
    hideAll()
    setText("Who's watching?", "Server: " + m.server)
    labels = []
    focusIdx = 0
    current = ""
    if m.server = P_ServerUrl() then current = P_ProfileId()
    for i = 0 to m.profiles.Count() - 1
        p = m.profiles[i]
        label = p.name
        if p.id = current then
            label = label + "   (current)"
            focusIdx = i
        end if
        labels.Push(label)
    end for
    labels.Push("+ Add a new user")
    labels.Push("Delete a user")
    labels.Push("Change server address")
    if not m.required then labels.Push("Store data on this TV only")
    showList(labels, focusIdx)
    if errorText <> "" then showError(errorText)
end sub

sub onUserSelected()
    idx = m.userList.itemSelected
    if idx = invalid or idx < 0 then return
    n = m.profiles.Count()
    if m.step = "users" then
        if idx < n then
            activate(m.profiles[idx], false)
        else if idx = n then
            showCreate(false, "")
        else if idx = n + 1 then
            showDeletePick()
        else if idx = n + 2 then
            showServer("")
        else
            P_UseLocal()
            finish("local")
        end if
    else if m.step = "deletePick" then
        if idx < n then
            showDeleteConfirm(m.profiles[idx])
        else
            showUsers("")
        end if
    end if
end sub

' --- step: create -------------------------------------------------------

sub showCreate(forced as Boolean, note as String)
    m.step = "create"
    m.createForced = forced
    hideAll()
    msg = "Enter a name for the new user (up to 24 letters, numbers or spaces)."
    if note <> "" then msg = note + " " + msg
    setText("New user", msg)
    showEntry("", ["Create", "Back"])
end sub

sub createUser()
    name = U_Trim(m.kb.text)
    if name = "" then
        showError("Type a name first.")
        return
    end if
    if Len(name) > 24 then
        showError("Names can be at most 24 characters.")
        return
    end if
    m.createName = name
    showBusy("Creating " + name + " ...")
    runTask("create", { name: name }, "afterCreate")
end sub

sub afterCreate(res as Object)
    if res.ok <> true then
        showCreate(m.createForced, "")
        m.kb.text = m.createName
        showError(res.error)
        return
    end if
    m.profiles.Push(res.profile)
    localData = P_ReadSections(true)
    m.localCount = P_CountEntries(localData)
    if m.localCount > 0 then
        showImport(res.profile)
    else
        activate(res.profile, false)
    end if
end sub

' --- step: import -------------------------------------------------------

sub showImport(profile as Object)
    m.step = "import"
    m.importProfile = profile
    hideAll()
    setText("Copy this TV's data?", "This TV already has favorites, watch history or search history saved on it. Copy them into " + profile.name + "'s profile on the server?")
    showChoices(["Yes, copy them", "No, start empty"], 0)
end sub

' --- step: delete -------------------------------------------------------

sub showDeletePick()
    m.step = "deletePick"
    hideAll()
    setText("Delete a user", "Pick the user to delete.")
    labels = []
    for each p in m.profiles
        labels.Push(p.name)
    end for
    labels.Push("Cancel")
    showList(labels, 0)
end sub

sub showDeleteConfirm(profile as Object)
    m.step = "deleteConfirm"
    m.deleteProfile = profile
    hideAll()
    setText("Delete " + profile.name + "?", profile.name + "'s favorites, watch history and resume points are removed from the server for every TV. This cannot be undone.")
    showChoices(["Delete " + profile.name, "Cancel"], 1)
end sub

sub afterDelete(res as Object)
    if res.ok <> true then
        showUsers("Could not delete: " + res.error)
        return
    end if
    if m.server = P_ServerUrl() and m.deleteProfile.id = P_ProfileId() then
        U_PrefSet("profileId", "")
        U_PrefSet("profileName", "")
        P_ClearPending()
        P_ClearCache()
        m.activeDeleted = true
    end if
    loadUsers("")
end sub

' --- activation ---------------------------------------------------------

' Make `profile` active and load its data. Changes this TV still holds
' for the previous profile are sent first so they are not dropped.
sub activate(profile as Object, importLocal as Boolean)
    m.activeProfile = profile
    m.importLocal = importLocal
    oldId = P_ProfileId()
    oldServer = P_ServerUrl()
    switching = (oldId <> profile.id or oldServer <> m.server)
    if switching and oldId <> "" and oldServer <> "" and P_HasPending() then
        showBusy("Saving changes for the previous user ...")
        targetServer = m.server
        m.server = oldServer
        runTask("push", { profileId: oldId }, "afterOldPush")
        m.server = targetServer
        return
    end if
    continueActivate()
end sub

sub afterOldPush(res as Object)
    ' Whatever the result, the previous profile's unsent changes cannot
    ' follow us into another profile.
    continueActivate()
end sub

sub continueActivate()
    profile = m.activeProfile
    if profile.id <> P_ProfileId() or m.server <> P_ServerUrl() then P_ClearPending()
    P_SetActiveProfile(m.server, profile.id, profile.name)
    if m.importLocal then P_ImportLocalToCache()
    showBusy("Loading " + profile.name + "'s favorites and history ...")
    runTask("sync", { profileId: profile.id }, "afterSync")
end sub

sub afterSync(res as Object)
    if res.ok = true then
        finish("network")
        return
    end if
    if res.offline = true then
        finish("offline")
        return
    end if
    ' The profile vanished (deleted from another TV).
    U_PrefSet("profileId", "")
    U_PrefSet("profileName", "")
    P_ClearPending()
    P_ClearCache()
    loadUsers("")
end sub

' --- input --------------------------------------------------------------

sub onChoice()
    idx = m.choices.buttonSelected
    if m.step = "mode" then
        if idx = 0 then
            P_UseLocal()
            finish("local")
        else
            m.fromMode = true
            showServer("")
        end if
    else if m.step = "import" then
        activate(m.importProfile, idx = 0)
    else if m.step = "offline" then
        if idx = 0 then
            finish("offline")
        else if idx = 1 then
            loadUsers("")
        else if idx = 2 then
            showServer("")
        else
            P_UseLocal()
            finish("local")
        end if
    else if m.step = "deleteConfirm" then
        if idx = 0 then
            showBusy("Deleting " + m.deleteProfile.name + " ...")
            runTask("delete", { profileId: m.deleteProfile.id }, "afterDelete")
        else
            showUsers("")
        end if
    end if
end sub

sub onKbAction()
    idx = m.kbActions.buttonSelected
    if idx = 0 then
        if m.step = "server" then connectServer()
        if m.step = "create" then createUser()
    else
        goBack()
    end if
end sub

sub goBack()
    if m.task <> invalid then
        ' Abandon the request and return to where it started.
        cancelTask()
        if m.step = "create" then
            showCreate(m.createForced, "")
        else
            showServer("")
        end if
        return
    end if
    if m.step = "mode" then
        if not m.required then finish("cancel")
    else if m.step = "server" then
        if m.fromMode or m.required or P_Mode() = "" then
            showMode()
        else
            finish("cancel")
        end if
    else if m.step = "offline" then
        finish("offline")
    else if m.step = "users" then
        if P_IsNetwork() and m.server = P_ServerUrl() and m.activeDeleted <> true then
            ' Keep the current user; still refresh its data.
            m.activeProfile = { id: P_ProfileId(), name: P_ProfileName() }
            m.importLocal = false
            continueActivate()
        else
            showServer("")
        end if
    else if m.step = "create" then
        if m.createForced then
            showServer("")
        else
            showUsers("")
        end if
    else if m.step = "import" then
        activate(m.importProfile, false)
    else if m.step = "deletePick" or m.step = "deleteConfirm" then
        showUsers("")
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if not m.top.visible then return false
    if key = "back" then
        goBack()
        return true
    end if
    if m.entry.visible then
        if key = "down" and m.kb.isInFocusChain() then
            m.kbActions.setFocus(true)
            return true
        end if
        if key = "up" and m.kbActions.isInFocusChain() then
            m.kb.setFocus(true)
            return true
        end if
    end if
    ' Nothing under the overlay may react while it is up.
    return true
end function

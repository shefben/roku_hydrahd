' Profiles.brs - Where favorites, watch progress and search history live.
'
' Two storage modes, picked on first run and changeable in Settings:
'   "local"   - this TV's registry only (the original behaviour; data is
'               kept in HydraHD_Progress / HydraHD_Favorites / HydraHD).
'   "network" - a user profile on the Python server (resolver/server.py,
'               /profiles endpoints). Any TV pointed at the same server
'               sees the same users. The registry keeps a cache of the
'               active profile in separate HydraHD_Net* sections, so the
'               local-mode data is never touched and the channel still
'               works when the server is down.
'
' Registry prefs (section "HydraHD"):
'   storageMode    "local" | "network"   (missing = first run, ask)
'   profileServer  "http://ip:port"
'   profileId      server id of the active profile
'   profileName    display name of the active profile

function P_Mode() as String
    reg = CreateObject("roRegistrySection", "HydraHD")
    if reg.Exists("storageMode") then
        v = reg.Read("storageMode")
        if v = "network" or v = "local" then return v
    end if
    return ""
end function

' Network mode with a profile chosen. Without a profile the channel falls
' back to local storage so nothing is written into a nameless cache.
function P_IsNetwork() as Boolean
    if P_Mode() <> "network" then return false
    return P_ProfileId() <> "" and P_ServerUrl() <> ""
end function

function P_ProfileId() as String
    return U_PrefDefault("profileId", "")
end function

function P_ProfileName() as String
    return U_PrefDefault("profileName", "")
end function

function P_ServerUrl() as String
    return U_PrefDefault("profileServer", "")
end function

' Turn what the user typed ("192.168.1.50", "192.168.1.50:8787",
' "http://host:8787/") into "http://host:port". Returns "" if empty.
function P_NormalizeServer(raw as Dynamic) as String
    if raw = invalid then return ""
    s = U_Trim(raw)
    if s = "" then return ""
    if LCase(Left(s, 7)) <> "http://" and LCase(Left(s, 8)) <> "https://" then s = "http://" + s
    while Right(s, 1) = "/"
        s = Left(s, Len(s) - 1)
    end while
    hostPart = s.Mid(Instr(1, s, "//") + 1)
    slash = Instr(1, hostPart, "/")
    if slash > 0 then hostPart = Left(hostPart, slash - 1)
    if Instr(1, hostPart, ":") = 0 then
        if slash > 0 then
            s = s.Replace(hostPart, hostPart + ":8787")
        else
            s = s + ":8787"
        end if
    end if
    return s
end function

' --- Registry sections ------------------------------------------------
'
' Logical section names match the server's data keys.

function P_SectionName(logical as String) as String
    if P_IsNetwork() then
        if logical = "progress" then return "HydraHD_NetProgress"
        if logical = "favorites" then return "HydraHD_NetFavorites"
        return "HydraHD_NetPrefs"
    end if
    return P_LocalSectionName(logical)
end function

function P_LocalSectionName(logical as String) as String
    if logical = "progress" then return "HydraHD_Progress"
    if logical = "favorites" then return "HydraHD_Favorites"
    return "HydraHD"
end function

function P_CacheSectionName(logical as String) as String
    if logical = "progress" then return "HydraHD_NetProgress"
    if logical = "favorites" then return "HydraHD_NetFavorites"
    return "HydraHD_NetPrefs"
end function

function P_LogicalSections() as Object
    return ["progress", "favorites", "prefs"]
end function

' Keys of the shared "HydraHD" section that belong to the user. The rest
' of that section is device settings and never leaves the TV.
function P_PrefKeys() as Object
    return ["searchHistory"]
end function

' { progress: {k: v}, favorites: {...}, prefs: {...} } read from the
' given registry sections (local ones when fromLocal, else the cache).
function P_ReadSections(fromLocal as Boolean) as Object
    out = {}
    for each logical in P_LogicalSections()
        if fromLocal then
            name = P_LocalSectionName(logical)
        else
            name = P_CacheSectionName(logical)
        end if
        reg = CreateObject("roRegistrySection", name)
        blob = {}
        if logical = "prefs" then
            for each k in P_PrefKeys()
                if reg.Exists(k) then blob[k] = reg.Read(k)
            end for
        else
            keys = reg.GetKeyList()
            if keys <> invalid then
                for each k in keys
                    blob[k] = reg.Read(k)
                end for
            end if
        end if
        out[logical] = blob
    end for
    return out
end function

function P_CountEntries(data as Object) as Integer
    n = 0
    if data = invalid then return 0
    for each logical in data
        blob = data[logical]
        if blob <> invalid then n = n + blob.Count()
    end for
    return n
end function

' Replace the network cache with a profile's data from the server.
sub P_WriteCache(data as Object)
    for each logical in P_LogicalSections()
        reg = CreateObject("roRegistrySection", P_CacheSectionName(logical))
        keys = reg.GetKeyList()
        if keys <> invalid then
            for each k in keys
                reg.Delete(k)
            end for
        end if
        blob = invalid
        if data <> invalid then blob = data[logical]
        if blob <> invalid then
            for each k in blob
                v = blob[k]
                if v <> invalid then
                    if type(v) <> "String" and type(v) <> "roString" then v = FormatJson(v)
                    reg.Write(k, v)
                end if
            end for
        end if
        reg.Flush()
    end for
end sub

sub P_ClearCache()
    P_WriteCache(invalid)
end sub

sub P_ClearPending()
    pend = CreateObject("roRegistrySection", "HydraHD_NetPending")
    keys = pend.GetKeyList()
    if keys <> invalid then
        for each k in keys
            pend.Delete(k)
        end for
    end if
    pend.Flush()
end sub

function P_HasPending() as Boolean
    keys = CreateObject("roRegistrySection", "HydraHD_NetPending").GetKeyList()
    return keys <> invalid and keys.Count() > 0
end function

' Copy this TV's local-mode data into the active profile's cache and
' mark every entry pending, so the next sync uploads it to the server.
' Entries the profile already has on the server are overwritten.
sub P_ImportLocalToCache()
    data = P_ReadSections(true)
    pend = CreateObject("roRegistrySection", "HydraHD_NetPending")
    for each logical in data
        blob = data[logical]
        reg = CreateObject("roRegistrySection", P_CacheSectionName(logical))
        for each k in blob
            reg.Write(k, blob[k])
            pend.Write(logical + "|" + k, "1")
        end for
        reg.Flush()
    end for
    pend.Flush()
end sub

' Make a profile the active one. A different profile than before gets an
' empty cache; the caller pulls its data afterwards.
sub P_SetActiveProfile(server as String, id as String, name as String)
    if id <> P_ProfileId() or server <> P_ServerUrl() then
        P_ClearCache()
    end if
    U_PrefSet("profileServer", server)
    U_PrefSet("profileId", id)
    U_PrefSet("profileName", name)
    U_PrefSet("storageMode", "network")
end sub

sub P_UseLocal()
    U_PrefSet("storageMode", "local")
end sub

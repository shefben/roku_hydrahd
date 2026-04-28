' Watchlist.brs - Persistent resume positions and watched state.
'
' Records per-movie and per-episode playback progress in a dedicated registry
' section so the user can pick up where they left off. Each entry stores the
' last position (in seconds), total duration, a "done" flag (set when the user
' finished within ~5% of the end), and a timestamp.
'
' Keys:
'   m:<itemKey>                - movie progress
'   e:<itemKey>:<season>:<ep>  - episode progress
'   s:<itemKey>                - "last episode watched" pointer for a series
'
' itemKey is whatever stable identifier we have for the title - the hydrahd
' href is preferred since it's available at every step (listing -> details ->
' player); imdb is used as a fallback.

function W_Section() as Object
    return CreateObject("roRegistrySection", "HydraHD_Progress")
end function

function W_ItemKey(imdb as String, href as String) as String
    if href <> invalid and href <> "" then return href
    if imdb <> invalid and imdb <> "" then return imdb
    return ""
end function

function W_AsInt(v as Dynamic) as Integer
    if v = invalid then return 0
    t = Type(v)
    if t = "Integer" or t = "roInt" or t = "roInteger" then return v
    if t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" then return Int(v)
    if t = "String" or t = "roString" then return v.ToInt()
    if t = "LongInteger" or t = "roLongInteger" then return v
    return 0
end function

function W_AsBool(v as Dynamic) as Boolean
    if v = invalid then return false
    t = Type(v)
    if t = "Boolean" or t = "roBoolean" then return v
    if t = "String" or t = "roString" then return LCase(v) = "true"
    return false
end function

function W_Read(key as String) as Object
    if key = "" then return invalid
    reg = W_Section()
    if not reg.Exists(key) then return invalid
    raw = reg.Read(key)
    if raw = invalid or raw = "" then return invalid
    parsed = ParseJson(raw)
    if parsed = invalid then return invalid
    return parsed
end function

sub W_Write(key as String, data as Object)
    if key = "" then return
    reg = W_Section()
    reg.Write(key, FormatJson(data))
    reg.Flush()
end sub

' Position is "essentially finished" when within 90 seconds of the end OR
' past 95% of total runtime - whichever the stream lets us detect first.
function W_IsFinished(posSec as Integer, dur as Integer) as Boolean
    if dur <= 0 then return false
    if posSec >= dur - 90 then return true
    if posSec >= Int(dur * 0.95) then return true
    return false
end function

' Below this many seconds it isn't worth offering a resume - just restart.
function W_MinResumeSeconds() as Integer
    return 30
end function

' --- Movies ----------------------------------------------------------------

function W_GetMovieProgress(imdb as String, href as String) as Object
    return W_Read("m:" + W_ItemKey(imdb, href))
end function

sub W_SaveMovieProgress(imdb as String, href as String, posSec as Integer, dur as Integer)
    k = W_ItemKey(imdb, href)
    if k = "" then return
    if posSec < 0 then posSec = 0
    W_Write("m:" + k, {
        pos:  posSec
        dur:  dur
        done: W_IsFinished(posSec, dur)
        ts:   CreateObject("roDateTime").AsSeconds()
    })
end sub

' --- Episodes / series -----------------------------------------------------

function W_GetEpisodeProgress(imdb as String, href as String, season as Integer, episode as Integer) as Object
    return W_Read("e:" + W_ItemKey(imdb, href) + ":" + season.ToStr() + ":" + episode.ToStr())
end function

sub W_SaveEpisodeProgress(imdb as String, href as String, season as Integer, episode as Integer, posSec as Integer, dur as Integer, slug as String, name as String)
    k = W_ItemKey(imdb, href)
    if k = "" then return
    if posSec < 0 then posSec = 0
    done = W_IsFinished(posSec, dur)
    ts = CreateObject("roDateTime").AsSeconds()
    W_Write("e:" + k + ":" + season.ToStr() + ":" + episode.ToStr(), {
        pos:  posSec
        dur:  dur
        done: done
        ts:   ts
    })
    W_Write("s:" + k, {
        season:  season
        episode: episode
        slug:    slug
        name:    name
        pos:     posSec
        dur:     dur
        done:    done
        ts:      ts
    })
end sub

function W_GetSeriesProgress(imdb as String, href as String) as Object
    return W_Read("s:" + W_ItemKey(imdb, href))
end function

' Returns the second to start playback at, or 0 if the user finished it / never
' got past the credit-skip window / never watched it.
function W_ResumePosition(entry as Object) as Integer
    if entry = invalid then return 0
    if W_AsBool(entry.done) then return 0
    posSec = W_AsInt(entry.pos)
    if posSec < W_MinResumeSeconds() then return 0
    return posSec
end function

' Pretty-print "12m 34s" / "1h 02m" for status labels.
function W_FormatTime(seconds as Integer) as String
    if seconds <= 0 then return "0s"
    h = Int(seconds / 3600)
    m = Int((seconds Mod 3600) / 60)
    s = seconds Mod 60
    if h > 0 then
        ms = m.ToStr()
        if m < 10 then ms = "0" + ms
        return h.ToStr() + "h " + ms + "m"
    end if
    if m > 0 then return m.ToStr() + "m " + s.ToStr() + "s"
    return s.ToStr() + "s"
end function

' --- Title context (for Continue Watching tiles) ---------------------
'
' Each playback heartbeat also stores a small dict of human-display info
' (title / poster / kind / ids) under c:<itemKey> so screens like the
' Continue Watching row can render a tile without re-fetching details.

sub W_RememberContext(itemKey as String, ctx as Object)
    if itemKey = "" or ctx = invalid then return
    existing = W_Read("c:" + itemKey)
    out = {}
    if existing <> invalid then
        for each k in existing
            out[k] = existing[k]
        end for
    end if
    for each k in ctx
        v = ctx[k]
        if v <> invalid and v <> "" then out[k] = v
    end for
    out.ts = CreateObject("roDateTime").AsSeconds()
    W_Write("c:" + itemKey, out)
end sub

function W_GetContext(itemKey as String) as Object
    if itemKey = "" then return invalid
    return W_Read("c:" + itemKey)
end function

' --- Listing helpers -------------------------------------------------

' Enumerate all in-progress titles (movies + TV series), newest first.
' Limit caps the result so a long-running channel doesn't blow up the
' Continue Watching row. Each entry is:
'   { itemKey, kind, title, poster, href, imdb, tmdb, pos, dur, pct, ts,
'     season, episode, slug, name }   (last four only set for TV)
function W_ListInProgress(limit as Integer) as Object
    out = []
    reg = W_Section()
    keys = reg.GetKeyList()
    if keys = invalid then return out
    seen = {}
    for each key in keys
        kind = ""
        itemKey = ""
        if Left(key, 2) = "m:" then
            kind = "movie"
            itemKey = Mid(key, 3)
        else if Left(key, 2) = "s:" then
            kind = "tv"
            itemKey = Mid(key, 3)
        end if
        if kind <> "" and not seen.DoesExist(itemKey) then
            seen[itemKey] = true
            entry = W_Read(key)
            if entry <> invalid and not W_AsBool(entry.done) then
                posSec = W_AsInt(entry.pos)
                dur = W_AsInt(entry.dur)
                if posSec >= W_MinResumeSeconds() then
                    ctx = W_GetContext(itemKey)
                    if ctx <> invalid then
                        item = {
                            itemKey: itemKey
                            kind:    kind
                            title:   ""
                            poster:  ""
                            href:    ""
                            imdb:    ""
                            tmdb:    ""
                            pos:     posSec
                            dur:     dur
                            pct:     W_PercentOf(posSec, dur)
                            ts:      W_AsInt(entry.ts)
                        }
                        if ctx.title  <> invalid then item.title  = ctx.title
                        if ctx.poster <> invalid then item.poster = ctx.poster
                        if ctx.href   <> invalid then item.href   = ctx.href
                        if ctx.imdb   <> invalid then item.imdb   = ctx.imdb
                        if ctx.tmdb   <> invalid then item.tmdb   = ctx.tmdb
                        if kind = "tv" then
                            item.season  = W_AsInt(entry.season)
                            item.episode = W_AsInt(entry.episode)
                            if entry.slug <> invalid then item.slug = entry.slug else item.slug = ""
                            if entry.name <> invalid then item.name = entry.name else item.name = ""
                        end if
                        out.Push(item)
                    end if
                end if
            end if
        end if
    end for
    ' Sort newest first.
    if out.Count() > 1 then
        for i = 0 to out.Count() - 2
            for j = 0 to out.Count() - 2 - i
                if out[j].ts < out[j + 1].ts then
                    tmp = out[j]
                    out[j] = out[j + 1]
                    out[j + 1] = tmp
                end if
            end for
        end for
    end if
    if limit > 0 and out.Count() > limit then
        trimmed = []
        for i = 0 to limit - 1
            trimmed.Push(out[i])
        end for
        return trimmed
    end if
    return out
end function

function W_PercentOf(posSec as Integer, dur as Integer) as Integer
    if dur <= 0 then return 0
    pct = Int((posSec * 100) / dur)
    if pct < 0 then pct = 0
    if pct > 100 then pct = 100
    return pct
end function

' Quick lookup for poster overlays. For movies pass season=0 episode=0.
' For TV listings (where we only know the show, not which episode the
' user is on), pass 0/0 too - we'll fall back to the series' last-watched
' episode pointer.
function W_GetProgressPct(imdb as String, href as String, season as Integer, episode as Integer) as Integer
    k = W_ItemKey(imdb, href)
    if k = "" then return 0
    if season > 0 and episode > 0 then
        e = W_Read("e:" + k + ":" + season.ToStr() + ":" + episode.ToStr())
        if e = invalid or W_AsBool(e.done) then return 0
        return W_PercentOf(W_AsInt(e.pos), W_AsInt(e.dur))
    end if
    ' Try movie first.
    m = W_Read("m:" + k)
    if m <> invalid and not W_AsBool(m.done) then
        return W_PercentOf(W_AsInt(m.pos), W_AsInt(m.dur))
    end if
    ' Fall back to current series episode pointer.
    s = W_Read("s:" + k)
    if s <> invalid and not W_AsBool(s.done) then
        return W_PercentOf(W_AsInt(s.pos), W_AsInt(s.dur))
    end if
    return 0
end function

' --- Favorites / "My List" ------------------------------------------

function W_FavSection() as Object
    return CreateObject("roRegistrySection", "HydraHD_Favorites")
end function

function W_IsFavorite(imdb as String, href as String) as Boolean
    k = W_ItemKey(imdb, href)
    if k = "" then return false
    return W_FavSection().Exists(k)
end function

sub W_AddFavorite(ctx as Object)
    if ctx = invalid then return
    imdb = ""
    href = ""
    if ctx.imdb <> invalid then imdb = ctx.imdb
    if ctx.href <> invalid then href = ctx.href
    k = W_ItemKey(imdb, href)
    if k = "" then return
    payload = {
        title:  ""
        poster: ""
        href:   href
        imdb:   imdb
        tmdb:   ""
        kind:   ""
        ts:     CreateObject("roDateTime").AsSeconds()
    }
    if ctx.title  <> invalid then payload.title  = ctx.title
    if ctx.poster <> invalid then payload.poster = ctx.poster
    if ctx.tmdb   <> invalid then payload.tmdb   = ctx.tmdb
    if ctx.kind   <> invalid then payload.kind   = ctx.kind
    reg = W_FavSection()
    reg.Write(k, FormatJson(payload))
    reg.Flush()
end sub

sub W_RemoveFavorite(imdb as String, href as String)
    k = W_ItemKey(imdb, href)
    if k = "" then return
    reg = W_FavSection()
    if reg.Exists(k) then
        reg.Delete(k)
        reg.Flush()
    end if
end sub

function W_ListFavorites() as Object
    out = []
    reg = W_FavSection()
    keys = reg.GetKeyList()
    if keys = invalid then return out
    for each k in keys
        raw = reg.Read(k)
        if raw <> invalid and raw <> "" then
            obj = ParseJson(raw)
            if obj <> invalid then
                if obj.itemKey = invalid then obj.itemKey = k
                out.Push(obj)
            end if
        end if
    end for
    ' Newest favorited first.
    if out.Count() > 1 then
        for i = 0 to out.Count() - 2
            for j = 0 to out.Count() - 2 - i
                a = W_AsInt(out[j].ts)
                b = W_AsInt(out[j + 1].ts)
                if a < b then
                    tmp = out[j]
                    out[j] = out[j + 1]
                    out[j + 1] = tmp
                end if
            end for
        end for
    end if
    return out
end function

' --- Search history --------------------------------------------------
'
' Stored as one JSON array under HydraHD/searchHistory. We cap the
' length so the registry value stays well under any per-key limits.

function W_SearchHistoryMax() as Integer
    return 12
end function

function W_GetSearchHistory() as Object
    reg = CreateObject("roRegistrySection", "HydraHD")
    if not reg.Exists("searchHistory") then return []
    raw = reg.Read("searchHistory")
    if raw = invalid or raw = "" then return []
    parsed = ParseJson(raw)
    if parsed = invalid then return []
    return parsed
end function

sub W_PushSearchQuery(q as String)
    if q = invalid then return
    qs = q
    if Type(qs) = "String" or Type(qs) = "roString" then
        qs = qs.Trim()
    end if
    if qs = "" then return
    list = W_GetSearchHistory()
    out = [qs]
    lc = LCase(qs)
    for each prev in list
        if Type(prev) = "String" or Type(prev) = "roString" then
            if LCase(prev) <> lc and out.Count() < W_SearchHistoryMax() then
                out.Push(prev)
            end if
        end if
    end for
    reg = CreateObject("roRegistrySection", "HydraHD")
    reg.Write("searchHistory", FormatJson(out))
    reg.Flush()
end sub

sub W_ClearSearchHistory()
    reg = CreateObject("roRegistrySection", "HydraHD")
    if reg.Exists("searchHistory") then
        reg.Delete("searchHistory")
        reg.Flush()
    end if
end sub

' --- Mirror reliability ---------------------------------------------
'
' One key per upstream host: "<successes>:<failures>". We use this to
' rank the mirror grid so well-known-good hosts float to the top.

function W_MirrorSection() as Object
    return CreateObject("roRegistrySection", "HydraHD_MirrorStats")
end function

function W_MirrorRecord(host as String) as Object
    if host = "" then return { ok: 0, fail: 0 }
    reg = W_MirrorSection()
    if not reg.Exists(host) then return { ok: 0, fail: 0 }
    raw = reg.Read(host)
    parts = raw.Tokenize(":")
    ok = 0
    fail = 0
    if parts.Count() >= 1 then ok = parts[0].ToInt()
    if parts.Count() >= 2 then fail = parts[1].ToInt()
    return { ok: ok, fail: fail }
end function

sub W_RecordMirrorOutcome(host as String, success as Boolean)
    if host = "" then return
    rec = W_MirrorRecord(host)
    if success then
        rec.ok = rec.ok + 1
    else
        rec.fail = rec.fail + 1
    end if
    reg = W_MirrorSection()
    reg.Write(host, rec.ok.ToStr() + ":" + rec.fail.ToStr())
    reg.Flush()
end sub

' Ratio in 0..1, or -1 if we have no data on this host yet. The bonus
' for total tries (rec.ok + rec.fail) is so a 1/1 mirror doesn't beat
' a 47/3 mirror just by being lucky once.
function W_MirrorScore(host as String) as Float
    if host = "" then return -1.0
    rec = W_MirrorRecord(host)
    total = rec.ok + rec.fail
    if total = 0 then return -1.0
    return rec.ok / total!
end function

function W_MirrorTotal(host as String) as Integer
    rec = W_MirrorRecord(host)
    return rec.ok + rec.fail
end function

' DetailsView.brs - Movie / TV details, season switcher, episode grid.

sub init()
    ' State first.
    m.activeSeason = 0
    m.detail = invalid
    m.kind = ""
    m.id = ""
    m.href = ""
    m.movieProgress = invalid
    m.seriesResume = invalid

    m.poster = m.top.findNode("poster")
    m.backdrop = m.top.findNode("backdrop")
    m.titleNode = m.top.findNode("title")
    m.metaNode = m.top.findNode("meta")
    m.genresNode = m.top.findNode("genres")
    m.overviewNode = m.top.findNode("overview")
    m.castNode = m.top.findNode("cast")
    ' status2 lives inside the top LayoutGroup so it is always on screen.
    m.statusNode = m.top.findNode("status2")

    m.actions = m.top.findNode("actions")
    m.actions.buttons = ["Play", "Choose Mirror"]
    m.actions.observeField("buttonSelected", "onActionSelected")

    m.seasonGroup = m.top.findNode("seasonGroup")
    m.seasonRow = m.top.findNode("seasonRow")
    m.epGrid = m.top.findNode("episodeGrid")
    m.epGrid.itemComponentName = "EpisodeItem"
    m.epGrid.observeField("itemSelected", "onEpisodeSelected")
    ' itemFocused fires every time the highlighted season changes (left/right
    ' on the remote). itemSelected only fires on OK. Observing both lets the
    ' episode list refresh as the user scrolls and also drops focus into the
    ' grid when they actually pick a season. The MarkupGrid auto-scrolls
    ' horizontally when there are more seasons than fit on screen.
    m.seasonRow.observeField("itemFocused", "onSeasonFocused")
    m.seasonRow.observeField("itemSelected", "onSeasonSelected")

    m.actions.setFocus(true)
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return
    ' Pull values defensively. ContentNode.contentType is a fixed enum that
    ' silently drops non-standard values like "tv" / "movie", so a.kind may
    ' arrive as invalid or an unexpected type. Comparing invalid to a String
    ' with `=` raises a Type Mismatch on Roku and halts the handler, which
    ' was making the screen freeze the instant a poster was clicked.
    m.kind = pickString(a, "kind")
    m.id = pickString(a, "id")
    m.href = pickString(a, "href")
    if m.kind <> "tv" and m.kind <> "movie" then
        if m.href <> "" and Instr(1, m.href, "/watchseries/") > 0 then
            m.kind = "tv"
        else
            m.kind = "movie"
        end if
    end if
    titleStr = pickString(a, "title")
    if titleStr <> "" then m.titleNode.text = titleStr
    posterStr = pickString(a, "poster")
    if posterStr <> "" then
        m.poster.uri = posterStr
        m.backdrop.uri = posterStr
    end if
    ' Set initial buttons based on detected kind so we don't briefly
    ' show "Play / Choose Mirror" before the details fetch finishes.
    if m.kind = "tv" then
        m.actions.buttons = ["Seasons"]
    else
        m.actions.buttons = ["Play", "Choose Mirror"]
    end if
    m.actions.setFocus(true)
    fetchDetails()
end sub

function pickString(aa as Object, key as String) as String
    if aa = invalid then return ""
    v = aa[key]
    if v = invalid then return ""
    if Type(v) = "String" or Type(v) = "roString" then return v
    return ""
end function

sub fetchDetails()
    m.top.loading = true
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "DetailsTask")
    m.task.observeField("result", "onDetailResult")
    m.task.kind = m.kind
    m.task.id = m.id
    m.task.href = m.href
    m.task.control = "RUN"
end sub

sub onDetailResult()
    res = m.task.result
    m.top.loading = false
    if res = invalid or res.detail = invalid then
        m.statusNode.text = "Failed to load details."
        return
    end if
    m.detail = res.detail
    paintDetail()
    ' Continue Watching tiles set autoResume=true so the user goes
    ' straight into playback. We hand off via onPlay() once paintDetail
    ' has filled in seriesResume / movieProgress.
    a = m.top.args
    if a <> invalid and a.autoResume = true then
        a.autoResume = false
        onPlay()
    end if
end sub

sub paintDetail()
    d = m.detail
    if d.title <> "" then m.titleNode.text = d.title
    metaParts = []
    if d.year <> "" then metaParts.Push(d.year)
    if d.runtime <> "" then metaParts.Push(d.runtime)
    if d.rating <> "" then metaParts.Push("* " + d.rating)
    if d.imdb <> "" then metaParts.Push(d.imdb)
    sep = "  -  "
    metaText = ""
    for i = 0 to metaParts.Count() - 1
        if i > 0 then metaText = metaText + sep
        metaText = metaText + metaParts[i]
    end for
    m.metaNode.text = metaText

    if d.genres.Count() > 0 then
        out = ""
        for i = 0 to d.genres.Count() - 1
            if i > 0 then out = out + " - "
            out = out + d.genres[i]
        end for
        m.genresNode.text = out
    end if

    m.overviewNode.text = d.description

    if d.cast.Count() > 0 then
        names = []
        for i = 0 to d.cast.Count() - 1
            names.Push(d.cast[i].name)
            if i >= 7 then exit for
        end for
        m.castNode.text = "Starring: " + joinWithComma(names)
    end if

    if d.poster <> "" then
        m.poster.uri = d.poster
        m.backdrop.uri = d.backdrop
    end if

    ' Trust the kind we already detected in onArgs - the parsed `d.kind`
    ' just echoes whichever fetcher was called.
    if m.kind = "tv" then
        m.seriesResume = computeSeriesResume()
        if m.seriesResume <> invalid then
            label = "Resume S" + m.seriesResume.ep.season.ToStr() + "E" + m.seriesResume.ep.episode.ToStr()
            m.actions.buttons = [label, "Seasons", favButtonLabel()]
        else
            m.actions.buttons = ["Seasons", favButtonLabel()]
        end if
        if d.seasons <> invalid and d.seasons.Count() > 0 then
            renderSeasons()
            m.seasonGroup.visible = true
        end if
    else
        m.movieProgress = W_GetMovieProgress(d.imdb, d.href)
        rp = W_ResumePosition(m.movieProgress)
        if rp > 0 then
            m.actions.buttons = ["Resume " + W_FormatTime(rp), "Restart", "Choose Mirror", favButtonLabel()]
        else
            m.actions.buttons = ["Play", "Choose Mirror", favButtonLabel()]
        end if
    end if
    m.actions.setFocus(true)
end sub

' Star icon (filled or outlined) reflecting the current saved state.
function favButtonLabel() as String
    if m.detail = invalid then return "Save to List"
    if W_IsFavorite(m.detail.imdb, m.detail.href) then
        return "* Saved"
    end if
    return "+ Save to List"
end function

' Toggles favorite state and re-paints the button label without
' rebuilding the whole action bar.
sub toggleFavorite()
    if m.detail = invalid then return
    if W_IsFavorite(m.detail.imdb, m.detail.href) then
        W_RemoveFavorite(m.detail.imdb, m.detail.href)
        m.statusNode.text = "Removed from My List."
    else
        W_AddFavorite({
            title:  m.detail.title
            poster: m.detail.poster
            href:   m.detail.href
            imdb:   m.detail.imdb
            tmdb:   m.detail.tmdb
            kind:   m.kind
        })
        m.statusNode.text = "Added to My List."
    end if
    btns = m.actions.buttons
    if btns <> invalid and btns.Count() > 0 then
        btns[btns.Count() - 1] = favButtonLabel()
        m.actions.buttons = btns
    end if
end sub

' Find an episode (and its season index) by season/episode number.
function findEpisodeByNum(season as Integer, episode as Integer) as Object
    if m.detail = invalid or m.detail.seasons = invalid then return invalid
    for si = 0 to m.detail.seasons.Count() - 1
        s = m.detail.seasons[si]
        for ei = 0 to s.episodes.Count() - 1
            e = s.episodes[ei]
            if e.season = season and e.episode = episode then
                return { seasonIdx: si, episodeIdx: ei, ep: e }
            end if
        end for
    end for
    return invalid
end function

' Episode that follows (season, episode) in show order, or invalid if the
' user already finished the very last one.
function findNextEpisode(season as Integer, episode as Integer) as Object
    cur = findEpisodeByNum(season, episode)
    if cur = invalid then return invalid
    si = cur.seasonIdx
    ei = cur.episodeIdx + 1
    s = m.detail.seasons[si]
    if ei < s.episodes.Count() then
        return { seasonIdx: si, episodeIdx: ei, ep: s.episodes[ei] }
    end if
    if si + 1 < m.detail.seasons.Count() then
        ns = m.detail.seasons[si + 1]
        if ns.episodes.Count() > 0 then
            return { seasonIdx: si + 1, episodeIdx: 0, ep: ns.episodes[0] }
        end if
    end if
    return invalid
end function

' For a TV series, decide which episode to highlight / resume:
'   - If the last-watched episode wasn't finished -> resume that one.
'   - If it was finished -> point at the next episode (with no resume offset).
'   - If there's no history -> invalid.
function computeSeriesResume() as Object
    if m.detail = invalid then return invalid
    if m.detail.seasons = invalid or m.detail.seasons.Count() = 0 then return invalid
    sp = W_GetSeriesProgress(m.detail.imdb, m.detail.href)
    if sp = invalid then return invalid
    season = W_AsInt(sp.season)
    episode = W_AsInt(sp.episode)
    target = findEpisodeByNum(season, episode)
    if target = invalid then return invalid
    if W_AsBool(sp.done) then
        nextT = findNextEpisode(season, episode)
        if nextT <> invalid then
            nextT.resumePos = 0
            return nextT
        end if
        ' Series fully watched - leave the highlight on the finale.
        target.resumePos = 0
        return target
    end if
    epEntry = W_GetEpisodeProgress(m.detail.imdb, m.detail.href, season, episode)
    target.resumePos = W_ResumePosition(epEntry)
    return target
end function

function joinWithComma(arr as Object) as String
    out = ""
    for i = 0 to arr.Count() - 1
        if i > 0 then out = out + ", "
        out = out + arr[i]
    end for
    return out
end function

sub renderSeasons()
    initial = 0
    if m.seriesResume <> invalid then initial = m.seriesResume.seasonIdx
    root = createObject("roSGNode", "ContentNode")
    for i = 0 to m.detail.seasons.Count() - 1
        ch = root.createChild("ContentNode")
        ch.title = m.detail.seasons[i].label
    end for
    m.seasonRow.content = root
    if root.getChildCount() > 0 then
        if initial < 0 or initial >= root.getChildCount() then initial = 0
        m.seasonRow.jumpToItem = initial
        selectSeason(initial)
    end if
end sub

function seasonCount() as Integer
    if m.seasonRow.content = invalid then return 0
    return m.seasonRow.content.getChildCount()
end function

sub onActionSelected()
    if m.actions.buttonSelected = invalid then return
    idx = m.actions.buttonSelected
    btns = m.actions.buttons
    ' The Save-to-List / Saved button is always last in the row, so the
    ' fav handler short-circuits any kind-specific dispatch below.
    if btns <> invalid and idx = btns.Count() - 1 then
        toggleFavorite()
        return
    end if
    if m.kind = "tv" then
        if m.seriesResume <> invalid then
            ' Buttons: [Resume S?E?, Seasons, Save]
            if idx = 0 then
                openMirrorPicker(m.seriesResume.ep, m.seriesResume.resumePos)
            else if idx = 1 then
                onShowSeasons()
            end if
        else
            ' Buttons: [Seasons, Save]
            if idx = 0 then onShowSeasons()
        end if
        return
    end if
    rp = 0
    if m.movieProgress <> invalid then rp = W_ResumePosition(m.movieProgress)
    if rp > 0 then
        ' Buttons: [Resume HH:MM, Restart, Choose Mirror, Save]
        if idx = 0 then
            openMirrorPicker(invalid, rp)
        else if idx = 1 then
            openMirrorPicker(invalid, 0)
        else if idx = 2 then
            openMirrorPicker(invalid, rp)
        end if
    else
        ' Buttons: [Play, Choose Mirror, Save]
        if idx = 0 then
            openMirrorPicker(invalid, 0)
        else if idx = 1 then
            openMirrorPicker(invalid, 0)
        end if
    end if
end sub

sub onShowSeasons()
    m.seasonGroup.visible = true
    if seasonCount() > 1 then
        m.seasonRow.setFocus(true)
    else if m.epGrid.content <> invalid then
        m.epGrid.setFocus(true)
    end if
end sub

sub onSeasonFocused()
    idx = m.seasonRow.itemFocused
    if idx = invalid or idx < 0 then return
    selectSeason(idx)
end sub

sub onSeasonSelected()
    idx = m.seasonRow.itemSelected
    if idx = invalid or idx < 0 then return
    selectSeason(idx)
    ' OK on a season jumps focus into the episode list so the user doesn't
    ' have to fish for the down arrow afterwards.
    if m.epGrid.content <> invalid and m.epGrid.content.getChildCount() > 0 then
        m.epGrid.setFocus(true)
    end if
end sub

sub selectSeason(idx as Integer)
    if m.detail = invalid or m.detail.seasons = invalid then return
    if idx < 0 or idx >= m.detail.seasons.Count() then return
    m.activeSeason = idx
    s = m.detail.seasons[idx]
    poster = ""
    if m.detail.poster <> invalid then poster = m.detail.poster
    desc = ""
    if m.detail.description <> invalid then desc = m.detail.description

    targetEpIdx = -1
    if m.seriesResume <> invalid and m.seriesResume.seasonIdx = idx then
        targetEpIdx = m.seriesResume.episodeIdx
    end if

    root = createObject("roSGNode", "ContentNode")
    for ei = 0 to s.episodes.Count() - 1
        ep = s.episodes[ei]
        cell = root.createChild("ContentNode")
        cell.title = ep.name
        cell.shortDescriptionLine2 = "S" + ep.season.ToStr() + " - E" + ep.episode.ToStr()
        airDate = ""
        if ep.airDate <> invalid then airDate = ep.airDate
        cell.shortDescriptionLine1 = airDate
        cell.description = desc
        cell.HDPosterUrl = poster
        cell.SDPosterUrl = poster
        cell.id = ep.slug + "|" + ep.season.ToStr() + "|" + ep.episode.ToStr()
        ' EpisodeItem reads `releaseDate` as a watched-state badge:
        '   "current:<label>" - up-next or resume target
        '   "watched"         - finished
        '   "partial:<time>"  - started but not finished
        marker = ""
        epEntry = W_GetEpisodeProgress(m.detail.imdb, m.detail.href, ep.season, ep.episode)
        if ei = targetEpIdx then
            rp = 0
            if m.seriesResume <> invalid and m.seriesResume.resumePos <> invalid then
                rp = m.seriesResume.resumePos
            end if
            if rp > 0 then
                marker = "current:Resume " + W_FormatTime(rp)
            else
                marker = "current:Up next"
            end if
        else if epEntry <> invalid and W_AsBool(epEntry.done) then
            marker = "watched"
        else if epEntry <> invalid then
            rp2 = W_ResumePosition(epEntry)
            if rp2 > 0 then marker = "partial:" + W_FormatTime(rp2)
        end if
        cell.releaseDate = marker
    end for
    m.epGrid.content = root
    if targetEpIdx >= 0 then m.epGrid.jumpToItem = targetEpIdx
    m.seasonGroup.visible = true
end sub

sub onEpisodeSelected()
    idx = m.epGrid.itemSelected
    if idx = invalid then return
    if m.detail = invalid then return
    s = m.detail.seasons[m.activeSeason]
    if idx < 0 or idx >= s.episodes.Count() then return
    ep = s.episodes[idx]
    openMirrorPicker(ep, 0)
end sub

sub onPlay()
    if m.detail = invalid then return
    if m.kind = "movie" then
        rp = 0
        if m.movieProgress <> invalid then rp = W_ResumePosition(m.movieProgress)
        openMirrorPicker(invalid, rp)
        return
    end if
    if m.detail.seasons.Count() = 0 then
        m.statusNode.text = "No episodes available."
        return
    end if
    if m.seriesResume <> invalid then
        openMirrorPicker(m.seriesResume.ep, m.seriesResume.resumePos)
        return
    end if
    s = m.detail.seasons[m.detail.seasons.Count() - 1]
    ep = s.episodes[s.episodes.Count() - 1]
    openMirrorPicker(ep, 0)
end sub

sub onMirrors()
    onPlay()
end sub

sub openMirrorPicker(ep as Object, startPos as Integer)
    if m.detail = invalid then return
    ' If no explicit resume position was passed (e.g. user picked an episode
    ' from the grid), still honor any progress we have for that episode.
    if startPos = 0 and ep <> invalid then
        epEntry = W_GetEpisodeProgress(m.detail.imdb, m.detail.href, ep.season, ep.episode)
        startPos = W_ResumePosition(epEntry)
    else if startPos = 0 and ep = invalid and m.kind = "movie" then
        if m.movieProgress = invalid then
            m.movieProgress = W_GetMovieProgress(m.detail.imdb, m.detail.href)
        end if
        startPos = W_ResumePosition(m.movieProgress)
    end if
    args = {
        kind: m.detail.kind
        title: m.detail.title
        poster: m.detail.poster
        imdb: m.detail.imdb
        tmdb: m.detail.tmdb
        href: m.detail.href
    }
    if ep <> invalid then
        args.episode = {
            slug: ep.slug
            season: ep.season
            episode: ep.episode
            name: ep.name
        }
        ' Pass the flat queue of every remaining episode in show order so
        ' PlayerView can auto-advance to the next one when the current
        ' stream ends.
        queue = []
        startIdx = -1
        for si = 0 to m.detail.seasons.Count() - 1
            s = m.detail.seasons[si]
            for ei = 0 to s.episodes.Count() - 1
                e = s.episodes[ei]
                queue.Push({ slug: e.slug, season: e.season, episode: e.episode, name: e.name })
                if startIdx = -1 and e.season = ep.season and e.episode = ep.episode then
                    startIdx = queue.Count() - 1
                end if
            end for
        end for
        if startIdx >= 0 then
            args.episodeQueue = queue
            args.episodeQueueIndex = startIdx
        end if
    end if
    if startPos > 0 then args.startPosition = startPos
    m.top.requestNav = {
        action: "open"
        view: "MirrorPicker"
        args: args
    }
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "down" and m.actions.hasFocus() then
        if m.kind = "tv" then
            m.seasonGroup.visible = true
            if seasonCount() > 1 then
                m.seasonRow.setFocus(true)
            else if m.epGrid.content <> invalid then
                m.epGrid.setFocus(true)
            end if
            return true
        end if
    end if
    if key = "down" and m.seasonRow.hasFocus() then
        if m.epGrid.content <> invalid then
            m.epGrid.setFocus(true)
            return true
        end if
    end if
    if key = "up" and m.epGrid.hasFocus() then
        if seasonCount() > 1 then
            m.seasonRow.setFocus(true)
        else
            m.actions.setFocus(true)
        end if
        return true
    end if
    if key = "up" and m.seasonRow.hasFocus() then
        m.actions.setFocus(true)
        return true
    end if
    return false
end function

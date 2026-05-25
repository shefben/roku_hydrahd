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
    m.seasonResumeBtn = m.top.findNode("seasonResumeBtn")
    m.seasonResumeBtn.observeField("buttonSelected", "onSeasonResumeSelected")
    m.epGrid.itemComponentName = "EpisodeItem"
    m.epGrid.observeField("itemSelected", "onEpisodeSelected")
    m.epGrid.observeField("itemFocused", "onEpisodeFocused")
    ' itemFocused fires every time the highlighted season changes (left/right
    ' on the remote). itemSelected only fires on OK. Observing both lets the
    ' episode list refresh as the user scrolls and also drops focus into the
    ' grid when they actually pick a season. The MarkupGrid auto-scrolls
    ' horizontally when there are more seasons than fit on screen.
    m.seasonRow.observeField("itemFocused", "onSeasonFocused")
    m.seasonRow.observeField("itemSelected", "onSeasonSelected")

    ' Per-episode description lazy loader. Fetches the episode page in the
    ' background when the user focuses an episode cell and caches the result
    ' so each episode shows its own description instead of the series blurb.
    m.epDescTask = invalid
    m.epDescSeason = -1
    m.epDescEpisode = -1
    m.seriesDesc = ""

    m.actions.setFocus(true)

    ' MainScene's pushView+focusActiveChild lands focus on this Group's
    ' root, which leaves arrow keys dead. Bounce down to the actions
    ' bar (or, if the user was browsing the season grid before going
    ' UP to nav, back to whichever grid is visible).
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.epGrid <> invalid and m.epGrid.content <> invalid and m.seasonGroup <> invalid and m.seasonGroup.visible then
        m.epGrid.setFocus(true)
        return
    end if
    if m.actions <> invalid then m.actions.setFocus(true)
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
    ' Callers can opt into a straight-to-playback fast path by passing
    ' autoResume=true in args. The Continue Watching tile flow used to
    ' rely on this; it now routes through ResumePicker so the user can
    ' pick mirror/episode first. Kept here for any future deep-link
    ' or auto-launch hook that wants the original behavior.
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
    m.seriesDesc = d.description

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
            label = buildResumeLabel(m.seriesResume)
            m.actions.buttons = [label, "Seasons", favButtonLabel()]
            m.seasonResumeBtn.text = label
            m.seasonResumeBtn.visible = true
        else
            m.actions.buttons = ["Seasons", favButtonLabel()]
            m.seasonResumeBtn.visible = false
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

' Resume button label - "Resume S?E? at HH:MM" when picking up
' mid-episode, "Play S?E?" when the most-recent episode was finished
' and we're queueing up the next one.
function buildResumeLabel(sr as Object) as String
    if sr = invalid or sr.ep = invalid then return "Resume"
    epTag = "S" + sr.ep.season.ToStr() + "E" + sr.ep.episode.ToStr()
    rp = 0
    if sr.resumePos <> invalid then rp = W_AsInt(sr.resumePos)
    if rp >= W_MinResumeSeconds() then
        return "Resume " + epTag + " - " + W_FormatTime(rp)
    end if
    return "Play " + epTag
end function

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
        lastIdx = btns.Count() - 1
        btns[lastIdx] = favButtonLabel()
        m.actions.buttons = btns
        ' Reassigning `buttons` tears down the existing Button child
        ' nodes and rebuilds them, so focus on the old Save Button is
        ' lost - the action bar then eats every remote press because
        ' ButtonGroup is in the focus chain with no focused Button.
        ' setFocus + focusButton re-anchors focus on the newly built
        ' Save / Saved button so the user can keep navigating.
        m.actions.setFocus(true)
        m.actions.focusButton = lastIdx
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

    ' Watchlist now sets sp.done only when the user has actually
    ' finished the show (last episode of last season). For the more
    ' common case where they just finished one episode, sp.done stays
    ' false but the per-episode record's `done` is true - we still
    ' want to advance the resume target to the next episode in that
    ' case so the "Continue Watching" tile points at S1E6 after they
    ' finished S1E5, instead of re-offering the just-finished episode.
    epEntry = W_GetEpisodeProgress(m.detail.imdb, m.detail.href, season, episode)
    epDone = false
    if epEntry <> invalid then epDone = W_AsBool(epEntry.done)

    if W_AsBool(sp.done) or epDone then
        ' Walk forward through episodes, skipping ones the user has
        ' already finished, until we hit one that's still unwatched.
        ' This handles the case where the most-recent progress entry
        ' is in a season the user has since completed entirely (e.g.
        ' last-watched=S1E5 but they've also already finished S1E6-10):
        ' the season picker should land on S2 instead of S1, and the
        ' episode highlight should land on the first genuinely
        ' unwatched episode rather than the just-finished one.
        cur = target
        while true
            nextT = findNextEpisode(cur.ep.season, cur.ep.episode)
            if nextT = invalid then exit while
            ne = W_GetEpisodeProgress(m.detail.imdb, m.detail.href, nextT.ep.season, nextT.ep.episode)
            if ne = invalid or not W_AsBool(ne.done) then
                nextT.resumePos = 0
                return nextT
            end if
            cur = nextT
        end while
        ' Series fully watched - leave the highlight on the finale.
        target.resumePos = 0
        return target
    end if
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
            openMirrorPickerEx(invalid, rp, false)
        end if
    else
        ' Buttons: [Play, Choose Mirror, Save]
        if idx = 0 then
            openMirrorPicker(invalid, 0)
        else if idx = 1 then
            openMirrorPickerEx(invalid, 0, false)
        end if
    end if
end sub

' "Resume S?E? - HH:MM" / "Play S?E?" button inside the seasonGroup -
' same dispatch as the top action bar's Resume button.
sub onSeasonResumeSelected()
    if m.seriesResume = invalid then return
    rp = 0
    if m.seriesResume.resumePos <> invalid then rp = W_AsInt(m.seriesResume.resumePos)
    openMirrorPicker(m.seriesResume.ep, rp)
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
    ' Cancel any pending episode-description fetch from the previous season.
    if m.epDescTask <> invalid then
        m.epDescTask.unobserveField("result")
        m.epDescTask.control = "STOP"
        m.epDescTask = invalid
    end if
    m.epDescSeason = -1
    m.epDescEpisode = -1
    m.overviewNode.text = m.seriesDesc
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
        '   "current:<label>"  - up-next or resume target (yellow chip)
        '   "watched"          - finished (green checkmark, 7-min rule)
        '   "partial:<pct>"    - started but not finished (progress bar)
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
        else if epEntry <> invalid then
            posSec = W_AsInt(epEntry.pos)
            durSec = W_AsInt(epEntry.dur)
            done = W_AsBool(epEntry.done)
            ' Apply the 7-min-remaining rule even if the saved record
            ' was written before the W_IsFinished threshold was bumped,
            ' so old "almost done" entries paint as completed too.
            if (not done) and durSec >= 840 and (durSec - posSec) < 420 then
                done = true
            end if
            if done then
                marker = "watched"
            else if posSec > 0 and durSec > 0 then
                pct = (posSec * 100) \ durSec
                if pct < 1 then pct = 1
                if pct > 99 then pct = 99
                marker = "partial:" + pct.ToStr()
            end if
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

' When the user highlights an episode cell, show its cached description
' immediately (if loaded before) or start a background fetch. Falls back
' to the series description while loading so the overview is never blank.
sub onEpisodeFocused()
    idx = m.epGrid.itemFocused
    if idx = invalid or idx < 0 then return
    if m.detail = invalid then return
    s = m.detail.seasons[m.activeSeason]
    if idx >= s.episodes.Count() then return
    ep = s.episodes[idx]

    cached = ep["epDesc"]
    if cached <> invalid and cached <> "" then
        m.overviewNode.text = cached
        return
    end if

    m.overviewNode.text = m.seriesDesc

    ' Don't re-launch the same fetch that's already in flight.
    if m.epDescSeason = ep.season and m.epDescEpisode = ep.episode then return

    if m.epDescTask <> invalid then
        m.epDescTask.unobserveField("result")
        m.epDescTask.control = "STOP"
        m.epDescTask = invalid
    end if
    m.epDescSeason = ep.season
    m.epDescEpisode = ep.episode

    task = createObject("roSGNode", "EpDescTask")
    task.observeField("result", "onEpDescResult")
    task.slug = ep.slug
    task.season = ep.season
    task.episode = ep.episode
    m.epDescTask = task
    task.control = "RUN"
end sub

sub onEpDescResult()
    if m.epDescTask = invalid then return
    res = m.epDescTask.result
    if res = invalid then return
    desc = ""
    if res.desc <> invalid then desc = res.desc
    resSeason = 0
    resEpisode = 0
    if res.season <> invalid then resSeason = res.season
    if res.episode <> invalid then resEpisode = res.episode

    ' Discard results from a superseded fetch.
    if resSeason <> m.epDescSeason or resEpisode <> m.epDescEpisode then return

    ' Cache on the episode object so subsequent focus hits are instant.
    if m.detail = invalid or m.detail.seasons = invalid then return
    si = m.activeSeason
    if si < 0 or si >= m.detail.seasons.Count() then return
    s = m.detail.seasons[si]
    for ei = 0 to s.episodes.Count() - 1
        ep = s.episodes[ei]
        if ep.season = resSeason and ep.episode = resEpisode then
            ep["epDesc"] = desc
            ' Also update the grid cell so the description travels with
            ' the item if the user scrolls away and comes back.
            cell = m.epGrid.content.getChild(ei)
            if cell <> invalid then
                if desc <> "" then cell.description = desc else cell.description = m.seriesDesc
            end if
            exit for
        end if
    end for

    ' Update the overview label if the user is still on this episode.
    focusIdx = m.epGrid.itemFocused
    if focusIdx = invalid or focusIdx < 0 or focusIdx >= s.episodes.Count() then return
    focusedEp = s.episodes[focusIdx]
    if focusedEp.season = resSeason and focusedEp.episode = resEpisode then
        if desc <> "" then
            m.overviewNode.text = desc
        else
            m.overviewNode.text = m.seriesDesc
        end if
    end if
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
    openMirrorPickerEx(ep, startPos, true)
end sub

' useSavedMirror=true is the Resume / Play / Restart / Episode-click
' behavior: if a previous mirror was recorded for this title, hand it
' to MirrorPicker so playback skips the picker UI. "Choose Mirror"
' passes false to force the full picker - that's the user explicitly
' opting to switch hosts.
sub openMirrorPickerEx(ep as Object, startPos as Integer, useSavedMirror as Boolean)
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

    ' Saved-mirror handoff. For movies the saved embed URL covers the
    ' whole title and goes through as directMirror (skips ServersTask
    ' entirely). For TV the saved URL is episode-specific, so we only
    ' use directMirror when the resume target IS that exact episode -
    ' otherwise we hint at the host and let MirrorPicker auto-pick the
    ' matching entry from a freshly fetched list. ResumePicker uses
    ' the same shape; this just brings the DetailsView Resume / Play
    ' / Episode-click paths into line with that.
    if useSavedMirror then
        ctx = invalid
        if m.detail.imdb <> invalid or m.detail.href <> invalid then
            ctx = W_GetContext(W_ItemKey(m.detail.imdb, m.detail.href))
        end if
        if ctx <> invalid and ctx.mirrorHost <> invalid and ctx.mirrorHost <> "" then
            sameContent = (m.kind = "movie")
            if not sameContent and ep <> invalid then
                sp = W_GetSeriesProgress(m.detail.imdb, m.detail.href)
                if sp <> invalid then
                    if W_AsInt(sp.season) = ep.season and W_AsInt(sp.episode) = ep.episode then
                        sameContent = true
                    end if
                end if
            end if
            if sameContent and ctx.mirrorLink <> invalid and ctx.mirrorLink <> "" then
                dm = { host: ctx.mirrorHost, link: ctx.mirrorLink, name: "" }
                if ctx.mirrorName <> invalid then dm.name = ctx.mirrorName
                args.directMirror = dm
            else
                args.preferredMirrorHost = ctx.mirrorHost
                if ctx.mirrorName <> invalid then args.preferredMirrorName = ctx.mirrorName
            end if
        end if
    end if

    m.top.requestNav = {
        action: "open"
        view: "MirrorPicker"
        args: args
    }
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    ' Star button toggles Save-to-List from anywhere on this screen,
    ' mirroring the favorite-toggle shortcut on the poster grids.
    if key = "options" then
        toggleFavorite()
        return true
    end if
    if key = "down" and m.actions.hasFocus() then
        if m.kind = "tv" then
            m.seasonGroup.visible = true
            if m.seasonResumeBtn.visible then
                m.seasonResumeBtn.setFocus(true)
            else if seasonCount() > 1 then
                m.seasonRow.setFocus(true)
            else if m.epGrid.content <> invalid then
                m.epGrid.setFocus(true)
            end if
            return true
        end if
    end if
    if key = "down" and m.seasonResumeBtn.hasFocus() then
        if seasonCount() > 1 then
            m.seasonRow.setFocus(true)
        else if m.epGrid.content <> invalid then
            m.epGrid.setFocus(true)
        end if
        return true
    end if
    if key = "up" and m.seasonResumeBtn.hasFocus() then
        m.actions.setFocus(true)
        return true
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
        else if m.seasonResumeBtn.visible then
            m.seasonResumeBtn.setFocus(true)
        else
            m.actions.setFocus(true)
        end if
        return true
    end if
    if key = "up" and m.seasonRow.hasFocus() then
        if m.seasonResumeBtn.visible then
            m.seasonResumeBtn.setFocus(true)
        else
            m.actions.setFocus(true)
        end if
        return true
    end if
    return false
end function

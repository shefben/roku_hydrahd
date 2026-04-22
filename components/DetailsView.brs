' DetailsView.brs - Movie / TV details, season switcher, episode grid.

sub init()
    ' State first.
    m.activeSeason = 0
    m.detail = invalid
    m.kind = ""
    m.id = ""
    m.href = ""

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
        m.actions.buttons = ["Seasons"]
        if d.seasons <> invalid and d.seasons.Count() > 0 then
            renderSeasons()
            m.seasonGroup.visible = true
        end if
    else
        m.actions.buttons = ["Play", "Choose Mirror"]
    end if
    m.actions.setFocus(true)
end sub

function joinWithComma(arr as Object) as String
    out = ""
    for i = 0 to arr.Count() - 1
        if i > 0 then out = out + ", "
        out = out + arr[i]
    end for
    return out
end function

sub renderSeasons()
    root = createObject("roSGNode", "ContentNode")
    for i = 0 to m.detail.seasons.Count() - 1
        ch = root.createChild("ContentNode")
        ch.title = m.detail.seasons[i].label
    end for
    m.seasonRow.content = root
    if root.getChildCount() > 0 then
        m.seasonRow.jumpToItem = 0
        selectSeason(0)
    end if
end sub

function seasonCount() as Integer
    if m.seasonRow.content = invalid then return 0
    return m.seasonRow.content.getChildCount()
end function

sub onActionSelected()
    if m.actions.buttonSelected = invalid then return
    idx = m.actions.buttonSelected
    if m.kind = "tv" then
        ' TV shows have a single "Seasons" button - just focus the season picker.
        onShowSeasons()
        return
    end if
    if idx = 0 then
        onPlay()
    else if idx = 1 then
        onMirrors()
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
    root = createObject("roSGNode", "ContentNode")
    for each ep in s.episodes
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
    end for
    m.epGrid.content = root
    m.seasonGroup.visible = true
end sub

sub onEpisodeSelected()
    idx = m.epGrid.itemSelected
    if idx = invalid then return
    if m.detail = invalid then return
    s = m.detail.seasons[m.activeSeason]
    if idx < 0 or idx >= s.episodes.Count() then return
    ep = s.episodes[idx]
    openMirrorPicker(ep)
end sub

sub onPlay()
    if m.detail = invalid then return
    if m.detail.kind = "movie" then
        openMirrorPicker(invalid)
    else
        if m.detail.seasons.Count() = 0 then
            m.statusNode.text = "No episodes available."
            return
        end if
        s = m.detail.seasons[m.detail.seasons.Count() - 1]
        ep = s.episodes[s.episodes.Count() - 1]
        openMirrorPicker(ep)
    end if
end sub

sub onMirrors()
    onPlay()
end sub

sub openMirrorPicker(ep as Object)
    if m.detail = invalid then return
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

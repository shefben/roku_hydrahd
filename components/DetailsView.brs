' DetailsView.brs - Movie / TV details, season switcher, episode grid.

sub init()
    ' State first.
    m.seasonButtons = []
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
    m.statusNode = m.top.findNode("status")

    m.actions = m.top.findNode("actions")
    m.actions.buttons = ["Play", "Choose Mirror"]
    m.actions.observeField("buttonSelected", "onActionSelected")

    m.seasonGroup = m.top.findNode("seasonGroup")
    m.seasonRow = m.top.findNode("seasonRow")
    m.epGrid = m.top.findNode("episodeGrid")
    m.epGrid.itemComponentName = "EpisodeItem"
    m.epGrid.observeField("itemSelected", "onEpisodeSelected")
    m.seasonRow.observeField("buttonSelected", "onSeasonSelected")

    m.actions.setFocus(true)
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return
    m.kind = a.kind
    m.id = a.id
    m.href = a.href
    if a.title <> invalid then m.titleNode.text = a.title
    if a.poster <> invalid and a.poster <> "" then
        m.poster.uri = a.poster
        m.backdrop.uri = a.poster
    end if
    fetchDetails()
end sub

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

    if d.kind = "tv" then
        m.actions.buttons = ["Seasons"]
        if d.seasons.Count() > 0 then
            renderSeasons()
            m.seasonGroup.visible = true
        end if
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
    m.seasonButtons = []
    labels = []
    for i = 0 to m.detail.seasons.Count() - 1
        labels.Push(m.detail.seasons[i].label)
    end for
    m.seasonRow.buttons = labels
    if labels.Count() > 0 then selectSeason(0)
end sub

sub onActionSelected()
    if m.actions.buttonSelected = invalid then return
    idx = m.actions.buttonSelected
    if m.detail <> invalid and m.detail.kind = "tv" then
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
    if m.seasonRow.buttons <> invalid and m.seasonRow.buttons.Count() > 1 then
        m.seasonRow.setFocus(true)
    else if m.epGrid.content <> invalid then
        m.epGrid.setFocus(true)
    end if
end sub

sub onSeasonSelected()
    if m.seasonRow.buttonSelected = invalid then return
    selectSeason(m.seasonRow.buttonSelected)
end sub

sub selectSeason(idx as Integer)
    if m.detail = invalid or m.detail.seasons = invalid then return
    if idx < 0 or idx >= m.detail.seasons.Count() then return
    m.activeSeason = idx
    s = m.detail.seasons[idx]
    root = createObject("roSGNode", "ContentNode")
    for each ep in s.episodes
        cell = root.createChild("ContentNode")
        cell.title = ep.name
        cell.shortDescriptionLine1 = "Season " + ep.season.ToStr() + " - Episode " + ep.episode.ToStr()
        cell.shortDescriptionLine2 = "E" + ep.episode.ToStr()
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
        if m.detail <> invalid and m.detail.kind = "tv" then
            m.seasonGroup.visible = true
            if m.seasonRow.buttons <> invalid and m.seasonRow.buttons.Count() > 1 then
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
        if m.seasonRow.buttons <> invalid and m.seasonRow.buttons.Count() > 1 then
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

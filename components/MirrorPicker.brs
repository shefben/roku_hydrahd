' MirrorPicker.brs - Lists all servers/mirrors and resolves selection to a stream.

sub init()
    m.mirrors = []
    m.args = invalid

    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.grid = m.top.findNode("mirrorGrid")
    m.status = m.top.findNode("status")
    m.grid.itemComponentName = "MirrorItem"
    m.grid.observeField("itemSelected", "onMirrorSelected")
    m.grid.setFocus(true)
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return
    m.args = a
    m.title.text = a.title
    if a.episode <> invalid then
        m.subtitle.text = "S" + a.episode.season.ToStr() + "E" + a.episode.episode.ToStr() + " - " + a.episode.name
    else
        m.subtitle.text = "Movie"
    end if
    fetchMirrors()
end sub

sub fetchMirrors()
    m.top.loading = true
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "ServersTask")
    m.task.observeField("result", "onMirrorResult")
    m.task.kind = m.args.kind
    m.task.imdb = m.args.imdb
    m.task.tmdb = m.args.tmdb
    m.task.refer = m.args.href
    if m.args.episode <> invalid then
        m.task.season = m.args.episode.season
        m.task.episode = m.args.episode.episode
        m.task.slug = m.args.episode.slug
    end if
    m.task.control = "RUN"
end sub

sub onMirrorResult()
    res = m.task.result
    m.top.loading = false
    if res = invalid or res.mirrors = invalid or res.mirrors.Count() = 0 then
        m.status.text = "No mirrors available."
        return
    end if
    m.mirrors = res.mirrors
    root = createObject("roSGNode", "ContentNode")
    for each mr in m.mirrors
        cell = root.createChild("ContentNode")
        cell.title = mr.name
        cell.shortDescriptionLine1 = mr.host
        if mr.qualityHint <> invalid and mr.qualityHint <> "" then
            cell.shortDescriptionLine2 = mr.qualityHint
        else
            cell.shortDescriptionLine2 = ""
        end if
        if mr.isPremium then cell.releaseDate = "premium"
    end for
    m.grid.content = root
    m.grid.setFocus(true)
    m.status.text = m.mirrors.Count().ToStr() + " mirrors loaded - pick any."
    if m.args <> invalid and m.args.autoPick = true then
        m.grid.itemSelected = 0
        onMirrorSelected()
    end if
end sub

sub onMirrorSelected()
    idx = m.grid.itemSelected
    if idx = invalid or idx < 0 or idx >= m.mirrors.Count() then return
    mirror = m.mirrors[idx]
    m.status.text = "Resolving stream from " + mirror.host + "..."
    m.top.loading = true
    if m.resolve <> invalid then m.resolve.unobserveField("result")
    m.resolve = createObject("roSGNode", "ResolveTask")
    m.resolve.observeField("result", "onResolved")
    m.resolve.embedUrl = mirror.link
    m.resolve.refer = m.args.href
    m.resolve.kind = m.args.kind
    m.resolve.imdb = m.args.imdb
    m.resolve.tmdb = m.args.tmdb
    if m.args.episode <> invalid then
        m.resolve.season = m.args.episode.season
        m.resolve.episode = m.args.episode.episode
    end if
    m.resolve.control = "RUN"
end sub

sub onResolved()
    res = m.resolve.result
    m.top.loading = false
    if res = invalid or res.url = invalid or res.url = "" then
        m.status.text = "Could not resolve a direct stream from this mirror. Try another."
        return
    end if
    referer = ""
    if res.referer <> invalid then referer = res.referer
    userAgent = ""
    if res.userAgent <> invalid then userAgent = res.userAgent
    playerArgs = {
        title: m.args.title
        subtitle: m.subtitle.text
        url: res.url
        streamFormat: res.streamFormat
        qualities: res.qualities
        subtitles: res.subtitles
        poster: m.args.poster
        referer: referer
        userAgent: userAgent
        kind: m.args.kind
        imdb: m.args.imdb
        tmdb: m.args.tmdb
        href: m.args.href
    }
    if m.args.episodeQueue <> invalid then
        playerArgs.episodeQueue = m.args.episodeQueue
        playerArgs.episodeQueueIndex = m.args.episodeQueueIndex
    end if
    payload = {
        action: "replace"
        view: "PlayerView"
        args: playerArgs
    }
    m.top.requestNav = payload
end sub

' PlayerView.brs - Video playback with quality, subtitle, audio, and CC styling controls.

sub init()
    m.video = m.top.findNode("video")
    m.overlay = m.top.findNode("overlay")
    m.overlayBg = m.top.findNode("overlayBg")
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.status = m.top.findNode("status")

    m.qualityPanel = m.top.findNode("qualityPanel")
    m.qualityRow = m.top.findNode("qualityRow")
    m.ccPanel = m.top.findNode("ccPanel")
    m.ccRow = m.top.findNode("ccRow")
    m.ccStylePanel = m.top.findNode("ccStylePanel")
    m.ccStyleRow = m.top.findNode("ccStyleRow")
    m.audioPanel = m.top.findNode("audioPanel")
    m.audioRow = m.top.findNode("audioRow")

    m.actionBar = m.top.findNode("actionBar")
    m.actionBar.observeField("buttonSelected", "onActionBar")

    m.qualityRow.observeField("itemSelected", "onQualityChosen")
    m.ccRow.observeField("itemSelected", "onCcChosen")
    m.audioRow.observeField("itemSelected", "onAudioChosen")

    m.ccStyleLabels = [
        "Text: Small", "Text: Medium", "Text: Large",
        "Color: White", "Color: Yellow", "Color: Cyan",
        "BG: Black", "BG: Semi", "BG: None"
    ]
    m.ccStyleRow.content = buildLabelContent(m.ccStyleLabels)
    m.ccStyleRow.observeField("itemSelected", "onCcStyleChosen")

    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    m.video.observeField("downloadedSegment", "onSegmentDownloaded")

    m.qualities = []
    m.subtitles = []
    m.audioTracks = []
    m.activeQuality = -1
    m.activeSubtitle = -1
    m.activeAudio = -1
    m.openPanel = ""

    applyCcGlobal()
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return
    m.title.text = a.title
    m.subtitle.text = a.subtitle

    m.qualities = a.qualities
    if m.qualities = invalid then m.qualities = []
    m.subtitles = a.subtitles
    if m.subtitles = invalid then m.subtitles = []
    m.streamUrl = a.url
    m.streamFormat = a.streamFormat
    m.streamReferer = ""
    if a.referer <> invalid then m.streamReferer = a.referer
    m.streamUserAgent = ""
    if a.userAgent <> invalid then m.streamUserAgent = a.userAgent

    print "[Player] qualities="; m.qualities.Count(); " subs="; m.subtitles.Count()
    startPlayback(m.streamUrl, m.streamFormat)
    renderQualityChips()
    renderCcChips()
end sub

sub startPlayback(url as String, fmt as String)
    if url = invalid or url = "" then
        showOverlay()
        m.status.text = "No stream URL - try a different mirror."
        return
    end if

    cn = createObject("roSGNode", "ContentNode")
    cn.url = url
    if fmt = invalid or fmt = "" then fmt = U_StreamFormat(url)
    cn.streamFormat = fmt
    cn.title = m.title.text
    cn.live = false
    cn.playStart = 0
    cn.httpCertificatesFile = "common:/certs/ca-bundle.crt"
    if m.top.args.poster <> invalid then cn.HDPosterUrl = m.top.args.poster

    headers = []
    if m.streamReferer <> invalid and m.streamReferer <> "" then
        headers.Push("Referer:" + m.streamReferer)
        org = m.streamReferer
        if Right(org, 1) = "/" then org = Left(org, Len(org) - 1)
        headers.Push("Origin:" + org)
    end if
    if m.streamUserAgent <> invalid and m.streamUserAgent <> "" then
        headers.Push("User-Agent:" + m.streamUserAgent)
    end if
    if headers.Count() > 0 then cn.httpHeaders = headers
    print "[Player] starting "; url; " (referer="; m.streamReferer; ")"

    if m.subtitles.Count() > 0 then
        tracks = []
        for i = 0 to m.subtitles.Count() - 1
            s = m.subtitles[i]
            tracks.Push({
                TrackName: s.url
                Language: s.language
                Description: s.name
            })
        end for
        cn.subtitleTracks = tracks
        m.activeSubtitle = -1
        m.video.subtitleTrack = ""
    end if

    m.video.content = cn
    m.video.control = "play"
    m.status.text = "Loading..."
end sub

sub onVideoState()
    s = m.video.state
    print "[Player] state="; s
    if s = "playing" then
        m.status.text = ""
        if not m.overlay.visible then m.video.setFocus(true)
        ingestRendition()
        ingestAudio()
    else if s = "buffering" then
        m.status.text = "Buffering..."
    else if s = "error" then
        showOverlay()
        m.status.text = "Playback error: " + m.video.errorStr
        print "[Player] errorStr="; m.video.errorStr; " errorCode="; m.video.errorCode
    else if s = "finished" then
        if tryAutoAdvance() then return
        ' Stream ended and there's no next episode (or this is a movie).
        ' Show the overlay so the user can pick something else.
        showOverlay()
        m.status.text = "Playback ended."
    end if
end sub

function tryAutoAdvance() as Boolean
    a = m.top.args
    if a = invalid then return false
    if a.kind <> "tv" then return false
    queue = a.episodeQueue
    if queue = invalid then return false
    idx = a.episodeQueueIndex
    if idx = invalid then return false
    nextIdx = idx + 1
    if nextIdx >= queue.Count() then return false
    nextEp = queue[nextIdx]
    nextArgs = {
        kind:    "tv"
        title:   a.title
        poster:  a.poster
        imdb:    a.imdb
        tmdb:    a.tmdb
        href:    a.href
        autoPick: true
        episode: {
            slug:    nextEp.slug
            season:  nextEp.season
            episode: nextEp.episode
            name:    nextEp.name
        }
        episodeQueue:      queue
        episodeQueueIndex: nextIdx
    }
    m.video.control = "stop"
    m.status.text = "Loading next episode..."
    m.top.requestNav = { action: "replace", view: "MirrorPicker", args: nextArgs }
    return true
end function

sub onVideoPosition()
end sub

sub onSegmentDownloaded()
    ingestRendition()
end sub

sub ingestRendition()
    info = m.video.streamingSegment
    if info = invalid then return
    bw = info.segBitrateBps
    if bw = invalid or bw = 0 then return
    label = "Auto"
    if info.segHeight <> invalid and info.segHeight > 0 then label = info.segHeight.ToStr() + "p"
    found = false
    for each q in m.qualities
        if q.label = label then
            found = true
            exit for
        end if
    end for
    if not found then
        m.qualities.Push({ label: label, height: info.segHeight, bandwidth: bw })
        renderQualityChips()
    end if
end sub

sub ingestAudio()
    tracks = m.video.availableAudioTracks
    if tracks = invalid then return
    if tracks.Count() = m.audioTracks.Count() then return
    m.audioTracks = []
    for each t in tracks
        m.audioTracks.Push({ name: t.Name, language: t.Language, trackId: t.TrackId })
    end for
    renderAudioChips()
end sub

' ---- overlay show / hide ----

sub showOverlay()
    m.overlayBg.visible = true
    m.overlay.visible = true
    m.actionBar.setFocus(true)
    m.openPanel = ""
end sub

sub hideOverlay()
    m.overlayBg.visible = false
    m.overlay.visible = false
    m.qualityPanel.visible = false
    m.ccPanel.visible = false
    m.ccStylePanel.visible = false
    m.audioPanel.visible = false
    m.openPanel = ""
    m.video.setFocus(true)
end sub

sub onActionBar()
    idx = m.actionBar.buttonSelected
    if idx = invalid then return
    if idx = 0 then
        onResume()
    else if idx = 1 then
        openPanel("quality")
    else if idx = 2 then
        openPanel("cc")
    else if idx = 3 then
        openPanel("ccStyle")
    else if idx = 4 then
        openPanel("audio")
    else if idx = 5 then
        onStop()
    end if
end sub

sub openPanel(name as String)
    m.qualityPanel.visible = (name = "quality")
    m.ccPanel.visible = (name = "cc")
    m.ccStylePanel.visible = (name = "ccStyle")
    m.audioPanel.visible = (name = "audio")
    m.openPanel = name
    if name = "quality" then
        m.qualityRow.setFocus(true)
    else if name = "cc" then
        m.ccRow.setFocus(true)
    else if name = "ccStyle" then
        m.ccStyleRow.setFocus(true)
    else if name = "audio" then
        m.audioRow.setFocus(true)
    end if
end sub

sub onResume()
    if m.video.state <> "playing" then m.video.control = "resume"
    hideOverlay()
end sub

sub onStop()
    m.video.control = "stop"
    m.top.requestNav = { action: "back" }
end sub

' ---- list rendering via LabelList content node ----

function buildLabelContent(labels as Object) as Object
    root = createObject("roSGNode", "ContentNode")
    for each label in labels
        ch = root.createChild("ContentNode")
        ch.title = label
    end for
    return root
end function

sub renderQualityChips()
    labels = ["Auto"]
    for i = 0 to m.qualities.Count() - 1
        labels.Push(m.qualities[i].label)
    end for
    m.qualityRow.content = buildLabelContent(labels)
end sub

sub onQualityChosen()
    idx = m.qualityRow.itemSelected
    if idx = invalid then return
    if idx = 0 then
        if m.streamUrl <> invalid and m.streamUrl <> "" then
            switchSource(m.streamUrl, m.streamFormat)
        end if
        m.status.text = "Quality: Auto"
    else
        qIdx = idx - 1
        if qIdx < 0 or qIdx >= m.qualities.Count() then return
        q = m.qualities[qIdx]
        if q.url <> invalid and q.url <> "" then
            resumeAt = m.video.position
            switchSource(q.url, "hls")
            m.video.seek = resumeAt
            m.status.text = "Quality: " + q.label
        else
            m.status.text = "Quality: " + q.label + " (auto - no per-rendition URL)"
        end if
    end if
end sub

sub renderCcChips()
    labels = ["Off"]
    for i = 0 to m.subtitles.Count() - 1
        s = m.subtitles[i]
        nm = s.name
        if nm = invalid or nm = "" then nm = UCase(s.language)
        labels.Push(nm)
    end for
    m.ccRow.content = buildLabelContent(labels)
end sub

sub onCcChosen()
    idx = m.ccRow.itemSelected
    if idx = invalid then return
    if idx = 0 then
        m.activeSubtitle = -1
        m.video.subtitleTrack = ""
        m.status.text = "Subtitles off"
        return
    end if
    sIdx = idx - 1
    if sIdx < 0 or sIdx >= m.subtitles.Count() then return
    sub_ = m.subtitles[sIdx]
    m.activeSubtitle = sIdx
    m.video.subtitleTrack = sub_.url
    m.status.text = "Subtitles: " + sub_.name
end sub

sub renderAudioChips()
    labels = []
    for i = 0 to m.audioTracks.Count() - 1
        t = m.audioTracks[i]
        labels.Push(t.name + " (" + t.language + ")")
    end for
    m.audioRow.content = buildLabelContent(labels)
end sub

sub onAudioChosen()
    idx = m.audioRow.itemSelected
    if idx = invalid then return
    if idx < 0 or idx >= m.audioTracks.Count() then return
    m.video.audioTrack = m.audioTracks[idx].trackId
    m.status.text = "Audio track changed"
end sub

sub onCcStyleChosen()
    idx = m.ccStyleRow.itemSelected
    if idx = invalid then return
    reg = CreateObject("roRegistrySection", "HydraHD")
    if idx = 0 then
        reg.Write("ccTextSize", "small")
    else if idx = 1 then
        reg.Write("ccTextSize", "medium")
    else if idx = 2 then
        reg.Write("ccTextSize", "large")
    else if idx = 3 then
        reg.Write("ccTextColor", "0xffffff")
    else if idx = 4 then
        reg.Write("ccTextColor", "0xffd24a")
    else if idx = 5 then
        reg.Write("ccTextColor", "0x66e5ff")
    else if idx = 6 then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "100")
    else if idx = 7 then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "60")
    else if idx = 8 then
        reg.Write("ccBgOpacity", "0")
    end if
    reg.Flush()
    applyCcGlobal()
    m.status.text = "Caption style: " + m.ccStyleLabels[idx]
end sub

sub switchSource(url as String, fmt as String)
    cn = createObject("roSGNode", "ContentNode")
    cn.url = url
    if fmt = invalid or fmt = "" then fmt = U_StreamFormat(url)
    cn.streamFormat = fmt
    cn.title = m.title.text
    if m.video.content <> invalid then
        if m.video.content.subtitleTracks <> invalid then
            cn.subtitleTracks = m.video.content.subtitleTracks
        end if
        if m.video.content.httpHeaders <> invalid then
            cn.httpHeaders = m.video.content.httpHeaders
        end if
    end if
    m.video.control = "stop"
    m.video.content = cn
    m.video.control = "play"
end sub

sub applyCcGlobal()
    return
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "OK" or key = "options" then
        if m.overlay.visible then
            ' Let ButtonGroup handle OK on its focused button.
            if m.openPanel <> "" then return false
            if m.actionBar.hasFocus() then return false
            hideOverlay()
        else
            showOverlay()
        end if
        return true
    end if
    if key = "back" then
        if m.openPanel <> "" then
            ' Close subpanel and return to action bar.
            m.qualityPanel.visible = false
            m.ccPanel.visible = false
            m.ccStylePanel.visible = false
            m.audioPanel.visible = false
            m.openPanel = ""
            m.actionBar.setFocus(true)
            return true
        end if
        if m.overlay.visible then
            hideOverlay()
            return true
        end if
        m.video.control = "stop"
        m.top.requestNav = { action: "back" }
        return true
    end if
    if key = "up" then
        if m.openPanel <> "" then
            ' Subpanel goes back to action bar.
            m.qualityPanel.visible = false
            m.ccPanel.visible = false
            m.ccStylePanel.visible = false
            m.audioPanel.visible = false
            m.openPanel = ""
            m.actionBar.setFocus(true)
            return true
        end if
        if not m.overlay.visible then
            showOverlay()
            return true
        end if
        ' Action bar is focused. Swallow up so MainScene doesn't try to
        ' steal focus to a hidden nav button.
        return true
    end if
    if key = "down" then
        if m.overlay.visible and m.actionBar.hasFocus() then
            fi = m.actionBar.buttonFocused
            if fi = invalid then fi = 0
            if fi = 1 then
                openPanel("quality")
                return true
            else if fi = 2 then
                openPanel("cc")
                return true
            else if fi = 3 then
                openPanel("ccStyle")
                return true
            else if fi = 4 then
                openPanel("audio")
                return true
            end if
        end if
        if not m.overlay.visible then
            showOverlay()
            return true
        end if
    end if
    return false
end function

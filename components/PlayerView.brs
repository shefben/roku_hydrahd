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
    ' Action-bar labels. The skip-intro / play-next-episode entry is
    ' prepended in rebuildActionBar() while a chapter window is active
    ' so the user always has access to the skip action - even after
    ' the floating banner has faded. onActionBar dispatches by label
    ' (not index) so the dynamic button doesn't shift everything else.
    m.baseActionLabels = ["Resume", "Quality", "Subtitles", "CC Settings", "Audio", "Stop"]

    m.qualityRow.observeField("itemSelected", "onQualityChosen")
    m.ccRow.observeField("itemSelected", "onCcChosen")
    m.audioRow.observeField("itemSelected", "onAudioChosen")

    m.ccStyleLabels = [
        "Text: Small", "Text: Medium", "Text: Large",
        "Color: White", "Color: Yellow", "Color: Cyan",
        "BG: Black", "BG: Semi", "BG: None",
        "Sync +0.25s", "Sync -0.25s"
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

    ' Resume / progress tracking. lastSavedPos throttles writes to roughly
    ' once every 5s; progressSaved flips false on the very first save so we
    ' always persist the starting position even on quick stops.
    m.startPosition = 0
    m.lastSavedPos = -999
    m.progressSaved = false

    ' Skip Intro / Play Next Episode banner state. Two distinct
    ' visual modes share the skipBanner node:
    '   - intro/recap: shown for 5s, then opacity-faded out by
    '     skipFadeAnim. After fade the action bar in the overlay still
    '     surfaces "Skip Intro" / "Skip Recap" until the playhead
    '     leaves the chapter window.
    '   - outro (TV episodes only, only when the queue has another
    '     episode after the current one): shown with a 5-second
    '     countdown bar (skipCountdown / skipCountdownFill driven by
    '     skipCountdownAnim) and a paired skipBannerTimer that fires
    '     performSkip() to auto-advance. BACK during the countdown
    '     cancels (m.bannerDismissed) so the user can finish watching
    '     the credits manually; OK skips immediately.
    m.skipBanner = m.top.findNode("skipBanner")
    m.skipLabel = m.top.findNode("skipLabel")
    m.skipCountdown = m.top.findNode("skipCountdown")
    m.skipCountdownFill = m.top.findNode("skipCountdownFill")
    m.skipBannerTimer = m.top.findNode("skipBannerTimer")
    m.skipBannerTimer.observeField("fire", "onSkipBannerTimerFire")
    m.skipFadeAnim = m.top.findNode("skipFadeAnim")
    m.skipCountdownAnim = m.top.findNode("skipCountdownAnim")
    m.chapters = []
    m.activeChapter = invalid
    m.activeChapterKind = ""
    m.activeChapterIsCountdown = false
    m.bannerDismissed = false

    ' Time-based "Skip to Next Episode" banner. Fires 135 s before the
    ' episode ends for any TV show with a queued next episode, independent
    ' of chapter data so it works on every mirror/host. m.nextEpActive
    ' stays true for the remainder of the episode once the window opens
    ' so the action-bar entry persists in the overlay after the floating
    ' banner has timed out.
    m.nextEpBanner = m.top.findNode("nextEpBanner")
    m.nextEpTimer = m.top.findNode("nextEpTimer")
    m.nextEpTimer.observeField("fire", "onNextEpTimerFire")
    m.nextEpActive = false      ' true while within 135 s of end AND next ep queued
    m.nextEpBannerShown = false ' true once floating banner has been displayed this ep

    ' Populate the action bar at least once so it has something for
    ' the user to focus on when the overlay first opens.
    rebuildActionBar()

    ' In-place episode advance state. m.advance is invalid except while
    ' a "Next Episode" cascade is running; populated with the next ep
    ' info, the mirror list, and the index of the mirror we're trying.
    m.advanceOverlay = m.top.findNode("advanceOverlay")
    m.advanceStatus = m.top.findNode("advanceStatus")
    m.advance = invalid

    ' Custom caption renderer state.
    m.capBox = m.top.findNode("capBox")
    m.capBg = m.top.findNode("capBg")
    m.capLabel = m.top.findNode("capLabel")
    m.capTimer = m.top.findNode("capTimer")
    if m.capTimer <> invalid then m.capTimer.observeField("fire", "onCapTick")
    m.cues = []
    m.subOffset = 0.0
    m.curCueText = ""
    m.subTask = invalid

    applyCcGlobal()

    ' If MainScene happens to land focus on this view's root (e.g. the
    ' user pressed BACK out of the resolver/MirrorPicker spinner before
    ' "playing" state arrived) we redirect to whichever element makes
    ' sense for the current state - the open panel, the action bar, or
    ' the video itself.
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.openPanel = "quality" then
        m.qualityRow.setFocus(true)
        return
    end if
    if m.openPanel = "cc" then
        m.ccRow.setFocus(true)
        return
    end if
    if m.openPanel = "ccStyle" then
        m.ccStyleRow.setFocus(true)
        return
    end if
    if m.openPanel = "audio" then
        m.audioRow.setFocus(true)
        return
    end if
    if m.overlay <> invalid and m.overlay.visible then
        m.actionBar.setFocus(true)
        return
    end if
    if m.video <> invalid then m.video.setFocus(true)
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

    if a.startPosition <> invalid then
        m.startPosition = W_AsInt(a.startPosition)
    else
        m.startPosition = 0
    end if
    m.lastSavedPos = -999
    m.progressSaved = false

    if a.chapters <> invalid then
        m.chapters = a.chapters
    else
        m.chapters = []
    end if
    ' Drop any skip-banner state from the previous episode/movie so a
    ' stale 5s timer or fade animation doesn't bleed into the new
    ' stream. updateSkipBanner will re-establish state once playback
    ' enters the new chapters' windows.
    clearActiveChapter()
    ' Reset time-based next-ep banner for the incoming episode.
    m.nextEpActive = false
    m.nextEpBannerShown = false
    if m.nextEpBanner <> invalid then m.nextEpBanner.visible = false
    if m.nextEpTimer <> invalid then m.nextEpTimer.control = "stop"

    print "[Player] qualities="; m.qualities.Count(); " subs="; m.subtitles.Count(); " chapters="; m.chapters.Count(); " resumeAt="; m.startPosition
    ' Default to the highest-bitrate variant the resolver advertised so
    ' the stream opens at top quality instead of letting the master
    ' playlist's ABR cold-start at a lower rendition. Resolver returns
    ' qualities sorted height-descending; we pick the first variant that
    ' has a per-rendition URL. "Auto" stays available in the overlay so
    ' the user can drop back to ABR if their bandwidth can't sustain it.
    initUrl = m.streamUrl
    initFmt = m.streamFormat
    ' Honor the user's Default Video Quality (Settings): "best" (default,
    ' top rendition - the original behavior), "1080"/"720" (highest at or
    ' below that cap), or "saver" (lowest, for slow connections / data).
    pref = U_PrefDefault("videoQuality", "best")
    selIdx = pickPreferredQualityIndex(pref)
    if selIdx >= 0 then
        sel = m.qualities[selIdx]
        initUrl = sel.url
        initFmt = "hls"
        m.activeQuality = selIdx
        print "[Player] quality pref="; pref; " -> "; sel.label
    end if
    startPlayback(initUrl, initFmt)
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
    cn.playStart = m.startPosition
    cn.httpCertificatesFile = "common:/certs/ca-bundle.crt"
    if m.top.args.poster <> invalid then cn.HDPosterUrl = m.top.args.poster

    ' Use roHttpAgent + setHttpAgent rather than ContentNode.httpHeaders.
    ' Per developer.roku.com/.../content-metadata.md: setting cn.httpHeaders
    ' wipes any existing agent-level headers on play, so the two paths
    ' don't compose - pick agent-only and put EVERY header (Referer,
    ' Origin, User-Agent) on the agent. This is the documented pattern
    ' for getting Referer to propagate to HLS segment fetches, which
    ' some upstreams (cloudnestra, lookmovie, xpass) IP/Referer-strict-
    ' check on every segment.
    needAgent = false
    agent = CreateObject("roHttpAgent")
    if m.streamReferer <> invalid and m.streamReferer <> "" then
        agent.AddHeader("Referer", m.streamReferer)
        org = m.streamReferer
        if Right(org, 1) = "/" then org = Left(org, Len(org) - 1)
        agent.AddHeader("Origin", org)
        needAgent = true
    end if
    if m.streamUserAgent <> invalid and m.streamUserAgent <> "" then
        agent.AddHeader("User-Agent", m.streamUserAgent)
        needAgent = true
    end if
    if needAgent then m.video.setHttpAgent(agent)
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
        ' Auto-pick an English track if one is present. Match on ISO code
        ' or on the human-readable name so labels like "English",
        ' "English - SDH", "English - eng(5)", "ENGLISH" etc. all qualify.
        ' Plain "English" wins over SDH variants when both exist.
        m.activeSubtitle = pickDefaultSubtitle(m.subtitles)
    else
        m.activeSubtitle = -1
    end if

    ' Custom caption rendering owns the on-screen captions. Force Roku's
    ' native caption overlay OFF (globalCaptionMode + empty subtitleTrack)
    ' so the user never sees two sets of subtitles (custom white text AND
    ' the system-rendered track). Native is re-enabled only as a fallback
    ' in onSubCues when the subtitle file fails to parse.
    m.video.subtitleTrack = ""
    m.video.globalCaptionMode = "Off"

    m.video.content = cn
    m.video.control = "play"
    m.status.text = "Loading..."
    ' Switch the auto-picked track to custom rendering (native stays as the
    ' fallback until cues parse).
    if m.activeSubtitle >= 0 and m.activeSubtitle < m.subtitles.Count() then
        loadCustomSubtitle(m.subtitles[m.activeSubtitle].url)
    end if
end sub

sub onVideoState()
    s = m.video.state
    print "[Player] state="; s
    ' Custom caption tick loop only runs while actively playing.
    if s <> "playing" then
        if m.capTimer <> invalid then m.capTimer.control = "stop"
        if m.capBox <> invalid then m.capBox.visible = false
    end if
    if s = "playing" then
        m.status.text = ""
        if not m.overlay.visible then m.video.setFocus(true)
        ingestRendition()
        ingestAudio()
        if m.cues <> invalid and m.cues.Count() > 0 and m.capTimer <> invalid then m.capTimer.control = "start"
    else if s = "buffering" then
        m.status.text = "Buffering..."
    else if s = "error" then
        saveProgress(false)
        ' If we never made it to the "playing" state and now errored,
        ' blame the mirror so its reliability score drops.
        if not m.progressSaved then
            a = m.top.args
            if a <> invalid and a.mirrorHost <> invalid and a.mirrorHost <> "" then
                W_RecordMirrorOutcome(a.mirrorHost, false)
            end if
        end if
        showOverlay()
        m.status.text = "Playback error: " + m.video.errorStr
        print "[Player] errorStr="; m.video.errorStr; " errorCode="; m.video.errorCode
    else if s = "finished" then
        saveProgress(true)
        if tryAutoAdvance() then return
        ' Stream ended and there's no next episode (or this is a movie).
        ' Show the overlay so the user can pick something else.
        showOverlay()
        m.status.text = "Playback ended."
    end if
end sub

' tryAutoAdvance now keeps the user inside PlayerView. When there's a
' next episode in the queue, kick off the in-place advance pipeline
' (saved mirror first, fall back to ServersTask + auto-cascade).
' Returns true if advance was started so the caller can stop processing
' the current state - false means there's no next episode to advance to.
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
    return startEpisodeAdvance(nextEp, nextIdx)
end function

' --- In-place episode advance ----------------------------------------
'
' Skip Credits / playback-finished / Skip-to-Next-Episode on a TV show
' triggers an in-place swap of the player's stream, instead of bouncing
' back through MirrorPicker. We fetch a fresh per-episode server list
' for the new S/E (the previous episode's mirror link is for a
' DIFFERENT episode and would replay it verbatim if reused), then
' iterate auto-cascade style - preferring the user's prior host so the
' same-host UX is preserved. The user only sees a brief "Loading next
' episode..." card on top of the (paused) Video node, never a
' different view.

function startEpisodeAdvance(nextEp as Object, nextIdx as Integer) as Boolean
    a = m.top.args
    if a = invalid then return false

    ' The current episode's mirrorLink/mirrorHost belong to the *previous*
    ' episode - the iframe URL is episode-specific on HydraHD, so handing
    ' it to ResolveTask as the embedUrl would just re-resolve and replay
    ' the same stream. Keep the host as a preference so we can favor it
    ' once the fresh server list arrives.
    preferredHost = ""
    if a.mirrorHost <> invalid then preferredHost = a.mirrorHost

    m.advance = {
        ep:            nextEp
        queueIdx:      nextIdx
        mirrors:       invalid
        triedHosts:    {}
        activeMirror:  invalid
        preferredHost: preferredHost
    }

    ' Tear down the floating banner state in case we got here via the
    ' "finished" path rather than performSkip - finished bypasses
    ' performSkip / clearActiveChapter and the 5s outro timer or
    ' fade animation could otherwise still be running underneath the
    ' "Loading next episode..." overlay.
    clearActiveChapter()
    m.video.control = "pause"
    label = ""
    if nextEp.season <> invalid and nextEp.episode <> invalid then
        label = "S" + nextEp.season.ToStr() + "E" + nextEp.episode.ToStr()
        if nextEp.name <> invalid and nextEp.name <> "" then label = label + " - " + nextEp.name
    end if
    m.advanceStatus.text = label
    m.advanceOverlay.visible = true

    ' Always fetch a fresh per-episode server list for the new S/E.
    ' advanceTryNextMirror() will pick the preferred host (if any) first.
    fetchAdvanceServers()
    return true
end function

sub fetchAdvanceServers()
    a = m.top.args
    if a = invalid or m.advance = invalid then return
    m.advanceStatus.text = "Finding mirrors..."
    if m.advanceServersTask <> invalid then m.advanceServersTask.unobserveField("result")
    task = createObject("roSGNode", "ServersTask")
    task.observeField("result", "onAdvanceServersResult")
    task.kind = "tv"
    if a.imdb <> invalid then task.imdb = a.imdb
    if a.tmdb <> invalid then task.tmdb = a.tmdb
    if a.href <> invalid then task.refer = a.href
    task.season = m.advance.ep.season
    task.episode = m.advance.ep.episode
    if m.advance.ep.slug <> invalid then task.slug = m.advance.ep.slug
    m.advanceServersTask = task
    task.control = "RUN"
end sub

sub onAdvanceServersResult()
    if m.advanceServersTask = invalid or m.advance = invalid then return
    res = m.advanceServersTask.result
    if res = invalid or res.mirrors = invalid or res.mirrors.Count() = 0 then
        showAdvanceFailure("No mirrors available for the next episode.")
        return
    end if
    m.advance.mirrors = res.mirrors
    if not advanceTryNextMirror() then
        showAdvanceFailure("All mirrors failed for the next episode.")
    end if
end sub

function advanceTryNextMirror() as Boolean
    if m.advance = invalid or m.advance.mirrors = invalid then return false
    ' First pass: prefer the host the user was already on. Same-host
    ' playback tends to work for every episode of a given show, so this
    ' minimizes the "Resolving..." latency on auto-advance.
    pref = ""
    if m.advance.preferredHost <> invalid then pref = LCase(m.advance.preferredHost)
    if pref <> "" then
        for i = 0 to m.advance.mirrors.Count() - 1
            host = ""
            if m.advance.mirrors[i].host <> invalid then host = m.advance.mirrors[i].host
            if host <> "" and LCase(host) = pref and not m.advance.triedHosts.DoesExist(host) then
                startAdvanceResolve(m.advance.mirrors[i])
                return true
            end if
        end for
    end if
    ' Second pass: any untried mirror.
    for i = 0 to m.advance.mirrors.Count() - 1
        host = ""
        if m.advance.mirrors[i].host <> invalid then host = m.advance.mirrors[i].host
        if host = "" or not m.advance.triedHosts.DoesExist(host) then
            startAdvanceResolve(m.advance.mirrors[i])
            return true
        end if
    end for
    return false
end function

sub startAdvanceResolve(mirror as Object)
    if mirror = invalid or m.advance = invalid then return
    a = m.top.args
    if a = invalid then return
    m.advance.activeMirror = mirror
    if mirror.host <> invalid and mirror.host <> "" then
        m.advance.triedHosts[mirror.host] = true
    end if
    label = "Resolving"
    if mirror.host <> invalid and mirror.host <> "" then label = label + " " + mirror.host
    label = label + "..."
    m.advanceStatus.text = label
    if m.advanceResolveTask <> invalid then m.advanceResolveTask.unobserveField("result")
    task = createObject("roSGNode", "ResolveTask")
    task.observeField("result", "onAdvanceResolveResult")
    task.embedUrl = mirror.link
    if a.href <> invalid then task.refer = a.href
    task.kind = "tv"
    if a.imdb <> invalid then task.imdb = a.imdb
    if a.tmdb <> invalid then task.tmdb = a.tmdb
    task.season = m.advance.ep.season
    task.episode = m.advance.ep.episode
    m.advanceResolveTask = task
    task.control = "RUN"
end sub

sub onAdvanceResolveResult()
    if m.advanceResolveTask = invalid or m.advance = invalid then return
    res = m.advanceResolveTask.result
    if res = invalid or res.url = invalid or res.url = "" then
        if m.advance.activeMirror <> invalid and m.advance.activeMirror.host <> invalid then
            W_RecordMirrorOutcome(m.advance.activeMirror.host, false)
        end if
        if not advanceTryNextMirror() then
            showAdvanceFailure("All mirrors failed for the next episode.")
        end if
        return
    end if
    if m.advance.activeMirror <> invalid and m.advance.activeMirror.host <> invalid then
        W_RecordMirrorOutcome(m.advance.activeMirror.host, true)
    end if
    completeAdvance(res)
end sub

sub completeAdvance(res as Object)
    a = m.top.args
    if a = invalid or m.advance = invalid then return

    nextEp = m.advance.ep
    epDict = {
        slug:    ""
        season:  nextEp.season
        episode: nextEp.episode
        name:    ""
    }
    if nextEp.slug <> invalid then epDict.slug = nextEp.slug
    if nextEp.name <> invalid then epDict.name = nextEp.name

    ' Build a NEW args dict and assign it through the field setter.
    ' SGNode assocarray field reads return a *copy*, not a live
    ' reference, so the previous implementation - which mutated the
    ' local `a` and called onArgs() manually - never propagated the
    ' new url / episode / queueIndex back to m.top.args. onArgs then
    ' read the stale field and replayed the just-finished episode.
    ' Assigning a fresh AA is the same pattern MainScene/MirrorPicker
    ' use for the initial PlayerView args, and it fires the onChange
    ' observer (onArgs) which starts playback against the new stream.
    newArgs = {}
    for each k in a
        newArgs[k] = a[k]
    end for
    newArgs.episode = epDict
    newArgs.episodeQueueIndex = m.advance.queueIdx
    newArgs.startPosition = 0
    newArgs.url = res.url
    newArgs.streamFormat = res.streamFormat
    newArgs.qualities = res.qualities
    newArgs.subtitles = res.subtitles
    referer = ""
    if res.referer <> invalid then referer = res.referer
    userAgent = ""
    if res.userAgent <> invalid then userAgent = res.userAgent
    newArgs.referer = referer
    newArgs.userAgent = userAgent
    if m.advance.activeMirror <> invalid then
        if m.advance.activeMirror.host <> invalid then newArgs.mirrorHost = m.advance.activeMirror.host
        if m.advance.activeMirror.link <> invalid then newArgs.mirrorLink = m.advance.activeMirror.link
        if m.advance.activeMirror.name <> invalid then newArgs.mirrorName = m.advance.activeMirror.name
    end if
    if res.chapters <> invalid then
        newArgs.chapters = res.chapters
    else
        newArgs.chapters = invalid
    end if
    sub2 = "S" + epDict.season.ToStr() + "E" + epDict.episode.ToStr()
    if epDict.name <> "" then sub2 = sub2 + " - " + epDict.name
    newArgs.subtitle = sub2

    print "[Player] advance complete - new episode S"; epDict.season.ToStr(); "E"; epDict.episode.ToStr(); " queueIdx="; newArgs.episodeQueueIndex
    m.advance = invalid
    m.advanceOverlay.visible = false
    m.top.args = newArgs
end sub

sub showAdvanceFailure(msg as String)
    m.advance = invalid
    if m.advanceStatus <> invalid then m.advanceStatus.text = msg
end sub

' Tear down any in-flight advance so a user-driven BACK out of the
' overlay leaves the view in a clean state.
sub cancelAdvance()
    if m.advanceServersTask <> invalid then
        m.advanceServersTask.unobserveField("result")
        m.advanceServersTask.control = "STOP"
        m.advanceServersTask = invalid
    end if
    if m.advanceResolveTask <> invalid then
        m.advanceResolveTask.unobserveField("result")
        m.advanceResolveTask.control = "STOP"
        m.advanceResolveTask = invalid
    end if
    m.advance = invalid
    m.advanceOverlay.visible = false
end sub

sub onVideoPosition()
    posSec = W_AsInt(m.video.position)
    updateSkipBanner(posSec)
    updateNextEpBanner(posSec)
    ' Save the very first heartbeat (so a quick exit still records something),
    ' then throttle to once every 5s while playing.
    if not m.progressSaved then
        saveProgress(false)
        return
    end if
    if Abs(posSec - m.lastSavedPos) >= 5 then saveProgress(false)
end sub

' Show the floating skip prompt when the playhead falls inside a
' chapter the resolver tagged. Chapters never come from us - if
' m.chapters is empty the banner stays permanently hidden.
'
' Behavior per kind:
'   intro / recap: show for 5s then opacity-fade. After the fade the
'     action bar in the overlay still surfaces the skip option until
'     the playhead leaves the window. OK during the visible window
'     skips past the chapter.
'   outro: TV-only and only when there's another queued episode.
'     Shows a 5s countdown bar that auto-advances when the timer
'     fires; OK advances immediately, BACK cancels (lets the user
'     watch the credits) without leaving the chapter. Movies and
'     TV finales never see an outro banner at all.
sub updateSkipBanner(posSec as Integer)
    if m.chapters = invalid or m.chapters.Count() = 0 then
        clearActiveChapter()
        return
    end if
    ' `end` is a BrightScript reserved keyword - `ch.end` evaluates to
    ' invalid even though the parser accepts it, so use bracket access.
    hit = invalid
    for each ch in m.chapters
        cs = W_AsInt(ch.start)
        ce = W_AsInt(ch["end"])
        if posSec >= cs and posSec < ce then
            hit = ch
            exit for
        end if
    end for
    if hit = invalid then
        clearActiveChapter()
        return
    end if
    ' Already inside this exact chapter? Don't restart the timer or
    ' reset the dismissed flag - the position observer fires every
    ' second and we don't want to revive a banner the user already
    ' dismissed via BACK or already saw fade out.
    if m.activeChapter <> invalid and m.activeChapter.start = hit.start and m.activeChapter["end"] = hit["end"] then
        return
    end if

    kind = "intro"
    if hit.kind <> invalid then kind = hit.kind

    a = m.top.args
    isTv = (a <> invalid and a.kind = "tv")
    hasNextEp = false
    if isTv and a.episodeQueue <> invalid and a.episodeQueueIndex <> invalid then
        if a.episodeQueueIndex + 1 < a.episodeQueue.Count() then hasNextEp = true
    end if

    ' Outros only make sense as a "Play Next Episode" prompt - drop
    ' them on movies and on TV finales so the banner doesn't lie to
    ' the user about an action it can't perform.
    if kind = "outro" and (not isTv or not hasNextEp) then
        clearActiveChapter()
        return
    end if

    ' Brand-new chapter window. Tear down any leftover state from a
    ' previous chapter, then bring the banner up fresh.
    m.skipBannerTimer.control = "stop"
    m.skipFadeAnim.control = "stop"
    m.skipCountdownAnim.control = "stop"

    m.activeChapter = hit
    m.activeChapterKind = kind
    m.bannerDismissed = false
    m.skipLabel.text = chapterActionLabel(kind)
    m.skipBanner.opacity = 1.0
    m.skipBanner.visible = true

    if kind = "outro" then
        m.activeChapterIsCountdown = true
        m.skipCountdownFill.width = 0
        m.skipCountdown.visible = true
        m.skipCountdownAnim.control = "start"
        m.skipBannerTimer.control = "start"
    else
        m.activeChapterIsCountdown = false
        m.skipCountdown.visible = false
        m.skipCountdownFill.width = 0
        m.skipBannerTimer.control = "start"
    end if

    ' If the user happens to be in the overlay when a chapter window
    ' opens, surface the skip option in the action bar immediately.
    if m.overlay.visible then rebuildActionBar()
end sub

' Tear down all skip-banner state. Cancels the 5s timer and any
' running fade / countdown animations, hides the banner, and clears
' the active-chapter pointer. Called when the playhead leaves a
' chapter window, when a new chapter takes over, when args reload
' (episode advance), and when performSkip seeks past the window.
sub clearActiveChapter()
    wasInChapter = (m.activeChapter <> invalid)
    m.activeChapter = invalid
    m.activeChapterKind = ""
    m.activeChapterIsCountdown = false
    m.bannerDismissed = false
    if m.skipBanner <> invalid then
        m.skipBanner.visible = false
        m.skipBanner.opacity = 1.0
    end if
    if m.skipCountdown <> invalid then m.skipCountdown.visible = false
    if m.skipCountdownFill <> invalid then m.skipCountdownFill.width = 0
    if m.skipBannerTimer <> invalid then m.skipBannerTimer.control = "stop"
    if m.skipFadeAnim <> invalid then m.skipFadeAnim.control = "stop"
    if m.skipCountdownAnim <> invalid then m.skipCountdownAnim.control = "stop"
    ' If the action bar was showing a skip entry, drop it now.
    if wasInChapter and m.overlay <> invalid and m.overlay.visible then
        rebuildActionBar()
    end if
end sub

' Show the time-based "Skip to Next Episode" floating button when the
' playhead is within 135 s (2 m 15 s) of the end of a TV episode that
' has a queued successor. Independent of chapter data - fires on every
' mirror / host. The floating banner appears once and hides after 10 s;
' the action-bar entry in the overlay persists until the episode ends.
sub updateNextEpBanner(posSec as Integer)
    a = m.top.args
    if a = invalid or a.kind <> "tv" then return
    if a.episodeQueue = invalid or a.episodeQueueIndex = invalid then return
    if a.episodeQueueIndex + 1 >= a.episodeQueue.Count() then return

    dur = W_AsInt(m.video.duration)
    if dur <= 0 then return
    remaining = dur - posSec

    wasActive = m.nextEpActive
    ' Last 5 minutes of the episode: the floating banner shows for 30 s
    ' (nextEpTimer) and the action-bar "Skip to Next Episode" entry stays
    ' available right up to the end.
    m.nextEpActive = (remaining >= 0 and remaining <= 300)

    ' Entering or leaving the window? Re-render the action bar if
    ' the overlay happens to be open so the button appears/vanishes.
    if m.nextEpActive <> wasActive then
        if m.overlay <> invalid and m.overlay.visible then rebuildActionBar()
    end if

    if not m.nextEpActive then return

    ' Show the floating banner exactly once per episode. Suppressed when:
    '   - already shown/timed-out this episode (m.nextEpBannerShown)
    '   - overlay is open (action-bar entry is the UI there)
    '   - an outro chapter is already showing the same "Play Next Episode" prompt
    if m.nextEpBannerShown then return
    if m.overlay <> invalid and m.overlay.visible then return
    if m.activeChapterKind = "outro" then return
    if m.nextEpBanner.visible then return

    m.nextEpBanner.visible = true
    m.nextEpBannerShown = true
    m.nextEpTimer.control = "start"
end sub

' 10-second banner timer fired: hide the floating button.
' m.nextEpActive stays true so the action-bar entry remains.
sub onNextEpTimerFire()
    if m.nextEpBanner <> invalid then m.nextEpBanner.visible = false
end sub

' User confirmed "Skip to Next Episode" - from either the floating
' banner (OK key) or the action-bar button in the overlay.
sub performNextEpSkip()
    if m.nextEpBanner <> invalid then m.nextEpBanner.visible = false
    if m.nextEpTimer <> invalid then m.nextEpTimer.control = "stop"
    m.nextEpActive = false
    m.nextEpBannerShown = true
    if m.overlay <> invalid and m.overlay.visible then hideOverlay()
    saveProgress(true)
    if not tryAutoAdvance() then
        showOverlay()
        m.status.text = "No next episode available."
    end if
end sub

' 5s timer fired. For outros we auto-advance to the next episode;
' for intros / recaps we kick off the 0.5s opacity fade and remember
' that the banner has been dismissed so we don't redraw on a stray
' position tick.
sub onSkipBannerTimerFire()
    if m.activeChapter = invalid then return
    if m.activeChapterIsCountdown then
        performSkip()
    else
        m.bannerDismissed = true
        m.skipFadeAnim.control = "start"
    end if
end sub

' Map a chapter kind to the label text shown both on the floating
' banner and on the action bar entry. Empty string means "don't
' surface a button at all" - used for unrecognized kinds.
function chapterActionLabel(kind as String) as String
    if kind = "outro" then return "Play Next Episode"
    if kind = "recap" then return "Skip Recap"
    if kind = "intro" then return "Skip Intro"
    return "Skip Intro"
end function

' Rebuild the action bar's button list, optionally prepending a skip
' entry when the playhead is currently in a chapter window. Called
' on init, every time the overlay opens, and whenever the active
' chapter changes while the overlay is already up.
sub rebuildActionBar()
    if m.actionBar = invalid or m.baseActionLabels = invalid then return
    prevLabels = m.actionBar.buttons
    prevFocused = m.actionBar.buttonFocused
    prevLabel = ""
    if prevLabels <> invalid and prevFocused <> invalid and prevFocused >= 0 and prevFocused < prevLabels.Count() then
        prevLabel = prevLabels[prevFocused]
    end if

    labels = []
    if m.activeChapter <> invalid then
        skipLabel = chapterActionLabel(m.activeChapterKind)
        if skipLabel <> "" then labels.Push(skipLabel)
    end if
    ' Time-based next-ep button. Omit when an outro chapter is already
    ' offering "Play Next Episode" to avoid a duplicate entry.
    if m.nextEpActive and m.activeChapterKind <> "outro" then
        labels.Push("Skip to Next Episode")
    end if
    for each l in m.baseActionLabels
        labels.Push(l)
    end for
    m.actionBar.buttons = labels

    ' Re-anchor focus on the same label if it survived the rebuild,
    ' otherwise let ButtonGroup default to index 0.
    if prevLabel <> "" then
        for i = 0 to labels.Count() - 1
            if labels[i] = prevLabel then
                m.actionBar.focusButton = i
                exit for
            end if
        end for
    end if
end sub

' Perform the skip the banner advertised. For TV outros we try to
' auto-advance to the next episode (mirrors the existing finished-state
' path); everything else just seeks past the chapter window.
sub performSkip()
    ch = m.activeChapter
    if ch = invalid then return
    target = W_AsInt(ch["end"])
    a = m.top.args
    isTvOutro = false
    if ch.kind <> invalid and ch.kind = "outro" then
        if a <> invalid and a.kind = "tv" and a.episodeQueue <> invalid then
            isTvOutro = true
        end if
    end if
    clearActiveChapter()
    if isTvOutro then
        ' Mark current episode finished and jump to the next one.
        saveProgress(true)
        if tryAutoAdvance() then return
    end if
    if target > 0 then m.video.seek = target
end sub

' Persist the current position to the watchlist registry. forceFinished is
' used when the stream's own "finished" state fires - some live-ish HLS
' manifests stop short of `duration`, so we trust the player there.
sub saveProgress(forceFinished as Boolean)
    a = m.top.args
    if a = invalid then return
    posSec = W_AsInt(m.video.position)
    dur = W_AsInt(m.video.duration)
    if forceFinished and dur > 0 then posSec = dur
    if posSec <= 0 and not forceFinished then return

    m.lastSavedPos = posSec
    m.progressSaved = true

    imdb = ""
    if a.imdb <> invalid then imdb = a.imdb
    href = ""
    if a.href <> invalid then href = a.href
    kind = ""
    if a.kind <> invalid then kind = a.kind
    title = ""
    if a.title <> invalid then title = a.title
    poster = ""
    if a.poster <> invalid then poster = a.poster
    tmdb = ""
    if a.tmdb <> invalid then tmdb = a.tmdb
    ' Stash a tile-friendly snapshot once per playback session so the
    ' Continue Watching row can render without re-fetching details.
    ' mirrorHost/Link/Name come from MirrorPicker so the ResumePicker
    ' can offer "Resume on <host>" without re-fetching servers.
    itemKey = W_ItemKey(imdb, href)
    if itemKey <> "" then
        ctx = {
            title:  title
            poster: poster
            href:   href
            imdb:   imdb
            tmdb:   tmdb
            kind:   kind
        }
        if a.mirrorHost <> invalid and a.mirrorHost <> "" then ctx.mirrorHost = a.mirrorHost
        if a.mirrorLink <> invalid and a.mirrorLink <> "" then ctx.mirrorLink = a.mirrorLink
        if a.mirrorName <> invalid and a.mirrorName <> "" then ctx.mirrorName = a.mirrorName
        W_RememberContext(itemKey, ctx)
    end if
    if kind = "tv" and a.episode <> invalid then
        slug = ""
        if a.episode.slug <> invalid then slug = a.episode.slug
        name = ""
        if a.episode.name <> invalid then name = a.episode.name
        ' Final-episode hint for Watchlist's series-completion logic.
        ' DetailsView builds episodeQueue with every episode of every
        ' season in show order; the last entry is the season finale of
        ' the last broadcast season. ResumePicker -> MirrorPicker path
        ' doesn't carry episodeQueue, so we fall back to 0 and the
        ' Watchlist preserves whatever lastSeason/lastEpisode an earlier
        ' DetailsView save populated.
        lastSeason = 0
        lastEpisode = 0
        if a.episodeQueue <> invalid and a.episodeQueue.Count() > 0 then
            finalEntry = a.episodeQueue[a.episodeQueue.Count() - 1]
            if finalEntry <> invalid then
                if finalEntry.season <> invalid then lastSeason = W_AsInt(finalEntry.season)
                if finalEntry.episode <> invalid then lastEpisode = W_AsInt(finalEntry.episode)
            end if
        end if
        W_SaveEpisodeProgress(imdb, href, a.episode.season, a.episode.episode, posSec, dur, slug, name, lastSeason, lastEpisode)
    else
        W_SaveMovieProgress(imdb, href, posSec, dur)
    end if
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
    ' Refresh the action-bar button list so a Skip Intro / Play Next
    ' Episode entry is present whenever the playhead is in a chapter
    ' window. This is what surfaces the skip option after the
    ' floating banner has faded out.
    rebuildActionBar()
    ' Banner would peek through the translucent overlay backdrop and
    ' look broken; hide it while the overlay is up. We also stop the
    ' 5s timer and animations so they don't fire underneath the
    ' overlay - the chapter is still active (m.activeChapter stays
    ' set), the user just isn't going to see the floating prompt.
    m.skipBanner.visible = false
    m.skipBannerTimer.control = "stop"
    m.skipFadeAnim.control = "stop"
    m.skipCountdownAnim.control = "stop"
    ' Same for the time-based next-ep banner. Stop its timer too so it
    ' doesn't fire while the overlay is up; treat opening the overlay as
    ' "banner shown" so the floating button doesn't reappear on close.
    if m.nextEpBanner <> invalid then m.nextEpBanner.visible = false
    if m.nextEpTimer <> invalid then
        m.nextEpTimer.control = "stop"
        m.nextEpBannerShown = true
    end if
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
    ' Don't auto-resurrect the banner here. If the user dismissed the
    ' overlay while in a chapter window the action bar already had
    ' the skip option; respawning a floating banner on every overlay
    ' close would feel like nagging. The next time the playhead
    ' enters a *new* chapter window updateSkipBanner will fire fresh.
end sub

sub onActionBar()
    idx = m.actionBar.buttonSelected
    if idx = invalid then return
    btns = m.actionBar.buttons
    if btns = invalid or idx < 0 or idx >= btns.Count() then return
    label = btns[idx]
    ' Skip-style entries only appear while a chapter is active; clicking
    ' them performs the same action as OK on the floating banner.
    if label = "Skip Intro" or label = "Skip Recap" or label = "Play Next Episode" then
        hideOverlay()
        performSkip()
        return
    end if
    if label = "Skip to Next Episode" then
        performNextEpSkip()
        return
    end if
    if label = "Resume" then
        onResume()
    else if label = "Quality" then
        openPanel("quality")
    else if label = "Subtitles" then
        openPanel("cc")
    else if label = "CC Settings" then
        openPanel("ccStyle")
    else if label = "Audio" then
        openPanel("audio")
    else if label = "Stop" then
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
    saveProgress(false)
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

' Map the Default Video Quality preference to a variant index, or -1 to
' use the master playlist (ABR). Variants carry a per-rendition URL and a
' height; we cap on height for 1080/720 and fall back to the lowest with
' a URL when nothing fits.
function pickPreferredQualityIndex(pref as String) as Integer
    if m.qualities = invalid or m.qualities.Count() = 0 then return -1
    bestIdx = -1 : bestH = -1
    lowIdx = -1 : lowH = 999999
    capIdx = -1 : capH = -1
    cap = 100000
    if pref = "1080" then cap = 1080
    if pref = "720" then cap = 720
    for i = 0 to m.qualities.Count() - 1
        q = m.qualities[i]
        if q.url <> invalid and q.url <> "" then
            h = 0
            if q.height <> invalid then h = W_AsInt(q.height)
            if h > bestH then bestH = h : bestIdx = i
            if h < lowH then lowH = h : lowIdx = i
            if h <= cap and h > capH then capH = h : capIdx = i
        end if
    end for
    if pref = "saver" then return lowIdx
    if pref = "1080" or pref = "720" then
        if capIdx >= 0 then return capIdx
        return lowIdx
    end if
    ' "best" (default)
    return bestIdx
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

' Pick a default-on subtitle track. Prefer a plain "English" (ISO code
' "en" with no SDH marker), then any English-coded track regardless of
' label, then any track whose name starts with / contains "english"
' (case-insensitive) for sources that left the language field blank.
' Returns -1 when no English track is found, leaving subtitles off.
function pickDefaultSubtitle(subs as Object) as Integer
    if subs = invalid or subs.Count() = 0 then return -1
    plainEn = -1
    anyEn = -1
    nameEn = -1
    for i = 0 to subs.Count() - 1
        s = subs[i]
        if s = invalid then continue for
        lang = ""
        if s.language <> invalid then lang = LCase(s.language)
        nm = ""
        if s.name <> invalid then nm = LCase(s.name)
        ' Skip hearing-impaired / SDH / CC variants when a vanilla
        ' English track is available; users with the SDH preference can
        ' switch to it from the chip list.
        isSdh = Instr(1, nm, "sdh") > 0 or Instr(1, nm, "hearing") > 0 or Instr(1, nm, "[cc]") > 0
        isEn = (lang = "en" or lang = "eng" or Left(lang, 3) = "en-")
        if not isEn and Len(nm) > 0 then
            ' Catch labels like "English", "English - SDH", "ENGLISH",
            ' "english - eng(5)" when the language field was blank.
            if Left(nm, 7) = "english" or Instr(1, nm, "english") > 0 then isEn = true
        end if
        if isEn then
            if anyEn = -1 then anyEn = i
            if not isSdh and plainEn = -1 then plainEn = i
        else if Len(nm) > 0 and nameEn = -1 then
            ' Defensive: if neither code nor "english" matched but the
            ' name happens to start with "en" (rare - some sources
            ' truncate). Keep this as the very last fallback.
            if Left(nm, 2) = "en" then nameEn = i
        end if
    end for
    if plainEn >= 0 then return plainEn
    if anyEn >= 0 then return anyEn
    if nameEn >= 0 then return nameEn
    return -1
end function

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
        applySubtitleSelection()
        m.status.text = "Subtitles off"
        return
    end if
    sIdx = idx - 1
    if sIdx < 0 or sIdx >= m.subtitles.Count() then return
    sub_ = m.subtitles[sIdx]
    m.activeSubtitle = sIdx
    applySubtitleSelection()
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
    ' Subtitle sync offset (not a stored style - applies to custom cues).
    if idx = 9 then
        m.subOffset = m.subOffset + 0.25
        m.curCueText = ""
        m.status.text = "Subtitle sync: " + Str(m.subOffset) + "s"
        return
    end if
    if idx = 10 then
        m.subOffset = m.subOffset - 0.25
        m.curCueText = ""
        m.status.text = "Subtitle sync: " + Str(m.subOffset) + "s"
        return
    end if
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

' Apply the user's caption style (size / color / background) to the custom
' caption Label+box. This is what makes the CC Settings actually do
' something - native subtitleTrack styling is system-controlled on Roku.
sub applyCcGlobal()
    if m.capLabel = invalid then return
    reg = CreateObject("roRegistrySection", "HydraHD")
    sz = "medium"
    if reg.Exists("ccTextSize") then sz = reg.Read("ccTextSize")
    if sz = "small" then
        m.capLabel.font = "font:MediumBoldSystemFont"
    else
        ' medium / large both use the largest system preset (Roku has no
        ' larger built-in bold preset without bundling a TTF).
        m.capLabel.font = "font:LargeBoldSystemFont"
    end if
    color = "0xffffffff"
    if reg.Exists("ccTextColor") then color = reg.Read("ccTextColor") + "ff"
    m.capLabel.color = color

    bgHex = "000000"
    if reg.Exists("ccBgColor") then bgHex = Mid(reg.Read("ccBgColor"), 3)
    bgOp = 67
    if reg.Exists("ccBgOpacity") then bgOp = reg.Read("ccBgOpacity").ToInt()
    a = Cint(bgOp * 255 / 100)
    if a > 255 then a = 255
    if a < 0 then a = 0
    aHex = StrI(a, 16).Trim()
    if Len(aHex) = 1 then aHex = "0" + aHex
    if m.capBg <> invalid then m.capBg.color = "0x" + bgHex + aHex
end sub

' Load + parse the selected subtitle into timed cues for custom rendering.
' Native subtitleTrack stays set as a fallback until cues arrive.
sub loadCustomSubtitle(url as String)
    if url = invalid or url = "" then return
    if m.subTask <> invalid then m.subTask.unobserveField("cues")
    m.subTask = createObject("roSGNode", "SubtitleTask")
    if m.subTask = invalid then return
    m.subTask.observeField("cues", "onSubCues")
    m.subTask.referer = m.streamReferer
    m.subTask.url = url
    m.subTask.control = "RUN"
end sub

sub onSubCues()
    cues = m.subTask.cues
    if cues = invalid then cues = []
    m.cues = cues
    if m.cues.Count() > 0 then
        ' Custom rendering: keep native captions fully OFF so they don't
        ' double up with our overlay.
        m.video.globalCaptionMode = "Off"
        m.video.subtitleTrack = ""
        m.curCueText = ""
        if m.video.state = "playing" and m.capTimer <> invalid then m.capTimer.control = "start"
    else
        ' Parse failed - fall back to Roku's native captions for this track.
        if m.activeSubtitle >= 0 and m.activeSubtitle < m.subtitles.Count() then
            m.video.subtitleTrack = m.subtitles[m.activeSubtitle].url
            m.video.globalCaptionMode = "On"
        end if
    end if
end sub

' Apply the current m.activeSubtitle selection: load custom cues (with
' native as the immediate fallback), or clear everything when off.
sub applySubtitleSelection()
    if m.activeSubtitle < 0 or m.activeSubtitle >= m.subtitles.Count() then
        ' Off: clear custom cues AND native captions.
        m.cues = []
        m.curCueText = ""
        m.video.subtitleTrack = ""
        m.video.globalCaptionMode = "Off"
        if m.capTimer <> invalid then m.capTimer.control = "stop"
        if m.capBox <> invalid then m.capBox.visible = false
        return
    end if
    url = m.subtitles[m.activeSubtitle].url
    ' Custom mode: native off; the parsed cues drive our overlay. (onSubCues
    ' turns native back on only if the file fails to parse.)
    m.video.subtitleTrack = ""
    m.video.globalCaptionMode = "Off"
    m.cues = []
    m.curCueText = ""
    if m.capBox <> invalid then m.capBox.visible = false
    loadCustomSubtitle(url)
end sub

' Tick: show the cue covering the current playhead (+ user sync offset),
' resizing the background box to hug the text. Hidden while the options
' overlay is open or when there's no active cue.
sub onCapTick()
    if m.capBox = invalid then return
    if m.cues = invalid or m.cues.Count() = 0 or m.overlay.visible then
        m.capBox.visible = false
        return
    end if
    tsec = m.video.position + m.subOffset
    text = ""
    for each c in m.cues
        if tsec >= c.s and tsec <= c.e then
            text = c.text
            exit for
        end if
    end for
    if text = m.curCueText then return
    m.curCueText = text
    if text = "" then
        m.capBox.visible = false
        return
    end if
    m.capLabel.text = text
    ' Resize the bg to hug the rendered text.
    rect = m.capLabel.boundingRect()
    if rect <> invalid and rect.width > 0 then
        w = rect.width + 48
        if w > 1600 then w = 1600
        h = rect.height + 18
        m.capBg.width = w
        m.capBg.height = h
        m.capBg.translation = [(1920 - w) / 2, (96 - h) / 2]
    end if
    m.capBox.visible = true
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    ' Advance overlay swallows all input until it succeeds, the user
    ' BACKs out, or one of its subtasks fails. OK during a failure
    ' message dismisses the overlay so the user can continue.
    if m.advanceOverlay <> invalid and m.advanceOverlay.visible then
        if key = "back" then
            cancelAdvance()
            saveProgress(false)
            m.video.control = "stop"
            m.top.requestNav = { action: "back" }
            return true
        end if
        if key = "OK" and m.advance = invalid then
            ' We got here on a failure (advance state torn down already);
            ' OK leaves the player so the user can pick another mirror /
            ' episode manually.
            m.advanceOverlay.visible = false
            saveProgress(false)
            m.video.control = "stop"
            m.top.requestNav = { action: "back" }
            return true
        end if
        return true
    end if
    ' Time-based next-ep banner: OK fires the skip immediately.
    ' BACK is not intercepted here so it still exits the player normally.
    if m.nextEpBanner <> invalid and m.nextEpBanner.visible and not m.overlay.visible then
        if key = "OK" then
            performNextEpSkip()
            return true
        end if
    end if
    ' Outro countdown: BACK lets the user finish the credits (cancels
    ' the auto-advance, hides the banner, but keeps the chapter
    ' active so the action-bar entry still works); OK advances
    ' immediately. Both bypass the regular OK / BACK paths.
    if m.activeChapterIsCountdown and not m.overlay.visible then
        if key = "back" then
            m.skipBanner.visible = false
            m.skipBanner.opacity = 1.0
            m.skipCountdown.visible = false
            m.skipBannerTimer.control = "stop"
            m.skipFadeAnim.control = "stop"
            m.skipCountdownAnim.control = "stop"
            m.activeChapterIsCountdown = false
            m.bannerDismissed = true
            return true
        end if
        if key = "OK" then
            performSkip()
            return true
        end if
    end if
    if key = "OK" or key = "options" then
        ' If the resolver gave us a chapter window and we're inside it,
        ' OK fires the skip instead of opening the overlay. Banner is
        ' only visible when there's a real chapter to skip, so this
        ' path stays dormant for streams without chapter data.
        if m.skipBanner.visible and m.activeChapter <> invalid and not m.overlay.visible then
            performSkip()
            return true
        end if
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
        saveProgress(false)
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
            btns = m.actionBar.buttons
            if fi = invalid then fi = 0
            if btns <> invalid and fi >= 0 and fi < btns.Count() then
                label = btns[fi]
                if label = "Quality" then
                    openPanel("quality")
                    return true
                else if label = "Subtitles" then
                    openPanel("cc")
                    return true
                else if label = "CC Settings" then
                    openPanel("ccStyle")
                    return true
                else if label = "Audio" then
                    openPanel("audio")
                    return true
                end if
            end if
        end if
        if not m.overlay.visible then
            showOverlay()
            return true
        end if
    end if
    return false
end function

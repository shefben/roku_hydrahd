' ResumePicker.brs - Continue Watching landing pad.
'
' Continue Watching tiles route here instead of jumping straight into
' playback so the user can pick whether to resume on the previously
' used mirror, switch mirrors, or jump back to the season/episode
' picker. The "fast" path (resume on previous mirror) hands the saved
' embed URL to MirrorPicker via args.directMirror, which skips the
' server-list fetch entirely and goes straight to ResolveTask.

sub init()
    m.title = m.top.findNode("title")
    m.subtitle = m.top.findNode("subtitle")
    m.resumeAt = m.top.findNode("resumeAt")
    m.status = m.top.findNode("status")
    m.poster = m.top.findNode("poster")
    m.actions = m.top.findNode("actions")
    m.actions.observeField("buttonSelected", "onActionSelected")
    m.actions.setFocus(true)

    ' MainScene.focusActiveChild lands focus on this Group's root after
    ' a nav round-trip. Bounce it down to the ButtonGroup so arrows
    ' aren't dead.
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.actions <> invalid then m.actions.setFocus(true)
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return

    titleStr = ""
    if a.title <> invalid then titleStr = a.title
    m.title.text = titleStr

    sub2 = ""
    if a.kind = "tv" and a.episode <> invalid then
        sub2 = "S" + a.episode.season.ToStr() + "E" + a.episode.episode.ToStr()
        if a.episode.name <> invalid and a.episode.name <> "" then
            sub2 = sub2 + " - " + a.episode.name
        end if
    else
        sub2 = "Movie"
    end if
    m.subtitle.text = sub2

    posSec = 0
    if a.startPosition <> invalid then posSec = W_AsInt(a.startPosition)
    if posSec > 0 then
        m.resumeAt.text = "Picks up at " + W_FormatTime(posSec)
    else
        m.resumeAt.text = ""
    end if

    if a.poster <> invalid and a.poster <> "" then m.poster.uri = a.poster

    ' We track the dispatch action per visible button so we don't have
    ' to reverse-engineer the index later (Save / Saved logic in
    ' DetailsView showed how brittle that gets when the visible set
    ' changes).
    btns = []
    m.actionMap = []
    hasMirror = (a.mirrorLink <> invalid and a.mirrorLink <> "")
    if hasMirror then
        host = ""
        if a.mirrorHost <> invalid then host = a.mirrorHost
        if host = "" and a.mirrorName <> invalid then host = a.mirrorName
        label = "Resume on previous mirror"
        if host <> "" then label = "Resume on " + host
        btns.Push(label)
        m.actionMap.Push("resumeSame")
    end if
    btns.Push("Choose a different mirror")
    m.actionMap.Push("pickMirror")
    if a.kind = "tv" then
        btns.Push("Pick a different episode or season")
        m.actionMap.Push("pickEpisode")
    end if
    btns.Push("Cancel")
    m.actionMap.Push("cancel")

    m.actions.buttons = btns
    m.actions.setFocus(true)
    m.actions.focusButton = 0
end sub

sub onActionSelected()
    idx = m.actions.buttonSelected
    if idx = invalid then return
    if m.actionMap = invalid or idx < 0 or idx >= m.actionMap.Count() then return
    a = m.top.args
    if a = invalid then return
    action = m.actionMap[idx]

    if action = "resumeSame" then
        m.top.requestNav = {
            action: "replace"
            view: "MirrorPicker"
            args: buildMirrorArgs(a, true)
        }
        return
    end if
    if action = "pickMirror" then
        m.top.requestNav = {
            action: "replace"
            view: "MirrorPicker"
            args: buildMirrorArgs(a, false)
        }
        return
    end if
    if action = "pickEpisode" then
        m.top.requestNav = {
            action: "replace"
            view: "DetailsView"
            args: buildDetailsArgs(a)
        }
        return
    end if
    ' Cancel - bubble back to the previous screen.
    m.top.requestNav = { action: "back" }
end sub

' BACK is handled globally by MainScene (popView), so we don't need
' our own onKeyEvent override here. ButtonGroup naturally bubbles
' BACK presses to the parent.

function buildMirrorArgs(a as Object, useDirect as Boolean) as Object
    out = {
        kind:   a.kind
        title:  a.title
        poster: a.poster
        imdb:   a.imdb
        tmdb:   a.tmdb
        href:   a.href
    }
    if a.episode <> invalid then out.episode = a.episode
    if a.startPosition <> invalid then out.startPosition = a.startPosition
    if useDirect then
        host = ""
        link = ""
        name = ""
        if a.mirrorHost <> invalid then host = a.mirrorHost
        if a.mirrorLink <> invalid then link = a.mirrorLink
        if a.mirrorName <> invalid then name = a.mirrorName
        out.directMirror = { host: host, link: link, name: name }
    end if
    return out
end function

function buildDetailsArgs(a as Object) as Object
    out = {
        kind:   a.kind
        href:   a.href
        imdb:   a.imdb
        tmdb:   a.tmdb
        title:  a.title
        poster: a.poster
    }
    return out
end function

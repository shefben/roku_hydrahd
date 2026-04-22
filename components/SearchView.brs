' SearchView.brs - On-screen keyboard + grid of results.

sub init()
    m.items = []
    m.lastQuery = ""

    m.kb = m.top.findNode("kb")
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.searchBtn = m.top.findNode("searchBtn")
    m.resultTitle = m.top.findNode("resultTitle")
    m.kb.text = ""
    m.grid.itemComponentName = "PosterItem"
    m.searchBtn.observeField("buttonSelected", "onSearchClick")
    m.kb.observeField("text", "onTextChange")
    m.grid.observeField("itemSelected", "onItemSelected")
    m.timer = createObject("roSGNode", "Timer")
    m.timer.duration = 0.6
    m.timer.repeat = false
    m.timer.observeField("fire", "onDebounce")

    ' MainScene.focusActiveChild() runs *after* this init returns and calls
    ' setFocus(true) on the SearchView root Group, which would yank focus
    ' off the keyboard and leave the user with arrow keys that do nothing.
    ' Defer the keyboard focus by one event-loop tick so it sticks.
    m.focusTimer = createObject("roSGNode", "Timer")
    m.focusTimer.duration = 0.05
    m.focusTimer.repeat = false
    m.focusTimer.observeField("fire", "grabKeyboardFocus")
    m.focusTimer.control = "start"
end sub

sub grabKeyboardFocus()
    m.kb.setFocus(true)
end sub

sub onTextChange()
    txt = m.kb.text
    if txt = invalid or Len(txt) < 2 then
        m.empty.visible = false
        m.grid.content = invalid
        return
    end if
    m.timer.control = "stop"
    m.timer.control = "start"
end sub

sub onDebounce()
    runQuery()
end sub

sub onSearchClick()
    runQuery()
end sub

sub runQuery()
    q = U_Trim(m.kb.text)
    if Len(q) < 2 then return
    if q = m.lastQuery then return
    m.lastQuery = q
    m.top.loading = true
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "SearchTask")
    m.task.observeField("result", "onResult")
    m.task.query = q
    m.task.control = "RUN"
end sub

sub onResult()
    r = m.task.result
    m.top.loading = false
    if r = invalid or r.items = invalid or r.items.Count() = 0 then
        m.empty.text = "No results for: " + Chr(34) + m.lastQuery + Chr(34)
        m.empty.visible = true
        m.grid.content = invalid
        return
    end if
    m.empty.visible = false
    m.items = r.items
    root = createObject("roSGNode", "ContentNode")
    for each item in m.items
        cell = root.createChild("ContentNode")
        cell.title = item.title
        cell.HDPosterUrl = item.poster
        cell.SDPosterUrl = item.poster
        cell.shortDescriptionLine1 = item.rating
        cell.shortDescriptionLine2 = item.year
        cell.releaseDate = item.quality
        cell.id = item.id
        cell.contentType = item.kind
        cell.url = item.href
    end for
    m.grid.content = root
    m.resultTitle.text = m.items.Count().ToStr() + " results"
end sub

sub onItemSelected()
    idx = m.grid.itemSelected
    if idx = invalid or m.items = invalid then return
    if idx < 0 or idx >= m.items.Count() then return
    item = m.items[idx]
    m.top.requestNav = {
        action: "open"
        view: "DetailsView"
        args: {
            kind: item.kind
            id: item.id
            href: item.href
            title: item.title
            poster: item.poster
        }
    }
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    ' Safety net: if focus somehow ends up on the root Group (e.g. focus
    ' race during view push) any directional key should land on the
    ' keyboard so the user is never stranded with dead arrows.
    if not m.kb.hasFocus() and not m.searchBtn.hasFocus() and not m.grid.hasFocus() then
        if key = "up" or key = "down" or key = "left" or key = "right" or key = "OK" then
            m.kb.setFocus(true)
            return true
        end if
    end if
    if key = "down" and m.kb.hasFocus() then
        m.searchBtn.setFocus(true)
        return true
    end if
    if key = "up" and m.searchBtn.hasFocus() then
        ' Without this the user gets stuck on the Search button - up would
        ' otherwise bubble out to MainScene and steal focus to the nav bar.
        m.kb.setFocus(true)
        return true
    end if
    if key = "right" and (m.kb.hasFocus() or m.searchBtn.hasFocus()) then
        if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
            m.grid.setFocus(true)
            return true
        end if
    end if
    if key = "left" and m.grid.hasFocus() then
        m.kb.setFocus(true)
        return true
    end if
    return false
end function

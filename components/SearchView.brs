' SearchView.brs - On-screen keyboard + grid of results, with a row of
' recent-query chips above the keyboard.

sub init()
    m.items = []
    m.lastQuery = ""
    m.resultsMode = false
    ' Set true by onSearchClick / onChipPressed before runQuery, then
    ' consumed in onResult. Tells onResult whether the user committed
    ' to a search (we should jump to the grid) vs. typed and paused
    ' (we keep focus on the keyboard unless the on-screen query exactly
    ' matches the query that just returned).
    m.autoFocusOnResult = false

    m.kb = m.top.findNode("kb")
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.searchBtn = m.top.findNode("searchBtn")
    m.resultTitle = m.top.findNode("resultTitle")
    m.layoutWrap = m.top.findNode("layoutWrap")
    m.slideAnim = m.top.findNode("slideAnim")
    m.slideInterp = m.top.findNode("slideInterp")
    m.chipsLabel = m.top.findNode("chipsLabel")
    m.chipsRow = m.top.findNode("chipsRow")
    m.chipClear = m.top.findNode("chipClear")

    m.kb.text = ""
    m.grid.itemComponentName = "PosterItem"
    m.searchBtn.observeField("buttonSelected", "onSearchClick")
    m.kb.observeField("text", "onTextChange")
    m.grid.observeField("itemSelected", "onItemSelected")
    m.timer = createObject("roSGNode", "Timer")
    m.timer.duration = 0.6
    m.timer.repeat = false
    m.timer.observeField("fire", "onDebounce")

    ' Idle timer: when the user stops typing for 1.5s and results
    ' exist, auto-focus the grid. This is the reliable kb->grid
    ' transition - relying on the Roku Keyboard widget to bubble DOWN
    ' or RIGHT at its edges is unreliable across firmware. The timer
    ' fires only after typing pauses, so it never yanks focus mid-type.
    m.idleTimer = createObject("roSGNode", "Timer")
    m.idleTimer.duration = 1.5
    m.idleTimer.repeat = false
    m.idleTimer.observeField("fire", "onIdleFire")

    m.maxChips = 6
    m.chipNodes = []
    for i = 0 to m.maxChips - 1
        node = m.top.findNode("chip" + i.ToStr())
        m.chipNodes.Push(node)
        node.observeField("buttonSelected", "onChipPressed")
    end for
    m.chipClear.observeField("buttonSelected", "onChipsClear")
    renderChips()

    ' MainScene.focusActiveChild() runs *after* this init returns and calls
    ' setFocus(true) on the SearchView root Group, which would yank focus
    ' off the keyboard and leave the user with arrow keys that do nothing.
    ' Defer the keyboard focus by one event-loop tick so it sticks.
    m.focusTimer = createObject("roSGNode", "Timer")
    m.focusTimer.duration = 0.05
    m.focusTimer.repeat = false
    m.focusTimer.observeField("fire", "grabKeyboardFocus")
    m.focusTimer.control = "start"
    ' Same focus-redirect pattern as the other views: when MainScene
    ' re-focuses the SearchView root (e.g. after returning from the
    ' top nav) we bounce focus down so arrows actually do something.
    ' If results are visible we land on the grid; otherwise the
    ' keyboard.
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.resultsMode and m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
        m.grid.setFocus(true)
    else
        m.kb.setFocus(true)
    end if
end sub

sub grabKeyboardFocus()
    m.kb.setFocus(true)
end sub

sub showResults()
    if m.resultsMode then return
    m.resultsMode = true
    m.slideAnim.control = "stop"
    m.slideInterp.keyValue = [[0, 0], [-450, 0]]
    m.slideAnim.control = "start"
end sub

sub showKeyboard()
    if not m.resultsMode then return
    m.resultsMode = false
    m.slideAnim.control = "stop"
    m.slideInterp.keyValue = [[-450, 0], [0, 0]]
    m.slideAnim.control = "start"
end sub

sub onTextChange()
    txt = m.kb.text
    ' Reset the idle timer on every keypress so it only fires after
    ' the user actually pauses.
    m.idleTimer.control = "stop"
    if txt = invalid or Len(txt) < 2 then
        m.empty.visible = false
        m.grid.content = invalid
        return
    end if
    m.timer.control = "stop"
    m.timer.control = "start"
    m.idleTimer.control = "start"
end sub

sub onIdleFire()
    ' User stopped typing for 1.5s. If results have arrived and they
    ' are still on the keyboard, hand them off to the grid. This is
    ' the *only* reliable way to escape the Roku Keyboard widget,
    ' which absorbs RIGHT internally and may not bubble DOWN on every
    ' firmware. Skip if focus has already moved (chips, search btn,
    ' grid) - we don't yank the user.
    if not m.kb.hasFocus() then return
    if m.grid.content = invalid then return
    if m.grid.content.getChildCount() = 0 then return
    m.grid.jumpToItem = 0
    m.grid.setFocus(true)
    showResults()
end sub

sub onDebounce()
    ' Debounced (auto) search - keep focus on the keyboard unless the
    ' user has fully paused typing.
    runQuery()
end sub

sub onSearchClick()
    ' Explicit Search button press - the user expects to land on the
    ' results, even if the query already ran on debounce. If runQuery
    ' is a no-op (same query) the existing grid is still good; just
    ' move focus there.
    m.autoFocusOnResult = true
    runQuery()
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
        m.autoFocusOnResult = false
        m.grid.jumpToItem = 0
        m.grid.setFocus(true)
        showResults()
    end if
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
        m.resultTitle.visible = false
        m.autoFocusOnResult = false
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
        U_SetCellKind(cell, item.kind)
        cell.url = item.href
        U_SetCellPct(cell, W_GetProgressPct("", item.href, 0, 0))
    end for
    m.grid.content = root
    m.resultTitle.text = m.items.Count().ToStr() + " results"
    m.resultTitle.visible = true
    ' Now that the user got real results, remember the query and
    ' refresh the chip row so it's there next time they come back.
    W_PushSearchQuery(m.lastQuery)
    renderChips()
    ' Only auto-focus the grid when the user has *explicitly* committed
    ' to a search (Search button or chip). Debounced background results
    ' arriving while the user is still typing must NEVER yank focus -
    ' that was the bug where pressing one key suddenly sent the next
    ' keypress to a poster. The user moves to the grid via DOWN-from-kb
    ' (handled in onKeyEvent) when they're ready.
    if m.autoFocusOnResult then
        m.autoFocusOnResult = false
        m.grid.jumpToItem = 0
        m.grid.setFocus(true)
        showResults()
    end if
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

' --- Recent-query chips --------------------------------------------------

sub renderChips()
    history = W_GetSearchHistory()
    if history = invalid then history = []
    visibleCount = history.Count()
    if visibleCount > m.maxChips then visibleCount = m.maxChips
    for i = 0 to m.maxChips - 1
        node = m.chipNodes[i]
        if i < visibleCount then
            node.text = history[i]
            node.visible = true
        else
            node.text = ""
            node.visible = false
        end if
    end for
    show = (visibleCount > 0)
    m.chipsLabel.visible = show
    m.chipsRow.visible = show
    m.chipClear.visible = show
end sub

sub onChipPressed(event as Object)
    sender = event.getRoSGNode()
    if sender = invalid then return
    q = sender.text
    if q = invalid or q = "" then return
    m.kb.text = q
    m.lastQuery = ""
    m.autoFocusOnResult = true
    runQuery()
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
        m.grid.setFocus(true)
        showResults()
    else
        m.kb.setFocus(true)
    end if
end sub

sub onChipsClear()
    W_ClearSearchHistory()
    renderChips()
    ' Drop focus back to keyboard since the chip the user was on just
    ' disappeared - never leave them stranded.
    m.kb.setFocus(true)
end sub

' --- Focus / remote navigation -------------------------------------------

function chipsHaveFocus() as Boolean
    if m.chipClear.hasFocus() then return true
    for each node in m.chipNodes
        if node.hasFocus() then return true
    end for
    return false
end function

function focusFirstVisibleChip() as Boolean
    if not m.chipsRow.visible then return false
    for each node in m.chipNodes
        if node.visible then
            node.setFocus(true)
            return true
        end if
    end for
    if m.chipClear.visible then
        m.chipClear.setFocus(true)
        return true
    end if
    return false
end function

function chipNeighbor(delta as Integer) as Object
    ' Build the in-order list of currently-focusable chip buttons.
    seq = []
    for each node in m.chipNodes
        if node.visible then seq.Push(node)
    end for
    if m.chipClear.visible then seq.Push(m.chipClear)
    if seq.Count() = 0 then return invalid
    cur = -1
    for i = 0 to seq.Count() - 1
        if seq[i].hasFocus() then
            cur = i
            exit for
        end if
    end for
    if cur < 0 then return seq[0]
    target = cur + delta
    if target < 0 or target >= seq.Count() then return invalid
    return seq[target]
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    ' Safety net: if focus somehow ends up on the root Group (e.g. focus
    ' race during view push) any directional key should land on the
    ' keyboard so the user is never stranded with dead arrows.
    if not m.kb.hasFocus() and not m.searchBtn.hasFocus() and not m.grid.hasFocus() and not chipsHaveFocus() then
        if key = "up" or key = "down" or key = "left" or key = "right" or key = "OK" then
            m.kb.setFocus(true)
            showKeyboard()
            return true
        end if
    end if
    if chipsHaveFocus() then
        if key = "left" then
            n = chipNeighbor(-1)
            if n <> invalid then
                n.setFocus(true)
                return true
            end if
            return true
        end if
        if key = "right" then
            n = chipNeighbor(1)
            if n <> invalid then
                n.setFocus(true)
                return true
            end if
            return true
        end if
        if key = "down" then
            m.kb.setFocus(true)
            return true
        end if
        if key = "up" then
            ' Bubble out so MainScene can grab the nav bar.
            return false
        end if
    end if
    if key = "up" and m.kb.hasFocus() then
        if focusFirstVisibleChip() then return true
        ' No chips - bubble so MainScene grabs nav.
        return false
    end if
    if key = "down" and m.kb.hasFocus() then
        ' When results already exist, DOWN-from-kb goes *straight* to
        ' the grid so the user has a 1-press path back. The keyboard
        ' absorbs RIGHT internally (wraps to next-row letter) so we
        ' can't rely on RIGHT for that. The Search button is only
        ' useful before any results land - after that it's redundant.
        if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
            m.grid.setFocus(true)
            showResults()
            return true
        end if
        m.searchBtn.setFocus(true)
        return true
    end if
    if key = "up" and m.searchBtn.hasFocus() then
        ' Without this the user gets stuck on the Search button - up would
        ' otherwise bubble out to MainScene and steal focus to the nav bar.
        m.kb.setFocus(true)
        return true
    end if
    ' DOWN from the Search button is the secondary path to the grid -
    ' the keyboard wraps RIGHT internally so we give the user another
    ' obvious way out (the auto-focus on result is the primary one).
    if key = "down" and m.searchBtn.hasFocus() then
        if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
            m.grid.setFocus(true)
            showResults()
            return true
        end if
        return true
    end if
    if key = "right" and (m.kb.hasFocus() or m.searchBtn.hasFocus()) then
        if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
            m.grid.setFocus(true)
            showResults()
            return true
        end if
    end if
    ' Star toggles favorite for the focused result poster. isInFocusChain
    ' covers grids that route focus through internal nodes.
    if key = "options" and m.grid.isInFocusChain() then
        idx = m.grid.itemFocused
        if idx <> invalid and idx >= 0 and m.grid.content <> invalid then
            cell = m.grid.content.getChild(idx)
            if cell <> invalid then
                if U_ToggleFavoriteForCell(cell, m.grid.content) then return true
            end if
        end if
    end if
    ' Left from the leftmost grid column bubbles up to here (MarkupGrid
    ' consumes left while moving between columns and only releases it at
    ' the leftmost edge), so this is the trigger to slide back to the
    ' keyboard.
    if key = "left" and m.grid.isInFocusChain() then
        m.kb.setFocus(true)
        showKeyboard()
        return true
    end if
    return false
end function

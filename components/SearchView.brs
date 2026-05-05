' SearchView.brs - Custom on-screen keyboard + grid of results, with a row
' of recent-query chips above the keyboard.
'
' Why a custom keyboard: the built-in Roku Keyboard widget absorbs
' LEFT/RIGHT internally - they wrap within the keyboard's own grid and
' never bubble to the parent's onKeyEvent. Horizontal ButtonGroup also
' eats UP/DOWN at non-edge columns. So we use a single MarkupGrid full
' of KbCell items: it handles 2D navigation at every cell and releases
' LEFT/RIGHT/UP/DOWN at the respective edges, so we can route to the
' result grid and the recent-search chips reliably from any position.
'
' When focus moves between the keyboard and the result grid we slide
' the whole pane left/right so the keyboard moves off-screen and the
' results take centre stage (and the reverse on the way back).

sub init()
    m.items = []
    m.lastQuery = ""
    m.query = ""
    m.resultsMode = false
    m.kbCols = 10

    m.queryDisplay = m.top.findNode("queryDisplay")
    m.kbGrid = m.top.findNode("kbGrid")
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.resultTitle = m.top.findNode("resultTitle")
    m.chipsLabel = m.top.findNode("chipsLabel")
    m.chipsRow = m.top.findNode("chipsRow")
    m.chipClear = m.top.findNode("chipClear")
    m.kbHint = m.top.findNode("kbHint")
    m.slideAnim = m.top.findNode("slideAnim")
    m.slideInterp = m.top.findNode("slideInterp")

    setupKeyboard()
    refreshQueryDisplay()

    m.grid.itemComponentName = "PosterItem"
    m.grid.observeField("itemSelected", "onItemSelected")

    m.timer = createObject("roSGNode", "Timer")
    m.timer.duration = 0.5
    m.timer.repeat = false
    m.timer.observeField("fire", "onDebounce")

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
    ' top nav) we bounce focus back to the keyboard - or to the grid if
    ' results exist and the user was last interacting with them.
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

' --- Custom keyboard setup -----------------------------------------------

sub setupKeyboard()
    m.kbLabels = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
        "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
        "U", "V", "W", "X", "Y", "Z", "0", "1", "2", "3",
        "4", "5", "6", "7", "8", "9", "SP", "DEL", "CLR", "GO"
    ]
    root = createObject("roSGNode", "ContentNode")
    for each label in m.kbLabels
        cell = root.createChild("ContentNode")
        cell.title = label
    end for
    m.kbGrid.content = root
    m.kbGrid.observeField("itemSelected", "onKbCellSelected")
end sub

sub onKbCellSelected()
    idx = m.kbGrid.itemSelected
    if idx = invalid or idx < 0 or idx >= m.kbLabels.Count() then return
    handleKey(m.kbLabels[idx])
end sub

sub handleKey(label as String)
    if label = "SP" then
        m.query = m.query + " "
    else if label = "DEL" then
        if Len(m.query) > 0 then m.query = Left(m.query, Len(m.query) - 1)
    else if label = "CLR" then
        m.query = ""
    else if label = "GO" then
        ' Skip debounce: run immediately and hand off to the grid.
        if Len(m.query) >= 2 then
            m.lastQuery = ""
            runQuery()
            if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
                showResults()
                m.grid.setFocus(true)
            end if
        end if
        return
    else
        m.query = m.query + LCase(label)
    end if
    refreshQueryDisplay()
    onTextChange()
end sub

sub refreshQueryDisplay()
    if m.query = "" then
        m.queryDisplay.text = "Type to search..."
        m.queryDisplay.color = "0x808080ff"
    else
        m.queryDisplay.text = m.query
        m.queryDisplay.color = "0xffffffff"
    end if
end sub

' --- Slide animation ----------------------------------------------------

sub showResults()
    if m.resultsMode then return
    m.resultsMode = true
    m.slideAnim.control = "stop"
    m.slideInterp.keyValue = [[0, 0], [-820, 0]]
    m.slideAnim.control = "start"
end sub

sub showKeyboard()
    if not m.resultsMode then return
    m.resultsMode = false
    m.slideAnim.control = "stop"
    m.slideInterp.keyValue = [[-820, 0], [0, 0]]
    m.slideAnim.control = "start"
end sub

' --- Search execution ----------------------------------------------------

sub onTextChange()
    if Len(m.query) < 2 then
        m.empty.visible = false
        m.grid.content = invalid
        m.resultTitle.visible = false
        m.timer.control = "stop"
        return
    end if
    m.timer.control = "stop"
    m.timer.control = "start"
end sub

sub onDebounce()
    runQuery()
end sub

sub runQuery()
    q = U_Trim(m.query)
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
    m.query = q
    refreshQueryDisplay()
    m.lastQuery = ""
    runQuery()
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
        showResults()
        m.grid.setFocus(true)
    else
        focusKeyboard()
    end if
end sub

sub onChipsClear()
    W_ClearSearchHistory()
    renderChips()
    ' Drop focus back to keyboard since the chip the user was on just
    ' disappeared - never leave them stranded.
    focusKeyboard()
end sub

' --- Focus helpers -------------------------------------------------------

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

sub focusKeyboard()
    m.kbGrid.setFocus(true)
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 and m.resultsMode then
        m.grid.setFocus(true)
    else
        focusKeyboard()
    end if
end sub

sub grabKeyboardFocus()
    focusKeyboard()
end sub

' --- Remote navigation ---------------------------------------------------

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    ' Safety net: if focus drifted to the root Group (e.g. focus race
    ' during view push), any directional key snaps to the keyboard so
    ' the user is never stranded with dead arrows.
    if not m.grid.isInFocusChain() and not chipsHaveFocus() and not m.kbGrid.isInFocusChain() then
        if key = "up" or key = "down" or key = "left" or key = "right" or key = "OK" then
            focusKeyboard()
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
            focusKeyboard()
            return true
        end if
        if key = "up" then
            ' Bubble out so MainScene grabs the nav bar.
            return false
        end if
    end if

    if m.kbGrid.isInFocusChain() then
        idx = m.kbGrid.itemFocused
        if idx = invalid or idx < 0 then idx = 0
        col = idx mod m.kbCols
        row = idx \ m.kbCols
        lastRow = (m.kbLabels.Count() - 1) \ m.kbCols

        if key = "up" and row = 0 then
            if focusFirstVisibleChip() then return true
            ' No chips: bubble for MainScene's nav-bar handling.
            return false
        end if

        if key = "right" and col = m.kbCols - 1 then
            ' Rightmost column - escape to results grid every time.
            if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
                showResults()
                m.grid.setFocus(true)
                return true
            end if
            ' No results yet - eat so it doesn't bubble into a nav move.
            return true
        end if

        if key = "left" and col = 0 then
            ' Leftmost column - eat so MainScene doesn't open the side
            ' menu (the user is mid-typing, not navigating).
            return true
        end if

        if key = "down" and row = lastRow then
            ' Bottom row fallback: also drop into the results grid.
            if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
                showResults()
                m.grid.setFocus(true)
                return true
            end if
            return true
        end if

        ' All non-edge moves: let MarkupGrid handle internal nav.
        return false
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
        showKeyboard()
        focusKeyboard()
        return true
    end if
    return false
end function

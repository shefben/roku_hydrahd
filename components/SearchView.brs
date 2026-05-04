' SearchView.brs - Custom on-screen keyboard + grid of results, with a row
' of recent-query chips above the keyboard.
'
' Why a custom keyboard: the built-in Roku Keyboard widget absorbs
' LEFT/RIGHT internally - they wrap within the keyboard's own grid and
' never bubble to the parent's onKeyEvent. That made it impossible to
' escape the keyboard with RIGHT and forced unreliable timer-based
' fallbacks. Building the keyboard out of horizontal ButtonGroups gives
' us every keypress at every row's edge: ButtonGroup releases LEFT/RIGHT
' when there's nothing more to navigate to in its layout direction, so
' the parent reliably sees them and can route to the results grid.

sub init()
    m.items = []
    m.lastQuery = ""
    m.query = ""

    m.queryDisplay = m.top.findNode("queryDisplay")
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.resultTitle = m.top.findNode("resultTitle")
    m.chipsLabel = m.top.findNode("chipsLabel")
    m.chipsRow = m.top.findNode("chipsRow")
    m.chipClear = m.top.findNode("chipClear")
    m.kbHint = m.top.findNode("kbHint")

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
        ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"],
        ["K", "L", "M", "N", "O", "P", "Q", "R", "S", "T"],
        ["U", "V", "W", "X", "Y", "Z", "0", "1", "2", "3"],
        ["4", "5", "6", "7", "8", "9"],
        ["SPACE", "DEL", "CLR"]
    ]
    m.kbRows = []
    for i = 0 to m.kbLabels.Count() - 1
        row = m.top.findNode("kbRow" + i.ToStr())
        if row <> invalid then
            row.buttons = m.kbLabels[i]
            row.observeField("buttonSelected", "onKbButton")
            m.kbRows.Push(row)
        end if
    end for
end sub

sub onKbButton(event as Object)
    sender = event.getRoSGNode()
    if sender = invalid then return
    rowIdx = -1
    for i = 0 to m.kbRows.Count() - 1
        if m.kbRows[i].isSameNode(sender) then
            rowIdx = i
            exit for
        end if
    end for
    if rowIdx < 0 then return
    btnIdx = sender.buttonSelected
    if btnIdx = invalid or btnIdx < 0 then return
    if btnIdx >= m.kbLabels[rowIdx].Count() then return
    handleKey(m.kbLabels[rowIdx][btnIdx])
end sub

sub handleKey(label as String)
    if label = "SPACE" then
        m.query = m.query + " "
    else if label = "DEL" then
        if Len(m.query) > 0 then m.query = Left(m.query, Len(m.query) - 1)
    else if label = "CLR" then
        m.query = ""
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
        m.grid.setFocus(true)
    else
        focusFirstKeyboardRow()
    end if
end sub

sub onChipsClear()
    W_ClearSearchHistory()
    renderChips()
    ' Drop focus back to keyboard since the chip the user was on just
    ' disappeared - never leave them stranded.
    focusFirstKeyboardRow()
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

function focusedKbRow() as Integer
    for i = 0 to m.kbRows.Count() - 1
        if m.kbRows[i].isInFocusChain() then return i
    end for
    return -1
end function

sub focusFirstKeyboardRow()
    if m.kbRows.Count() > 0 then m.kbRows[0].setFocus(true)
end sub

sub focusKbRow(idx as Integer, preserveCol as Integer)
    if idx < 0 or idx >= m.kbRows.Count() then return
    row = m.kbRows[idx]
    cnt = m.kbLabels[idx].Count()
    target = preserveCol
    if target < 0 then target = 0
    if target >= cnt then target = cnt - 1
    ' setFocus first - on some firmwares it reinitialises the focused
    ' button index. Setting focusButton afterwards reliably lands the
    ' marker where we want it.
    row.setFocus(true)
    row.focusButton = target
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 and m.grid.itemFocused >= 0 then
        m.grid.setFocus(true)
    else
        focusFirstKeyboardRow()
    end if
end sub

sub grabKeyboardFocus()
    focusFirstKeyboardRow()
end sub

' --- Remote navigation ---------------------------------------------------

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    ' Safety net: if focus somehow ends up on the root Group (e.g. focus
    ' race during view push), any directional key should land on the
    ' keyboard so the user is never stranded with dead arrows.
    if not m.grid.isInFocusChain() and not chipsHaveFocus() and focusedKbRow() < 0 then
        if key = "up" or key = "down" or key = "left" or key = "right" or key = "OK" then
            focusFirstKeyboardRow()
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
            focusFirstKeyboardRow()
            return true
        end if
        if key = "up" then
            ' Bubble out so MainScene can grab the nav bar.
            return false
        end if
    end if

    rowIdx = focusedKbRow()
    if rowIdx >= 0 then
        col = m.kbRows[rowIdx].buttonFocused
        if col = invalid then col = 0
        if key = "down" then
            if rowIdx < m.kbRows.Count() - 1 then
                focusKbRow(rowIdx + 1, col)
                return true
            end if
            ' From the last keyboard row, DOWN jumps to the results grid
            ' as a secondary escape path.
            if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
                m.grid.setFocus(true)
                return true
            end if
            return true
        end if
        if key = "up" then
            if rowIdx > 0 then
                focusKbRow(rowIdx - 1, col)
                return true
            end if
            ' From the top row: hop to chips if visible, otherwise let
            ' MainScene grab the nav bar.
            if focusFirstVisibleChip() then return true
            return false
        end if
        if key = "right" then
            ' Horizontal ButtonGroup releases RIGHT only when there is no
            ' next button in the row, i.e. the user is on the rightmost
            ' key. Route them straight to the results grid every time.
            if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
                m.grid.setFocus(true)
                return true
            end if
            ' No results yet - eat the key so it doesn't bubble into a
            ' nav-bar move.
            return true
        end if
        if key = "left" then
            ' RIGHT-from-rightmost-key already handed off above. LEFT
            ' from the leftmost key has nowhere to go - eat the key.
            return true
        end if
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
        focusFirstKeyboardRow()
        return true
    end if
    return false
end function

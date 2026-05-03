' ListView.brs - Paginated grid for movies, tv shows, popular, top rated.

sub init()
    ' State first - observers below can fire immediately on setFocus.
    m.page = 0
    m.loading = false
    m.allDone = false
    m.items = []
    m.source = ""

    m.grid = m.top.findNode("grid")
    m.header = m.top.findNode("header")
    m.empty = m.top.findNode("empty")
    m.grid.itemComponentName = "PosterItem"
    m.grid.observeField("itemSelected", "onItemSelected")
    m.grid.observeField("itemFocused", "onItemFocused")
    m.grid.setFocus(true)
    ' Bounce self-focus down to the grid whenever MainScene refocuses
    ' the view root (e.g. after the user comes back from the top nav).
    ' Without this the user is stranded - arrows hit a dead Group.
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    if m.grid = invalid or m.grid.content = invalid then return
    if m.grid.content.getChildCount() = 0 then return
    m.grid.setFocus(true)
end sub

sub onArgs()
    a = m.top.args
    if a = invalid then return
    m.source = a.source
    if a.title <> invalid then m.header.text = a.title else m.header.text = ""
    m.page = 0
    m.allDone = false
    m.items = []
    ' Start with an empty content node so subsequent pages can append
    ' children in place rather than replacing the whole tree (which
    ' was wiping the grid's focus state mid-navigation and leaving the
    ' cursor "stuck" on whatever poster happened to be focused when
    ' a new page arrived).
    m.grid.content = createObject("roSGNode", "ContentNode")
    fetchPage()
end sub

sub fetchPage()
    if m.loading or m.allDone then return
    m.loading = true
    m.top.loading = true
    m.page = m.page + 1
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "ListTask")
    m.task.observeField("result", "onPageResult")
    m.task.source = m.source
    m.task.page = m.page
    m.task.control = "RUN"
end sub

sub onPageResult()
    res = m.task.result
    m.loading = false
    m.top.loading = false
    if res = invalid or res.items = invalid then
        if m.items.Count() = 0 then m.empty.visible = true
        m.allDone = true
        return
    end if

    items = res.items
    if items.Count() = 0 then
        if m.items.Count() = 0 then m.empty.visible = true
        m.allDone = true
        return
    end if

    appendItems(items)
end sub

' Append new cells to the live ContentNode instead of swapping the
' whole tree. The MarkupGrid keeps its current focus index, the user's
' cursor doesn't snap or freeze when a page arrives mid-navigation,
' and we don't lose the in-flight scroll animation.
sub appendItems(items as Object)
    root = m.grid.content
    if root = invalid then
        root = createObject("roSGNode", "ContentNode")
        m.grid.content = root
    end if
    for each item in items
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
        m.items.Push(item)
    end for
end sub

sub onItemFocused()
    idx = m.grid.itemFocused
    if idx = invalid then return
    if m.items = invalid then return
    if idx >= m.items.Count() - 14 and not m.allDone then fetchPage()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "up" then
        idx = m.grid.itemFocused
        if idx = invalid then idx = 0
        if idx < m.grid.numColumns then
            ' At top row - let MainScene bubble to nav buttons.
            return false
        end if
    end if
    ' Star button toggles favorite for the focused poster. isInFocusChain
    ' is used (not hasFocus) so we still match when the grid has routed
    ' focus through an internal node.
    if key = "options" and m.grid.isInFocusChain() then
        if toggleFavoriteAtFocus() then return true
    end if
    ' LEFT-to-sidebar handoff has moved to MainScene (LEFT on the
    ' leftmost nav button). MarkupGrid does bubble LEFT at col 0, so
    ' we could trigger here too, but keeping the trigger in one place
    ' avoids two SideMenu instances and ambiguous focus restoration.
    return false
end function

function toggleFavoriteAtFocus() as Boolean
    idx = m.grid.itemFocused
    if idx = invalid or idx < 0 then return false
    if m.grid.content = invalid then return false
    cell = m.grid.content.getChild(idx)
    if cell = invalid then return false
    return U_ToggleFavoriteForCell(cell, m.grid.content)
end function

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

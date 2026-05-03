' FavoritesView.brs - Grid of titles the user has starred via DetailsView.

sub init()
    m.items = []
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.grid.itemComponentName = "PosterItem"
    m.grid.observeField("itemSelected", "onItemSelected")
    refresh()
    ' Bounce self-focus down to the grid when MainScene re-focuses the
    ' view root (e.g. user came back from the top nav).
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if fc.isSameNode(m.top) and m.grid.content <> invalid then
        m.grid.setFocus(true)
    end if
end sub

sub onArgs()
    refresh()
end sub

' Re-read the registry every time the view is shown so a freshly-saved
' or removed favorite reflects without a full channel restart.
sub refresh()
    favs = W_ListFavorites()
    if favs = invalid then favs = []
    m.items = favs
    if favs.Count() = 0 then
        m.grid.content = invalid
        m.empty.visible = true
        ' No items to focus - press UP bubbles to MainScene's nav bar
        ' (handled in MainScene.onKeyEvent), so the user is never
        ' stranded. No need to focus the Label itself.
        return
    end if
    m.empty.visible = false
    root = createObject("roSGNode", "ContentNode")
    for each fv in favs
        cell = root.createChild("ContentNode")
        if fv.title <> invalid then cell.title = fv.title
        if fv.poster <> invalid then
            cell.HDPosterUrl = fv.poster
            cell.SDPosterUrl = fv.poster
        end if
        if fv.kind <> invalid then U_SetCellKind(cell, fv.kind)
        if fv.href <> invalid then cell.url = fv.href
        if fv.itemKey <> invalid then cell.id = fv.itemKey
        U_SetCellPct(cell, W_GetProgressPct("", fv.href, 0, 0))
    end for
    m.grid.content = root
    m.grid.jumpToItem = 0
    m.grid.setFocus(true)
end sub

sub onItemSelected()
    idx = m.grid.itemSelected
    if idx = invalid or idx < 0 or idx >= m.items.Count() then return
    item = m.items[idx]
    kind = "movie"
    if item.kind <> invalid and item.kind <> "" then
        kind = item.kind
    else if item.href <> invalid and Instr(1, item.href, "/watchseries/") > 0 then
        kind = "tv"
    end if
    href = ""
    if item.href <> invalid then href = item.href
    m.top.requestNav = {
        action: "open"
        view: "DetailsView"
        args: {
            kind: kind
            id: ""
            href: href
            title: item.title
            poster: item.poster
        }
    }
end sub

' At the top row, let `up` bubble out so MainScene can grab the nav bar.
function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "up" and m.grid.hasFocus() then
        idx = m.grid.itemFocused
        if idx = invalid then idx = 0
        if idx < m.grid.numColumns then return false
    end if
    ' Star toggles favorite. On this view that *removes* the title from
    ' the list, so after the toggle we rebuild the grid and try to keep
    ' focus on the surviving cell at the same index (or the previous
    ' one if we just unstarred the last cell). isInFocusChain handles
    ' grids that route focus through internal nodes.
    if key = "options" and m.grid.isInFocusChain() then
        idx = m.grid.itemFocused
        if idx = invalid or idx < 0 or m.grid.content = invalid then return false
        cell = m.grid.content.getChild(idx)
        if cell = invalid then return false
        if not U_ToggleFavoriteForCell(cell, m.grid.content) then return false
        ' Removed: list shrank. Rebuild and re-focus.
        refresh()
        if m.grid.content <> invalid and m.grid.content.getChildCount() > 0 then
            keep = idx
            n = m.grid.content.getChildCount()
            if keep >= n then keep = n - 1
            if keep < 0 then keep = 0
            m.grid.jumpToItem = keep
            m.grid.setFocus(true)
        end if
        return true
    end if
    return false
end function

' FavoritesView.brs - Grid of titles the user has starred via DetailsView.

sub init()
    m.items = []
    m.grid = m.top.findNode("grid")
    m.empty = m.top.findNode("empty")
    m.grid.itemComponentName = "PosterItem"
    m.grid.observeField("itemSelected", "onItemSelected")
    refresh()
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
        if fv.kind <> invalid then cell.contentType = fv.kind
        if fv.href <> invalid then cell.url = fv.href
        if fv.itemKey <> invalid then cell.id = fv.itemKey
        cell.percentageWatched = W_GetProgressPct("", fv.href, 0, 0)
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
    return false
end function

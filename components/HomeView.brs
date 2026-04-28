' HomeView.brs - RowList of categories from the hydrahd index page.

sub init()
    m.rows = m.top.findNode("rows")
    m.empty = m.top.findNode("empty")
    m.sideMenu = m.top.findNode("sideMenu")
    m.rows.observeField("rowItemSelected", "onItemSelected")
    m.rows.itemComponentName = "PosterItem"
    m.rows.setFocus(true)
    ' Index of the Continue Watching row when it's present (-1 = absent).
    ' We use this in onItemSelected so tiles in that row jump straight
    ' into playback instead of opening DetailsView first.
    m.continueRowIdx = -1
    m.sideMenu.observeField("command", "onSideMenuCommand")

    ' MainScene.focusActiveChild() calls setFocus(true) on the HomeView
    ' Group root whenever the user comes back from the top nav (e.g.
    ' presses DOWN from the nav bar). Focus then sits on this Group
    ' itself, not on the rowlist - arrows do nothing until we forward
    ' it. Observing focusedChild and bouncing self-focus down to
    ' m.rows fixes the "stuck on first poster" bug and also makes
    ' LEFT-at-col-0 (sidebar handoff in onKeyEvent) reliable.
    m.top.observeField("focusedChild", "onSelfFocusChanged")

    m.task = createObject("roSGNode", "HomeTask")
    m.task.observeField("result", "onResult")
    m.top.loading = true
    m.task.control = "RUN"
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if not fc.isSameNode(m.top) then return
    ' Don't try to bounce focus before the rowlist has any content -
    ' setFocus on an empty RowList is a no-op and we'd fire a second
    ' focusedChild change for nothing. After content arrives onResult
    ' calls setFocus directly anyway.
    if m.rows = invalid or m.rows.content = invalid then return
    m.rows.setFocus(true)
end sub

' Forward navigation actions to MainScene; restore focus on collapse.
sub onSideMenuCommand()
    cmd = m.sideMenu.command
    if cmd = invalid then return
    if cmd.action = "collapsed" then
        m.rows.setFocus(true)
        return
    end if
    m.top.requestNav = cmd
end sub

sub onResult()
    bundle = m.task.result
    m.top.loading = false
    if bundle = invalid or bundle.rows = invalid or bundle.rows.Count() = 0 then
        m.empty.text = "Failed to load - press OK to retry, or * to search."
        m.empty.visible = true
        m.empty.focusable = true
        m.empty.setFocus(true)
        return
    end if
    rows = bundle.rows

    rootContent = createObject("roSGNode", "ContentNode")
    m.continueRowIdx = -1

    ' "Continue Watching" goes first when the user has anything in
    ' progress. Tiles drop the user straight into MirrorPicker for the
    ' resume target so they don't have to click through DetailsView.
    inProg = W_ListInProgress(20)
    if inProg <> invalid and inProg.Count() > 0 then
        m.continueRowIdx = rootContent.getChildCount()
        cwRow = rootContent.createChild("ContentNode")
        cwRow.title = "Continue Watching"
        for each ip in inProg
            cell = cwRow.createChild("ContentNode")
            cell.title = ip.title
            cell.HDPosterUrl = ip.poster
            cell.SDPosterUrl = ip.poster
            ' Subtitle: episode tag for TV, time-left for movies.
            if ip.kind = "tv" and ip.season <> invalid and ip.episode <> invalid then
                cell.shortDescriptionLine2 = "S" + ip.season.ToStr() + "E" + ip.episode.ToStr()
            else
                cell.shortDescriptionLine2 = W_FormatTime(ip.pos) + " in"
            end if
            cell.releaseDate = "Resume"
            cell.id = ip.itemKey
            cell.contentType = ip.kind
            cell.url = ip.href
            cell.percentageWatched = ip.pct
        end for
    end if

    ' Favorites tucked under Continue Watching so the user's manually
    ' starred titles are also one click from home.
    favs = W_ListFavorites()
    if favs <> invalid and favs.Count() > 0 then
        favRow = rootContent.createChild("ContentNode")
        favRow.title = "My List"
        for each fv in favs
            cell = favRow.createChild("ContentNode")
            if fv.title <> invalid then cell.title = fv.title
            if fv.poster <> invalid then
                cell.HDPosterUrl = fv.poster
                cell.SDPosterUrl = fv.poster
            end if
            if fv.kind <> invalid then cell.contentType = fv.kind
            if fv.href <> invalid then cell.url = fv.href
            if fv.itemKey <> invalid then cell.id = fv.itemKey
            ' Show resume bar on My List tiles too if they have progress.
            cell.percentageWatched = W_GetProgressPct(fv.imdb, fv.href, 0, 0)
        end for
    end if

    for each row in rows
        rowNode = rootContent.createChild("ContentNode")
        rowNode.title = row.title
        for each item in row.items
            cell = rowNode.createChild("ContentNode")
            cell.title = item.title
            cell.HDPosterUrl = item.poster
            cell.SDPosterUrl = item.poster
            cell.shortDescriptionLine1 = item.rating
            cell.shortDescriptionLine2 = item.year
            cell.releaseDate = item.quality
            cell.id = item.id
            cell.contentType = item.kind
            cell.url = item.href
            cell.percentageWatched = W_GetProgressPct("", item.href, 0, 0)
        end for
    end for
    m.rows.content = rootContent
    if rootContent.getChildCount() > 0 then
        m.rows.jumpToRowItem = [0, 0]
    end if
    ' Re-grab focus now that there's actually something to focus on.
    m.rows.setFocus(true)
end sub

' OK on the empty state retries the load.
sub retryLoad()
    m.empty.visible = false
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "HomeTask")
    m.task.observeField("result", "onResult")
    m.top.loading = true
    m.task.control = "RUN"
end sub

sub onItemSelected()
    sel = m.rows.rowItemSelected
    if sel = invalid then return
    rowIdx = sel[0]
    colIdx = sel[1]
    rowContent = m.rows.content.getChild(rowIdx)
    if rowContent = invalid then return
    item = rowContent.getChild(colIdx)
    if item = invalid then return
    href = ""
    if item.url <> invalid then href = item.url
    kind = "movie"
    if item.contentType <> invalid and (item.contentType = "tv" or item.contentType = "movie") then
        kind = item.contentType
    else if href <> "" and Instr(1, href, "/watchseries/") > 0 then
        kind = "tv"
    end if
    args = {
        kind: kind
        id: item.id
        href: href
        title: item.title
        poster: item.HDPosterUrl
    }
    ' Continue Watching tiles fast-path into resume - DetailsView will
    ' fire its Play action automatically once details fetch finishes.
    if rowIdx = m.continueRowIdx then args.autoResume = true
    m.top.requestNav = {
        action: "open"
        view: "DetailsView"
        args: args
    }
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.empty.visible and (key = "OK" or key = "play") then
        retryLoad()
        return true
    end if
    ' Star button (`*` on the Roku remote, "options" event) toggles the
    ' favorite state of the focused poster. Star indicators on every
    ' duplicate cell update via U_BumpAllCellsByUrl.
    if key = "options" and m.rows.hasFocus() then
        if toggleFavoriteAtFocus() then return true
    end if
    ' LEFT at the leftmost column of the row hands focus to the side
    ' drawer's collapsed strip. RowList absorbs left between columns
    ' and only bubbles when there's nowhere left to go.
    if key = "left" and m.rows.hasFocus() then
        sel = m.rows.rowItemFocused
        col = 0
        if sel <> invalid and sel.Count() >= 2 then col = sel[1]
        if col = 0 then
            m.sideMenu.callFunc("focusStrip", invalid)
            return true
        end if
    end if
    return false
end function

function toggleFavoriteAtFocus() as Boolean
    sel = m.rows.rowItemFocused
    if sel = invalid or sel.Count() < 2 then return false
    rowIdx = sel[0]
    colIdx = sel[1]
    rowContent = m.rows.content.getChild(rowIdx)
    if rowContent = invalid then return false
    cell = rowContent.getChild(colIdx)
    if cell = invalid then return false
    return U_ToggleFavoriteForCell(cell, m.rows.content)
end function

' ListView.brs - Paginated grid for movies, tv shows, popular, top rated.

sub init()
    ' State first - observers below can fire immediately on setFocus.
    m.page = 0
    m.loading = false
    m.allDone = false
    m.items = []
    m.source = ""
    m.kind = ""
    m.activePath = ""
    m.activeFilterIndex = 0
    m.filterOptions = []

    m.grid = m.top.findNode("grid")
    m.header = m.top.findNode("header")
    m.empty = m.top.findNode("empty")
    m.filterBtn = m.top.findNode("filterBtn")
    m.filterOverlay = m.top.findNode("filterOverlay")
    m.filterList = m.top.findNode("filterList")
    m.grid.itemComponentName = "PosterItem"
    m.grid.observeField("itemSelected", "onItemSelected")
    m.grid.observeField("itemFocused", "onItemFocused")
    m.filterBtn.observeField("buttonSelected", "onFilterBtnSelected")
    m.filterList.observeField("itemSelected", "onFilterChosen")
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
    m.kind = ""
    if a.kind <> invalid then m.kind = a.kind
    if a.path <> invalid then
        m.activePath = a.path
    else
        m.activePath = ""
    end if
    buildFilterList()
    m.page = 0
    m.allDone = false
    m.items = []
    m.empty.visible = false
    ' Start with an empty content node so subsequent pages can append
    ' children in place rather than replacing the whole tree (which
    ' was wiping the grid's focus state mid-navigation and leaving the
    ' cursor "stuck" on whatever poster happened to be focused when
    ' a new page arrived).
    m.grid.content = createObject("roSGNode", "ContentNode")
    fetchPage()
end sub

' Populate m.filterOptions and the dropdown LabelList based on the
' current tab kind. Options were lifted directly from hydrahd.ru's
' own /movies and /tv-shows dropdowns - if hydrahd adds new genres
' upstream this list needs to be re-synced.
sub buildFilterList()
    if m.kind = "movie" then
        m.filterOptions = [
            { label: "Just Added (Latest)",  path: "movies" }
            { label: "Popular",              path: "movies/popular" }
            { label: "Rating",               path: "movies/star-rating" }
            { label: "Featured",             path: "movies/featured" }
            { label: "By Year",              path: "movies/year" }
            { label: "Genre: Action",        path: "genres/watch-action-movies-online-free" }
            { label: "Genre: Adventure",     path: "genres/watch-adventure-movies-online-free" }
            { label: "Genre: Animation",     path: "genres/watch-animation-movies-online-free" }
            { label: "Genre: Biography",     path: "genres/watch-biography-movies-online-free" }
            { label: "Genre: Comedy",        path: "genres/watch-comedy-movies-online-free" }
            { label: "Genre: Crime",         path: "genres/watch-crime-movies-online-free" }
            { label: "Genre: Documentary",   path: "genres/watch-documentary-movies-online-free" }
            { label: "Genre: Drama",         path: "genres/watch-drama-movies-online-free" }
            { label: "Genre: Family",        path: "genres/watch-family-movies-online-free" }
            { label: "Genre: Fantasy",       path: "genres/watch-fantasy-movies-online-free" }
            { label: "Genre: History",       path: "genres/watch-history-movies-online-free" }
            { label: "Genre: Horror",        path: "genres/watch-horror-movies-online-free" }
            { label: "Genre: Music",         path: "genres/watch-music-movies-online-free" }
            { label: "Genre: Musical",       path: "genres/watch-musical-movies-online-free" }
            { label: "Genre: Mystery",       path: "genres/watch-mystery-movies-online-free" }
            { label: "Genre: Romance",       path: "genres/watch-romance-movies-online-free" }
            { label: "Genre: Sci-Fi",        path: "genres/watch-sci-fi-movies-online-free" }
            { label: "Genre: Sport",         path: "genres/watch-sport-movies-online-free" }
            { label: "Genre: Thriller",      path: "genres/watch-thriller-movies-online-free" }
            { label: "Genre: War",           path: "genres/watch-war-movies-online-free" }
            { label: "Genre: Western",       path: "genres/watch-western-movies-online-free" }
        ]
    else if m.kind = "tv" then
        m.filterOptions = [
            { label: "Latest (Date)",        path: "tv-shows" }
            { label: "Rating",               path: "tv-shows/star-rating" }
            { label: "Popular",              path: "tv-shows/popular" }
            { label: "Genre: Action",        path: "tv-tags/action" }
            { label: "Genre: Adventure",     path: "tv-tags/adventure" }
            { label: "Genre: Animation",     path: "tv-tags/animation" }
            { label: "Genre: Biography",     path: "tv-tags/biography" }
            { label: "Genre: Comedy",        path: "tv-tags/comedy" }
            { label: "Genre: Crime",         path: "tv-tags/crime" }
            { label: "Genre: Documentary",   path: "tv-tags/documentary" }
            { label: "Genre: Drama",         path: "tv-tags/drama" }
            { label: "Genre: Family",        path: "tv-tags/family" }
            { label: "Genre: Fantasy",       path: "tv-tags/fantasy" }
            { label: "Genre: Game-Show",     path: "tv-tags/game-show" }
            { label: "Genre: History",       path: "tv-tags/history" }
            { label: "Genre: Horror",        path: "tv-tags/horror" }
            { label: "Genre: Music",         path: "tv-tags/music" }
            { label: "Genre: Musical",       path: "tv-tags/musical" }
            { label: "Genre: Mystery",       path: "tv-tags/mystery" }
            { label: "Genre: News",          path: "tv-tags/news" }
            { label: "Genre: Reality-TV",    path: "tv-tags/reality-tv" }
            { label: "Genre: Romance",       path: "tv-tags/romance" }
            { label: "Genre: Sci-Fi",        path: "tv-tags/sci-fi" }
            { label: "Genre: Sport",         path: "tv-tags/sport" }
            { label: "Genre: Talk-Show",     path: "tv-tags/talk-show" }
            { label: "Genre: Thriller",      path: "tv-tags/thriller" }
            { label: "Genre: War",           path: "tv-tags/war" }
            { label: "Genre: Western",       path: "tv-tags/western" }
        ]
    else
        m.filterOptions = []
    end if

    if m.filterOptions.Count() = 0 then
        m.filterBtn.visible = false
        return
    end if
    m.filterBtn.visible = true

    activeIdx = 0
    cn = createObject("roSGNode", "ContentNode")
    for i = 0 to m.filterOptions.Count() - 1
        opt = m.filterOptions[i]
        c = cn.createChild("ContentNode")
        c.title = opt.label
        if opt.path = m.activePath then activeIdx = i
    end for
    m.filterList.content = cn
    m.activeFilterIndex = activeIdx
    m.filterBtn.text = m.filterOptions[activeIdx].label
end sub

sub onFilterBtnSelected()
    if m.filterOptions.Count() = 0 then return
    m.filterOverlay.visible = true
    m.filterList.jumpToItem = m.activeFilterIndex
    m.filterList.setFocus(true)
end sub

sub onFilterChosen()
    idx = m.filterList.itemSelected
    m.filterOverlay.visible = false
    if idx = invalid or idx < 0 or idx >= m.filterOptions.Count() then
        m.filterBtn.setFocus(true)
        return
    end if
    chosen = m.filterOptions[idx]
    m.activeFilterIndex = idx
    m.activePath = chosen.path
    m.filterBtn.text = chosen.label
    ' Cancel any in-flight page fetch so a stale earlier filter result
    ' can't append to the new filter's grid after we reset state.
    if m.task <> invalid then
        m.task.unobserveField("result")
        m.task.control = "STOP"
        m.task = invalid
    end if
    m.page = 0
    m.allDone = false
    m.loading = false
    m.items = []
    m.empty.visible = false
    m.grid.content = createObject("roSGNode", "ContentNode")
    fetchPage()
    m.grid.setFocus(true)
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
    if m.activePath <> "" then m.task.path = m.activePath
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

    ' Filter dropdown is modal - trap navigation while it's open so the
    ' grid behind it can't steal focus on a stray UP/DOWN.
    if m.filterOverlay.visible then
        if key = "back" or key = "left" then
            m.filterOverlay.visible = false
            m.filterBtn.setFocus(true)
            return true
        end if
        return false
    end if

    if m.filterBtn.hasFocus() then
        if key = "down" then
            m.grid.setFocus(true)
            return true
        end if
        ' UP from filter button bubbles to MainScene which lifts focus
        ' to the nav bar. LEFT/RIGHT have nowhere meaningful to go on
        ' a single-button row, so consume them to avoid surprising drift.
        if key = "left" or key = "right" then return true
        return false
    end if

    if key = "up" then
        idx = m.grid.itemFocused
        if idx = invalid then idx = 0
        if idx < m.grid.numColumns then
            ' At the top row of the grid - jump to the filter button if
            ' this tab has filter options, otherwise bubble to nav.
            if m.filterBtn.visible then
                m.filterBtn.setFocus(true)
                return true
            end if
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

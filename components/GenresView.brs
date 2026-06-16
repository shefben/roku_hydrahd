' GenresView.brs - Genre hub. A grid of genre cards; selecting one opens
' the paginated ListView filtered to that genre (movies catalogue).

sub init()
    m.grid = m.top.findNode("grid")
    m.grid.observeField("itemSelected", "onSelected")

    ' Genre -> hydrahd movies path (mirrors ListView's movie filter list).
    m.genres = [
        { label: "Action",      path: "genres/watch-action-movies-online-free" }
        { label: "Adventure",   path: "genres/watch-adventure-movies-online-free" }
        { label: "Animation",   path: "genres/watch-animation-movies-online-free" }
        { label: "Comedy",      path: "genres/watch-comedy-movies-online-free" }
        { label: "Crime",       path: "genres/watch-crime-movies-online-free" }
        { label: "Documentary", path: "genres/watch-documentary-movies-online-free" }
        { label: "Drama",       path: "genres/watch-drama-movies-online-free" }
        { label: "Family",      path: "genres/watch-family-movies-online-free" }
        { label: "Fantasy",     path: "genres/watch-fantasy-movies-online-free" }
        { label: "History",     path: "genres/watch-history-movies-online-free" }
        { label: "Horror",      path: "genres/watch-horror-movies-online-free" }
        { label: "Music",       path: "genres/watch-music-movies-online-free" }
        { label: "Mystery",     path: "genres/watch-mystery-movies-online-free" }
        { label: "Romance",     path: "genres/watch-romance-movies-online-free" }
        { label: "Sci-Fi",      path: "genres/watch-sci-fi-movies-online-free" }
        { label: "Thriller",    path: "genres/watch-thriller-movies-online-free" }
        { label: "War",         path: "genres/watch-war-movies-online-free" }
        { label: "Western",     path: "genres/watch-western-movies-online-free" }
    ]

    root = createObject("roSGNode", "ContentNode")
    for each g in m.genres
        c = root.createChild("ContentNode")
        c.title = g.label
    end for
    m.grid.content = root
    m.grid.setFocus(true)
    m.top.observeField("focusedChild", "onSelfFocusChanged")
end sub

sub onSelfFocusChanged()
    fc = m.top.focusedChild
    if fc = invalid then return
    if fc.isSameNode(m.top) and m.grid.content <> invalid then m.grid.setFocus(true)
end sub

sub onSelected()
    idx = m.grid.itemSelected
    if idx = invalid or idx < 0 or idx >= m.genres.Count() then return
    g = m.genres[idx]
    m.top.requestNav = {
        action: "open"
        view: "ListView"
        args: { source: "movies", title: g.label, kind: "movie", path: g.path }
    }
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "up" then
        idx = m.grid.itemFocused
        if idx = invalid then idx = 0
        if idx < m.grid.numColumns then return false   ' top row -> bubble to nav
    end if
    if key = "left" then
        idx = m.grid.itemFocused
        cols = m.grid.numColumns
        if cols = invalid or cols < 1 then cols = 1
        if idx = invalid or idx < 0 or (idx mod cols) = 0 then
            m.top.requestNav = { action: "openMenu" }
            return true
        end if
        return false
    end if
    return false
end function

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    src = m.top.source
    page = m.top.page
    pth = m.top.path
    items = []
    ' Filter / dropdown picks supply a relative path
    ' ("movies/popular", "tv-shows/star-rating", "genres/...", "tv-tags/...")
    ' that bypasses the named-source switch below.
    if pth <> invalid and pth <> "" then
        items = HA_FetchListByPath(pth, page)
    else if src = "movies" then
        items = HA_FetchMovies(page)
    else if src = "tv" then
        items = HA_FetchTvShows(page)
    else if src = "popular" then
        items = HA_FetchPopular(page)
    else if src = "topRated" then
        items = HA_FetchTopRated(page)
    else
        items = HA_FetchMovies(page)
    end if
    if items = invalid then items = []
    m.top.result = { items: items, page: page }
end sub

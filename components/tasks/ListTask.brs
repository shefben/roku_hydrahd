sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    src = m.top.source
    page = m.top.page
    items = []
    if src = "movies" then
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

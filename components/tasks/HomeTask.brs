sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    rows = []

    addRow(rows, "Trending Movies",     HA_FetchPopular(1))
    addRow(rows, "Trending Series",     HA_FetchTvShowsPopular(1))
    addRow(rows, "Latest Movies",       HA_FetchMovies(1))
    addRow(rows, "Latest Series",       HA_FetchTvShows(1))
    addRow(rows, "Top Rated Movies",    HA_FetchTopRated(1))
    addRow(rows, "Top Rated Series",    HA_FetchTvShowsTopRated(1))

    m.top.result = { rows: rows }
end sub

sub addRow(rows as Object, title as String, items as Object)
    if items = invalid or items.Count() = 0 then return
    slice = []
    for i = 0 to 23
        if i >= items.Count() then exit for
        slice.Push(items[i])
    end for
    rows.Push({ title: title, items: slice })
end sub

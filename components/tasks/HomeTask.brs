sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    ' Pull the actual hydrahd.ru landing page so the order, labels, and
    ' poster set match what the website shows. HA_FetchHome reads the
    ' <h3> headers ("Trending", "Latest", "Top Rated", ...) and groups
    ' the cards underneath each one. Person profile rows like
    ' "Trending People" are dropped automatically because their cards
    ' have /person/ hrefs which the parser ignores.
    rows = HA_FetchHome()
    if rows = invalid then rows = []

    ' Cap each row at 24 cards to keep the home grid responsive.
    capped = []
    for each row in rows
        items = row.items
        if items <> invalid and items.Count() > 0 then
            slice = []
            for i = 0 to 23
                if i >= items.Count() then exit for
                slice.Push(items[i])
            end for
            capped.Push({ title: row.title, items: slice })
        end if
    end for

    ' Append two TV-specific rows. The hydrahd landing page mostly
    ' surfaces movies under its "Latest" / "Top Rated" headers, so these
    ' two extra rows give the home view dedicated TV-show coverage that
    ' matches what /tv-shows/ and /tv-shows/star-rating/ return.
    appendIfNonEmpty(capped, "Latest TV Shows",    HA_FetchTvShows(1))
    appendIfNonEmpty(capped, "Top Rated TV Shows", HA_FetchTvShowsTopRated(1))

    m.top.result = { rows: capped }
end sub

sub appendIfNonEmpty(target as Object, title as String, items as Object)
    if items = invalid or items.Count() = 0 then return
    slice = []
    for i = 0 to 23
        if i >= items.Count() then exit for
        slice.Push(items[i])
    end for
    target.Push({ title: title, items: slice })
end sub

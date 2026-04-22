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

    m.top.result = { rows: capped }
end sub

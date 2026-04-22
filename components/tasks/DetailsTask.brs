sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    kind = m.top.kind
    href = m.top.href
    if kind = invalid then kind = ""
    if href = invalid then href = ""
    ' Roku ContentNode has a `contentType` enum that may strip non-standard
    ' values like "tv" / "movie" - if the caller's kind got lost, derive it
    ' from the href so TV shows don't fall through to the movie fetcher.
    if kind <> "tv" and kind <> "movie" then
        if href <> "" and Instr(1, href, "/watchseries/") > 0 then
            kind = "tv"
        else
            kind = "movie"
        end if
    end if
    if kind = "tv" then
        d = HA_FetchTvDetails(href, m.top.id)
    else
        d = HA_FetchMovieDetails(href, m.top.id)
    end if
    m.top.result = { detail: d }
end sub

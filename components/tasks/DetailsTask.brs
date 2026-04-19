sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    if m.top.kind = "tv" then
        d = HA_FetchTvDetails(m.top.href, m.top.id)
    else
        d = HA_FetchMovieDetails(m.top.href, m.top.id)
    end if
    m.top.result = { detail: d }
end sub

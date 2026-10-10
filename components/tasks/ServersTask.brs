sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    mirrors = []
    if m.top.kind = "tv" then
        if U_FirstMatch(m.top.tmdb, "^(\d+)$") <> "" then
            mirrors = HA_FetchEpisodeMirrors(m.top.imdb, m.top.tmdb, m.top.season, m.top.episode, m.top.refer)
        else if m.top.slug <> "" then
            m.top.result = HA_FetchEpisodeMirrorInfoBySlug(m.top.slug, m.top.season, m.top.episode)
            return
        end if
    else
        mirrors = HA_FetchMovieMirrors(m.top.imdb, m.top.tmdb, m.top.refer)
    end if
    if mirrors = invalid then mirrors = []
    m.top.result = { mirrors: mirrors }
end sub

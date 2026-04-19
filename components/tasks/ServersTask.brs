sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    mirrors = []
    if m.top.kind = "tv" then
        if m.top.imdb <> "" and m.top.tmdb <> "" then
            mirrors = HA_FetchEpisodeMirrors(m.top.imdb, m.top.tmdb, m.top.season, m.top.episode, m.top.refer)
        else if m.top.slug <> "" then
            mirrors = HA_FetchEpisodeMirrorsBySlug(m.top.slug, m.top.season, m.top.episode)
        end if
    else
        mirrors = HA_FetchMovieMirrors(m.top.imdb, m.top.tmdb, m.top.refer)
    end if
    if mirrors = invalid then mirrors = []
    m.top.result = { mirrors: mirrors }
end sub

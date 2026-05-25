sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    slug = m.top.slug
    season = m.top.season
    episode = m.top.episode
    if slug = invalid then slug = ""
    desc = ""
    if slug <> "" and season > 0 and episode > 0 then
        desc = HA_FetchEpisodeDesc(slug, season, episode)
    end if
    m.top.result = { desc: desc, season: season, episode: episode }
end sub

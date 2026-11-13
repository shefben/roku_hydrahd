sub Main()
    m.sentinel = "task context"
    check(U_FirstMatch("id=123", "id=(\d+)") = "123", "regex capture")
    check(m.sentinel = "task context", "regex helpers preserve task context")
    html = ReadAsciiFile("pkg:/tools/fixtures/hydra/home.html")
    rows = HA_ParseHomeRows(html)
    check(rows.Count() = 6, "homepage includes all three movie and series sections")
    if rows.Count() >= 2 then
        check(rows[0].title = "Trending Movies", "trending movie row")
        check(rows[1].title = "Trending TV Shows", "trending series row")
    end if
    if rows.Count() = 6 then
        check(rows[2].title = "Latest Movies" and rows[4].title = "Top Rated Movies", "consecutive homepage headers retained")
        for each row in rows
            check(row.items.Count() = 2, "each homepage tab has its own items")
        end for
    end if
    check(HA_Base() = "https://hydrahd.gd", "current default domain")
    check(U_NormalizeBaseUrl(" https://hydrahd.ru/ ") = "https://hydrahd.gd", "retired settings migrate")
    check(U_NormalizeBaseUrl("https://custom.example/") = "https://custom.example", "custom settings preserved")
    check(U_NormalizeBaseUrl("https://hydrahd.ws") = "https://hydrahd.gd", "saved .ws setting migrates (mirror ajax 404s on a cross-domain Referer)")
    check(U_CatalogUrl("https://hydrahd.ws/movie/52481-watch-avatar-2009-online") = "https://hydrahd.gd/movie/52481-watch-avatar-2009-online", "saved .ws referer rebased")
    check(U_CatalogIdentity("https://hydrahd.gd/movie/52481-watch-avatar-2009-online") = "https://hydrahd.ru/movie/52481-watch-avatar-2009-online", "new domain keeps registry identity")
    check(U_CatalogUrl("https://hydrahd.ru/movie/52481-watch-avatar-2009-online") = "https://hydrahd.gd/movie/52481-watch-avatar-2009-online", "saved catalog URL rebased")
    check(U_CatalogUrl("https://play.xpass.top/e/movie/19995") = "https://play.xpass.top/e/movie/19995", "provider URLs untouched")
    check(U_CatalogIdentity("https://hydrahd.gd/watchseries/slow-horses-online-free") = "https://hydrahd.ru/watchseries/slow-horses-online-free", "resume and favorite identity retained")
    m.testRegistry = { values: {}, Exists: T_RegistryExists, Read: T_RegistryRead }
    oldHref = "https://hydrahd.ru/movie/52481-watch-avatar-2009-online"
    newHref = "https://hydrahd.gd/movie/52481-watch-avatar-2009-online"
    m.testRegistry.values[oldHref] = "favorite"
    m.testRegistry.values["m:" + oldHref] = FormatJson({ pos: 123, dur: 1000, done: false })
    check(W_ItemKey("tt0499549", newHref) = oldHref, "current title uses existing registry key")
    check(W_IsFavorite("tt0499549", newHref), "existing favorite found for new domain")
    progress = W_GetMovieProgress("tt0499549", newHref)
    check(progress <> invalid and progress.pos = 123, "existing resume position found for new domain")
    m.testRegistry.values = {}
    m.testRegistry.values[newHref] = "favorite"
    m.testRegistry.values["m:" + newHref] = FormatJson({ pos: 234, dur: 1000, done: false })
    check(W_IsFavorite("tt0499549", newHref), "favorite saved after manual domain switch preserved")
    progress = W_GetMovieProgress("tt0499549", newHref)
    check(progress <> invalid and progress.pos = 234, "progress saved after manual domain switch preserved")
    m.testBase = "https://catalog.example/"
    check(HA_Base() = "https://catalog.example", "custom base is used")
    check(U_CatalogUrl("https://hydrahd.ru/movie/52481") = "https://catalog.example/movie/52481", "saved catalog URL uses custom base")
    m.testBase = invalid
    cards = HA_ParseCards(ReadAsciiFile("pkg:/tools/fixtures/hydra/search.html"))
    check(cards.Count() >= 10, "full search results include movie and TV cards")
    details = HA_ParseDetails(ReadAsciiFile("pkg:/tools/fixtures/hydra/movie.html"), "movie", "202724", "https://hydrahd.gd/movie/202724-watch-spider-man-brand-new-day-2026-online")
    check(details.tmdb = "969681", "movie site ID is distinct from TMDB ID")
    seasons = HA_ParseSeasons(ReadAsciiFile("pkg:/tools/fixtures/hydra/seasons.html"))
    check(seasons.Count() >= 5, "series seasons")
    if seasons.Count() > 0 then check(seasons[0].episodes.Count() = 6, "first season episodes")
    ids = HA_ParseEpisodeIds(ReadAsciiFile("pkg:/tools/fixtures/hydra/episode.html"))
    check(ids.tmdb = "95480" and ids.imdb = "tt5875444", "episode mirror IDs")
    mirrors = HA_ParseMirrors(ReadAsciiFile("pkg:/tools/fixtures/hydra/movie-mirrors.html"))
    check(mirrors.Count() = 11, "current movie mirrors excluding blocked host")
    tvMirrors = HA_ParseMirrors(ReadAsciiFile("pkg:/tools/fixtures/hydra/tv-mirrors.html"))
    check(tvMirrors.Count() = 11, "current episode mirrors excluding blocked host")
    for each mirror in tvMirrors
        check(Instr(1, mirror.link, "&amp;") = 0, "decoded mirror query parameters")
    end for
    check(HA_ParseCards(ReadAsciiFile("pkg:/tools/fixtures/hydra/movies-page2.html")).Count() = 4, "movie pagination cards")
    check(HA_ParseCards(ReadAsciiFile("pkg:/tools/fixtures/hydra/tv-page2.html")).Count() = 4, "TV pagination cards")
    m.testRequests = []
    m.testReplies = {}
    refer = "https://hydrahd.gd/watchseries/slow-horses-online-free/season/1/episode/1"
    m.testReplies[refer] = ReadAsciiFile("pkg:/tools/fixtures/hydra/episode.html")
    m.testReplies["https://hydrahd.gd/ajax/tv_0.php?i=tt5875444&t=95480&s=1&e=1"] = ReadAsciiFile("pkg:/tools/fixtures/hydra/tv-mirrors.html")
    result = HA_FetchEpisodeMirrorInfoBySlug("slow-horses", 1, 1)
    check(result.tmdb = "95480" and result.imdb = "tt5875444", "episode mirror result carries numeric fallback IDs")
    check(result.mirrors.Count() = 11, "episode request uses parsed IDs")
    check(result.refer = refer, "episode mirror referer retained")
    m.top = { kind: "tv", imdb: "tt5875444", tmdb: "slow-horses", slug: "slow-horses", season: 1, episode: 1, refer: "https://hydrahd.gd/watchseries/slow-horses-online-free" }
    doWork()
    check(m.top.result.tmdb = "95480", "server task converts series slug to numeric mirror IDs")
    check(m.top.result.mirrors.Count() = 11, "server task returns episode mirrors without TMDB enrichment")
    m.testReplies["https://hydrahd.gd/movies/date/2"] = ReadAsciiFile("pkg:/tools/fixtures/hydra/movies-page2.html")
    m.testReplies["https://hydrahd.gd/tv-shows/date/2"] = ReadAsciiFile("pkg:/tools/fixtures/hydra/tv-page2.html")
    check(HA_FetchMovies(2).Count() = 4, "movie page fetch uses canonical pagination URL")
    check(HA_FetchTvShows(2).Count() = 4, "TV page fetch uses canonical pagination URL")
    m.testReplies["https://hydrahd.gd/index.php?menu=search&query=Avatar%20%26%20aliens"] = ReadAsciiFile("pkg:/tools/fixtures/hydra/search.html")
    check(HA_Search(" Avatar & aliens ").Count() >= 10, "search request trims and encodes query")
    print "FAILURES: "; m.failures
end sub

function T_Get(url as String, refer as String) as String
    m.testRequests.Push({ url: url, refer: refer })
    if m.testReplies.DoesExist(url) then return m.testReplies[url]
    return ""
end function

function T_RegistryExists(key as String) as Boolean
    return m.values.DoesExist(key)
end function

function T_RegistryRead(key as String) as String
    return m.values[key]
end function

sub check(ok as Boolean, label as String)
    if m.failures = invalid then m.failures = 0
    if not ok then
        print "FAIL: "; label
        m.failures = m.failures + 1
    end if
end sub


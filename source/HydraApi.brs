' HydraApi.brs - Scrapes hydrahd.ru pages and exposes typed result objects.
' All functions are synchronous and meant to be called from Tasks (background threads).

function HA_Base() as String
    base = U_PrefDefault("baseUrl", "https://hydrahd.ru")
    if Right(base, 1) = "/" then base = Left(base, Len(base) - 1)
    return base
end function

function HA_UA() as String
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
end function

' --- HTTP -------------------------------------------------------------

function HA_Get(url as String, refer as String) as String
    xfer = CreateObject("roUrlTransfer")
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.AddHeader("X-Roku-Reserved-Dev-Id", "")
    xfer.InitClientCertificates()
    xfer.SetUrl(url)
    xfer.AddHeader("User-Agent", HA_UA())
    xfer.AddHeader("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    xfer.AddHeader("Accept-Language", "en-US,en;q=0.9")
    if refer <> invalid and refer <> "" then xfer.AddHeader("Referer", refer)
    xfer.EnableEncodings(true)
    ' Bail out if the response stalls for 12s straight. Stops a wedged
    ' DNS / unreachable host from holding a task thread (and the visible
    ' loading spinner) for the full 60s OS-level TCP timeout.
    xfer.SetMinimumTransferRate(1, 12)
    body = xfer.GetToString()
    if body = invalid then return ""
    return body
end function

' HA_GetJson is used by ResolveTask to call the LAN resolver. Synchronous
' GetToString has no timeout and would hang the task thread for 30-60s
' when the resolver host is unreachable - that's perceived as a freeze
' because MirrorPicker sits on its "Resolving stream from ..." spinner
' the whole time. Async + 8s deadline gives us a fast, clean failure
' that MirrorPicker can surface as "Could not resolve a direct stream".
function HA_GetJson(url as String) as Object
    xfer = CreateObject("roUrlTransfer")
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.SetUrl(url)
    xfer.AddHeader("User-Agent", HA_UA())
    xfer.AddHeader("Accept", "application/json,text/plain,*/*")
    xfer.EnableEncodings(true)

    msgPort = CreateObject("roMessagePort")
    xfer.SetMessagePort(msgPort)
    if not xfer.AsyncGetToString() then return invalid

    deadlineMs = 8000
    timer = CreateObject("roTimespan")
    timer.mark()
    body = invalid
    while timer.totalMilliseconds() < deadlineMs
        remaining = deadlineMs - timer.totalMilliseconds()
        if remaining < 1 then exit while
        msg = wait(remaining, msgPort)
        if msg = invalid then exit while
        if type(msg) = "roUrlEvent" then
            if msg.getResponseCode() = 200 then body = msg.getString()
            exit while
        end if
    end while

    if body = invalid then
        xfer.AsyncCancel()
        return invalid
    end if
    if body = "" then return invalid
    return ParseJson(body)
end function

' --- Parsers ----------------------------------------------------------

' Each card on the home / list pages looks like:
'   <a class="hthis" href="/movie/12345-watch-..." title="Title online free" ...>
'      <span>...year...</span>
'      <img data-src="https://image.tmdb.org/...jpg" alt="Title poster">
'   </a>
function HA_ParseCards(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    re = CreateObject("roRegex", "<a[^>]+class=" + chr(34) + "hthis" + chr(34) + "[^>]+href=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34) + "[^>]+title=" + chr(34) + "([^" + chr(34) + "]*)" + chr(34) + "[^>]*>(.*?)</a>", "is")
    matches = re.matchAll(html)
    if matches = invalid then return out
    for each mt in matches
        href = U_Trim(mt[1])
        title = U_HtmlDecode(mt[2])
        inner = mt[3]

        kind = ""
        slug = ""
        id = ""
        if Instr(1, href, "/watchseries/") = 1 then
            kind = "tv"
            slug = Mid(href, Len("/watchseries/") + 1)
            slug = slug.Replace("-online-free", "")
            id = slug
        else if Instr(1, href, "/movie/") = 1 then
            kind = "movie"
            rest = Mid(href, Len("/movie/") + 1)
            id = U_FirstMatch(rest, "^(\d+)")
            slug = rest
        end if

        if kind <> "" then
            poster = U_FirstMatch(inner, "data-src=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34))
            if poster = "" then poster = U_FirstMatch(inner, "src=" + chr(34) + "(https://image\.tmdb\.org/[^" + chr(34) + "]+)" + chr(34))
            year = U_FirstMatch(inner, ">\s*(\d{4})\s*<")
            rating = U_FirstMatch(inner, "fa-star[^>]*></i>\s*([0-9.]+)")
            quality = U_FirstMatch(inner, ">\s*(HD|TS|CAM|SD|4K)\s*<")
            cleanTitle = title.Replace(" online free", "")
            cleanTitle = cleanTitle.Replace("Watch ", "")
            cleanTitle = U_Trim(cleanTitle)

            item = {
                id: id
                kind: kind
                title: cleanTitle
                year: year
                rating: rating
                quality: quality
                poster: U_TmdbImage(poster, "w500")
                posterHd: U_TmdbImage(poster, "w780")
                href: U_AbsUrl(href, HA_Base())
            }
            out.Push(item)
        end if
    end for
    return out
end function

' Group cards into rows by the <h3> headers preceding them.
function HA_ParseHomeRows(html as String) as Object
    rows = []
    if html = invalid or html = "" then return rows

    titleRe = CreateObject("roRegex", "<h3[^>]*>.*?title=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34) + ".*?>([^<]+)</a>.*?</h3>", "is")
    titleMatches = titleRe.matchAll(html)
    headers = []
    if titleMatches <> invalid then
        for each tm in titleMatches
            label = U_Trim(tm[2])
            if label = "" then label = U_Trim(tm[1])
            if label <> "" then headers.Push({label: label, raw: tm[0]})
        end for
    end if

    if headers.Count() = 0 then
        return [{ title: "Featured", items: HA_ParseCards(html) }]
    end if

    cursor = 0
    for i = 0 to headers.Count() - 1
        h = headers[i]
        idx = Instr(cursor + 1, html, h.raw)
        if idx > 0 then
            startBody = idx + Len(h.raw)
            endBody = Len(html) + 1
            if i + 1 < headers.Count() then
                nextIdx = Instr(startBody, html, headers[i + 1].raw)
                if nextIdx > 0 then endBody = nextIdx
            end if
            chunk = Mid(html, startBody, endBody - startBody)
            cards = HA_ParseCards(chunk)
            if cards.Count() > 0 then
                rows.Push({ title: h.label, items: cards })
            end if
            cursor = endBody
        end if
    end for

    if rows.Count() = 0 then
        rows.Push({ title: "Featured", items: HA_ParseCards(html) })
    end if
    return rows
end function

function HA_FetchHome() as Object
    html = HA_Get(HA_Base() + "/", "")
    return HA_ParseHomeRows(html)
end function

function HA_FetchMovies(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/movies/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_FetchPopular(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/movies/popular/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_FetchTopRated(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/movies/star-rating/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_FetchTvShows(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/tv-shows/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_FetchTvShowsPopular(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/tv-shows/popular/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_FetchTvShowsTopRated(page as Integer) as Object
    if page < 1 then page = 1
    url = HA_Base() + "/tv-shows/star-rating/" + page.ToStr() + "/"
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

function HA_Search(query as String) as Object
    url = HA_Base() + "/index.php?menu=search&query=" + U_UrlEncode(query)
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseCards(html)
end function

' --- Detail pages -----------------------------------------------------

function HA_FetchMovieDetails(href as String, id as String) as Object
    url = href
    if url = "" or url = invalid then
        url = HA_Base() + "/movie/" + id + "-watch-online"
    end if
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseDetails(html, "movie", id, url)
end function

function HA_FetchTvDetails(href as String, slug as String) as Object
    url = href
    if url = "" or url = invalid then
        url = HA_Base() + "/watchseries/" + slug + "-online-free"
    end if
    html = HA_Get(url, HA_Base() + "/")
    return HA_ParseDetails(html, "tv", slug, url)
end function

function HA_ParseDetails(html as String, kind as String, id as String, baseHref as String) as Object
    info = {
        kind: kind
        id: id
        title: ""
        description: ""
        poster: ""
        backdrop: ""
        year: ""
        rating: ""
        runtime: ""
        genres: []
        cast: []
        imdb: ""
        tmdb: id
        href: baseHref
        seasons: []
    }

    if html = invalid or html = "" then return info

    title = U_FirstMatch(html, "<meta property=" + chr(34) + "og:title" + chr(34) + " content=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34))
    title = title.Replace("Stream ", "")
    title = title.Replace(" Online Free Watch Full Now HD - HydraHD", "")
    title = title.Replace(" - HydraHD", "")
    info.title = U_Trim(U_HtmlDecode(title))

    poster = U_FirstMatch(html, "<meta property=" + chr(34) + "og:image" + chr(34) + " content=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34))
    info.poster = U_TmdbImage(poster, "w500")
    info.backdrop = U_TmdbImage(U_FirstMatch(html, "background-image:\s*url\(([^)]+)\)"), "w1280")
    if info.backdrop = "" then info.backdrop = U_TmdbImage(poster, "w1280")

    desc = U_FirstMatch(html, "<p style=" + chr(34) + "font-size:16px;color:\s*#fff" + chr(34) + ">([^<]+)</p>")
    if desc = "" then desc = U_FirstMatch(html, "<meta name=" + chr(34) + "description" + chr(34) + " content=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34))
    info.description = U_Trim(U_HtmlDecode(desc))

    info.year = U_FirstMatch(html, ">\s*(\d{4})\s*<")
    info.rating = U_FirstMatch(html, "fa-star[^>]*></i>\s*([0-9.]+)")
    info.runtime = U_FirstMatch(html, "(\d+\s*min)")

    info.imdb = U_FirstMatch(html, "(tt\d{6,})")

    if kind = "movie" then
        info.tmdb = U_FirstMatch(html, chr(34) + "t" + chr(34) + "\s*:\s*" + chr(34) + "(\d+)" + chr(34))
        if info.tmdb = "" then info.tmdb = id
    else
        info.seasons = HA_ParseSeasons(html)
    end if

    ' Genres
    genreRe = CreateObject("roRegex", "/genres/watch-([a-z-]+)-movies-online-free", "ig")
    gm = genreRe.matchAll(html)
    seen = {}
    if gm <> invalid then
        for each g in gm
            label = g[1].Replace("-", " ")
            label = UCase(Left(label, 1)) + Mid(label, 2)
            if not seen.DoesExist(label) then
                seen[label] = true
                info.genres.Push(label)
            end if
        end for
    end if

    ' Cast (uses /person/<id> pattern)
    castRe = CreateObject("roRegex", "<a[^>]+href=" + chr(34) + "/person/(\d+)" + chr(34) + "[^>]*title=" + chr(34) + "watch ([^" + chr(34) + "]+) movies", "ig")
    cm = castRe.matchAll(html)
    if cm <> invalid then
        for each c in cm
            info.cast.Push({ id: c[1], name: U_HtmlDecode(c[2]) })
            if info.cast.Count() >= 12 then exit for
        end for
    end if

    return info
end function

function HA_ParseSeasons(html as String) as Object
    seasons = []
    epRe = CreateObject("roRegex", "data-slug=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34) + "[\s\S]*?data-season=" + chr(34) + "(\d+)" + chr(34) + "[\s\S]*?data-episode=" + chr(34) + "(\d+)" + chr(34) + "[\s\S]*?<span class=" + chr(34) + "tv_episode_name" + chr(34) + "[^>]*>([\s\S]*?)</span>", "ig")
    matches = epRe.matchAll(html)
    if matches = invalid then return seasons

    dateRe = CreateObject("roRegex", "(\d{4}-\d{2}-\d{2})", "")
    bySeason = {}
    for each mt in matches
        slug = mt[1]
        s = mt[2].ToInt()
        e = mt[3].ToInt()
        raw = U_Trim(U_HtmlDecode(U_StripTags(mt[4])))
        ' Hydrahd packs the airdate into the same span as the title:
        '   "1997-08-13 - Cartman Gets an Anal Probe"
        airDate = ""
        title = raw
        dm = dateRe.match(raw)
        if dm <> invalid and dm.Count() >= 2 then
            airDate = dm[1]
            ' Strip "<date> -" prefix
            stripRe = CreateObject("roRegex", "^\d{4}-\d{2}-\d{2}\s*-\s*", "")
            title = U_Trim(stripRe.replace(raw, ""))
        end if
        if title = "" then title = "Episode " + e.ToStr()
        key = "s" + s.ToStr()
        if not bySeason.DoesExist(key) then bySeason[key] = []
        bySeason[key].Push({
            slug: slug, season: s, episode: e,
            name: title, airDate: airDate
        })
    end for

    sortable = []
    for each k in bySeason
        n = Mid(k, 2).ToInt()
        sortable.Push({ k: k, n: n })
    end for
    ' simple insertion sort
    for i = 1 to sortable.Count() - 1
        j = i
        while j > 0 and sortable[j].n < sortable[j - 1].n
            tmp = sortable[j]
            sortable[j] = sortable[j - 1]
            sortable[j - 1] = tmp
            j = j - 1
        end while
    end for
    for each entry in sortable
        eps = bySeason[entry.k]
        ' sort episodes ascending
        for i = 1 to eps.Count() - 1
            j = i
            while j > 0 and eps[j].episode < eps[j - 1].episode
                tmp = eps[j]
                eps[j] = eps[j - 1]
                eps[j - 1] = tmp
                j = j - 1
            end while
        end for
        seasons.Push({ number: entry.n, label: "Season " + entry.n.ToStr(), episodes: eps })
    end for

    return seasons
end function

' --- Stream / mirror discovery ---------------------------------------

' Returns array of mirror objects:
' { id, name, link, qualityHint, isPremium }
function HA_FetchMovieMirrors(imdb as String, tmdb as String, refer as String) as Object
    url = HA_Base() + "/ajax/mov_0.php?i=" + U_UrlEncode(imdb) + "&t=" + U_UrlEncode(tmdb)
    html = HA_Get(url, refer)
    return HA_ParseMirrors(html)
end function

function HA_FetchEpisodeMirrors(imdb as String, tmdb as String, season as Integer, episode as Integer, refer as String) as Object
    url = HA_Base() + "/ajax/tv_0.php?i=" + U_UrlEncode(imdb) + "&t=" + U_UrlEncode(tmdb) + "&s=" + season.ToStr() + "&e=" + episode.ToStr()
    html = HA_Get(url, refer)
    return HA_ParseMirrors(html)
end function

function HA_FetchEpisodeMirrorsBySlug(slug as String, season as Integer, episode as Integer) as Object
    refer = HA_Base() + "/watchseries/" + slug + "-online-free/season/" + season.ToStr() + "/episode/" + episode.ToStr()
    html = HA_Get(refer, HA_Base() + "/")
    info = HA_ParseEpisodeIds(html)
    if info.imdb = "" or info.tmdb = "" then return []
    return HA_FetchEpisodeMirrors(info.imdb, info.tmdb, season, episode, refer)
end function

function HA_ParseEpisodeIds(html as String) as Object
    out = { imdb: "", tmdb: "" }
    if html = invalid or html = "" then return out
    out.imdb = U_FirstMatch(html, "(tt\d{6,})")
    out.tmdb = U_FirstMatch(html, chr(34) + "t" + chr(34) + "\s*:\s*" + chr(34) + "(\d+)" + chr(34))
    return out
end function

function HA_ParseMirrors(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    btnRe = CreateObject("roRegex", "<div[^>]+class=" + chr(34) + "iframe-server-button([^" + chr(34) + "]*)" + chr(34) + "[^>]+data-id=" + chr(34) + "(\d+)" + chr(34) + "[^>]+data-link=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34) + "[^>]*>(.*?)</div>", "is")
    m = btnRe.matchAll(html)
    if m = invalid then return out
    for each btn in m
        flags = btn[1]
        id = btn[2]
        link = U_HtmlDecode(btn[3])
        inner = btn[4]

        name = U_Trim(U_HtmlDecode(U_FirstMatch(inner, "<p[^>]*>([^<]+)</p>")))
        if name = "" then name = U_Trim(U_HtmlDecode(U_FirstMatch(inner, "<span[^>]*class=" + chr(34) + "iframe-server-name" + chr(34) + "[^>]*>([^<]+)</span>")))
        if name = "" then name = U_Trim(U_HtmlDecode(U_FirstMatch(inner, "^\s*([A-Za-z0-9 _.-]{2,30})\s*<")))
        if name = "" then name = "Server " + id

        ' Quality detection: the source HTML inconsistently labels the
        ' resolution. The original `iframe-server-quality` element only
        ' fires for a small subset of mirrors - most mirrors carry the
        ' resolution as a class flag, in a data-quality attribute, or
        ' inline as plain text inside the button. Layered fallbacks here
        ' so 1080p / 720p / etc. show up consistently in the picker.
        quality = U_FirstMatch(inner, "iframe-server-quality[^>]*>([^<]+)<")
        if quality = "" then
            quality = U_FirstMatch(inner, "data-quality=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34))
        end if
        if quality = "" then
            quality = U_FirstMatch(inner, "(2160p|1080p|720p|480p|360p|4K|FHD|UHD|HD|SD|CAM|TS)")
        end if
        if quality = "" then
            quality = U_FirstMatch(flags, "(2160p|1080p|720p|480p|360p|4K|FHD|UHD|HD|SD|CAM|TS)")
        end if
        if quality = "" then
            quality = U_FirstMatch(link, "(2160p|1080p|720p|480p|4K|FHD|UHD|HD)")
        end if
        out.Push({
            id: id
            name: name
            link: link
            qualityHint: U_Trim(U_HtmlDecode(quality))
            isPremium: Instr(1, flags, "premium") > 0
            host: HA_HostOf(link)
        })
    end for
    return out
end function

function HA_HostOf(url as String) as String
    if url = invalid or url = "" then return ""
    h = U_FirstMatch(url, "https?://([^/]+)/")
    if h = "" then return ""
    if Left(h, 4) = "www." then h = Mid(h, 5)
    return h
end function

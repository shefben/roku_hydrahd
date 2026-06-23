' TmdbApi.brs - Real metadata enrichment from The Movie Database (TMDB).
'
' HydraHD's own detail pages only carry a generic "watch online free"
' blurb and a thin cast list, so titles look bare. When a (free) TMDB v3
' API key is configured we overlay the real synopsis, rating, runtime,
' genres, cast (with headshots) and a high-res backdrop on top of the
' scraped HydraHD `info` object. Everything degrades gracefully: with no
' key, or on any network/parse failure, the original HydraHD data is
' returned unchanged.
'
' Key resolution order:
'   1. registry "tmdbKey"  (set in Settings)
'   2. TMDB_BuildKey()     (paste a key here to ship one with the build)

function TMDB_BuildKey() as String
    ' Paste a free TMDB v3 API key here to bake it into the build, or set
    ' it at runtime via Settings -> "TMDB API key". Empty = disabled.
    return ""
end function

function TMDB_Key() as String
    k = U_PrefDefault("tmdbKey", "")
    if k <> invalid and k <> "" then return k
    return TMDB_BuildKey()
end function

function TMDB_Enabled() as Boolean
    return TMDB_Key() <> ""
end function

function TMDB_Image(path as String, size as String) as String
    if path = invalid or path = "" then return ""
    if size = "" then size = "w500"
    if Left(path, 4) = "http" then return path
    return "https://image.tmdb.org/t/p/" + size + path
end function

function TMDB_IsNumeric(s as Dynamic) as Boolean
    if s = invalid then return false
    str = ""
    if Type(s) = "String" or Type(s) = "roString" then
        str = s
    else
        return false
    end if
    if str = "" then return false
    re = CreateObject("roRegex", "^\d+$", "")
    return re.isMatch(str)
end function

function TMDB_FmtRating(v as Dynamic) as String
    if v = invalid then return ""
    n = 0.0
    n = v
    if n <= 0 then return ""
    ' one decimal place
    tenths = Int(n * 10 + 0.5)
    whole = tenths \ 10
    frac = tenths mod 10
    return whole.ToStr() + "." + frac.ToStr()
end function

' Look up a TMDB id by title (+ optional year) when HydraHD didn't give us
' a numeric one (common for TV, whose HydraHD id is a slug). Returns "" on
' miss so the caller can fall back to the scraped data.
function TMDB_FindId(title as String, year as String, kind as String) as String
    if not TMDB_Enabled() then return ""
    if title = invalid or title = "" then return ""
    path = "movie"
    if kind = "tv" then path = "tv"
    url = "https://api.themoviedb.org/3/search/" + path + "?api_key=" + TMDB_Key() + "&query=" + U_UrlEncode(title)
    if year <> invalid and year <> "" then
        if kind = "tv" then
            url = url + "&first_air_date_year=" + year
        else
            url = url + "&year=" + year
        end if
    end if
    data = HA_GetJson(url)
    if data = invalid or data.results = invalid then return ""
    if data.results.Count() = 0 then return ""
    first = data.results[0]
    if first.id = invalid then return ""
    return first.id.ToStr()
end function

' Enrich a HydraHD `info` detail object in place with TMDB data. Safe to
' call unconditionally - returns `info` untouched when disabled or on any
' failure. `info` must have at least .kind, .title, .year, .tmdb.
function TMDB_Enrich(info as Object) as Object
    if info = invalid then return info
    if not TMDB_Enabled() then return info

    tmdb = ""
    if info.tmdb <> invalid then tmdb = info.tmdb.ToStr()
    if not TMDB_IsNumeric(tmdb) then
        ' TV (and some movies) only have a slug; look the id up by title.
        tmdb = TMDB_FindId(info.title, info.year, info.kind)
    end if
    if not TMDB_IsNumeric(tmdb) then return info

    path = "movie"
    if info.kind = "tv" then path = "tv"
    url = "https://api.themoviedb.org/3/" + path + "/" + tmdb + "?api_key=" + TMDB_Key() + "&append_to_response=credits&language=en-US"
    d = HA_GetJson(url)
    if d = invalid then return info

    info.tmdb = tmdb
    if d.overview <> invalid and d.overview <> "" then info.description = d.overview
    if d.backdrop_path <> invalid and d.backdrop_path <> "" then info.backdrop = TMDB_Image(d.backdrop_path, "w1280")
    if (info.poster = "" or info.poster = invalid) and d.poster_path <> invalid then info.poster = TMDB_Image(d.poster_path, "w500")

    r = TMDB_FmtRating(d.vote_average)
    if r <> "" then info.rating = r

    if info.kind = "tv" then
        if d.episode_run_time <> invalid and Type(d.episode_run_time) = "roArray" and d.episode_run_time.Count() > 0 then
            info.runtime = d.episode_run_time[0].ToStr() + " min"
        end if
        if d.first_air_date <> invalid and Len(d.first_air_date) >= 4 then info.year = Left(d.first_air_date, 4)
    else
        if d.runtime <> invalid and d.runtime > 0 then info.runtime = d.runtime.ToStr() + " min"
        if d.release_date <> invalid and Len(d.release_date) >= 4 then info.year = Left(d.release_date, 4)
    end if

    if d.genres <> invalid and d.genres.Count() > 0 then
        g = []
        for each ge in d.genres
            if ge.name <> invalid then g.Push(ge.name)
        end for
        if g.Count() > 0 then info.genres = g
    end if

    if d.credits <> invalid and d.credits.cast <> invalid and d.credits.cast.Count() > 0 then
        cast = []
        for each c in d.credits.cast
            entry = { id: "", name: "", character: "", photo: "" }
            if c.id <> invalid then entry.id = c.id.ToStr()
            if c.name <> invalid then entry.name = c.name
            if c.character <> invalid then entry.character = c.character
            if c.profile_path <> invalid and c.profile_path <> "" then entry.photo = TMDB_Image(c.profile_path, "w185")
            cast.Push(entry)
            if cast.Count() >= 18 then exit for
        end for
        if cast.Count() > 0 then info.cast = cast
    end if

    return info
end function

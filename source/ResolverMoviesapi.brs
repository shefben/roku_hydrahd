' ResolverMoviesapi.brs - moviesapi.to (vidora API, cdn.vidspark.to fallback).
'
' moviesapi.to is a single-page app. Its own source is
'   GET /api/vidora/v1/movie/<tmdb> | /v1/tv/<tmdb>/<s>/<e>
' with header x-player-key (a constant in the page's /assets/index-*.js,
' written `"x-player-key":<ident>` ... `<ident>=`<hex>``) and
' Referer https://moviesapi.to/. Answer: { result, sources: [{url, tracks}] }.
' That stream is AES-128 HLS whose segments need the moviesapi.to Referer.
'
' When vidora has nothing ("Movie not yet encoded") the page falls back to
' an iframe of cdn.vidspark.to/<movie/ID | tv/ID/S/E>. Same API there, with
' its own key in /assets/main-*.js, plus ?source=<server key>; the servers
' are listed in that bundle as {key:`p9fx`,label:`Vertex`,...}.
'   w7dn: HLS. Some titles serve segments wrapped in a PNG, which Roku
'         cannot play, so the first segment is checked.
'   p9fx: HEVC DASH (or a blocked MP4 proxy). Tried last.
'
' Keys are cached per bundle file name, so the 1.3 MB bundle is read
' again only after the site redeploys.

function MA_PlayerKey(origin as String, pageBody as String, bundleRe as String, refer as String, session as Object) as String
    bundle = U_FirstMatch(pageBody, bundleRe)
    if bundle = "" then return ""
    cache = CreateObject("roRegistrySection", "HydraHD_Cache")
    slot = "pk:" + origin + bundle
    if cache.Exists(slot) then return cache.Read(slot)
    js = HC_Get(session, origin + bundle, { "Referer": refer }, 12000)
    if js = invalid or js.body = "" then return ""
    ident = U_FirstMatch(js.body, Chr(34) + "x-player-key" + Chr(34) + ":([A-Za-z_$][A-Za-z0-9_$]*)")
    if ident = "" then return ""
    escaped = CreateObject("roRegex", "\$", "").ReplaceAll(ident, "\\$")
    key = U_FirstMatch(js.body, "[,\s;]" + escaped + "=" + Chr(96) + "([^" + Chr(96) + "]*)" + Chr(96))
    if key = "" then return ""
    servers = ""
    for each hit in U_AllMatches(js.body, "\{key:" + Chr(96) + "(\w+)" + Chr(96) + ",label:" + Chr(96))
        if servers <> "" then servers = servers + ","
        servers = servers + hit[1]
    end for
    cache.Write(slot, key)
    cache.Write("sv:" + origin + bundle, servers)
    cache.Flush()
    return key
end function

function MA_Servers(origin as String, pageBody as String, bundleRe as String) as Object
    bundle = U_FirstMatch(pageBody, bundleRe)
    cache = CreateObject("roRegistrySection", "HydraHD_Cache")
    slot = "sv:" + origin + bundle
    if bundle = "" or not cache.Exists(slot) or cache.Read(slot) = "" then return []
    return cache.Read(slot).Tokenize(",")
end function

' Playable result from one vidora answer, or invalid.
function MA_Result(body as String, referer as String, session as Object) as Object
    data = ParseJson(body)
    if data = invalid or type(data) <> "roAssociativeArray" or data.result <> true then return invalid
    if data.sources = invalid or type(data.sources) <> "roArray" or data.sources.Count() = 0 then return invalid
    src = data.sources[0]
    if type(src) <> "roAssociativeArray" or src.url = invalid or src.url = "" then return invalid
    url = src.url
    origin = referer
    if Right(origin, 1) = "/" then origin = Left(origin, Len(origin) - 1)
    head = HC_Get(session, url, { "Referer": referer, "Origin": origin }, 8000)
    if head = invalid or head.body = "" then return invalid
    fmt = ""
    if Left(head.body, 7) = "#EXTM3U" then
        ' Encrypted segments cannot be sniffed; plain ones are checked so a
        ' PNG-wrapped or dead stream is skipped.
        if Instr(1, head.body, "#EXT-X-KEY") = 0 and not RP_HlsFirstSegmentOk(session, head.body, url, referer) then
            print "[moviesapi] segments not playable"
            return invalid
        end if
        fmt = "hls"
    else if Instr(1, Left(head.body, 400), "<MPD") > 0 then
        fmt = "dash"
    else
        return invalid
    end if
    subs = []
    if src.tracks <> invalid and type(src.tracks) = "roArray" then
        for each t in src.tracks
            if type(t) = "roAssociativeArray" and t.file <> invalid and t.file <> "" then
                name = "Subtitles"
                if t.label <> invalid and t.label <> "" then name = t.label
                lang = ""
                if LCase(Left(name, 7)) = "english" then lang = "en"
                subs.Push({ url: t.file, language: lang, name: name })
            end if
        end for
    end if
    return { url: url, streamFormat: fmt, qualities: [], subtitles: subs, chapters: [], referer: referer, userAgent: "" }
end function

function RP_ResolveMoviesapiTo(embedUrl as String, refer as String, session as Object) as Object
    parts = CreateObject("roRegex", "moviesapi\.[a-z]+/(movie|tv)/(\d+)(?:-(\d+)-(\d+))?", "i").Match(embedUrl)
    if parts = invalid or parts.Count() < 3 then return invalid
    kind = LCase(parts[1])
    apiPath = "/api/vidora/v1/movie/" + parts[2]
    pagePath = "/movie/" + parts[2]
    if kind = "tv" then
        if parts.Count() < 5 or parts[3] = "" then return invalid
        apiPath = "/api/vidora/v1/tv/" + parts[2] + "/" + parts[3] + "/" + parts[4]
        pagePath = "/tv/" + parts[2] + "/" + parts[3] + "/" + parts[4]
    end if
    origin = HC_OriginOf(embedUrl)
    q = Chr(34)

    page = HC_Get(session, embedUrl, { "Referer": refer }, 8000)
    if page <> invalid and page.body <> "" then
        key = MA_PlayerKey(origin, page.body, "src=" + q + "(/assets/index-[^" + q + "]+\.js)" + q, embedUrl, session)
        if key <> "" then
            res = HC_Get(session, origin + apiPath, { "x-player-key": key, "Referer": origin + "/" }, 10000)
            if res <> invalid and res.status = 200 then
                out = MA_Result(res.body, origin + "/", session)
                if out <> invalid then return out
            end if
        end if
    end if

    ' Fallback player, as the page itself does.
    spark = "https://cdn.vidspark.to"
    mainRe = "src=" + q + "(/assets/main-[^" + q + "]+\.js)" + q
    page = HC_Get(session, spark + pagePath, { "Referer": origin + "/" }, 8000)
    if page = invalid or page.body = "" then return invalid
    key = MA_PlayerKey(spark, page.body, mainRe, spark + pagePath, session)
    if key = "" then return invalid
    servers = MA_Servers(spark, page.body, mainRe)
    ordered = []
    for each s in servers
        if s <> "p9fx" then ordered.Push(s)
    end for
    for each s in servers
        if s = "p9fx" then ordered.Push(s)
    end for
    clock = CreateObject("roTimespan")
    clock.mark()
    for each s in ordered
        if clock.totalMilliseconds() > 30000 then exit for
        res = HC_Get(session, spark + apiPath + "?source=" + s, { "x-player-key": key, "Referer": spark + "/" }, 12000)
        if res <> invalid and res.status = 200 then
            out = MA_Result(res.body, spark + "/", session)
            if out <> invalid then
                print "[moviesapi] vidspark "; s
                return out
            end if
        end if
    end for
    return invalid
end function

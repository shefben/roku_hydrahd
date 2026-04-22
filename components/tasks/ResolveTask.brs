' ResolveTask.brs - Resolves an embed URL to a direct video stream.
'
' HydraHD aggregates third-party iframe embeds (vidsrc.cc, videasy.net,
' vidfast.pro, embed.su, etc.). Roku's Video node can only play direct
' HLS / DASH / MP4 URLs, not arbitrary HTML players. We delegate the
' extraction to a small companion HTTP service whose URL is configurable
' in Settings ("Resolver URL"). See resolver/README.md.
'
' If the mirror URL is already a direct .m3u8 / .mp4 we just play it.
' If no resolver is configured we attempt a best-effort scrape of the
' iframe HTML for an .m3u8 / .mp4 URL.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    embedUrl = m.top.embedUrl

    if U_LooksHls(embedUrl) or U_LooksMp4(embedUrl) then
        m.top.result = {
            url: embedUrl
            streamFormat: U_StreamFormat(embedUrl)
            qualities: []
            subtitles: []
            referer: ""
            userAgent: ""
        }
        return
    end if

    resolver = U_PrefDefault("resolverUrl", U_DefaultResolverUrl())
    if resolver <> "" then
        out = resolveViaService(resolver, embedUrl)
        if out <> invalid and out.url <> "" then
            m.top.result = out
            return
        end if
    end if

    out = resolveBestEffort(embedUrl)
    if out <> invalid and out.url <> "" then
        m.top.result = out
        return
    end if

    m.top.result = { url: "", streamFormat: "hls", qualities: [], subtitles: [] }
end sub

function resolveViaService(resolver as String, embedUrl as String) as Object
    if Right(resolver, 1) = "/" then resolver = Left(resolver, Len(resolver) - 1)
    qs = "?embed=" + U_UrlEncode(embedUrl)
    qs = qs + "&kind=" + U_UrlEncode(m.top.kind)
    if m.top.imdb <> "" then qs = qs + "&imdb=" + U_UrlEncode(m.top.imdb)
    if m.top.tmdb <> "" then qs = qs + "&tmdb=" + U_UrlEncode(m.top.tmdb)
    if m.top.kind = "tv" then
        qs = qs + "&season=" + m.top.season.ToStr()
        qs = qs + "&episode=" + m.top.episode.ToStr()
    end if
    if m.top.refer <> "" then qs = qs + "&refer=" + U_UrlEncode(m.top.refer)
    json = HA_GetJson(resolver + "/resolve" + qs)
    if json = invalid then return invalid
    if json.url = invalid or json.url = "" then return invalid
    out = {
        url: json.url
        streamFormat: ""
        qualities: []
        subtitles: []
        referer: ""
        userAgent: ""
    }
    if json.streamFormat <> invalid then out.streamFormat = json.streamFormat
    if out.streamFormat = "" then out.streamFormat = U_StreamFormat(out.url)
    if json.qualities <> invalid then out.qualities = json.qualities
    if json.subtitles <> invalid then out.subtitles = json.subtitles
    if json.referer <> invalid then out.referer = json.referer
    if json.userAgent <> invalid then out.userAgent = json.userAgent
    return out
end function

function resolveBestEffort(embedUrl as String) as Object
    html = HA_Get(embedUrl, m.top.refer)
    if html = invalid or html = "" then return invalid

    hlsRe = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.m3u8[^" + chr(34) + "'\\\s>]*)", "i")
    h = hlsRe.match(html)
    if h <> invalid and h.Count() >= 2 then
        return {
            url: h[1]
            streamFormat: "hls"
            qualities: []
            subtitles: extractSubs(html)
            referer: m.top.refer
            userAgent: ""
        }
    end if

    mp4Re = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.mp4[^" + chr(34) + "'\\\s>]*)", "i")
    m2 = mp4Re.match(html)
    if m2 <> invalid and m2.Count() >= 2 then
        return {
            url: m2[1]
            streamFormat: "mp4"
            qualities: []
            subtitles: extractSubs(html)
            referer: m.top.refer
            userAgent: ""
        }
    end if
    return invalid
end function

function extractSubs(html as String) as Object
    subs = []
    re = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.(?:vtt|srt))", "ig")
    m = re.matchAll(html)
    if m = invalid then return subs
    for each match in m
        url = match[1]
        lang = "en"
        ' Try to detect language from URL
        langRe = CreateObject("roRegex", "[/_-]([a-z]{2})[/._-]", "i")
        lm = langRe.match(url)
        if lm <> invalid and lm.Count() >= 2 then lang = LCase(lm[1])
        subs.Push({ url: url, language: lang, name: UCase(lang) })
    end for
    return subs
end function

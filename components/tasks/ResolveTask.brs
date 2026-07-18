' ResolveTask.brs - Resolves an embed URL to a direct video stream.
'
' HydraHD aggregates third-party iframe embeds (vidsrc.cc, videasy.net,
' vidfast.pro, embed.su, etc.). Roku's Video node can only play direct
' HLS / DASH / MP4 URLs, not arbitrary HTML players.
'
' Resolution path (in priority order):
'   1. Direct passthrough if the URL is already .m3u8 / .mp4.
'   2. In-channel resolver (Resolver.brs) if the inChannelResolve
'      Settings toggle is on. This is the Standlone_Channel branch's
'      goal: full BrightScript port of the Python resolver so no LAN
'      host is required. Off by default until validated.
'   3. External resolver service (resolver/server.py on a LAN host or
'      Oracle A1 cloud relay) if a URL is configured in Settings.
'   4. Best-effort regex scrape of the iframe HTML for any visible
'      .m3u8 / .mp4 URL. Last-resort fallback that catches plain
'      JWPlayer pages without crypto.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    embedUrl = m.top.embedUrl
    print "[ResolveTask] embedUrl="; embedUrl

    if U_LooksHls(embedUrl) or U_LooksMp4(embedUrl) then
        print "[ResolveTask] direct passthrough"
        ' Direct .m3u8 embeds skip R_EnrichResult, so run the dead-lead-in
        ' probe here too (HLS only - MP4 has no segments). Fail-open: 0 on
        ' any probe failure so a good stream is never delayed/blocked.
        lead = 0
        if U_LooksHls(embedUrl) then
            sess = HC_NewSession()
            lead = RP_HlsLeadSkip(sess, "", embedUrl, m.top.refer)
            HC_Close(sess)
        end if
        m.top.result = {
            url: embedUrl
            streamFormat: U_StreamFormat(embedUrl)
            qualities: []
            subtitles: []
            referer: ""
            userAgent: ""
            leadSkip: lead
        }
        return
    end if

    ' In-channel resolver (Standlone_Channel feature). Default off so a
    ' user upgrading from the previous build sees zero behaviour change
    ' until they toggle it. Once Phase 2-4 providers are wired and the
    ' Roku-segment-header forwarding has been validated on real devices,
    ' the default flips to true.
    inChannelOn = U_PrefDefault("inChannelResolve", true)
    print "[ResolveTask] inChannelResolve="; inChannelOn
    if inChannelOn then
        out = resolveInChannel()
        if out <> invalid and out.url <> "" then
            print "[ResolveTask] in-channel HIT: "; out.url
            m.top.result = out
            return
        end if
        print "[ResolveTask] in-channel miss, falling through"
    end if

    ' Prefer the build-time hardcoded URL over any registry-cached one.
    ' When auto-discovery was on, it cached whatever it found at runtime
    ' (potentially the wrong host on a multi-homed LAN); after disabling
    ' it, that stale value would still win via U_PrefDefault and make
    ' ResolveTask hang on an unreachable IP, which the UI shows as a
    ' freeze. Falling back to the registry only when no build-time URL
    ' is baked in keeps the manual-Settings override path working for
    ' channels built without an IP.
    resolver = U_DefaultResolverUrl()
    if resolver = "" then resolver = U_PrefDefault("resolverUrl", "")
    print "[ResolveTask] external resolver="; resolver
    if resolver <> "" then
        out = resolveViaService(resolver, embedUrl)
        if out <> invalid and out.url <> "" then
            print "[ResolveTask] external HIT: "; out.url
            m.top.result = out
            return
        end if
        print "[ResolveTask] external miss"
    end if

    out = resolveBestEffort(embedUrl)
    if out <> invalid and out.url <> "" then
        print "[ResolveTask] best-effort HIT: "; out.url
        m.top.result = out
        return
    end if

    print "[ResolveTask] ALL paths failed"
    m.top.result = { url: "", streamFormat: "hls", qualities: [], subtitles: [] }
end sub

' --- In-channel resolver dispatcher entry ---------------------------
'
' Bridges the Task-thread interface fields to Resolver.brs's
' R_ResolveEmbed args shape. Returns the same envelope as resolveViaService.

function resolveInChannel() as Object
    args = {
        embedUrl: m.top.embedUrl
        refer:    m.top.refer
        kind:     m.top.kind
        imdb:     m.top.imdb
        tmdb:     m.top.tmdb
        season:   m.top.season
        episode:  m.top.episode
    }
    return R_ResolveEmbed(args)
end function

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
    cid = U_ClientId()
    if cid <> "" then qs = qs + "&cid=" + U_UrlEncode(cid)
    json = HA_GetJson(resolver + "/resolve" + qs)
    if json = invalid then return invalid
    if json.url = invalid or json.url = "" then return invalid
    out = {
        url: json.url
        streamFormat: ""
        qualities: []
        subtitles: []
        chapters: []
        referer: ""
        userAgent: ""
        leadSkip: 0
    }
    if json.streamFormat <> invalid then out.streamFormat = json.streamFormat
    if out.streamFormat = "" then out.streamFormat = U_StreamFormat(out.url)
    if json.qualities <> invalid then out.qualities = json.qualities
    if json.subtitles <> invalid then out.subtitles = json.subtitles
    if json.chapters <> invalid then out.chapters = json.chapters
    if json.referer <> invalid then out.referer = json.referer
    if json.userAgent <> invalid then out.userAgent = json.userAgent
    if json.leadSkip <> invalid then out.leadSkip = json.leadSkip
    return out
end function

function resolveBestEffort(embedUrl as String) as Object
    html = HA_Get(embedUrl, m.top.refer)
    if html = invalid or html = "" then return invalid

    hlsRe = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.m3u8[^" + chr(34) + "'\\\s>]*)", "i")
    h = hlsRe.match(html)
    if h <> invalid and h.Count() >= 2 then
        ' Best-effort scrape bypasses R_EnrichResult, so probe the
        ' dead-lead-in here too. Fail-open: 0 on any probe failure.
        besess = HC_NewSession()
        lead = RP_HlsLeadSkip(besess, "", h[1], m.top.refer)
        HC_Close(besess)
        return {
            url: h[1]
            streamFormat: "hls"
            qualities: []
            subtitles: extractSubs(html)
            referer: m.top.refer
            userAgent: ""
            leadSkip: lead
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

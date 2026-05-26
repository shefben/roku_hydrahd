' Resolver.brs - In-channel stream resolver dispatcher.
'
' R_ResolveEmbed(args) is the single entry point called from
' ResolveTask.brs when the inChannelResolve feature flag is on. It
' mirrors the shape of the existing /resolve HTTP API so PlayerView can
' consume the result without changes:
'   { url, streamFormat, qualities, subtitles, chapters, referer, userAgent }
' Returns invalid only if every provider chain fails AND the TMDB-id
' fallback pool also exhausts.
'
' Provider implementations live in ResolverProviders.brs as RP_Resolve*
' functions. This file owns dispatch, iframe chaining (with depth
' limit), the TMDB-id fallback pool, and the result envelope.

' --- Public entry ---------------------------------------------------

' args: {
'   embedUrl, refer, kind ("movie"|"tv"|""), imdb, tmdb, season, episode
' }
function R_ResolveEmbed(args as Object) as Object
    if args = invalid then return invalid
    embedUrl = ""
    if args.embedUrl <> invalid then embedUrl = args.embedUrl
    if embedUrl = "" then return invalid

    refer = ""
    if args.refer <> invalid then refer = args.refer
    if refer = "" then refer = HC_OriginOf(embedUrl)

    ' Direct passthrough - no need to spend cycles on resolution.
    if U_LooksHls(embedUrl) or U_LooksMp4(embedUrl) then
        return {
            url: embedUrl
            streamFormat: U_StreamFormat(embedUrl)
            qualities: []
            subtitles: []
            chapters: []
            referer: refer
            userAgent: ""
        }
    end if

    session = HC_NewSession()
    out = invalid
    err = ""

    ' First attempt: dispatch on embed host.
    out = R_DispatchByHost(embedUrl, refer, session)

    ' If primary failed AND we have content ids, try the same content
    ' through other working providers. Mirrors fallback_via_known_providers
    ' from server.py:1731.
    if (out = invalid or out.url = "") and R_HasContentIds(args) then
        out = R_FallbackByContentIds(args, session)
    end if

    if out <> invalid and out.url <> invalid and out.url <> "" then
        out = R_EnrichResult(out, args, refer, session)
    end if

    HC_Close(session)

    if out = invalid then return invalid
    if out.url = invalid or out.url = "" then return invalid
    return R_NormalizeResult(out, refer)
end function

' --- Result enrichment ----------------------------------------------
'
' After a provider returns a stream URL, top up the result with anything
' the provider didn't fill in itself:
'   * HLS quality variants by parsing the master playlist
'   * Skip-intro / outro / recap chapters from #EXT-X-DATERANGE entries
'     in the playlist, then from the AniSkip API (free, anime-only) if
'     the stream had nothing
'   * Free subtitles from sub.wyzie.io if the provider returned none
' Idempotent - if a provider already populated a field we keep theirs.

function R_EnrichResult(raw as Object, args as Object, refer as String, session as Object) as Object
    if raw = invalid or raw.url = invalid or raw.url = "" then return raw
    streamUrl = raw.url
    isHls = U_LooksHls(streamUrl)

    refUrl = ""
    if raw.referer <> invalid and raw.referer <> "" then refUrl = raw.referer
    if refUrl = "" then refUrl = refer
    if refUrl = "" then refUrl = streamUrl

    imdb = ""
    tmdb = ""
    kind = ""
    season = 0
    episode = 0
    if args <> invalid then
        if args.imdb <> invalid then imdb = args.imdb
        if args.tmdb <> invalid then tmdb = args.tmdb
        if args.kind <> invalid then kind = args.kind
        if args.season <> invalid then season = args.season
        if args.episode <> invalid then episode = args.episode
    end if

    if isHls then
        existingQualities = invalid
        if raw.qualities <> invalid and type(raw.qualities) = "roArray" then existingQualities = raw.qualities
        if existingQualities = invalid or existingQualities.Count() = 0 then
            raw.qualities = HM_FetchQualities(streamUrl, refUrl, session)
        end if

        existingChapters = invalid
        if raw.chapters <> invalid and type(raw.chapters) = "roArray" then existingChapters = raw.chapters
        if existingChapters = invalid or existingChapters.Count() = 0 then
            raw.chapters = HM_ExtractChaptersHls(streamUrl, refUrl, session)
        end if
    end if

    ' Free skip-intro / outro lookup from AniSkip if the upstream had no
    ' DATERANGE markers. AniSkip is anime-only - non-anime content will
    ' return an empty result quickly via the Jikan / AniList lookups.
    if raw.chapters = invalid or type(raw.chapters) <> "roArray" or raw.chapters.Count() = 0 then
        raw.chapters = HM_FetchSkipTimes(imdb, tmdb, kind, season, episode, session)
    end if

    ' Subtitles, merged from every source we know about. The provider's
    ' own track list typically covers only the title's "default" language
    ' (or just English), so we always pad it out with HLS-embedded subs
    ' AND a full OpenSubtitles query. Dedup is by URL, then by (language,
    ' name) so identical entries from multiple sources collapse to one
    ' chip but real language variants (e.g. "English" vs "English (SDH)")
    ' stay distinct in the picker.
    if raw.subtitles = invalid or type(raw.subtitles) <> "roArray" then raw.subtitles = []
    if isHls then
        hlsSubs = HM_ExtractSubsHls(streamUrl, refUrl, session)
        raw.subtitles = HM_MergeSubtitles(raw.subtitles, hlsSubs)
    end if
    freeSubs = HM_FetchFreeSubs(imdb, tmdb, kind, season, episode, session)
    raw.subtitles = HM_MergeSubtitles(raw.subtitles, freeSubs)

    return raw
end function

' --- Dispatch -------------------------------------------------------
'
' First-match-wins on host substring, mirroring the PROVIDERS table in
' server.py:1858. Most providers are stubs in Phase 1 - they delegate
' to RP_ResolveGeneric until their real implementation lands in Phase 2-4.

function R_DispatchByHost(embedUrl as String, refer as String, session as Object) as Object
    host = HC_HostOf(embedUrl)
    print "[R_Dispatch] host="; host; " url="; embedUrl
    if host = "" then return invalid

    ' Cloudnestra family - rcpvip / prorcp pages.
    if Instr(1, host, "cloudnestra.com") > 0 then return RP_ResolveCloudnestra(embedUrl, refer, session)

    ' Vidsrc.xyz iframe family.
    if Instr(1, host, "vidsrc.xyz") > 0 or Instr(1, host, "vidsrc.in") > 0 or Instr(1, host, "vidsrc.pm") > 0 or Instr(1, host, "vidsrc.io") > 0 or Instr(1, host, "vidsrc.net") > 0 or Instr(1, host, "vsembed.ru") > 0 then return RP_ResolveVidsrcXyz(embedUrl, refer, session)

    ' vidsrc.cc has its own JSON API independent of cloudnestra.
    if Instr(1, host, "vidsrc.cc") > 0 then return RP_ResolveVidsrcCc(embedUrl, refer, session)

    ' Vidrock / vidsrc.vip share /api/{movie|tv}/{tmdb} JSON.
    if Instr(1, host, "vidrock.net") > 0 or Instr(1, host, "vidsrc.vip") > 0 then return RP_ResolveVidrock(embedUrl, refer, session)

    ' 2embed -> streamsrcs -> lookmovie2 chain.
    if Instr(1, host, "2embed.cc") > 0 or Instr(1, host, "2embed.org") > 0 then return RP_Resolve2embed(embedUrl, refer, session)

    if Instr(1, host, "lookmovie2.skin") > 0 then return RP_ResolveLookmovie(embedUrl, refer, session)

    if Instr(1, host, "moviesapi.club") > 0 or Instr(1, host, "moviesapi.to") > 0 then return RP_ResolveMoviesapi(embedUrl, refer, session)

    if Instr(1, host, "vidora.stream") > 0 then return RP_ResolveVidora(embedUrl, refer, session)

    if Instr(1, host, "autoembed.cc") > 0 then return RP_ResolveAutoembed(embedUrl, refer, session)

    if Instr(1, host, "xpass.top") > 0 then return RP_ResolveXpass(embedUrl, refer, session)

    if Instr(1, host, "airflix1.com") > 0 or Instr(1, host, "brightpathsignals.com") > 0 then return RP_ResolveAirflix(embedUrl, refer, session)

    ' New providers cracked in this session.
    if Instr(1, host, "videasy.net") > 0 then return RP_ResolveVideasy(embedUrl, refer, session)
    if Instr(1, host, "vidking.net") > 0 then return RP_ResolveVidking(embedUrl, refer, session)
    if Instr(1, host, "ythd.org") > 0 then return RP_ResolveYthd(embedUrl, refer, session)
    if Instr(1, host, "peachify.top") > 0 then return RP_ResolvePeachify(embedUrl, refer, session)
    if Instr(1, host, "primesrc.me") > 0 then return RP_ResolvePrimesrc(embedUrl, refer, session)

    ' Phase 4 downstream extractors. These are typically reached through
    ' an iframe chain from primesrc / autoembed / 2embed rather than as
    ' a direct mirror entry, so we match host substrings permissively.
    if Instr(1, host, "streamtape") > 0 or Instr(1, host, "streamta.pe") > 0 then return RP_ResolveStreamtape(embedUrl, refer, session)
    if Instr(1, host, "uqload") > 0 then return RP_ResolveUqload(embedUrl, refer, session)
    if Instr(1, host, "dood") > 0 or Instr(1, host, "d000d") > 0 or Instr(1, host, "d0000d") > 0 or Instr(1, host, "ds2play") > 0 or Instr(1, host, "ds2video") > 0 then return RP_ResolveDoodstream(embedUrl, refer, session)
    if Instr(1, host, "voe.sx") > 0 or Instr(1, host, "voe.com") > 0 or Instr(1, host, "voeunbl") > 0 or Instr(1, host, "voe-unblock") > 0 then return RP_ResolveVoe(embedUrl, refer, session)
    if Instr(1, host, "watchsb") > 0 or Instr(1, host, "streamsb") > 0 or Instr(1, host, "sbembed") > 0 or Instr(1, host, "sbplay") > 0 or Instr(1, host, "sbnet") > 0 then return RP_ResolveStreamsb(embedUrl, refer, session)
    if Instr(1, host, "mixdrop") > 0 or Instr(1, host, "mxdrop") > 0 then return RP_ResolveMixdrop(embedUrl, refer, session)

    ' Stubs for providers that are CF-gated or architecture-blocked.
    ' These return invalid quickly so the fallback chain kicks in.
    if Instr(1, host, "vidfast.pro") > 0 or Instr(1, host, "vidup.to") > 0 or Instr(1, host, "embedmaster.link") > 0 or Instr(1, host, "kllamrd.org") > 0 or Instr(1, host, "frembed.bond") > 0 then return invalid

    ' Default: best-effort generic regex scrape.
    return RP_ResolveGeneric(embedUrl, refer, session)
end function

' --- Iframe chaining ------------------------------------------------
'
' Some providers nest iframes 2-3 levels deep before exposing the real
' player. Walk the iframe tree depth-first up to maxDepth, dispatching
' each landed host through R_DispatchByHost so chains that terminate at
' a known provider get full extraction.

function R_FollowKnownIframes(html as String, pageUrl as String, refer as String, depth as Integer, session as Object) as Object
    if html = invalid or html = "" then return invalid
    if depth >= 3 then return invalid

    re = CreateObject("roRegex", "<iframe[^>]+src=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "ig")
    matches = re.matchAll(html)
    if matches = invalid then return invalid

    for each mt in matches
        if mt.Count() < 2 then continue for
        candidate = U_AbsUrl(mt[1], HC_OriginOf(pageUrl))
        if candidate = "" then continue for
        direct = R_DispatchByHost(candidate, pageUrl, session)
        if direct <> invalid and direct.url <> invalid and direct.url <> "" then return direct
        ' Recurse one level into this iframe page.
        page = HC_Get(session, candidate, { "Referer": pageUrl }, 6000)
        if page <> invalid and page.body <> "" then
            inner = R_FollowKnownIframes(page.body, candidate, pageUrl, depth + 1, session)
            if inner <> invalid and inner.url <> "" then return inner
        end if
    end for
    return invalid
end function

' --- Fallback chain --------------------------------------------------
'
' Triggered when the matched provider fails OR returns no playable URL.
' Tries the same TMDB / IMDB id through working providers in priority
' order, mirroring fallback_via_known_providers from server.py.
' Order is deliberate: airflix1 and xpass are fastest and most reliable,
' followed by vidsrc.cc (independent of CF), then videasy/vidking
' (shared backend), then 2embed (slow chain), then autoembed.

function R_FallbackByContentIds(args as Object, session as Object) as Object
    if not R_HasContentIds(args) then return invalid
    kind = ""
    if args.kind <> invalid then kind = args.kind
    tmdb = ""
    if args.tmdb <> invalid then tmdb = args.tmdb
    imdb = ""
    if args.imdb <> invalid then imdb = args.imdb
    season = 1
    if args.season <> invalid then season = args.season
    episode = 1
    if args.episode <> invalid then episode = args.episode

    refer = ""
    if args.refer <> invalid then refer = args.refer

    cands = R_BuildFallbackCandidates(kind, tmdb, imdb, season, episode)
    for each url in cands
        if url <> "" then
            out = R_DispatchByHost(url, refer, session)
            if out <> invalid and out.url <> invalid and out.url <> "" then return out
        end if
    end for
    return invalid
end function

function R_BuildFallbackCandidates(kind as String, tmdb as String, imdb as String, season as Integer, episode as Integer) as Object
    out = []
    isMovie = (kind <> "tv")

    if tmdb <> "" then
        if isMovie then
            out.Push("https://airflix1.com/embed/movie/" + tmdb)
            out.Push("https://play.xpass.top/e/movie/" + tmdb)
            out.Push("https://vidsrc.cc/v2/embed/movie/" + tmdb)
            out.Push("https://player.videasy.net/movie/" + tmdb)
            out.Push("https://www.vidking.net/embed/movie/" + tmdb)
            out.Push("https://vidrock.net/movie/" + tmdb)
            out.Push("https://www.2embed.cc/embed/" + tmdb)
            out.Push("https://moviesapi.club/movie/" + tmdb)
        else
            out.Push("https://airflix1.com/embed/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://play.xpass.top/e/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://vidsrc.cc/v2/embed/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://player.videasy.net/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://www.vidking.net/embed/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://vidsrc.vip/embed/tv/" + tmdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://www.2embed.cc/embedtv/" + tmdb + "&s=" + season.ToStr() + "&e=" + episode.ToStr())
            out.Push("https://moviesapi.club/tv/" + tmdb + "-" + season.ToStr() + "-" + episode.ToStr())
        end if
    end if
    if imdb <> "" then
        if isMovie then
            out.Push("https://player.autoembed.cc/embed/movie/" + imdb)
            out.Push("https://ythd.org/embed/" + imdb + "/")
        else
            out.Push("https://player.autoembed.cc/embed/tv/" + imdb + "/" + season.ToStr() + "/" + episode.ToStr())
            out.Push("https://ythd.org/embed/" + imdb + "/" + season.ToStr() + "-" + episode.ToStr() + "/")
        end if
    end if
    return out
end function

function R_HasContentIds(args as Object) as Boolean
    if args = invalid then return false
    if args.tmdb <> invalid and args.tmdb <> "" then return true
    if args.imdb <> invalid and args.imdb <> "" then return true
    return false
end function

' --- Result envelope -------------------------------------------------
'
' Providers may return partial results (just url + streamFormat). Fill in
' the standard fields with sensible defaults so PlayerView's consumer at
' line 437 doesn't have to null-check every property.

function R_NormalizeResult(raw as Object, defaultRefer as String) as Object
    out = {
        url: ""
        streamFormat: "hls"
        qualities: []
        subtitles: []
        chapters: []
        referer: ""
        userAgent: ""
    }
    if raw = invalid then return out
    if raw.url <> invalid then out.url = raw.url
    if raw.streamFormat <> invalid and raw.streamFormat <> "" then
        out.streamFormat = raw.streamFormat
    else if out.url <> "" then
        out.streamFormat = U_StreamFormat(out.url)
    end if
    if raw.qualities <> invalid then out.qualities = raw.qualities
    if raw.subtitles <> invalid then out.subtitles = raw.subtitles
    if raw.chapters <> invalid then out.chapters = raw.chapters
    if raw.referer <> invalid and raw.referer <> "" then
        out.referer = raw.referer
    else
        out.referer = defaultRefer
    end if
    if raw.userAgent <> invalid then out.userAgent = raw.userAgent
    return out
end function

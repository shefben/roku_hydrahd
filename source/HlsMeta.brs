' HlsMeta.brs - HLS master-playlist parsing, chapter / "skip intro"
' detection, and generic subtitle scraping for the in-channel resolver.
'
' This is the post-resolve enrichment step. After a provider returns a
' stream URL, we fetch the master m3u8 and extract:
'   * `qualities` - one entry per #EXT-X-STREAM-INF rendition so the
'      PlayerView quality overlay shows real resolutions instead of
'      just "Auto".
'   * `chapters`  - skip-intro / skip-outro / recap markers from either
'      JSON config strings in the embed HTML or #EXT-X-DATERANGE entries
'      in the playlist itself.
'   * `subtitles` - any plain .vtt / .srt URLs embedded in the page,
'      used to top up subtitle lists from providers that don't expose
'      them via their JSON API.
'
' Direct port of server.py:348 (parse_master_playlist),
' server.py:430 (extract_chapters_from_html),
' server.py:478 (extract_chapters_from_hls),
' server.py:384 (collect_subtitles).

' --- Quality / variant parsing ---------------------------------------

' Fetch the master playlist at streamUrl and return an array of variant
' records. Returns [] if streamUrl is empty, not HLS, unreachable, or
' isn't actually a master (no #EXT-X-STREAM-INF).
function HM_FetchQualities(streamUrl as String, refer as String, session as Object) as Object
    out = []
    if streamUrl = invalid or streamUrl = "" then return out
    if Instr(1, LCase(streamUrl), ".m3u8") = 0 then return out

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, streamUrl, headers, 6000)
    if res = invalid or res.body = "" then return out
    if Instr(1, res.body, "#EXT-X-STREAM-INF") = 0 then return out
    return HM_ParseMasterPlaylist(res.body, streamUrl)
end function

function HM_ParseMasterPlaylist(text as String, baseUrl as String) as Object
    out = []
    if text = invalid or text = "" then return out
    lines = text.Tokenize(chr(10))
    if lines = invalid then return out

    n = lines.Count()
    for i = 0 to n - 1
        line = lines[i]
        if Left(line, 17) <> "#EXT-X-STREAM-INF" then continue for

        attrs = HM_ParseAttrs(line)
        bw = 0
        if attrs.BANDWIDTH <> invalid then bw = attrs.BANDWIDTH.ToInt()
        height = 0
        resStr = ""
        if attrs.RESOLUTION <> invalid then resStr = attrs.RESOLUTION
        if resStr <> "" then
            xIdx = Instr(1, resStr, "x")
            if xIdx > 0 and xIdx < Len(resStr) then
                height = Mid(resStr, xIdx + 1).ToInt()
            end if
        end if

        ' Variant URL is the next non-comment, non-empty line.
        varUrl = ""
        for j = i + 1 to n - 1
            cand = U_Trim(lines[j])
            if cand = "" then continue for
            if Left(cand, 1) = "#" then continue for
            varUrl = cand
            exit for
        end for
        if varUrl = "" then continue for
        varUrl = RP_AbsUrl(varUrl, baseUrl)

        label = "Variant"
        if height > 0 then
            label = height.ToStr() + "p"
        else if bw > 0 then
            label = (bw \ 1000).ToStr() + "kbps"
        end if

        out.Push({
            label: label
            height: height
            bandwidth: bw
            url: varUrl
        })
    end for

    ' Sort height-descending so PlayerView's auto-pick lands on the
    ' highest available rendition. Insertion sort is fine for the
    ' typical 3-6 variant count.
    for i = 1 to out.Count() - 1
        cur = out[i]
        curH = cur.height
        if curH = invalid then curH = 0
        j = i - 1
        while j >= 0
            prevH = out[j].height
            if prevH = invalid then prevH = 0
            if prevH >= curH then exit while
            out[j + 1] = out[j]
            j = j - 1
        end while
        out[j + 1] = cur
    end for
    return out
end function

' Parse a single #EXT-X-* line's KEY=VALUE pairs. Quoted values keep
' their content; bare values stop at the next comma.
function HM_ParseAttrs(line as String) as Object
    out = {}
    if line = invalid or line = "" then return out
    re = CreateObject("roRegex", "([A-Z0-9-]+)=(" + chr(34) + "[^" + chr(34) + "]*" + chr(34) + "|[^,]*)", "g")
    matches = re.matchAll(line)
    if matches = invalid then return out
    for each pair in matches
        if pair.Count() < 3 then continue for
        k = pair[1]
        v = pair[2]
        if Len(v) >= 2 and Left(v, 1) = chr(34) and Right(v, 1) = chr(34) then
            v = Mid(v, 2, Len(v) - 2)
        end if
        out[k] = v
    end for
    return out
end function

' --- Chapter / skip-intro detection ----------------------------------

' Map a free-form label ("intro", "opening", "credits", ...) to the
' three canonical kinds PlayerView understands.
function HM_CoerceKind(label as String) as String
    if label = invalid or label = "" then return ""
    s = LCase(label)
    if Instr(1, s, "intro") > 0 or Instr(1, s, "opening") > 0 then return "intro"
    if Instr(1, s, "outro") > 0 or Instr(1, s, "credit") > 0 or Instr(1, s, "ending") > 0 then return "outro"
    if Instr(1, s, "recap") > 0 then return "recap"
    return ""
end function

' Look for skipIntro / skipOutro / introStart-introEnd JSON blobs in the
' raw embed HTML. Returns array of { kind, start, end }.
function HM_ExtractChaptersHtml(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    seen = {}

    jsonRe = CreateObject("roRegex", chr(34) + "(?:skip)?(intro|outro|credits|recap|opening|ending)" + chr(34) + "\s*:\s*\{\s*" + chr(34) + "start" + chr(34) + "\s*:\s*(\d+(?:\.\d+)?)\s*,\s*" + chr(34) + "end" + chr(34) + "\s*:\s*(\d+(?:\.\d+)?)", "ig")
    jms = jsonRe.matchAll(html)
    if jms <> invalid then
        for each mt in jms
            if mt.Count() < 4 then continue for
            kind = HM_CoerceKind(mt[1])
            if kind = "" or seen.DoesExist(kind) then continue for
            startVal = mt[2].ToFloat()
            endVal = mt[3].ToFloat()
            if endVal > startVal then
                out.Push({ kind: kind, start: startVal, end: endVal })
                seen[kind] = true
            end if
        end for
    end if

    ' Numeric pair fallback: introStart=60, introEnd=90 (or with ":" / quotes
    ' between the two halves). The prefix and suffix names must match.
    pairRe = CreateObject("roRegex", "(intro|outro|credits|recap|opening|ending)[_\-]?start[" + chr(34) + "\s:=,]+(\d+(?:\.\d+)?)[\s\S]{0,200}?(?:\1)[_\-]?end[" + chr(34) + "\s:=,]+(\d+(?:\.\d+)?)", "ig")
    pms = pairRe.matchAll(html)
    if pms <> invalid then
        for each mt in pms
            if mt.Count() < 4 then continue for
            kind = HM_CoerceKind(mt[1])
            if kind = "" or seen.DoesExist(kind) then continue for
            startVal = mt[2].ToFloat()
            endVal = mt[3].ToFloat()
            if endVal > startVal then
                out.Push({ kind: kind, start: startVal, end: endVal })
                seen[kind] = true
            end if
        end for
    end if

    return out
end function

' Look for #EXT-X-DATERANGE entries in the HLS playlist. If the input
' is a master playlist that doesn't itself carry DATERANGE entries,
' descend into the first variant once and re-scan.
function HM_ExtractChaptersHls(streamUrl as String, refer as String, session as Object) as Object
    out = []
    if streamUrl = invalid or streamUrl = "" then return out

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, streamUrl, headers, 6000)
    if res = invalid or res.body = "" then return out
    text = res.body
    if Instr(1, text, "#EXT-X-DATERANGE") = 0 then
        ' Master playlist often has no DATERANGE; check the first variant.
        if Instr(1, text, "#EXT-X-STREAM-INF") = 0 then return out
        firstVariant = ""
        lines = text.Tokenize(chr(10))
        if lines = invalid then return out
        for i = 0 to lines.Count() - 1
            cand = U_Trim(lines[i])
            if cand = "" or Left(cand, 1) = "#" then continue for
            firstVariant = cand
            exit for
        end for
        if firstVariant = "" then return out
        firstVariant = RP_AbsUrl(firstVariant, streamUrl)
        res2 = HC_Get(session, firstVariant, headers, 6000)
        if res2 = invalid or res2.body = "" then return out
        text = res2.body
        if Instr(1, text, "#EXT-X-DATERANGE") = 0 then return out
    end if

    seen = {}
    lines = text.Tokenize(chr(10))
    if lines = invalid then return out
    for i = 0 to lines.Count() - 1
        line = lines[i]
        if Left(line, 16) <> "#EXT-X-DATERANGE" then continue for
        attrs = HM_ParseAttrs(line)
        cls = ""
        if attrs.CLASS <> invalid then cls = attrs.CLASS
        kind = HM_CoerceKind(cls)
        if kind = "" and attrs.ID <> invalid then kind = HM_CoerceKind(attrs.ID)
        if kind = "" or seen.DoesExist(kind) then continue for
        startStr = ""
        if attrs.X_START <> invalid then startStr = attrs.X_START
        if startStr = "" and attrs["X-START"] <> invalid then startStr = attrs["X-START"]
        if startStr = "" and attrs["X-COM-INTRO-START"] <> invalid then startStr = attrs["X-COM-INTRO-START"]
        startVal = 0.0
        if startStr <> "" then startVal = startStr.ToFloat()
        endStr = ""
        if attrs["X-END"] <> invalid then endStr = attrs["X-END"]
        if endStr = "" and attrs["X-COM-INTRO-END"] <> invalid then endStr = attrs["X-COM-INTRO-END"]
        endVal = 0.0
        if endStr <> "" then
            endVal = endStr.ToFloat()
        else if attrs.DURATION <> invalid then
            endVal = startVal + attrs.DURATION.ToFloat()
        end if
        if endVal > startVal then
            out.Push({ kind: kind, start: startVal, end: endVal })
            seen[kind] = true
        end if
    end for
    return out
end function

' --- HLS-embedded subtitle parsing -----------------------------------
'
' Master playlists may declare per-language subtitle renditions via
'   #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=...,NAME="English",
'                  LANGUAGE="en",URI="<url>"
' Roku's Video node does NOT auto-promote these to the subtitleTracks
' field, so we parse them out here and feed them via TrackName like
' sidecar VTT files. URI may point either at a direct .vtt or at a
' subtitle sub-playlist (.m3u8 carrying one or more .vtt segments) —
' HM_ResolveSubPlaylist follows the sub-playlist case and returns the
' first .vtt segment URL Roku can consume.

function HM_ExtractSubsHls(streamUrl as String, refer as String, session as Object) as Object
    out = []
    if streamUrl = invalid or streamUrl = "" then return out
    if Instr(1, LCase(streamUrl), ".m3u8") = 0 then return out

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, streamUrl, headers, 6000)
    if res = invalid or res.body = "" then return out
    text = res.body
    if Instr(1, text, "TYPE=SUBTITLES") = 0 then return out

    lines = text.Tokenize(chr(10))
    if lines = invalid then return out

    seen = {}
    for i = 0 to lines.Count() - 1
        line = U_Trim(lines[i])
        if Left(line, 12) <> "#EXT-X-MEDIA" then continue for
        if Instr(1, line, "TYPE=SUBTITLES") = 0 then continue for

        attrs = HM_ParseAttrs(line)
        uri = ""
        if attrs.URI <> invalid then uri = attrs.URI
        if uri = "" then continue for

        absUri = RP_AbsUrl(uri, streamUrl)
        finalUrl = HM_ResolveSubPlaylist(absUri, refer, session)
        if finalUrl = "" then continue for

        lang = "en"
        if attrs.LANGUAGE <> invalid then lang = LCase(attrs.LANGUAGE)
        nameStr = ""
        if attrs.NAME <> invalid then nameStr = attrs.NAME
        if nameStr = "" then nameStr = UCase(lang)

        if seen.DoesExist(finalUrl) then continue for
        seen[finalUrl] = true
        out.Push({
            url: finalUrl
            language: lang
            name: nameStr
        })
    end for
    return out
end function

' Given a URI from #EXT-X-MEDIA, return a URL Roku can consume directly.
' Direct .vtt / .srt URIs pass through unchanged. .m3u8 sub-playlists are
' fetched and the first non-comment line (the segment URL) is returned —
' for the typical "single-VTT-as-segment" case this gives Roku a playable
' VTT URL even though it was nested behind an HLS sub-playlist.
function HM_ResolveSubPlaylist(uri as String, refer as String, session as Object) as String
    if uri = invalid or uri = "" then return ""
    lc = LCase(uri)
    if Instr(1, lc, ".vtt") > 0 then return uri
    if Instr(1, lc, ".srt") > 0 then return uri
    if Instr(1, lc, ".m3u8") = 0 then return uri

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, uri, headers, 5000)
    if res = invalid or res.body = "" then return uri
    lines = res.body.Tokenize(chr(10))
    if lines = invalid then return uri
    for i = 0 to lines.Count() - 1
        cand = U_Trim(lines[i])
        if cand = "" or Left(cand, 1) = "#" then continue for
        return RP_AbsUrl(cand, uri)
    end for
    return uri
end function

' --- Generic subtitle scraping ---------------------------------------

' Pull every plain .vtt / .srt URL out of the page HTML. Used as a
' top-up for providers that surface tracks via static URLs in the page
' rather than via their JSON API.
function HM_ScrapeSubs(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    re = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.(?:vtt|srt))", "ig")
    matches = re.matchAll(html)
    if matches = invalid then return out
    seen = {}
    for each mt in matches
        if mt.Count() < 2 then continue for
        url = mt[1]
        if seen.DoesExist(url) then continue for
        seen[url] = true
        lang = "en"
        langRe = CreateObject("roRegex", "[/_-]([a-z]{2})[/._-]", "i")
        lm = langRe.match(url)
        if lm <> invalid and lm.Count() >= 2 then lang = LCase(lm[1])
        out.Push({ url: url, language: lang, name: UCase(lang) })
    end for
    return out
end function

' Merge subtitle arrays, deduping on url. Provider-supplied subs
' (typed labels, language hints) take priority over scraped ones.
function HM_MergeSubs(primary as Object, extra as Object) as Object
    out = []
    seen = {}
    if primary <> invalid and type(primary) = "roArray" then
        for each s in primary
            if type(s) <> "roAssociativeArray" then continue for
            if s.url = invalid or s.url = "" then continue for
            if seen.DoesExist(s.url) then continue for
            seen[s.url] = true
            out.Push(s)
        end for
    end if
    if extra <> invalid and type(extra) = "roArray" then
        for each s in extra
            if type(s) <> "roAssociativeArray" then continue for
            if s.url = invalid or s.url = "" then continue for
            if seen.DoesExist(s.url) then continue for
            seen[s.url] = true
            out.Push(s)
        end for
    end if
    return out
end function

' --- Free subtitle library (OpenSubtitles + wyzie.io) ---------------
'
' rest.opensubtitles.org's read-only search endpoint returns one record
' per available subtitle file across many languages, but each record's
' SubDownloadLink points to a gzipped .srt (which Roku's Video node
' cannot consume). sub.wyzie.io operates a free public proxy that
' fetches a SubDownloadLink, ungzips it, and converts SRT -> WebVTT on
' the fly via the URL pattern:
'   https://sub.wyzie.io/c/{vrf}/id/{sub_id}?format=vtt&encoding=UTF-8
' where {vrf} and {sub_id} come from the SubDownloadLink path
' "/vrf-{hex}/filead/{digits}". The two services together give us a
' working free CC fallback for providers (notably airflix1 /
' brightpathsignals / vaplayer.ru) that ship streams without inline
' subtitles. Mirrors server.py:opensubtitles_search.
'
' OpenSubtitles indexes by IMDB only - TMDB ids are silently ignored
' upstream, so we don't bother trying them here.

function HM_FetchFreeSubs(imdb as String, tmdb as String, kind as String, season as Integer, episode as Integer, session as Object) as Object
    return HM_QueryOpenSubtitles(imdb, kind, season, episode, session)
end function

function HM_QueryOpenSubtitles(imdbId as String, kind as String, season as Integer, episode as Integer, session as Object) as Object
    out = []
    if imdbId = invalid or imdbId = "" then return out
    if Left(imdbId, 2) <> "tt" then return out
    bare = Mid(imdbId, 3)
    if bare = "" then return out

    if kind = "tv" and season > 0 and episode > 0 then
        url = "https://rest.opensubtitles.org/search/episode-" + episode.ToStr() + "/imdbid-" + bare + "/season-" + season.ToStr()
    else
        url = "https://rest.opensubtitles.org/search/imdbid-" + bare
    end if

    ' rest.opensubtitles.org rejects requests without a non-empty
    ' X-User-Agent. Any string works for read-only search; the Python
    ' resolver uses "trailers.to-UA" so we match it for parity.
    res = HC_Get(session, url, {
        "X-User-Agent": "trailers.to-UA"
        "Accept": "application/json"
    }, 6000)
    if res = invalid or res.body = "" then return out
    if res.status < 200 or res.status >= 300 then return out
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roArray" then return out

    vrfRe = CreateObject("roRegex", "/vrf-([a-f0-9]+)/filead/(\d+)", "i")
    seenLangs = {}
    for each entry in payload
        if type(entry) <> "roAssociativeArray" then continue for
        langId3 = ""
        if entry.SubLanguageID <> invalid then langId3 = LCase(entry.SubLanguageID)
        if langId3 = "" then continue for
        if seenLangs.DoesExist(langId3) then continue for
        downloadLink = ""
        if entry.SubDownloadLink <> invalid then downloadLink = entry.SubDownloadLink
        if downloadLink = "" then continue for
        mt = vrfRe.match(downloadLink)
        if mt = invalid or mt.Count() < 3 then continue for
        vrf = mt[1]
        subId = mt[2]
        wyzieUrl = "https://sub.wyzie.io/c/" + vrf + "/id/" + subId + "?format=vtt&encoding=UTF-8"
        iso2 = ""
        if entry.ISO639 <> invalid then iso2 = LCase(entry.ISO639)
        if iso2 = "" then iso2 = Left(langId3, 2)
        nameStr = ""
        if entry.LanguageName <> invalid then nameStr = entry.LanguageName
        if nameStr = "" then nameStr = UCase(langId3)
        out.Push({
            url: wyzieUrl
            language: iso2
            name: nameStr
        })
        seenLangs[langId3] = true
    end for
    return out
end function

' Merge two subtitle lists, preserving the order of `base` and appending
' tracks from `extra` that aren't already there. Dedup keys are (url) and
' (LCase(language) + "|" + LCase(name)) so identical entries collapse but
' real variants ("English" vs "English (SDH)") survive as distinct chips.
' Used by Resolver.R_EnrichResult to fold HLS-embedded + OpenSubtitles
' tracks into whatever the upstream provider already returned.
function HM_MergeSubtitles(base as Object, extra as Object) as Object
    out = []
    seenUrl = {}
    seenKey = {}
    if base = invalid or type(base) <> "roArray" then base = []
    if extra = invalid or type(extra) <> "roArray" then extra = []
    for each s in base
        if type(s) <> "roAssociativeArray" then continue for
        url = ""
        if s.url <> invalid then url = s.url
        if url = "" then continue for
        if seenUrl.DoesExist(url) then continue for
        lang = ""
        if s.language <> invalid then lang = LCase(s.language)
        nm = ""
        if s.name <> invalid then nm = LCase(s.name)
        key = lang + "|" + nm
        if nm <> "" and seenKey.DoesExist(key) then continue for
        seenUrl[url] = true
        if nm <> "" then seenKey[key] = true
        out.Push(s)
    end for
    for each s in extra
        if type(s) <> "roAssociativeArray" then continue for
        url = ""
        if s.url <> invalid then url = s.url
        if url = "" then continue for
        if seenUrl.DoesExist(url) then continue for
        lang = ""
        if s.language <> invalid then lang = LCase(s.language)
        nm = ""
        if s.name <> invalid then nm = LCase(s.name)
        key = lang + "|" + nm
        if nm <> "" and seenKey.DoesExist(key) then continue for
        seenUrl[url] = true
        if nm <> "" then seenKey[key] = true
        out.Push(s)
    end for
    return out
end function

' --- Free skip-intro / outro times -----------------------------------
'
' Three-tier cascade for the "the upstream stream had no DATERANGE"
' case. The first two are general TV/movie databases; the third is
' anime-specific.
'
'   1. TheIntroDB (primary)  - api.theintrodb.org/v2/media. Community-
'      curated, indexes by tmdb_id or imdb_id. Returns intro / recap /
'      credits / preview arrays with start_ms / end_ms (millisecond
'      timestamps). No API key required for reads.
'   2. IntroDB (backup)      - api.introdb.app/segments. Different
'      community database. Indexes by imdb_id only. Returns segments
'      with segment_type and start_sec / end_sec (clock strings or
'      raw seconds). No API key required.
'   3. AniSkip (tertiary)    - api.aniskip.com/v2/skip-times. Anime
'      only, indexed by MAL ID, so we resolve the title -> MAL via
'      Jikan (primary) or AniList GraphQL (backup) before hitting it.
'
' Restricted to TV content because (a) movies don't typically have
' skippable intros/outros and (b) all three databases are essentially
' episode-keyed.

function HM_FetchSkipTimes(imdb as String, tmdb as String, kind as String, season as Integer, episode as Integer, session as Object) as Object
    out = []
    if kind <> "tv" then return out
    if episode = invalid or episode <= 0 then return out
    if season = invalid then season = 0

    out = HM_FetchTheIntroDB(imdb, tmdb, season, episode, session)
    if out.Count() > 0 then return out

    out = HM_FetchIntroDB(imdb, season, episode, session)
    if out.Count() > 0 then return out

    out = HM_FetchAniSkipForEpisode(tmdb, episode, session)
    return out
end function

' --- Tier 1: TheIntroDB ---------------------------------------------

' Hit api.theintrodb.org/v2/media with whatever id we have. tmdb_id is
' preferred because it's an integer (no chance of url-encoding edge
' cases); imdb_id with the leading "tt" is the documented fallback.
' Response shape:
'   { "tmdb_id":..., "type":"tv", "season":1, "episode":1,
'     "intro":   [{"start_ms": ..., "end_ms": ...}, ...],
'     "recap":   [...], "credits": [...], "preview": [...] }
' Each timestamp is in milliseconds; null end_ms means "to end of
' stream" which we can't seek to deterministically, so those entries
' are skipped.
function HM_FetchTheIntroDB(imdb as String, tmdb as String, season as Integer, episode as Integer, session as Object) as Object
    out = []
    if season <= 0 or episode <= 0 then return out

    qParam = ""
    if tmdb <> invalid and tmdb <> "" then
        qParam = "tmdb_id=" + U_UrlEncode(tmdb)
    else if imdb <> invalid and imdb <> "" then
        qParam = "imdb_id=" + U_UrlEncode(imdb)
    else
        return out
    end if

    url = "https://api.theintrodb.org/v2/media?" + qParam + "&season=" + season.ToStr() + "&episode=" + episode.ToStr()
    res = HC_Get(session, url, {
        "Accept": "application/json"
        "User-Agent": "HydraHD-Roku/1.0"
    }, 5000)
    if res = invalid or res.body = "" then return out
    if res.status = 204 or res.status = 404 then return out
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return out

    HM_AppendTheIntroDbSegments(payload.intro,   "intro",  out)
    HM_AppendTheIntroDbSegments(payload.recap,   "recap",  out)
    HM_AppendTheIntroDbSegments(payload.credits, "outro",  out)
    return out
end function

' Push every {start_ms, end_ms} entry of an array as a {kind, start,
' end}-shaped chapter onto `out`. Skips entries with missing or
' equal-or-decreasing endpoints.
sub HM_AppendTheIntroDbSegments(arr as Dynamic, kindOut as String, out as Object)
    if arr = invalid or type(arr) <> "roArray" then return
    for each seg in arr
        if type(seg) <> "roAssociativeArray" then continue for
        startMs = 0
        if seg.start_ms <> invalid then startMs = seg.start_ms
        endMs = invalid
        if seg.end_ms <> invalid then endMs = seg.end_ms
        if endMs = invalid then continue for
        startVal = startMs / 1000.0
        endVal = endMs / 1000.0
        if endVal <= startVal then continue for
        out.Push({ kind: kindOut, start: startVal, end: endVal })
    end for
end sub

' --- Tier 2: IntroDB ------------------------------------------------

' GET /segments?imdb_id=tt...&season=...&episode=... . IntroDB indexes
' by IMDB only. Each record carries segment_type ("intro" / "recap" /
' "outro" / "credits") and start_sec / end_sec which can be either
' a numeric string in seconds or a clock-style string ("00:01:30" or
' "1:30") - HM_ParseClockOrSeconds handles both.
function HM_FetchIntroDB(imdb as String, season as Integer, episode as Integer, session as Object) as Object
    out = []
    if imdb = invalid or imdb = "" then return out
    if season <= 0 or episode <= 0 then return out

    url = "https://api.introdb.app/segments?imdb_id=" + U_UrlEncode(imdb) + "&season=" + season.ToStr() + "&episode=" + episode.ToStr()
    res = HC_Get(session, url, {
        "Accept": "application/json"
        "User-Agent": "HydraHD-Roku/1.0"
    }, 5000)
    if res = invalid or res.body = "" then return out
    if res.status = 204 or res.status = 404 then return out
    payload = ParseJSON(res.body)
    if payload = invalid then return out

    items = invalid
    if type(payload) = "roArray" then
        items = payload
    else if type(payload) = "roAssociativeArray" then
        if payload.segments <> invalid and type(payload.segments) = "roArray" then items = payload.segments
        if items = invalid and payload.data <> invalid and type(payload.data) = "roArray" then items = payload.data
        if items = invalid and payload.results <> invalid and type(payload.results) = "roArray" then items = payload.results
    end if
    if items = invalid then return out

    for each it in items
        if type(it) <> "roAssociativeArray" then continue for
        segType = ""
        if it.segment_type <> invalid then segType = LCase(it.segment_type)
        if segType = "" and it.type <> invalid then segType = LCase(it.type)
        kindOut = ""
        if segType = "intro" then kindOut = "intro"
        if segType = "recap" then kindOut = "recap"
        if segType = "outro" or segType = "credits" then kindOut = "outro"
        if kindOut = "" then continue for

        startVal = HM_ParseClockOrSeconds(it.start_sec)
        endVal = HM_ParseClockOrSeconds(it.end_sec)
        if endVal <= startVal then continue for
        out.Push({ kind: kindOut, start: startVal, end: endVal })
    end for
    return out
end function

' Accept "60", 60, 60.5, "00:01:00", "1:00", "1:00:30" - return seconds
' as Float. Used by IntroDB which can deliver either format depending
' on which client submitted the segment.
function HM_ParseClockOrSeconds(v as Dynamic) as Float
    if v = invalid then return 0.0
    t = type(v)
    if t = "Integer" or t = "roInt" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" then
        return v + 0.0
    end if
    if t = "String" or t = "roString" then
        s = v
        if s = "" then return 0.0
        if Instr(1, s, ":") = 0 then return s.ToFloat()
        parts = s.Tokenize(":")
        if parts = invalid then return 0.0
        n = parts.Count()
        if n = 3 then
            return parts[0].ToFloat() * 3600.0 + parts[1].ToFloat() * 60.0 + parts[2].ToFloat()
        else if n = 2 then
            return parts[0].ToFloat() * 60.0 + parts[1].ToFloat()
        else
            return s.ToFloat()
        end if
    end if
    return 0.0
end function

' --- Tier 3: AniSkip (anime only) -----------------------------------

' Resolve title -> MAL ID via Jikan (primary) then AniList (backup),
' then query AniSkip with whichever returned a usable ID. Almost always
' a no-op for live-action content, which is what we want.
function HM_FetchAniSkipForEpisode(tmdb as String, episode as Integer, session as Object) as Object
    out = []
    if tmdb = invalid or tmdb = "" then return out
    if episode <= 0 then return out

    title = HM_FetchTitleFromTmdb(tmdb, "tv", session)
    if title = "" then return out

    malId = HM_LookupMalIdViaJikan(title, session)
    if malId <> "" then
        out = HM_FetchAniSkipByMal(malId, episode, session)
        if out.Count() > 0 then return out
    end if

    malId2 = HM_LookupMalIdViaAnilist(title, session)
    if malId2 <> "" and malId2 <> malId then
        out = HM_FetchAniSkipByMal(malId2, episode, session)
    end if
    return out
end function

' Fetch the show's original (Japanese) title from TMDB. We hit the same
' db.videasy.net mirror used by the Vidking / Videasy port to avoid
' burning a TMDB API key. Falls back to localized title if original is
' missing.
function HM_FetchTitleFromTmdb(tmdb as String, kind as String, session as Object) as String
    if tmdb = invalid or tmdb = "" then return ""
    metaUrl = "https://db.videasy.net/3/" + kind + "/" + tmdb
    res = HC_Get(session, metaUrl, {}, 5000)
    if res = invalid or res.body = "" then return ""
    meta = ParseJSON(res.body)
    if meta = invalid or type(meta) <> "roAssociativeArray" then return ""
    if kind = "tv" then
        if meta.original_name <> invalid and meta.original_name <> "" then return meta.original_name
        if meta.name <> invalid then return meta.name
    else
        if meta.original_title <> invalid and meta.original_title <> "" then return meta.original_title
        if meta.title <> invalid then return meta.title
    end if
    return ""
end function

' Search Jikan for the title and return the first match's MAL ID.
function HM_LookupMalIdViaJikan(title as String, session as Object) as String
    if title = invalid or title = "" then return ""
    url = "https://api.jikan.moe/v4/anime?q=" + U_UrlEncode(title) + "&limit=1"
    res = HC_Get(session, url, { "Accept": "application/json" }, 5000)
    if res = invalid or res.body = "" then return ""
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return ""
    list = payload.data
    if list = invalid or type(list) <> "roArray" or list.Count() = 0 then return ""
    first = list[0]
    if type(first) <> "roAssociativeArray" then return ""
    if first.mal_id = invalid then return ""
    return first.mal_id.ToStr()
end function

' GraphQL search via AniList -> idMal field. Used as the secondary MAL
' lookup when Jikan rate-limits or returns no match.
function HM_LookupMalIdViaAnilist(title as String, session as Object) as String
    if title = invalid or title = "" then return ""
    body = "{" + chr(34) + "query" + chr(34) + ":" + chr(34) + "query($s:String){Media(search:$s,type:ANIME){idMal}}" + chr(34) + "," + chr(34) + "variables" + chr(34) + ":{" + chr(34) + "s" + chr(34) + ":" + chr(34) + HM_JsonEscape(title) + chr(34) + "}}"
    res = HC_Post(session, "https://graphql.anilist.co", { "Content-Type": "application/json", "Accept": "application/json" }, body, 5000)
    if res = invalid or res.body = "" then return ""
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return ""
    data = payload.data
    if data = invalid or type(data) <> "roAssociativeArray" then return ""
    media = data.Media
    if media = invalid or type(media) <> "roAssociativeArray" then return ""
    if media.idMal = invalid then return ""
    return media.idMal.ToStr()
end function

' AniSkip /v2/skip-times/{malId}/{ep}?types[]=op&types[]=ed
' Maps op -> intro, ed -> outro for the PlayerView skip banner.
function HM_FetchAniSkipByMal(malId as String, episode as Integer, session as Object) as Object
    out = []
    if malId = invalid or malId = "" then return out
    url = "https://api.aniskip.com/v2/skip-times/" + malId + "/" + episode.ToStr() + "?types[]=op&types[]=ed"
    res = HC_Get(session, url, { "Accept": "application/json" }, 5000)
    if res = invalid or res.body = "" then return out
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return out
    if payload.found <> true then return out
    results = payload.results
    if results = invalid or type(results) <> "roArray" then return out
    for each r in results
        if type(r) <> "roAssociativeArray" then continue for
        intvl = r.interval
        if intvl = invalid or type(intvl) <> "roAssociativeArray" then continue for
        startVal = 0.0
        endVal = 0.0
        if intvl.startTime <> invalid then startVal = intvl.startTime
        if intvl.endTime <> invalid then endVal = intvl.endTime
        if endVal <= startVal then continue for
        skipType = ""
        if r.skipType <> invalid then skipType = LCase(r.skipType)
        kind = ""
        if skipType = "op" then kind = "intro"
        if skipType = "ed" then kind = "outro"
        if skipType = "mixed-op" then kind = "intro"
        if skipType = "mixed-ed" then kind = "outro"
        if skipType = "recap" then kind = "recap"
        if kind = "" then continue for
        out.Push({ kind: kind, start: startVal, end: endVal })
    end for
    return out
end function

' Minimal JSON-string escaper for embedding a title in a GraphQL POST
' body. Handles the four characters that would break the JSON literal.
function HM_JsonEscape(s as String) as String
    if s = invalid or s = "" then return ""
    bs = chr(92)
    out = s
    re1 = CreateObject("roRegex", bs + bs, "g")
    out = re1.replaceAll(out, bs + bs)
    re2 = CreateObject("roRegex", chr(34), "g")
    out = re2.replaceAll(out, bs + chr(34))
    re3 = CreateObject("roRegex", chr(10), "g")
    out = re3.replaceAll(out, bs + "n")
    re4 = CreateObject("roRegex", chr(13), "g")
    out = re4.replaceAll(out, bs + "r")
    return out
end function

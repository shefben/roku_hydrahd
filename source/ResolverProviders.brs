' ResolverProviders.brs - Per-provider resolver functions.
'
' Each function takes (embedUrl, refer, session) and returns
'   { url, streamFormat, qualities, subtitles, chapters, referer, userAgent }
' on success, or invalid on failure. The dispatcher in Resolver.brs
' maps host substrings to these functions.
'
' Phase 1 ships RP_ResolveGeneric implemented for real (it covers the
' best-effort regex scrape that resolveBestEffort already does), and
' every other provider as a thin delegator to RP_ResolveGeneric so the
' channel keeps booting while we incrementally fill in real algorithms
' across Phases 2 - 4b.
'
' Provider implementations land in this order (matching plan phases):
'   Phase 2: Generic, VidsrcCc, Airflix, Vidrock, Xpass
'   Phase 3: JwplayerPage, Lookmovie, Vidora, 2embed, Cloudnestra,
'            VidsrcXyz, Moviesapi, Autoembed, Ythd
'   Phase 4: Streamtape, Uqload, Doodstream, Voe, Streamsb, Mixdrop
'   Phase 4b: Vidking, Videasy (shared WASM-equivalent), Peachify

' --- Generic best-effort scrape --------------------------------------
'
' Mirrors ResolveTask.brs:resolveBestEffort lines 94-124 plus
' subtitle extraction. This is what every "no specific match" host
' falls back to and is sufficient for plain JWPlayer pages that emit
' an .m3u8 / .mp4 URL in their inline config.

function RP_ResolveGeneric(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid

    html = page.body
    finalUrl = page.finalUrl
    if finalUrl = invalid or finalUrl = "" then finalUrl = embedUrl

    hlsRe = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.m3u8[^" + chr(34) + "'\\\s>]*)", "i")
    h = hlsRe.match(html)
    if h <> invalid and h.Count() >= 2 then
        return {
            url: h[1]
            streamFormat: "hls"
            qualities: []
            subtitles: RP_ExtractSubs(html)
            chapters: []
            referer: refer
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
            subtitles: RP_ExtractSubs(html)
            chapters: []
            referer: refer
            userAgent: ""
        }
    end if

    return invalid
end function

function RP_ExtractSubs(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    re = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.(?:vtt|srt))", "ig")
    matches = re.matchAll(html)
    if matches = invalid then return out
    for each mt in matches
        if mt.Count() < 2 then continue for
        url = mt[1]
        lang = "en"
        langRe = CreateObject("roRegex", "[/_-]([a-z]{2})[/._-]", "i")
        lm = langRe.match(url)
        if lm <> invalid and lm.Count() >= 2 then lang = LCase(lm[1])
        out.Push({ url: url, language: lang, name: UCase(lang) })
    end for
    return out
end function

' --- Phase 2: vidsrc.cc ----------------------------------------------
'
' Page is CF-protected and useless to scrape, but the player has a stable
' JSON API:
'   GET /api/episode/{tmdb}/servers           (movies)
'   GET /api/episode/{tmdb}/{s}/{e}/servers   (tv)
'     -> { data: [ { name, hash }, ... ] }
'   GET /api/source/{hash}
'     -> { success, data: { stream, subtitles: [ {file, label, language}, ... ] } }
' Both endpoints require Referer matching the embed origin, an Origin
' header, and X-Requested-With: XMLHttpRequest. Port of server.py:1498.

function RP_ResolveVidsrcCc(embedUrl as String, refer as String, session as Object) as Object
    pathRe = CreateObject("roRegex", "/(?:v2/)?embed/(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    kind = m[1]
    cid = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if

    origin = HC_OriginOf(embedUrl)
    if origin = "" then return invalid

    if kind = "tv" and season <> "" and episode <> "" then
        serversUrl = origin + "/api/episode/" + cid + "/" + season + "/" + episode + "/servers"
    else
        serversUrl = origin + "/api/episode/" + cid + "/servers"
    end if

    apiHeaders = {
        "Referer": embedUrl
        "Origin": origin
        "Accept": "application/json, text/plain, */*"
        "X-Requested-With": "XMLHttpRequest"
    }

    res = HC_Get(session, serversUrl, apiHeaders, 8000)
    if res = invalid or res.body = "" then return invalid
    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid

    servers = invalid
    if payload.data <> invalid then servers = payload.data
    if (servers = invalid or type(servers) <> "roArray") and payload.servers <> invalid then servers = payload.servers
    if servers = invalid or type(servers) <> "roArray" then return invalid

    for each srv in servers
        if type(srv) <> "roAssociativeArray" then continue for
        srvHash = ""
        if srv.hash <> invalid then srvHash = srv.hash
        if srvHash = "" and srv.data_id <> invalid then srvHash = srv.data_id
        if srvHash = "" and srv.id <> invalid then srvHash = srv.id
        if srvHash = "" then continue for

        sourceUrl = origin + "/api/source/" + srvHash
        sres = HC_Get(session, sourceUrl, apiHeaders, 8000)
        if sres = invalid or sres.body = "" then continue for
        sdata = ParseJSON(sres.body)
        if sdata = invalid or type(sdata) <> "roAssociativeArray" then continue for

        data = invalid
        if sdata.data <> invalid and type(sdata.data) = "roAssociativeArray" then
            data = sdata.data
        else
            data = sdata
        end if

        stream = ""
        if data.stream <> invalid then stream = RP_AsStreamString(data.stream)
        if stream = "" and data.source <> invalid then stream = RP_AsStreamString(data.source)
        if stream = "" and data.file <> invalid then stream = RP_AsStreamString(data.file)
        if stream = "" and data.url <> invalid then stream = RP_AsStreamString(data.url)
        if stream = "" then continue for

        subs = []
        rawSubs = invalid
        if data.subtitles <> invalid then rawSubs = data.subtitles
        if rawSubs = invalid and data.captions <> invalid then rawSubs = data.captions
        if rawSubs <> invalid and type(rawSubs) = "roArray" then
            for each s in rawSubs
                if type(s) <> "roAssociativeArray" then continue for
                surl = ""
                if s.file <> invalid then surl = s.file
                if surl = "" and s.url <> invalid then surl = s.url
                if surl = "" and s.src <> invalid then surl = s.src
                if surl = "" then continue for
                lang = "en"
                if s.language <> invalid then lang = LCase(Left(s.language, 2))
                if lang = "" and s.lang <> invalid then lang = LCase(Left(s.lang, 2))
                if lang = "" and s.label <> invalid then lang = LCase(Left(s.label, 2))
                name = ""
                if s.label <> invalid then name = s.label
                if name = "" and s.language <> invalid then name = s.language
                if name = "" then name = "Subtitles"
                subs.Push({ url: surl, language: lang, name: name })
            end for
        end if

        return {
            url: stream
            streamFormat: U_StreamFormat(stream)
            qualities: []
            subtitles: subs
            chapters: []
            referer: embedUrl
            userAgent: ""
        }
    end for

    return invalid
end function

' Helper: vidsrc.cc occasionally returns `stream` as either a string OR
' a list of {file:..} objects. Coerce to a single URL string.
function RP_AsStreamString(v as Dynamic) as String
    if v = invalid then return ""
    if type(v) = "String" or type(v) = "roString" then return v
    if type(v) = "roArray" then
        if v.Count() = 0 then return ""
        first = v[0]
        if type(first) = "String" or type(first) = "roString" then return first
        if type(first) = "roAssociativeArray" then
            if first.file <> invalid then return first.file
            if first.url <> invalid then return first.url
        end if
    end if
    return ""
end function

' --- Phase 2: airflix1.com -------------------------------------------
'
' Calls https://streamdata.vaplayer.ru/api.php?(tmdb|imdb)=<id>&type=<kind>
' [&season=&episode=]. The endpoint requires nextgencloudfabric.com as both
' Referer and Origin (vaplayer.ru rejects requests from any other origin;
' the previous brightpathsignals.com origin now 404s).
' Returns { status_code, data: { stream_urls: [ "...m3u8", ... ] }, default_subs: [...] }.
' Validates each candidate by GETing it and checking #EXTM3U prefix.
' Port of server.py:1753.

function RP_ResolveAirflix(embedUrl as String, refer as String, session as Object) as Object
    pathRe = CreateObject("roRegex", "/embed/(movie|tv)/(tt\d+|\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    mediaType = m[1]
    mediaId = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if

    idParam = "tmdb"
    if Left(mediaId, 2) = "tt" then idParam = "imdb"

    apiUrl = "https://streamdata.vaplayer.ru/api.php?" + idParam + "=" + U_UrlEncode(mediaId) + "&type=" + mediaType
    if mediaType = "tv" and season <> "" and episode <> "" then
        apiUrl = apiUrl + "&season=" + season + "&episode=" + episode
    end if

    ' airflix1.com's player iframes nextgencloudfabric.com, which is now the
    ' only Origin/Referer the vaplayer.ru stream API accepts - the old
    ' brightpathsignals.com origin started returning HTTP 404 (verified
    ' 2026-06: brightpathsignals/airflix1/no-referer -> 404, nextgencloudfabric
    ' -> 200 with stream_urls). apiReferer also flows into the stream
    ' validation GET below and the returned result envelope's referer.
    apiReferer = "https://nextgencloudfabric.com/"
    res = HC_Get(session, apiUrl, {
        "Referer": apiReferer
        "Origin": "https://nextgencloudfabric.com"
    }, 8000)
    if res = invalid or res.body = "" then return invalid

    envelope = ParseJSON(res.body)
    if envelope = invalid or type(envelope) <> "roAssociativeArray" then return invalid
    sc = ""
    if envelope.status_code <> invalid then sc = envelope.status_code.ToStr()
    if sc <> "200" then return invalid
    data = envelope.data
    if data = invalid or type(data) <> "roAssociativeArray" then return invalid
    streams = data.stream_urls
    if streams = invalid or type(streams) <> "roArray" or streams.Count() = 0 then return invalid

    ' Airflix serves subtitles in TWO separate lists: "subs" (usually just
    ' English) and "default_subs" (all languages on shows that have them -
    ' Mandalorian, Rings of Power, etc.). Each entry looks like
    '   {"lang":"English (SDH)","code":"en","url":"https://..."}
    ' - `code` is the ISO 639-1 code, `lang` is the display label (which
    ' can be "English (SDH)", "English - eng(5)", "Portuguese (Brazilian)",
    ' etc.). Pre-fix this read `s.lang` as the code, so language matching
    ' downstream (English-first sort, PlayerView auto-pick) all fell over.
    ' Merge all four possible source keys, deduplicate by URL, sort
    ' English first by ISO code.
    subs = []
    seenSubUrl = {}
    allRawSubs = []
    subSources = [envelope.subs, data.subs, envelope.default_subs, data.default_subs]
    for each lst in subSources
        if lst = invalid or type(lst) <> "roArray" then continue for
        for each s in lst
            if type(s) <> "roAssociativeArray" then continue for
            surl = ""
            if s.url <> invalid then surl = s.url
            if surl = "" and s.file <> invalid then surl = s.file
            if surl = "" then continue for
            if seenSubUrl.DoesExist(surl) then continue for
            seenSubUrl[surl] = true
            ' ISO code: prefer `code` (vaplayer / airflix1 default_subs
            ' shape), then `language`, then a 2-char prefix of `lang` as a
            ' last resort (works when `lang` is the bare ISO like "en").
            lang = ""
            if s.code <> invalid then lang = LCase(s.code)
            if lang = "" and s.language <> invalid then lang = LCase(s.language)
            if lang = "" and s.lang <> invalid and Len(s.lang) >= 2 then lang = LCase(Left(s.lang, 2))
            if lang = "" then lang = "en"
            ' Display name: prefer the full label (`lang`) so chips like
            ' "English (SDH)" or "Portuguese (Brazilian)" stay legible.
            name = ""
            if s.label <> invalid then name = s.label
            if name = "" and s.lang <> invalid then name = s.lang
            if name = "" and s.language <> invalid then name = s.language
            if name = "" then name = UCase(lang)
            allRawSubs.Push({ url: surl, language: lang, name: name })
        end for
    end for
    ' English first so the CC panel defaults to it and Roku's language
    ' matching doesn't auto-select a track the device has no font for.
    for each track in allRawSubs
        if track.language = "en" then subs.Push(track)
    end for
    for each track in allRawSubs
        if track.language <> "en" then subs.Push(track)
    end for

    for each streamUrl in streams
        if type(streamUrl) <> "String" and type(streamUrl) <> "roString" then continue for
        if streamUrl = "" then continue for
        playlist = HC_Get(session, streamUrl, { "Referer": apiReferer }, 6000)
        if playlist = invalid or playlist.body = "" then continue for
        if Left(playlist.body, 7) <> "#EXTM3U" then continue for
        return {
            url: streamUrl
            streamFormat: "hls"
            qualities: []
            subtitles: subs
            chapters: []
            referer: apiReferer
            userAgent: ""
        }
    end for

    return invalid
end function

' --- Phase 2: vidrock / vidsrc.vip -----------------------------------
'
' Both share a JSON API at vidrock.net/api/{movie|tv}/{tmdb}[/{s}/{e}].
' Response is either plain JSON or base64-encoded JSON in the body.
' Walks the parsed tree for any string containing .m3u8 / .mp4.
' Port of server.py:1631.

' AES-256-CBC encrypt `plain` (PKCS7) with hex key/iv, return base64url
' ciphertext. Ports vidrock's JS Fk(): CryptoJS.AES.encrypt(...).ciphertext
' -> base64 -> base64url. Must call BOTH Process() and Final() - for a
' single-block input Process() buffers and Final() emits the padded block.
function RP_VidrockEncrypt(plain as String, keyHex as String, ivHex as String) as String
    cipher = CreateObject("roEVPCipher")
    rc = cipher.Setup(true, "aes-256-cbc", keyHex, ivHex, 1)   ' 1 = PKCS7 padding
    if rc <> 0 then return ""
    pt = CreateObject("roByteArray")
    pt.FromAsciiString(plain)
    full = CreateObject("roByteArray")
    ct = cipher.Process(pt)
    if ct <> invalid then
        for i = 0 to ct.Count() - 1
            full.Push(ct[i])
        end for
    end if
    fin = cipher.Final()
    if fin <> invalid then
        for i = 0 to fin.Count() - 1
            full.Push(fin[i])
        end for
    end if
    if full.Count() = 0 then return ""
    b64 = full.ToBase64String()
    ' base64url: + -> - , / -> _ , strip trailing =
    re1 = CreateObject("roRegex", "\+", "")
    re2 = CreateObject("roRegex", "/", "")
    re3 = CreateObject("roRegex", "=+$", "")
    out = re1.ReplaceAll(b64, "-")
    out = re2.ReplaceAll(out, "_")
    out = re3.ReplaceAll(out, "")
    return out
end function

function RP_ResolveVidrock(embedUrl as String, refer as String, session as Object) as Object
    ' HydraHD now serves /movie/<tmdb> (no /embed/); accept both forms.
    pathRe = CreateObject("roRegex", "/(?:embed/)?(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    kind = m[1]
    cid = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if

    ' Domain moved vidrock.net -> vidrock.ru (301; HC_Get doesn't update
    ' finalUrl on redirect, so target .ru directly). The API id is now
    ' AES-256-CBC(id) base64url'd - the old plaintext path returns
    ' {"error":"Forbidden"}. key="x7k9mPqT2rWvY8zA5bC3nF6hJ2lK4mN9" (32B),
    ' iv = first 16 bytes of the key.
    apiOrigin = "https://vidrock.ru"
    if kind = "tv" and season <> "" and episode <> "" then
        plain = cid + "_" + season + "_" + episode
    else
        plain = cid
    end if
    keyHex = "78376b396d5071543272577659387a41356243336e4636684a326c4b346d4e39"
    ivHex  = "78376b396d5071543272577659387a41"
    enc = RP_VidrockEncrypt(plain, keyHex, ivHex)
    if enc = "" then return invalid
    if kind = "tv" and season <> "" and episode <> "" then
        apiUrl = apiOrigin + "/api/tv/" + enc
    else
        apiUrl = apiOrigin + "/api/movie/" + enc
    end if

    headers = {
        "Referer": apiOrigin + "/" + kind + "/" + cid
        "Origin": apiOrigin
        "Accept": "application/json, text/plain, */*"
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    }

    res = HC_Get(session, apiUrl, headers, 8000)
    if res = invalid or res.body = "" then return invalid

    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then
        ' Some deployments return base64-encoded JSON in plain text.
        decoded = RP_TryBase64Decode(U_Trim(res.body))
        if decoded <> "" then payload = ParseJSON(decoded)
        if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid
    end if

    streams = []
    RP_WalkForStreams(payload, streams)
    if streams.Count() = 0 then return invalid

    subs = []
    rawSubs = invalid
    if payload.subtitle <> invalid then rawSubs = payload.subtitle
    if rawSubs = invalid and payload.subtitles <> invalid then rawSubs = payload.subtitles
    if rawSubs = invalid and payload.captions <> invalid then rawSubs = payload.captions
    if rawSubs <> invalid and type(rawSubs) = "roArray" then
        for each s in rawSubs
            if type(s) <> "roAssociativeArray" then continue for
            surl = ""
            if s.file <> invalid then surl = s.file
            if surl = "" and s.url <> invalid then surl = s.url
            if surl = "" then continue for
            lang = "en"
            if s.language <> invalid then lang = LCase(Left(s.language, 2))
            if lang = "" and s.lang <> invalid then lang = LCase(Left(s.lang, 2))
            name = ""
            if s.label <> invalid then name = s.label
            if name = "" and s.language <> invalid then name = s.language
            if name = "" then name = "Subtitles"
            subs.Push({ url: surl, language: lang, name: name })
        end for
    end if

    stream = streams[0]
    return {
        url: stream
        streamFormat: U_StreamFormat(stream)
        qualities: []
        subtitles: subs
        chapters: []
        referer: embedUrl
        userAgent: ""
    }
end function

' Recursively walk an arbitrary parsed JSON tree pushing any string that
' looks like a video URL into `out`. Stops descending non-collection
' values. Used by vidrock and any other provider that hides the stream
' URL inside an unpredictable tree shape.
sub RP_WalkForStreams(obj as Dynamic, out as Object)
    if obj = invalid or out = invalid then return
    t = type(obj)
    if t = "roAssociativeArray" then
        for each k in obj
            v = obj[k]
            if v = invalid then continue for
            vt = type(v)
            if vt = "String" or vt = "roString" then
                if Instr(1, v, ".m3u8") > 0 or Instr(1, v, ".mp4") > 0 then out.Push(v)
            else if vt = "roAssociativeArray" or vt = "roArray" then
                RP_WalkForStreams(v, out)
            end if
        end for
    else if t = "roArray" then
        for each item in obj
            if item = invalid then continue for
            it = type(item)
            if it = "String" or it = "roString" then
                if Instr(1, item, ".m3u8") > 0 or Instr(1, item, ".mp4") > 0 then out.Push(item)
            else if it = "roAssociativeArray" or it = "roArray" then
                RP_WalkForStreams(item, out)
            end if
        end for
    end if
end sub

' Tolerant base64 decoder for vidrock's alt-shape responses. Pads the
' input to a multiple of 4 because Roku's FromBase64String is strict.
function RP_TryBase64Decode(s as String) as String
    if s = invalid or s = "" then return ""
    s2 = s
    pad = Len(s2) mod 4
    if pad = 1 then return ""
    if pad = 2 then s2 = s2 + "=="
    if pad = 3 then s2 = s2 + "="
    ba = CreateObject("roByteArray")
    ba.FromBase64String(s2)
    return ba.ToAsciiString()
end function

' --- Phase 2: xpass.top ----------------------------------------------
'
' play.xpass.top page exposes:
'   var data = { "playlist": "/mdata/<hash>/<n>/playlist.json", ... }
'   var backups = [ { id, name, url, dl }, ... ]
'   var suburl = "https://sub.wyzie.io/search?id=<tmdb>&..."
' Each playlist.json returns
'   { playlist: [ { sources: [ { file: "<m3u8>", type: "hls" } ] } ] }
' We try the primary first, then walk the backups list. The TIK / mdata
' backend serves PNG-steganography segments which Roku can't decode, so
' we down-rank that source. Port of server.py:1120.

function RP_ResolveXpass(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer else headers["Referer"] = "https://hydrahd.ru/"
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    html = page.body
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl

    candidates = []  ' { label, url } records

    primaryRe = CreateObject("roRegex", chr(34) + "playlist" + chr(34) + "\s*:\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    pm = primaryRe.match(html)
    if pm <> invalid and pm.Count() >= 2 then
        candidates.Push({ label: "TIK primary", url: RP_AbsUrl(pm[1], final) })
    end if

    backups = RP_ParseXpassBackups(html)
    if backups <> invalid and type(backups) = "roArray" then
        for each entry in backups
            if type(entry) <> "roAssociativeArray" then continue for
            url = entry.url
            if url = invalid or url = "" then continue for
            name = ""
            if entry.name <> invalid then name = entry.name
            if name = "" then name = "backup"
            candidates.Push({ label: name, url: RP_AbsUrl(url, final) })
        end for
    end if

    ' Dedup while preserving order.
    seen = {}
    uniq = []
    for each c in candidates
        if c.url = "" then continue for
        if seen.DoesExist(c.url) then continue for
        seen[c.url] = true
        uniq.Push(c)
    end for

    ' Sort: prefer mov/vip/sfy backends over TIK/mdata (steganography).
    ' Smaller rank = tried first.
    for i = 1 to uniq.Count() - 1
        cur = uniq[i]
        curRank = RP_XpassSrcRank(cur)
        j = i - 1
        while j >= 0
            if RP_XpassSrcRank(uniq[j]) <= curRank then exit while
            uniq[j + 1] = uniq[j]
            j = j - 1
        end while
        uniq[j + 1] = cur
    end for

    subs = RP_FetchXpassSubs(html, session)

    for each c in uniq
        playlistUrl = c.url
        plRes = HC_Get(session, playlistUrl, { "Referer": final }, 6000)
        if plRes = invalid or plRes.body = "" then continue for
        data = ParseJSON(plRes.body)
        if data = invalid or type(data) <> "roAssociativeArray" then continue for
        streamUrl = RP_XpassFirstSource(data)
        if streamUrl = "" then continue for
        streamUrl = RP_AbsUrl(streamUrl, playlistUrl)

        verify = HC_Get(session, streamUrl, { "Referer": final }, 6000)
        if verify = invalid or verify.body = "" then continue for
        if Left(verify.body, 7) <> "#EXTM3U" then continue for

        return {
            url: streamUrl
            streamFormat: "hls"
            qualities: []
            subtitles: subs
            chapters: []
            referer: final
            userAgent: ""
        }
    end for

    return invalid
end function

function RP_XpassSrcRank(item as Object) as Integer
    label = ""
    url = ""
    if item.label <> invalid then label = UCase(item.label)
    if item.url <> invalid then url = LCase(item.url)
    if Instr(1, label, "TIK") > 0 or Instr(1, url, "/mdata/") > 0 then return 100
    if Instr(1, label, "MOV") > 0 or Instr(1, url, "mov.1x2") > 0 then return 0
    if Instr(1, label, "VIP") > 0 or Instr(1, url, "/vip/") > 0 then return 1
    if Instr(1, label, "SFY") > 0 or Instr(1, url, "/sfy/") > 0 then return 2
    return 50
end function

' Walk the inline `var backups = [...]` array out of the page. Manual
' bracket walking respects strings (and embedded ['] / [\] / [\"] etc.)
' so we don't trip on the first `]` inside a quoted URL. JSON-parses the
' captured substring. Port of _parse_xpass_backups in server.py:1204.
function RP_ParseXpassBackups(html as String) as Object
    if html = invalid or html = "" then return []
    re = CreateObject("roRegex", "var\s+backups\s*=\s*\[", "i")
    head = re.match(html)
    if head = invalid or head.Count() < 1 then return []
    needle = head[0]
    startIdx = Instr(1, html, needle)
    if startIdx <= 0 then return []
    bracketIdx = Instr(startIdx, html, "[")
    if bracketIdx <= 0 then return []

    depth = 0
    inStr = false
    quote = ""
    escNext = false
    endIdx = 0
    n = Len(html)
    bs = chr(92)
    dq = chr(34)
    sq = "'"

    for i = bracketIdx to n
        ch = Mid(html, i, 1)
        if inStr then
            if escNext then
                escNext = false
            else if ch = bs then
                escNext = true
            else if ch = quote then
                inStr = false
            end if
        else
            if ch = dq or ch = sq then
                inStr = true
                quote = ch
            else if ch = "[" then
                depth = depth + 1
            else if ch = "]" then
                depth = depth - 1
                if depth = 0 then
                    endIdx = i
                    exit for
                end if
            end if
        end if
    end for
    if endIdx = 0 then return []

    raw = Mid(html, bracketIdx, endIdx - bracketIdx + 1)
    parsed = ParseJSON(raw)
    if parsed = invalid or type(parsed) <> "roArray" then return []
    return parsed
end function

' Pull the first {sources:[{file:...}]} entry out of a parsed playlist.json.
function RP_XpassFirstSource(data as Object) as String
    if data = invalid or type(data) <> "roAssociativeArray" then return ""
    pl = data.playlist
    if pl = invalid or type(pl) <> "roArray" then return ""
    for each entry in pl
        if type(entry) <> "roAssociativeArray" then continue for
        srcs = entry.sources
        if srcs = invalid or type(srcs) <> "roArray" then continue for
        for each src in srcs
            if type(src) <> "roAssociativeArray" then continue for
            f = src.file
            if f <> invalid and f <> "" then return f
        end for
    end for
    return ""
end function

' Fetch the wyzie.io subtitle search endpoint referenced by the page's
' var suburl = "..." and convert the first 30 entries to our subtitle
' record shape. Failures are silent — subs are never load-bearing.
function RP_FetchXpassSubs(html as String, session as Object) as Object
    out = []
    if html = invalid or html = "" then return out
    re = CreateObject("roRegex", "var\s+suburl\s*=\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    m = re.match(html)
    if m = invalid or m.Count() < 2 then return out
    res = HC_Get(session, m[1], invalid, 6000)
    if res = invalid or res.body = "" then return out
    items = ParseJSON(res.body)
    if items = invalid or type(items) <> "roArray" then return out
    take = items.Count()
    if take > 30 then take = 30
    for i = 0 to take - 1
        it = items[i]
        if type(it) <> "roAssociativeArray" then continue for
        url = it.url
        if url = invalid or url = "" then continue for
        lang = "en"
        if it.language <> invalid then lang = LCase(it.language)
        name = ""
        if it.display <> invalid then name = it.display
        if name = "" then
            if it.language <> invalid then name = UCase(it.language) else name = "EN"
        end if
        out.Push({ url: url, language: lang, name: name })
    end for
    return out
end function

' --- Phase 3: JWPlayer page resolver ---------------------------------
'
' Many embed pages are minimal JWPlayer / Playerjs pages whose stream URL
' lives in `file: "..."` / `source: "..."` / `src: "..."` / `playUrl: "..."`
' or in a Dean Edwards `eval(p,a,c,k,e,d)` packed wrapper around either.
' This is the workhorse for vidora, lookmovie, and most generic embeds.
' Validates each candidate by GET + #EXTM3U sniffing for HLS so dead
' candidates are skipped silently. Port of server.py:1375.

function RP_ResolveJwplayerPage(html as String, pageUrl as String, refer as String, session as Object) as Object
    if html = invalid or html = "" then return invalid

    candidates = []
    RP_JwExtractInto(html, candidates)

    packedRe = CreateObject("roRegex", "eval\(function\(p,a,c,k,e,d\)[\s\S]+?</script>", "i")
    pm = packedRe.match(html)
    if pm <> invalid and pm.Count() >= 1 then
        unpacked = JU_UnpackPacked(pm[0])
        if unpacked <> "" then RP_JwExtractInto(unpacked, candidates)
    end if

    if candidates.Count() = 0 then return invalid

    refUrl = refer
    if refUrl = "" then refUrl = pageUrl

    seen = {}
    for each cand in candidates
        u = RP_AbsUrl(cand.url, pageUrl)
        if u = "" then continue for
        if seen.DoesExist(u) then continue for
        seen[u] = true
        res = HC_Get(session, u, { "Referer": refUrl }, 6000)
        if res = invalid or res.body = "" then continue for
        if cand.fmt = "hls" and Left(res.body, 7) <> "#EXTM3U" then continue for
        return {
            url: u
            streamFormat: cand.fmt
            qualities: []
            subtitles: RP_ExtractSubs(html)
            chapters: []
            referer: refUrl
            userAgent: ""
        }
    end for
    return invalid
end function

' Pull every plausible JWPlayer source candidate out of `text` and push
' { url, fmt } records into `out`. Handles four common config-key shapes
' plus a generic m3u8 / mp4 URL fallback. Used both on raw HTML and on
' the Dean-Edwards-unpacked output.
sub RP_JwExtractInto(text as String, out as Object)
    if text = invalid or text = "" then return
    dq = chr(34)

    pat1 = "file\s*:\s*[" + dq + "']([^" + dq + "']{8,})[" + dq + "']"
    pat2 = "source\s*:\s*[" + dq + "']([^" + dq + "']{8,})[" + dq + "']"
    pat3 = "src\s*:\s*[" + dq + "']([^" + dq + "']{8,}\.(?:m3u8|mp4)[^" + dq + "']*)[" + dq + "']"
    pat4 = "playUrl\s*:\s*[" + dq + "']([^" + dq + "']{8,})[" + dq + "']"

    for each pat in [pat1, pat2, pat3, pat4]
        re = CreateObject("roRegex", pat, "i")
        m = re.match(text)
        if m <> invalid and m.Count() >= 2 then
            url = RP_UnescapeSlashes(m[1])
            fmt = "hls"
            if Instr(1, LCase(url), ".mp4") > 0 then fmt = "mp4"
            out.Push({ url: url, fmt: fmt })
        end if
    end for

    hlsRe = CreateObject("roRegex", "(https?://[^" + dq + "'\\\s>]+\.m3u8[^" + dq + "'\\\s>]*)", "i")
    h = hlsRe.match(text)
    if h <> invalid and h.Count() >= 2 then out.Push({ url: h[1], fmt: "hls" })

    mp4Re = CreateObject("roRegex", "(https?://[^" + dq + "'\\\s>]+\.mp4[^" + dq + "'\\\s>]*)", "i")
    p = mp4Re.match(text)
    if p <> invalid and p.Count() >= 2 then out.Push({ url: p[1], fmt: "mp4" })
end sub

' JSON-encoded URLs come back with `\/` instead of `/`. The roUrlTransfer
' would happily fetch the literal-backslash form on some firmware but
' returns 404 on others, so always normalise.
function RP_UnescapeSlashes(s as String) as String
    if s = invalid or s = "" then return ""
    re = CreateObject("roRegex", "\\/", "g")
    return re.replaceAll(s, "/")
end function

' urljoin-equivalent that handles the cases providers actually emit:
' absolute, protocol-relative (`//cdn/path`), origin-relative (`/path`),
' and path-relative. U_AbsUrl in Utils.brs naively concatenates and
' produces wrong output when `base` includes a path component, which is
' the common case for cloudnestra / lookmovie / autoembed iframe srcs.
function RP_AbsUrl(href as String, baseUrl as String) as String
    if href = invalid or href = "" then return ""
    h = U_Trim(href)
    if Left(h, 7) = "http://" or Left(h, 8) = "https://" then return h
    if Left(h, 2) = "//" then return "https:" + h
    origin = HC_OriginOf(baseUrl)
    if origin = "" then return h
    if Left(h, 1) = "/" then return origin + h

    ' Path-relative: trim everything after the last `/` in the path.
    pathStart = Len(origin) + 1
    if pathStart > Len(baseUrl) then return origin + "/" + h
    pathPart = Mid(baseUrl, pathStart + 1)
    qIdx = Instr(1, pathPart, "?")
    if qIdx > 0 then pathPart = Left(pathPart, qIdx - 1)
    fIdx = Instr(1, pathPart, "#")
    if fIdx > 0 then pathPart = Left(pathPart, fIdx - 1)
    lastSlash = 0
    for i = 1 to Len(pathPart)
        if Mid(pathPart, i, 1) = "/" then lastSlash = i
    end for
    if lastSlash = 0 then return origin + "/" + h
    return origin + "/" + Left(pathPart, lastSlash) + h
end function

' --- Phase 3: lookmovie2.skin ----------------------------------------
'
' /e/<id> is a packed JWPlayer config with hls2 / hls3 / hls4 keys; the
' real player picks hls4 if available, then hls3, then hls2. Validate
' each candidate against #EXTM3U so we don't hand the Video node a 404.
' Port of server.py:1059.

function RP_ResolveLookmovie(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer else headers["Referer"] = embedUrl
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl

    packedRe = CreateObject("roRegex", "eval\(function\(p,a,c,k,e,d\)[\s\S]*?</script>", "i")
    pm = packedRe.match(page.body)
    if pm = invalid or pm.Count() < 1 then return invalid
    unpacked = JU_UnpackPacked(pm[0])
    if unpacked = "" then return invalid

    links = {}
    keyRe = CreateObject("roRegex", chr(34) + "(hls[234])" + chr(34) + "\s*:\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "ig")
    matches = keyRe.matchAll(unpacked)
    if matches <> invalid then
        for each mt in matches
            if mt.Count() < 3 then continue for
            links[mt[1]] = RP_UnescapeSlashes(mt[2])
        end for
    end if

    ' hls4's master still validates but its variant is now ad-only tiktokcdn
    ' image segments; hls3 carries the real MPEG-TS video. Prefer hls3.
    order = ["hls3", "hls4", "hls2"]
    for each k in order
        u = links[k]
        if u = invalid or u = "" then continue for
        u = RP_AbsUrl(u, final)
        res = HC_Get(session, u, { "Referer": final }, 6000)
        if res = invalid or res.body = "" then continue for
        if Left(res.body, 7) <> "#EXTM3U" then continue for
        return {
            url: u
            streamFormat: "hls"
            qualities: []
            subtitles: RP_ExtractSubs(page.body)
            chapters: []
            referer: final
            userAgent: ""
        }
    end for
    return invalid
end function

' --- Phase 3: vidora.stream / ww*.moviesapi.* ------------------------
'
' Plain JWPlayer page with eval(p,a,c,k,e,d) packed config. Delegates to
' RP_ResolveJwplayerPage which handles both raw and unpacked sources.
' Port of server.py:1623.

function RP_ResolveVidora(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer else headers["Referer"] = "https://moviesapi.to/"
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl
    ' vidora.stream's CDN (bx/box.netrocdn.site) strictly requires a
    ' vidora.stream Referer; the inherited moviesapi/autoembed referer yields
    ' HTTP 403 on the master.m3u8. Always use our own embed page URL (final)
    ' as the referer for the JWPlayer source fetch AND the referer returned to
    ' the Roku player (segments are validated the same way).
    return RP_ResolveJwplayerPage(page.body, final, final, session)
end function

' --- Phase 3: 2embed.cc ----------------------------------------------
'
' /embed/<tmdb> page contains a streamsrcs.2embed.cc/swish?id=...&ref=...
' iframe. The swish page itself contains an <iframe src="<id>"> where
' a tiny JS rewrites src → "https://lookmovie2.skin/e/<id>". We bypass
' the JS by doing the URL build ourselves and delegate to lookmovie.
' Port of server.py:1090.

function RP_Resolve2embed(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer else headers["Referer"] = "https://hydrahd.ru/"
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl

    swishRe = CreateObject("roRegex", "(?:data-src|src)=[" + chr(34) + "'](https?://streamsrcs\.2embed\.cc/swish\?[^" + chr(34) + "']+)[" + chr(34) + "']", "i")
    sm = swishRe.match(page.body)
    swishUrl = ""
    if sm <> invalid and sm.Count() >= 2 then
        swishUrl = sm[1]
    else
        fallbackRe = CreateObject("roRegex", "(https?://streamsrcs\.2embed\.cc/swish\?[^\s" + chr(34) + "'<>]+)", "i")
        fm = fallbackRe.match(page.body)
        if fm <> invalid and fm.Count() >= 2 then swishUrl = fm[1]
    end if
    if swishUrl = "" then return invalid
    swishUrl = U_HtmlDecode(swishUrl)

    swish = HC_Get(session, swishUrl, { "Referer": final }, 8000)
    if swish = invalid or swish.body = "" then return invalid
    swishFinal = swish.finalUrl
    if swishFinal = invalid or swishFinal = "" then swishFinal = swishUrl

    iframeRe = CreateObject("roRegex", "<iframe[^>]+src=[" + chr(34) + "']([^" + chr(34) + "']+)[" + chr(34) + "']", "i")
    fim = iframeRe.match(swish.body)
    if fim = invalid or fim.Count() < 2 then return invalid
    inner = fim[1]
    target = ""
    if Left(inner, 4) = "http" then
        target = inner
    else
        target = "https://lookmovie2.skin/e/" + inner
    end if
    return RP_ResolveLookmovie(target, swishFinal, session)
end function

' --- Phase 3: cloudnestra rcpvip → prorcp → tmstr1.<host> chain -----
'
' Step 1: rcpvip page links to /prorcp/<hash>. Step 2: prorcp page has
' a Playerjs `file: "url1 or url2 or url3"` string with `{v1}/{v2}`
' placeholders, plus a list of "https://tmstr1.<HOST>" mirror hosts.
' We expand placeholders against each host and return the first
' candidate whose response starts with #EXTM3U. Port of server.py:986.

function RP_ResolveCloudnestra(embedUrl as String, refer as String, session as Object) as Object
    refUrl = refer
    if refUrl = "" then refUrl = embedUrl
    page1 = HC_Get(session, embedUrl, { "Referer": refUrl }, 8000)
    if page1 = invalid or page1.body = "" then return invalid
    final = page1.finalUrl
    if final = invalid or final = "" then final = embedUrl

    re1 = CreateObject("roRegex", "src:\s*[" + chr(34) + "'](/prorcp/[^" + chr(34) + "']+)[" + chr(34) + "']", "i")
    m = re1.match(page1.body)
    if m = invalid or m.Count() < 2 then
        re2 = CreateObject("roRegex", "[" + chr(34) + "']/(prorcp/[^" + chr(34) + "']+)[" + chr(34) + "']", "i")
        m = re2.match(page1.body)
        if m = invalid or m.Count() < 2 then return RP_ResolveGeneric(embedUrl, refer, session)
    end if
    rawPath = m[1]
    if Left(rawPath, 1) <> "/" then rawPath = "/" + rawPath
    prorcpUrl = RP_AbsUrl(rawPath, final)

    page2 = HC_Get(session, prorcpUrl, { "Referer": final }, 8000)
    if page2 = invalid or page2.body = "" then return invalid
    final2 = page2.finalUrl
    if final2 = invalid or final2 = "" then final2 = prorcpUrl

    fileRe = CreateObject("roRegex", "file:\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    fm = fileRe.match(page2.body)
    if fm = invalid or fm.Count() < 2 then return invalid
    fileField = fm[1]

    hostRe = CreateObject("roRegex", chr(34) + "https://(tmstr1\.[a-z0-9.-]+\.[a-z]+)" + chr(34), "ig")
    hostMatches = hostRe.matchAll(page2.body)
    hosts = []
    seenHost = {}
    if hostMatches <> invalid then
        for each hm in hostMatches
            if hm.Count() < 2 then continue for
            h = hm[1]
            if seenHost.DoesExist(h) then continue for
            seenHost[h] = true
            hosts.Push(h)
        end for
    end if
    if hosts.Count() = 0 then hosts.Push("tmstr1.cloudorchestranova.com")

    rawUrls = []
    splitRe = CreateObject("roRegex", "\s+or\s+", "i")
    parts = splitRe.split(fileField)
    if parts <> invalid then
        for each part in parts
            t = U_Trim(part)
            if t <> "" then rawUrls.Push(t)
        end for
    end if

    candidates = []
    placeholderRe = CreateObject("roRegex", "\{v\d+\}", "g")
    for each raw in rawUrls
        if Instr(1, raw, "{v") > 0 then
            for each h in hosts
                ' h is e.g. "tmstr1.cloudnestra.com" - take everything after
                ' the first dot so we substitute "cloudnestra.com" / etc.
                dotIdx = Instr(1, h, ".")
                if dotIdx > 0 and dotIdx < Len(h) then
                    suffix = Mid(h, dotIdx + 1)
                else
                    suffix = h
                end if
                candidates.Push(placeholderRe.replaceAll(raw, suffix))
            end for
        else
            candidates.Push(raw)
        end if
    end for

    seen = {}
    for each u in candidates
        if u = "" or seen.DoesExist(u) then continue for
        seen[u] = true
        res = HC_Get(session, u, { "Referer": final2 }, 6000)
        if res = invalid or res.body = "" then continue for
        if Left(res.body, 7) <> "#EXTM3U" then continue for
        return {
            url: u
            streamFormat: "hls"
            qualities: []
            subtitles: RP_ExtractSubs(page2.body)
            chapters: []
            referer: final2
            userAgent: ""
        }
    end for

    return invalid
end function

' --- Phase 3: vidsrc.xyz iframe family -------------------------------
'
' vidsrc.xyz / vidsrc.in / .pm / .io / .net / vsembed.ru all wrap a
' cloudnestra iframe. Find the player_iframe src or a generic
' //cloudnestra src and delegate to RP_ResolveCloudnestra.
' Port of server.py:1045.

function RP_ResolveVidsrcXyz(embedUrl as String, refer as String, session as Object) as Object
    refUrl = refer
    if refUrl = "" then refUrl = "https://vidsrc.xyz/"
    page = HC_Get(session, embedUrl, { "Referer": refUrl }, 8000)
    if page = invalid or page.body = "" then return invalid
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl

    re1 = CreateObject("roRegex", "<iframe[^>]+id=[" + chr(34) + "']player_iframe[" + chr(34) + "'][^>]+src=[" + chr(34) + "']([^" + chr(34) + "']+)[" + chr(34) + "']", "i")
    m = re1.match(page.body)
    if m = invalid or m.Count() < 2 then
        re2 = CreateObject("roRegex", "src=[" + chr(34) + "'](//[^" + chr(34) + "']*cloudnestra[^" + chr(34) + "']+)[" + chr(34) + "']", "i")
        m = re2.match(page.body)
    end if
    if m = invalid or m.Count() < 2 then return invalid
    rcp = RP_AbsUrl(m[1], final)
    return RP_ResolveCloudnestra(rcp, final, session)
end function

' --- Phase 3: moviesapi.club / .to -----------------------------------
'
' Page just iframes ww2.moviesapi.to which iframes vidora.stream / ww1.
' Walk the iframe chain; fall back to a JWPlayer scrape if a chain
' matched but produced no playable URL. Port of server.py:1603.

function RP_ResolveMoviesapi(embedUrl as String, refer as String, session as Object) as Object
    refUrl = refer
    if refUrl = "" then refUrl = "https://hydrahd.ru/"
    page = HC_Get(session, embedUrl, { "Referer": refUrl }, 8000)
    if page = invalid or page.body = "" then return invalid
    final = page.finalUrl
    if final = invalid or final = "" then final = embedUrl
    chain = R_FollowKnownIframes(page.body, final, refUrl, 0, session)
    if chain <> invalid and chain.url <> invalid and chain.url <> "" then return chain
    return RP_ResolveJwplayerPage(page.body, final, refUrl, session)
end function

' --- Phase 3: autoembed (.co) ----------------------------------------
'
' player.autoembed.cc is DEAD (NXDOMAIN). autoembed migrated to the .co TLD
' and its player iframes nextgencloudfabric.com, which serves the stream from
' streamdata.vaplayer.ru/api.php - the SAME backend as airflix1. The embed
' page no longer carries inline stream URLs, so we hit that JSON API directly
' (Referer https://nextgencloudfabric.com/, required by both the API and its
' playlist CDNs) instead of walking iframes. Mirrors RP_ResolveAirflix.

function RP_ResolveAutoembed(embedUrl as String, refer as String, session as Object) as Object
    apiReferer = "https://nextgencloudfabric.com/"

    pathRe = CreateObject("roRegex", "/embed/(movie|tv)/(tt\d+|\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    mediaType = m[1]
    mediaId = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if

    idParam = "tmdb"
    if Left(mediaId, 2) = "tt" then idParam = "imdb"
    apiUrl = "https://streamdata.vaplayer.ru/api.php?" + idParam + "=" + U_UrlEncode(mediaId) + "&type=" + mediaType
    if mediaType = "tv" and season <> "" and episode <> "" then
        apiUrl = apiUrl + "&season=" + season + "&episode=" + episode
    end if

    res = HC_Get(session, apiUrl, {
        "Referer": apiReferer
        "Origin": "https://nextgencloudfabric.com"
    }, 8000)
    if res = invalid or res.body = "" then return invalid

    envelope = ParseJSON(res.body)
    if envelope = invalid or type(envelope) <> "roAssociativeArray" then return invalid
    sc = ""
    if envelope.status_code <> invalid then sc = envelope.status_code.ToStr()
    if sc <> "200" then return invalid
    data = envelope.data
    if data = invalid or type(data) <> "roAssociativeArray" then return invalid
    streams = data.stream_urls
    if streams = invalid or type(streams) <> "roArray" or streams.Count() = 0 then return invalid

    for each streamUrl in streams
        if type(streamUrl) <> "String" and type(streamUrl) <> "roString" then continue for
        if streamUrl = "" then continue for
        playlist = HC_Get(session, streamUrl, { "Referer": apiReferer }, 6000)
        if playlist = invalid or playlist.body = "" then continue for
        if Left(playlist.body, 7) <> "#EXTM3U" then continue for
        return {
            url: streamUrl
            streamFormat: "hls"
            qualities: []
            subtitles: []
            chapters: []
            referer: apiReferer
            userAgent: ""
        }
    end for

    return invalid
end function

function RP_ResolveYthd(embedUrl as String, refer as String, session as Object) as Object
    ' Fetch the embed page and extract data-hash="..." values - the
    ' included sources.js iframes to https://cloudnestra.com/rcp/<hash>.
    headers = {}
    if refer <> "" then headers["Referer"] = refer
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    ' The cloudnestra RCP host migrated to cloudorchestranova.com (cloudnestra.com
    ' has no A record now). Read the live host+hash from the embed page's
    ' player_iframe so we never hit the dead host (and survive future renames).
    ifrRe = CreateObject("roRegex", "player_iframe" + chr(34) + "\s+src=" + chr(34) + "//([^/" + chr(34) + "]+)/rcp/([^" + chr(34) + "]+)" + chr(34), "i")
    im = ifrRe.match(page.body)
    if im <> invalid and im.Count() >= 3 then
        rcpUrl = "https://" + im[1] + "/rcp/" + im[2]
        return RP_ResolveCloudnestra(rcpUrl, embedUrl, session)
    end if
    re = CreateObject("roRegex", "data-hash=" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    m = re.match(page.body)
    if m = invalid or m.Count() < 2 then return invalid
    hash = m[1]
    rcpUrl = "https://cloudorchestranova.com/rcp/" + hash
    return RP_ResolveCloudnestra(rcpUrl, embedUrl, session)
end function

' --- Phase 4b: Videasy / Vidking shared port ------------------------
'
' Both providers share the same WASM (byte-identical SHA256) and the
' same algorithm. The integer seed differs - vidking uses Date.now() ms,
' videasy uses tmdbId - and the outer AES password is always empty
' because the JS Hashids().encode step rejects hex strings (the empty
' string is what CryptoJS.AES sees). The "WASM" is RC4 keyed by a
' hardcoded "Hello Reverse Engineers!" string plus a glibc LCG keystream
' over the seed; the wasm output is the standard CryptoJS Salted__
' envelope with AES-128-CBC underneath.
'
' Pipeline summary (RP_VideasyDecrypt):
'   1. LCG keystream of 50 bytes from seed (state = state*1103515245+12345
'      mod 2^31; byte = state mod 255 - note: 255, not 256).
'   2. Serialize as comma-separated decimal string.
'   3. RC4 init with hardcoded UTF-8 key "Hello Reverse Engineers! 👋 - Ciarán".
'   4. RC4-encrypt the LCG string -> inner_key bytes.
'   5. RC4 re-init with inner_key.
'   6. RC4-decrypt the hex-decoded ciphertext -> wasm output (Salted__).
'   7. Parse Salted__: 8-byte magic + 8-byte salt + AES-128-CBC blob.
'   8. EvpBytesToKey(MD5, "", salt, 32) -> 16-byte key + 16-byte IV.
'   9. AES-128-CBC decrypt the blob -> JSON.

function RP_ResolveVidking(embedUrl as String, refer as String, session as Object) as Object
    pathRe = CreateObject("roRegex", "/embed/(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    kind = m[1]
    tmdb = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if
    ' Vidking seeds the keystream with the TMDB id (live bundle: Ct(body,
    ' tmdbId)), not the ms timestamp - the timestamp was only the old &_t=
    ' nonce. Makes vidking identical to RP_ResolveVideasy.
    seed# = B_StrToLong(tmdb)
    return RP_VideasyFamilyResolve(kind, tmdb, season, episode, seed#, tmdb, session)
end function

function RP_ResolveVideasy(embedUrl as String, refer as String, session as Object) as Object
    pathRe = CreateObject("roRegex", "/(movie|tv)/(\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    kind = m[1]
    tmdb = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if
    seed# = B_StrToLong(tmdb)
    return RP_VideasyFamilyResolve(kind, tmdb, season, episode, seed#, tmdb, session)
end function

' Shared resolver for the api.videasy.net family. Tries each known
' provider path until one returns a usable response. seedStr is the
' decimal form of the LCG seed - vidking uses ms timestamp, videasy
' uses tmdbId - and is also the value of the &_t= query param.
function RP_VideasyFamilyResolve(kind as String, tmdb as String, season as String, episode as String, seed as LongInteger, seedStr as String, session as Object) as Object
    metaUrl = "https://db.videasy.to/3/" + kind + "/" + tmdb + "?append_to_response=external_ids"
    metaRes = HC_Get(session, metaUrl, {}, 6000)
    title = ""
    year = ""
    imdb = ""
    if metaRes <> invalid and metaRes.body <> "" then
        meta = ParseJSON(metaRes.body)
        if type(meta) = "roAssociativeArray" then
            if kind = "movie" and meta.title <> invalid then title = meta.title
            if kind = "tv" and meta.name <> invalid then title = meta.name
            if kind = "movie" and meta.release_date <> invalid then year = Left(meta.release_date, 4)
            if kind = "tv" and meta.first_air_date <> invalid then year = Left(meta.first_air_date, 4)
            if meta.external_ids <> invalid and type(meta.external_ids) = "roAssociativeArray" then
                if meta.external_ids.imdb_id <> invalid then imdb = meta.external_ids.imdb_id
            end if
        end if
    end if

    providers = ["mb-flix", "cdn", "downloader2"]   ' 1movies removed (api.videasy.to 404s it)
    apiHeaders = {
        "Referer": "https://player.videasy.to/"
        "Origin": "https://player.videasy.to"
        "Accept": "*/*"
    }

    for each prov in providers
        url = "https://api.videasy.to/" + prov + "/sources-with-title?title=" + U_UrlEncode(title) + "&mediaType=" + kind + "&year=" + U_UrlEncode(year)
        if kind = "tv" then
            ep = "1"
            sn = "1"
            if episode <> "" then ep = episode
            if season <> "" then sn = season
            url = url + "&episodeId=" + ep + "&seasonId=" + sn
        end if
        url = url + "&tmdbId=" + tmdb + "&imdbId=" + U_UrlEncode(imdb)

        res = HC_Get(session, url, apiHeaders, 8000)
        if res = invalid or res.body = "" then continue for

        ' NOTE (2026-06): api.videasy.to now returns ciphertext whose AES key
        ' is derived by a browser-only WASM proof-of-work (player.videasy.to/
        ' module.wasm). The LCG/RC4/AES-128 pipeline below no longer matches it,
        ' so this decrypt currently fails and the provider is skipped cleanly,
        ' falling through to a working mirror. Host/seed kept correct so it
        ' resolves again if they drop the WASM gate or a decrypt proxy is added.
        plaintext = RP_VideasyDecrypt(U_Trim(res.body), seed)
        if plaintext = "" then continue for

        payload = ParseJSON(plaintext)
        if payload = invalid or type(payload) <> "roAssociativeArray" then continue for
        sources = payload.sources
        if sources = invalid or type(sources) <> "roArray" or sources.Count() = 0 then continue for

        streamUrl = ""
        for each src in sources
            if type(src) <> "roAssociativeArray" then continue for
            if src.url <> invalid and src.url <> "" then
                streamUrl = src.url
                exit for
            end if
            if src.file <> invalid and src.file <> "" then
                streamUrl = src.file
                exit for
            end if
        end for
        if streamUrl = "" then continue for

        subs = []
        if payload.subtitles <> invalid and type(payload.subtitles) = "roArray" then
            for each s in payload.subtitles
                if type(s) <> "roAssociativeArray" then continue for
                surl = ""
                if s.url <> invalid then surl = s.url
                if surl = "" and s.file <> invalid then surl = s.file
                if surl = "" then continue for
                lang = "en"
                if s.language <> invalid then lang = LCase(Left(s.language, 2))
                if lang = "" and s.lang <> invalid then lang = LCase(Left(s.lang, 2))
                name = ""
                if s.label <> invalid then name = s.label
                if name = "" then name = UCase(lang)
                subs.Push({ url: surl, language: lang, name: name })
            end for
        end if

        return {
            url: streamUrl
            streamFormat: U_StreamFormat(streamUrl)
            qualities: []
            subtitles: subs
            chapters: []
            referer: "https://player.videasy.net/"
            userAgent: ""
        }
    end for

    return invalid
end function

' Decrypt one ASCII-hex ciphertext using the videasy/vidking pipeline.
' Returns "" on any decode failure.
function RP_VideasyDecrypt(hexCt as String, seed as LongInteger) as String
    if hexCt = invalid or hexCt = "" then return ""

    ct = CreateObject("roByteArray")
    ct.FromHexString(hexCt)
    if ct.Count() = 0 then return ""

    lcg = RP_VkLcgBytes(seed, 50)
    lcgStr = RP_VkSerializeBytes(lcg)
    lcgBytes = CreateObject("roByteArray")
    lcgBytes.FromAsciiString(lcgStr)

    ' UTF-8 of "Hello Reverse Engineers! 👋 - Ciarán" (39 bytes).
    ' Hardcoded as hex so FromAsciiString's ASCII-only restriction
    ' doesn't truncate the emoji or the á.
    keyHex = "48656c6c6f205265766572736520456e67696e656572732120f09f918b202d2043696172c3a16e"
    keyBytes = CreateObject("roByteArray")
    keyBytes.FromHexString(keyHex)

    S1 = R4_KSA(keyBytes)
    innerKey = R4_PRGA(S1, lcgBytes)

    S2 = R4_KSA(innerKey)
    wasmOut = R4_PRGA(S2, ct)

    ' wasmOut is the CryptoJS "Salted__" envelope.
    if wasmOut.Count() < 32 then return ""
    if wasmOut[0] <> 83 or wasmOut[1] <> 97 or wasmOut[2] <> 108 or wasmOut[3] <> 116 then return ""
    if wasmOut[4] <> 101 or wasmOut[5] <> 100 or wasmOut[6] <> 95 or wasmOut[7] <> 95 then return ""

    salt = B_Slice(wasmOut, 8, 16)
    aesCt = B_Slice(wasmOut, 16, wasmOut.Count())

    pwBytes = CreateObject("roByteArray")
    keyAndIv = EvpBytesToKey(pwBytes, salt, 32)
    if keyAndIv.Count() < 32 then return ""

    keyBa = B_Slice(keyAndIv, 0, 16)
    ivBa = B_Slice(keyAndIv, 16, 32)
    aesKeyHex = keyBa.ToHexString()
    aesIvHex = ivBa.ToHexString()

    cipher = CreateObject("roEVPCipher")
    rc = cipher.Setup(false, "aes-128-cbc", aesKeyHex, aesIvHex, 1)
    if rc <> 0 then return ""

    out = CreateObject("roByteArray")
    pt = cipher.Process(aesCt)
    if pt <> invalid then
        for i = 0 to pt.Count() - 1
            out.Push(pt[i])
        end for
    end if
    fin = cipher.Final()
    if fin <> invalid then
        for i = 0 to fin.Count() - 1
            out.Push(fin[i])
        end for
    end if
    if out.Count() = 0 then return ""
    return out.ToAsciiString()
end function

' glibc-style LCG keystream. State is masked to 31 bits each iteration
' (per glibc rand()). Output bytes are state mod 255 (NOT 256) - that's
' the videasy/vidking convention captured during RE.
function RP_VkLcgBytes(seed as LongInteger, count as Integer) as Object
    out = CreateObject("roByteArray")
    state# = seed AND 2147483647&
    for i = 1 to count
        state# = (state# * 1103515245& + 12345&) AND 2147483647&
        b# = state# mod 255&
        out.Push(b#)
    end for
    return out
end function

' Serialize a byte array as a comma-separated decimal string ("12,34,56").
' Matches the JS array.toString() output the player feeds to its inner
' RC4 step.
function RP_VkSerializeBytes(bytes as Object) as String
    if bytes = invalid or bytes.Count() = 0 then return ""
    out = ""
    n = bytes.Count()
    for i = 0 to n - 1
        if i > 0 then out = out + ","
        out = out + bytes[i].ToStr()
    end for
    return out
end function

' --- Phase 4b: Peachify (AES-256-GCM with hardcoded key) ------------
'
' Five upstream provider variants split across two hosts. Each returns
'   { isEncrypted: true, data: "<iv>.<ct>.<tag>" }
' where each segment is base64-URL. AES-256-GCM with a hardcoded key.
' Roku has no native GCM-256 so we use the Phase 4b AesGcm256 wrapper
' (CTR + ECB-256, tag verification skipped for performance).

function RP_ResolvePeachify(embedUrl as String, refer as String, session as Object) as Object
    pathRe = CreateObject("roRegex", "/(movie|tv)/(\d+|tt\d+)(?:/(\d+)/(\d+))?", "i")
    m = pathRe.match(embedUrl)
    if m = invalid or m.Count() < 3 then return invalid
    kind = m[1]
    tmdb = m[2]
    season = ""
    episode = ""
    if m.Count() >= 5 then
        season = m[3]
        episode = m[4]
    end if

    ' holly first: its up-1.eat-peach.sbs/m3u8-proxy HLS plays for generic
    ' referers, whereas moviebox's cf-worker mp4-proxy 403s off-site.
    providers = [
        { host: "usa.eat-peach.sbs",  path: "holly" },
        { host: "uwu.eat-peach.sbs",  path: "moviebox" },
        { host: "usa.eat-peach.sbs",  path: "multi" },
        { host: "uwu.eat-peach.sbs",  path: "net" },
        { host: "usa.eat-peach.sbs",  path: "air" }
    ]

    headers = {
        "Referer": "https://peachify.top/"
        "Origin": "https://peachify.top"
        "Accept": "application/json"
    }

    for each prov in providers
        url = "https://" + prov.host + "/" + prov.path + "/" + kind + "/" + tmdb
        if kind = "tv" and season <> "" and episode <> "" then
            url = url + "/" + season + "/" + episode
        end if

        res = HC_Get(session, url, headers, 8000)
        if res = invalid or res.body = "" then continue for

        env = ParseJSON(res.body)
        if env = invalid or type(env) <> "roAssociativeArray" then continue for
        if env.isEncrypted <> true then continue for
        data = env.data
        if data = invalid or type(data) <> "roString" then continue for

        plaintext = RP_PeachifyDecrypt(data)
        if plaintext = "" then continue for

        payload = ParseJSON(plaintext)
        if payload = invalid or type(payload) <> "roAssociativeArray" then continue for
        sources = payload.sources
        if sources = invalid or type(sources) <> "roArray" or sources.Count() = 0 then continue for

        streamUrl = ""
        for each src in sources
            if type(src) <> "roAssociativeArray" then continue for
            if src.url <> invalid and src.url <> "" then
                streamUrl = src.url
                exit for
            end if
            if src.file <> invalid and src.file <> "" then
                streamUrl = src.file
                exit for
            end if
        end for
        if streamUrl = "" then continue for

        subs = []
        if payload.subtitles <> invalid and type(payload.subtitles) = "roArray" then
            for each s in payload.subtitles
                if type(s) <> "roAssociativeArray" then continue for
                surl = ""
                if s.url <> invalid then surl = s.url
                if surl = "" and s.file <> invalid then surl = s.file
                if surl = "" then continue for
                lang = "en"
                if s.language <> invalid then lang = LCase(Left(s.language, 2))
                name = ""
                if s.label <> invalid then name = s.label
                if name = "" then name = UCase(lang)
                subs.Push({ url: surl, language: lang, name: name })
            end for
        end if

        ' Peachify's holly/moviebox sources are extensionless worker proxies
        ' (.../mp4-proxy or .../m3u8-proxy). U_StreamFormat only sniffs file
        ' extensions, so an mp4 proxy would be mislabelled "hls" and fail to
        ' play. Detect by substring instead.
        pfFmt = U_StreamFormat(streamUrl)
        lu = LCase(streamUrl)
        if Instr(1, lu, "m3u8") > 0 then
            pfFmt = "hls"
        else if Instr(1, lu, "mp4") > 0 then
            pfFmt = "mp4"
        end if
        return {
            url: streamUrl
            streamFormat: pfFmt
            qualities: []
            subtitles: subs
            chapters: []
            referer: "https://peachify.top/"
            userAgent: ""
        }
    end for

    return invalid
end function

' Decrypt the "<iv>.<ct>.<tag>" base64-URL triple using the hardcoded
' Peachify key. Returns "" on any decode failure.
function RP_PeachifyDecrypt(payload as String) as String
    if payload = invalid or payload = "" then return ""
    parts = payload.Tokenize(".")
    if parts = invalid or parts.Count() < 3 then return ""

    ivBytes = HC_Base64UrlDecode(parts[0])
    ctBytes = HC_Base64UrlDecode(parts[1])
    tagBytes = HC_Base64UrlDecode(parts[2])
    if ivBytes.Count() <> 12 then return ""
    if tagBytes.Count() <> 16 then return ""

    ' Provider rotated its hardcoded AES-256-GCM key (verified 2026-06: old
    ' d8f2... fails the GCM MAC on all 5 endpoints; this a8f2... decrypts them).
    keyHex = "a8f2a1b5e9c470814f6b2c3a5d8e7f9c1a2b3c4d5e3f7a8b8cad1e2d0a4d5c5b"
    pt = AGD_Decrypt(keyHex, ivBytes, ctBytes, tagBytes)
    if pt = invalid then return ""
    return pt.ToAsciiString()
end function

' --- Primesrc.me (catalog-only port) --------------------------------
'
' /api/v1/s catalog returns server names + opaque keys. /api/v1/l link
' resolution is CF-Turnstile-gated. Workaround: when we encounter a
' primesrc embed, hit the catalog and route the named upstream server
' (Voe / Doodstream / Streamtape / Uqload / Mixdrop) through the
' Phase 4 downstream extractor of the same name. Filemoon falls
' through to invalid since its key rotates too fast to chase.

function RP_ResolvePrimesrc(embedUrl as String, refer as String, session as Object) as Object
    ' DEAD as of 2026-06: link resolution /api/v1/l is now behind a Cloudflare
    ' MANAGED Turnstile challenge (HTTP 403 Cf-Mitigated: challenge) that a Roku
    ' channel cannot solve, and the ungated /api/v1/s catalog returns only opaque
    ' internal keys (never upstream host URLs). The embed page is an SPA shell
    ' with no inline .m3u8/.mp4, so the old RP_ResolveGeneric delegation also
    ' always failed after a wasted round-trip. Fail fast so the dispatcher falls
    ' through cleanly to a working mirror.
    return invalid
end function

' --- Phase 4: Downstream file-host extractors -----------------------
'
' These are reachable from primesrc routing and from frembed links.
' Algorithms ported from Kohi-den's Aniyomi extractor library on the
' main branch (2026-05-09); StreamSB was purged in 2023-08 and uses the
' last-known-good implementation from aniyomi-extensions@5ab164e5.

' --- Streamtape ------------------------------------------------------
'
' Embed page contains a script with:
'   document.getElementById('robotlink').innerHTML = '<prefix>' + ('xcd<token>'.substring(...))
' where the playable URL is `https:` + <prefix> + <token>. We extract via
' two substring anchors. The token always starts after `+ ('xcd`.

function RP_ResolveStreamtape(embedUrl as String, refer as String, session as Object) as Object
    idRe = CreateObject("roRegex", "/[ev]/([a-zA-Z0-9_-]+)", "i")
    im = idRe.match(embedUrl)
    if im = invalid or im.Count() < 2 then return invalid
    canonicalUrl = "https://streamtape.com/e/" + im[1]

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    page = HC_Get(session, canonicalUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid

    anchor1 = "document.getElementById('robotlink').innerHTML = '"
    idx1 = Instr(1, page.body, anchor1)
    if idx1 <= 0 then return invalid
    after1 = Mid(page.body, idx1 + Len(anchor1))

    qIdx = Instr(1, after1, "'")
    if qIdx <= 0 then return invalid
    part1 = Left(after1, qIdx - 1)

    anchor2 = "+ ('xcd"
    idx2 = Instr(1, after1, anchor2)
    if idx2 <= 0 then return invalid
    after2 = Mid(after1, idx2 + Len(anchor2))
    qIdx2 = Instr(1, after2, "'")
    if qIdx2 <= 0 then return invalid
    part2 = Left(after2, qIdx2 - 1)

    videoUrl = "https:" + part1 + part2
    return {
        url: videoUrl
        streamFormat: U_StreamFormat(videoUrl)
        qualities: []
        subtitles: []
        chapters: []
        referer: "https://streamtape.com/"
        userAgent: ""
    }
end function

' --- Uqload ----------------------------------------------------------
'
' Plain JWPlayer-style page: `sources: ["<mp4-url>"]` is the only thing
' we need. The CDN demands Referer https://uqload.ws/ regardless of which
' uqload TLD the embed lives on.

function RP_ResolveUqload(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid

    re = CreateObject("roRegex", "sources\s*:\s*\[" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    m = re.match(page.body)
    if m = invalid or m.Count() < 2 then return invalid
    url = m[1]
    if Left(url, 4) <> "http" then return invalid
    return {
        url: url
        streamFormat: U_StreamFormat(url)
        qualities: []
        subtitles: []
        chapters: []
        referer: "https://uqload.ws/"
        userAgent: ""
    }
end function

' --- Doodstream ------------------------------------------------------
'
' Two-hop: GET embed (follow redirects), regex `/pass_md5/...`, GET that
' second URL, then build the final URL as
'   <body> + <random-10> + ?token=<token>&expiry=<ms-timestamp>
' Random alphabet is A-Z + a-z + 0-9 (62 chars). Expiry is 13-digit ms.
' The post-redirect Referer is mandatory on the pass_md5 request.

function RP_ResolveDoodstream(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    finalUrl = page.finalUrl
    if finalUrl = invalid or finalUrl = "" then finalUrl = embedUrl

    if Instr(1, page.body, "/pass_md5/") <= 0 then return invalid

    pmRe = CreateObject("roRegex", "/pass_md5/[^'" + chr(34) + "]+", "i")
    pm = pmRe.match(page.body)
    if pm = invalid or pm.Count() < 1 then return invalid
    md5Path = pm[0]
    doodHost = HC_OriginOf(finalUrl)
    if doodHost = "" then return invalid
    md5Url = doodHost + md5Path

    ' Token is the part after the last "/" of the md5 path.
    lastSlash = 0
    for i = 1 to Len(md5Path)
        if Mid(md5Path, i, 1) = "/" then lastSlash = i
    end for
    if lastSlash = 0 or lastSlash = Len(md5Path) then return invalid
    token = Mid(md5Path, lastSlash + 1)

    md5Res = HC_Get(session, md5Url, { "Referer": finalUrl }, 8000)
    if md5Res = invalid or md5Res.body = "" then return invalid

    rand10 = RP_RandomB62String(10)
    expiry = RP_NowMillis()

    videoUrl = md5Res.body + rand10 + "?token=" + token + "&expiry=" + expiry

    ' Quality from <title>
    quality = ""
    titleRe = CreateObject("roRegex", "<title>([^<]*)</title>", "i")
    tm = titleRe.match(page.body)
    if tm <> invalid and tm.Count() >= 2 then
        qRe = CreateObject("roRegex", "(\d{3,4}p)", "i")
        qm = qRe.match(tm[1])
        if qm <> invalid and qm.Count() >= 2 then quality = qm[1]
    end if

    return {
        url: videoUrl
        streamFormat: U_StreamFormat(videoUrl)
        qualities: []
        subtitles: []
        chapters: []
        referer: doodHost + "/"
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    }
end function

' Random base-62 string of length n. Alphabet matches Kohi-den exactly:
' A-Z first, then a-z, then 0-9. Used by Doodstream for the trailing
' segment of the signed video URL.
function RP_RandomB62String(n as Integer) as String
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    out = ""
    for i = 1 to n
        idx = Rnd(62)
        out = out + Mid(alphabet, idx, 1)
    end for
    return out
end function

' Current Unix time in milliseconds, returned as a 13-digit decimal
' string. BrightScript Integer is 32-bit so secs * 1000 would overflow
' in mid-2026; concatenate the decimal seconds with zero-padded ms.
function RP_NowMillis() as String
    dt = CreateObject("roDateTime")
    dt.Mark()
    secs = dt.AsSeconds()
    ms = dt.GetMilliseconds()
    msStr = ms.ToStr()
    msStr = Right("000" + msStr, 3)
    return secs.ToStr() + msStr
end function

' --- VOE -------------------------------------------------------------
'
' Encoded blob lives in <script type="application/json"> as a single-
' element JSON-array string. Decryption chain:
'   rot13 -> replace [@$, ^^, ~@, %?, *~, !!, #&] with _ -> strip _
'   -> base64 decode -> -3 byte shift (mod 256) -> reverse
'   -> base64 decode again -> JSON.
' Output JSON has `source` (m3u8) and optional `direct_access_url` (mp4).

function RP_ResolveVoe(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer
    headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid
    html = page.body
    finalUrl = page.finalUrl
    if finalUrl = invalid or finalUrl = "" then finalUrl = embedUrl

    ' Some VOE pages stash an intermediate redirect in the first script.
    redirRe = CreateObject("roRegex", "window\.location\.href\s*=\s*'([^']+)';", "i")
    rm = redirRe.match(html)
    if rm <> invalid and rm.Count() >= 2 then
        target = RP_AbsUrl(rm[1], finalUrl)
        nextPage = HC_Get(session, target, headers, 8000)
        if nextPage <> invalid and nextPage.body <> "" then
            html = nextPage.body
            finalUrl = nextPage.finalUrl
            if finalUrl = invalid or finalUrl = "" then finalUrl = target
        end if
    end if

    blobRe = CreateObject("roRegex", "<script[^>]+type=" + chr(34) + "application/json" + chr(34) + "[^>]*>([\s\S]*?)</script>", "i")
    bm = blobRe.match(html)
    if bm = invalid or bm.Count() < 2 then return invalid
    raw = U_Trim(bm[1])
    ' Wrapper is ["<encoded>"] - strip outer.
    if Left(raw, 2) <> "[" + chr(34) then return invalid
    raw = Mid(raw, 3)
    closeIdx = 0
    for i = Len(raw) to 1 step -1
        if Mid(raw, i, 1) = "]" then
            closeIdx = i
            exit for
        end if
    end for
    if closeIdx <= 1 then return invalid
    raw = Left(raw, closeIdx - 1)
    if Right(raw, 1) = chr(34) then raw = Left(raw, Len(raw) - 1)

    decoded = RP_VoeDecrypt(raw)
    if decoded = "" then return invalid
    payload = ParseJSON(decoded)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid

    streamUrl = ""
    fmt = "hls"
    if payload.source <> invalid and type(payload.source) = "roString" then
        streamUrl = payload.source
        fmt = "hls"
    else if payload.direct_access_url <> invalid and type(payload.direct_access_url) = "roString" then
        streamUrl = payload.direct_access_url
        fmt = "mp4"
    end if
    if streamUrl = "" then return invalid

    return {
        url: streamUrl
        streamFormat: fmt
        qualities: []
        subtitles: []
        chapters: []
        referer: finalUrl
        userAgent: headers["User-Agent"]
    }
end function

' VOE decrypt chain. Input is the raw blob string (post-strip-wrapper).
' Returns "" on any failure.
function RP_VoeDecrypt(blob as String) as String
    if blob = invalid or blob = "" then return ""

    ' Step 1: rot13 (only A-Z and a-z).
    s = RP_VoeRot13(blob)

    ' Step 2: replace 7 literal pairs with _.
    pairsRe = CreateObject("roRegex", "@\$|\^\^|~@|%\?|\*~|!!|#&", "g")
    s = pairsRe.replaceAll(s, "_")

    ' Step 3: strip _.
    underRe = CreateObject("roRegex", "_", "g")
    s = underRe.replaceAll(s, "")

    ' Step 4: base64 decode to bytes.
    ba = CreateObject("roByteArray")
    ba.FromBase64String(s)
    n = ba.Count()
    if n = 0 then return ""

    ' Step 5: -3 byte shift mod 256.
    for i = 0 to n - 1
        v = ba[i] - 3
        if v < 0 then v = v + 256
        ba[i] = v
    end for

    ' Step 6: reverse.
    i = 0
    j = n - 1
    while i < j
        tmp = ba[i]
        ba[i] = ba[j]
        ba[j] = tmp
        i = i + 1
        j = j - 1
    end while

    ' Step 7: bytes are now ASCII base64 chars. Decode them again.
    b64Str = ba.ToAsciiString()
    ba2 = CreateObject("roByteArray")
    ba2.FromBase64String(b64Str)
    if ba2.Count() = 0 then return ""

    ' Step 8: result is JSON UTF-8 text.
    return ba2.ToAsciiString()
end function

' Byte-level rot13 to avoid the O(n^2) immutable-string concat penalty.
' Only A-Z and a-z rotate; everything else passes through untouched.
function RP_VoeRot13(s as String) as String
    if s = "" then return ""
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(s)
    for i = 0 to ba.Count() - 1
        c = ba[i]
        if c >= 65 and c <= 90 then
            ba[i] = ((c - 65 + 13) mod 26) + 65
        else if c >= 97 and c <= 122 then
            ba[i] = ((c - 97 + 13) mod 26) + 97
        end if
    end for
    return ba.ToAsciiString()
end function

' --- StreamSB / watchsb ----------------------------------------------
'
' Largely defunct (Kohi-den purged 2023-08) but the algorithm still works
' on surviving SB-family hosts. Build a path of the form
'   /sources16/<hex>
' where <hex> = uppercase ASCII hex of "bZ6BXaRBvdu2||{id}||GaWEPeOtaVm4||streamsb"
' Response shape: { stream_data: { file: "<master.m3u8>", subs: [...] | null } }.

function RP_ResolveStreamsb(embedUrl as String, refer as String, session as Object) as Object
    idRe = CreateObject("roRegex", "(?:/e/|/embed-)([a-zA-Z0-9_-]+)", "i")
    im = idRe.match(embedUrl)
    if im = invalid or im.Count() < 2 then return invalid
    id = im[1]

    host = HC_HostOf(embedUrl)
    if host = "" then return invalid

    template = "bZ6BXaRBvdu2||" + id + "||GaWEPeOtaVm4||streamsb"
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(template)
    hexStr = UCase(ba.ToHexString())
    apiUrl = "https://" + host + "/sources16/" + hexStr

    res = HC_Get(session, apiUrl, {
        "Referer": embedUrl
        "watchsb": "sbstream"
        "Accept": "application/json"
    }, 8000)
    if res = invalid or res.body = "" then return invalid

    payload = ParseJSON(res.body)
    if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid
    sd = payload.stream_data
    if sd = invalid or type(sd) <> "roAssociativeArray" then return invalid
    streamUrl = ""
    if sd.file <> invalid then streamUrl = U_Trim(sd.file)
    if streamUrl = "" then return invalid

    subs = []
    rawSubs = sd.subs
    if rawSubs <> invalid and type(rawSubs) = "roArray" then
        for each s in rawSubs
            if type(s) <> "roAssociativeArray" then continue for
            surl = s.file
            if surl = invalid or surl = "" then continue for
            label = ""
            if s.label <> invalid then label = s.label
            lang = "en"
            if label <> "" then lang = LCase(Left(label, 2))
            subs.Push({ url: surl, language: lang, name: label })
        end for
    end if

    return {
        url: streamUrl
        streamFormat: "hls"
        qualities: []
        subtitles: subs
        chapters: []
        referer: embedUrl
        userAgent: ""
    }
end function

' --- MixDrop ---------------------------------------------------------
'
' Standard Dean Edwards packed page. The packer's base is 62 (digits +
' lowercase + uppercase, in that order - JU_ToBase handles this since
' the JsUnpack base-62 extension landed in Phase 4). After unpacking,
' the video URL is in `Core.wurl="..."` (or `MDCore.wurl="..."`) and
' the optional subtitle is in `Core.remotesub="..."`. URL is protocol-
' relative (`//host/path`) so we prepend `https:`.

function RP_ResolveMixdrop(embedUrl as String, refer as String, session as Object) as Object
    headers = {}
    if refer <> "" then headers["Referer"] = refer else headers["Referer"] = "https://mixdrop.co/"
    headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
    page = HC_Get(session, embedUrl, headers, 8000)
    if page = invalid or page.body = "" then return invalid

    ' Find the script block containing both `eval` and `MDCore`.
    scriptRe = CreateObject("roRegex", "<script[^>]*>(eval[\s\S]*?MDCore[\s\S]*?)</script>", "i")
    sm = scriptRe.match(page.body)
    if sm = invalid or sm.Count() < 2 then
        ' Try the other ordering in case the page format changes.
        scriptRe2 = CreateObject("roRegex", "<script[^>]*>([\s\S]*?MDCore[\s\S]*?eval[\s\S]*?)</script>", "i")
        sm = scriptRe2.match(page.body)
        if sm = invalid or sm.Count() < 2 then return invalid
    end if
    packed = sm[1]

    unpacked = JU_UnpackPacked(packed)
    if unpacked = "" then return invalid

    urlRe = CreateObject("roRegex", "Core\.wurl\s*=\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    um = urlRe.match(unpacked)
    if um = invalid or um.Count() < 2 then return invalid
    raw = um[1]
    if Left(raw, 2) = "//" then
        videoUrl = "https:" + raw
    else if Left(raw, 4) = "http" then
        videoUrl = raw
    else
        return invalid
    end if

    subs = []
    subRe = CreateObject("roRegex", "Core\.remotesub\s*=\s*" + chr(34) + "([^" + chr(34) + "]+)" + chr(34), "i")
    subm = subRe.match(unpacked)
    if subm <> invalid and subm.Count() >= 2 then
        subUrl = subm[1]
        if Left(subUrl, 2) = "//" then subUrl = "https:" + subUrl
        if Left(subUrl, 4) = "http" then
            subs.Push({ url: subUrl, language: "en", name: "Subtitles" })
        end if
    end if

    return {
        url: videoUrl
        streamFormat: U_StreamFormat(videoUrl)
        qualities: []
        subtitles: subs
        chapters: []
        referer: headers["Referer"]
        userAgent: headers["User-Agent"]
    }
end function

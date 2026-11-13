' ResolverMirrors.brs - resolvers for the mirrors HydraHD lists as of
' 2026-11: 1src.org (HydraVip / Alfa), vixsrc.to, and the encrypted source
' list play.xpass.top moved to. airflix1 / ythd live in ResolverVaplayer.brs
' and vidfast in ResolverVidfast.brs.

' --- Shared: is the first media segment something a Roku can decode? ----
'
' A playlist that answers #EXTM3U is not enough any more: xpass "TIK"
' sources serve PNG-wrapped segments, and several CDNs hand out a healthy
' playlist whose segments are 403. Walks master -> first variant -> first
' segment and looks at the first bytes. Fails closed on a definite bad
' answer, open on anything ambiguous (encrypted segments look random).
function RP_HlsFirstSegmentOk(session as Object, body as String, url as String, referer as String) as Boolean
    mediaBody = body
    mediaUrl = url
    headers = {}
    if referer <> "" then headers["Referer"] = referer
    if Instr(1, body, "#EXT-X-STREAM-INF") > 0 then
        variant = RP_FirstUriLine(body)
        if variant = "" then return false
        mediaUrl = RP_AbsUrl(variant, url)
        res = HC_Get(session, mediaUrl, headers, 5000)
        if res = invalid or Left(res.body, 7) <> "#EXTM3U" then return false
        mediaBody = res.body
    end if
    segment = RP_FirstUriLine(mediaBody)
    if segment = "" then return false
    probe = HC_GetRange(session, RP_AbsUrl(segment, mediaUrl), headers, "bytes=0-15", 5000)
    if probe = invalid then return false
    if probe.status <> 200 and probe.status <> 206 then return false
    head = probe.body
    if head = invalid or head = "" then return true
    if Left(head, 1) = "<" or Left(head, 1) = "{" then return false
    if Mid(head, 2, 3) = "PNG" then return false
    return true
end function

' First line of a playlist that is not blank and not a tag.
function RP_FirstUriLine(body as String) as String
    for each line in body.Split(Chr(10))
        t = U_Trim(line)
        if t <> "" and Left(t, 1) <> "#" then return t
    end for
    return ""
end function

function RP_CountOf(haystack as String, needle as String) as Integer
    count = 0
    at = Instr(1, haystack, needle)
    while at > 0
        count = count + 1
        at = Instr(at + Len(needle), haystack, needle)
    end while
    return count
end function

' --- 1src.org ------------------------------------------------------------
'
' "HydraVip" is https://1src.org/players/{movie|tv}player.php?tmdb=..., a
' player that asks its own page for sources, one provider at a time:
'   <page url>&action=sources&provider=<id>
'     -> { sources: [ { file, label, type, provider } ] }
' The files are ready-to-play HLS behind 1src's proxy and need no Referer.
' "Alfa" (www.1src.org/embed/...) is the same site's server picker for the
' same title, so it is resolved through the same sources.

function RP_ResolveOnesrc(embedUrl as String, refer as String, session as Object) as Object
    pageUrl = embedUrl
    parts = CreateObject("roRegex", "/embed/(movie|tv)/(\d+)(?:/(\d+)/(\d+))?", "i").Match(embedUrl)
    if parts <> invalid and parts.Count() >= 3 then
        if LCase(parts[1]) = "tv" then
            if parts.Count() < 5 or parts[3] = "" then return invalid
            pageUrl = "https://1src.org/players/tvplayer.php?tmdb=" + parts[2] + "&s=" + parts[3] + "&e=" + parts[4]
        else
            pageUrl = "https://1src.org/players/movieplayer.php?tmdb=" + parts[2]
        end if
    end if
    if Instr(1, pageUrl, "/players/") = 0 or Instr(1, pageUrl, "?") = 0 then return invalid

    ' Provider ids and their order come from the page so a rename there
    ' does not strand this resolver.
    providers = []
    page = HC_Get(session, pageUrl, { "Referer": refer }, 8000)
    if page <> invalid and page.body <> "" then
        listed = U_FirstMatch(page.body, "apiProviders\s*:\s*\[([^\]]*)\]")
        for each hit in U_AllMatches(listed, Chr(34) + "([A-Za-z0-9_-]+)" + Chr(34))
            if hit.Count() >= 2 then providers.Push(hit[1])
        end for
    end if
    if providers.Count() = 0 then providers = ["xpass", "febbox", "7reels", "cineruv"]

    best = invalid
    bestVariants = -1
    probes = 0
    for each provider in providers
        api = pageUrl.Replace("?", "?action=sources&provider=" + U_UrlEncode(provider) + "&")
        res = HC_Get(session, api, { "Referer": pageUrl, "Accept": "application/json" }, 12000)
        data = invalid
        if res <> invalid and res.body <> "" then data = ParseJson(res.body)
        sources = invalid
        if data <> invalid and type(data) = "roAssociativeArray" then
            sources = data.sources
            if sources = invalid and data.data <> invalid and type(data.data) = "roAssociativeArray" then sources = data.data.sources
        end if
        if sources <> invalid and type(sources) = "roArray" then
            for each source in sources
                if probes >= 10 then exit for
                file = ""
                if type(source) = "roAssociativeArray" then
                    if source.file <> invalid then file = source.file
                    if file = "" and source.url <> invalid then file = source.url
                end if
                if file <> "" then
                    probes = probes + 1
                    file = RP_AbsUrl(file, pageUrl)
                    playlist = HC_Get(session, file, { "Referer": "https://1src.org/" }, 6000)
                    if playlist <> invalid and Left(playlist.body, 7) = "#EXTM3U" then
                        variants = RP_CountOf(playlist.body, "#EXT-X-STREAM-INF")
                        if variants > bestVariants and RP_HlsFirstSegmentOk(session, playlist.body, file, "https://1src.org/") then
                            bestVariants = variants
                            best = {
                                url: file
                                streamFormat: "hls"
                                qualities: []
                                subtitles: []
                                chapters: []
                                referer: "https://1src.org/"
                                userAgent: ""
                            }
                            ' A real master with a quality ladder: good enough.
                            if variants >= 2 then return best
                        end if
                    end if
                end if
            end for
        end if
        if probes >= 10 then exit for
    end for
    return best
end function

' --- vixsrc.to -------------------------------------------------------------
'
'   GET /api/{movie/<tmdb> | tv/<tmdb>/<s>/<e>}  -> { src: "/embed/<id>?token=..." }
'   GET <src>                                    -> window.masterPlaylist =
'        { params: { token, expires }, url: "https://vixsrc.to/playlist/<id>" }
'   <url>.m3u8?token=&expires=&h=1&lang=en       -> master (480/720/1080)
' h=1 unlocks the 1080p rung (403 without it); lang=en makes English the
' default audio rendition. Audio is delivered as separate renditions.

function RP_ResolveVixsrc(embedUrl as String, refer as String, session as Object) as Object
    parts = CreateObject("roRegex", "vixsrc\.[a-z]+/(movie|tv)/(\d+)(?:/(\d+)/(\d+))?", "i").Match(embedUrl)
    if parts = invalid or parts.Count() < 3 then return invalid
    origin = HC_OriginOf(embedUrl)
    path = "/api/movie/" + parts[2]
    if LCase(parts[1]) = "tv" then
        if parts.Count() < 5 or parts[3] = "" then return invalid
        path = "/api/tv/" + parts[2] + "/" + parts[3] + "/" + parts[4]
    end if
    api = HC_Get(session, origin + path, { "Referer": origin + "/" }, 8000)
    if api = invalid or api.body = "" then return invalid
    link = ParseJson(api.body)
    if link = invalid or type(link) <> "roAssociativeArray" or link.src = invalid or link.src = "" then return invalid

    embed = HC_Get(session, RP_AbsUrl(link.src, origin + "/"), { "Referer": origin + "/" }, 8000)
    if embed = invalid or embed.body = "" then return invalid
    token = U_FirstMatch(embed.body, "'token'\s*:\s*'([^']+)'")
    expires = U_FirstMatch(embed.body, "'expires'\s*:\s*'([^']+)'")
    playlist = U_FirstMatch(embed.body, "masterPlaylist[^;]*?url\s*:\s*'([^']+)'")
    if token = "" or expires = "" or playlist = "" then
        print "[vixsrc] embed page has no masterPlaylist token"
        return invalid
    end if
    sep = "?"
    if Instr(1, playlist, "?") > 0 then sep = "&"
    ' The ".m3u8" suffix is accepted by the server and lets every
    ' extension-based HLS check in the channel recognise the URL.
    if Instr(1, playlist, "?") = 0 then playlist = playlist + ".m3u8"
    url = playlist + sep + "token=" + token + "&expires=" + expires + "&h=1&lang=en"
    master = HC_Get(session, url, { "Referer": origin + "/" }, 8000)
    if master = invalid or Left(master.body, 7) <> "#EXTM3U" then return invalid
    return {
        url: url
        streamFormat: "hls"
        qualities: []
        subtitles: []
        chapters: []
        referer: origin + "/"
        userAgent: ""
    }
end function

' --- play.xpass.top: encrypted source list ----------------------------------
'
' The page used to inline `var backups = [...]`. It now ships an empty
' array plus
'   var dataUrl = "/data/movie/<id>?...&token=<a>.<64 hex>"
' whose response is base64url( iv[12] || AES-256-GCM ciphertext || tag[16] )
' of the same [{ id, name, url, dl }] list. The key is
'   SHA-256( "spv3-data-response|" + <build id> + "|" + <path> + "|" + <token> )
' and the build id is a string constant in the site's obfuscated player
' script, which is itself named by a string in the loader script.

' obfuscator.io string tables are base64 with upper and lower case swapped.
function XP_ObfDecode(encoded as String) as String
    swapped = CreateObject("roByteArray")
    swapped.FromAsciiString(encoded)
    for i = 0 to swapped.Count() - 1
        c = swapped[i]
        if c >= 65 and c <= 90 then
            swapped[i] = c + 32
        else if c >= 97 and c <= 122 then
            swapped[i] = c - 32
        end if
    end for
    text = swapped.ToAsciiString()
    pad = Len(text) mod 4
    if pad = 1 then return ""
    if pad = 2 then text = text + "=="
    if pad = 3 then text = text + "="
    out = CreateObject("roByteArray")
    out.FromBase64String(text)
    return out.ToAsciiString()
end function

function XP_Sha256Hex(text as String) as String
    digest = CreateObject("roEVPDigest")
    digest.Setup("sha256")
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    digest.Update(bytes)
    return LCase(digest.Final())
end function

' Decrypt a /data response. Returns the plaintext JSON, or "".
function XP_Decrypt(build as String, path as String, token as String, body as String) as String
    raw = HC_Base64UrlDecode(U_Trim(body))
    if raw.Count() < 29 then return ""
    iv = CreateObject("roByteArray")
    ct = CreateObject("roByteArray")
    tag = CreateObject("roByteArray")
    last = raw.Count() - 1
    for i = 0 to last
        if i < 12 then
            iv.Push(raw[i])
        else if i > last - 16 then
            tag.Push(raw[i])
        else
            ct.Push(raw[i])
        end if
    end for
    plain = AGD_Decrypt(XP_Sha256Hex("spv3-data-response|" + build + "|" + path + "|" + token), iv, ct, tag)
    if plain = invalid then return ""
    text = plain.ToAsciiString()
    ' AGD_Decrypt does not verify the tag; a wrong key shows up as non-JSON.
    if Left(text, 1) <> "[" then return ""
    return text
end function

' Marker = swapped-case base64 of a known plaintext prefix. Returns the
' decoded table entry that starts with it, or "".
function XP_FindObfString(script as String, marker as String) as String
    hit = CreateObject("roRegex", marker + "[A-Za-z0-9+/]*", "").Match(script)
    if hit = invalid or hit.Count() < 1 then return ""
    return XP_ObfDecode(hit[0])
end function

function XP_BuildId(html as String, pageUrl as String, session as Object) as String
    headers = { "Referer": pageUrl }
    for each hit in U_AllMatches(html, "<script[^>]+src=" + Chr(34) + "(/static/[^" + Chr(34) + "]+)" + Chr(34))
        loader = HC_Get(session, RP_AbsUrl(hit[1], pageUrl), headers, 6000)
        if loader <> invalid and loader.body <> "" then
            ' "/static/<name>.js?t=..." -> l3n0yxrPyY...
            player = XP_FindObfString(loader.body, "l3n0yxrPyY")
            if Left(player, 8) = "/static/" then
                script = HC_Get(session, RP_AbsUrl(player, pageUrl), headers, 8000)
                if script <> invalid and script.body <> "" then
                    ' "spv3-build-..." -> C3b2mY1IDwLS...
                    build = XP_FindObfString(script.body, "C3b2mY1IDwLS")
                    if Left(build, 11) = "spv3-build-" then return build
                end if
            end if
        end if
    end for
    print "[xpass] build id not found in player script - using last known"
    return "spv3-build-1787821613-50e5fc97c9dce367"
end function

' Returns the decrypted [{ id, name, url, dl }] list, or [].
function RP_XpassEncryptedSources(html as String, pageUrl as String, session as Object) as Object
    dataUrl = U_FirstMatch(html, "var\s+dataUrl\s*=\s*" + Chr(34) + "([^" + Chr(34) + "]+)" + Chr(34))
    if dataUrl = "" then return []
    token = U_FirstMatch(dataUrl, "[?&]token=([^&]+)")
    path = dataUrl
    at = Instr(1, path, "?")
    if at > 0 then path = Left(path, at - 1)
    if token = "" or Left(path, 6) <> "/data/" then return []
    res = HC_Get(session, RP_AbsUrl(dataUrl, pageUrl), { "Referer": pageUrl }, 8000)
    if res = invalid or res.body = "" then return []
    text = XP_Decrypt(XP_BuildId(html, pageUrl, session), path, token, res.body)
    if text = "" then
        print "[xpass] source list did not decrypt"
        return []
    end if
    list = ParseJson(text)
    if list = invalid or type(list) <> "roArray" then return []
    return list
end function

' --- 2embed.cc (vidsrc.buzz / videm.buzz player) ----------------------
'
' 2embed's page lazy-loads vidsrc.buzz/embed/<type>/<id> (data-src). That
' player (videm.buzz runs the same one) server-renders its config as
' `var Q = {...}`: a signed token `t` and a first list of servers. More
' servers come from <base>api.php?a=sources&...&pf=1, and
' api.php?a=play&ref=<server ref>&t=<t> mints a stream URL per server.
' Most servers serve segments wrapped in a PNG image (the site's own
' player strips the PNG header in JavaScript); Roku cannot, so each
' server's first segment is checked and only plain MPEG-TS / fMP4 is used.
function RP_ResolveVsrcPlayer(playerUrl as String, refer as String, session as Object) as Object
    origin = HC_OriginOf(playerUrl)
    if origin = "" then return invalid
    page = HC_Get(session, playerUrl, { "Referer": refer }, 8000)
    if page = invalid or page.body = "" then return invalid
    cfg = ParseJson(U_FirstMatch(page.body, "var Q = (\{[^\n]*\});"))
    if cfg = invalid or type(cfg) <> "roAssociativeArray" or cfg.t = invalid or cfg.id = invalid then
        print "[vsrc] player config not found"
        return invalid
    end if
    base = U_FirstMatch(page.body, "<base href=" + chr(34) + "([^" + chr(34) + "]*)" + chr(34))
    if base = "" then base = "/"
    api = RP_AbsUrl(base + "api.php", origin + "/")
    pageRef = origin + "/"
    headers = { "Referer": playerUrl }

    servers = []
    seen = {}
    if cfg.ssr <> invalid and type(cfg.ssr) = "roAssociativeArray" and cfg.ssr.servers <> invalid then
        for each s in cfg.ssr.servers
            if s.ref <> invalid and s.k <> invalid and not seen.DoesExist(s.k) then
                seen[s.k] = true
                servers.Push(s)
            end if
        end for
    end if
    qs = "type=" + cfg.type + "&id=" + U_UrlEncode(cfg.id) + "&s=" + cfg.s.ToStr() + "&e=" + cfg.e.ToStr() + "&t=" + U_UrlEncode(cfg.t)
    more = HC_Get(session, api + "?a=sources&" + qs + "&pf=1", headers, 8000)
    if more <> invalid and more.body <> "" then
        listing = ParseJson(more.body)
        if listing <> invalid and type(listing) = "roAssociativeArray" and listing.servers <> invalid then
            for each s in listing.servers
                if s.ref <> invalid and s.k <> invalid and not seen.DoesExist(s.k) then
                    seen[s.k] = true
                    servers.Push(s)
                end if
            end for
        end if
    end if

    tried = 0
    for each s in servers
        tried = tried + 1
        if tried > 6 then exit for
        play = HC_Get(session, api + "?a=play&ref=" + U_UrlEncode(s.ref) + "&t=" + U_UrlEncode(cfg.t), headers, 6000)
        if play <> invalid and play.body <> "" then
            info = ParseJson(play.body)
            if info <> invalid and type(info) = "roAssociativeArray" and info.url <> invalid and info.url <> "" then
                url = RP_AbsUrl(info.url, api)
                master = HC_Get(session, url, { "Referer": pageRef }, 6000)
                if master <> invalid and Left(master.body, 7) = "#EXTM3U" then
                    if RP_HlsFirstSegmentOk(session, master.body, url, pageRef) then
                        print "[vsrc] using "; s.name
                        return {
                            url: url
                            streamFormat: "hls"
                            qualities: []
                            subtitles: []
                            chapters: []
                            referer: pageRef
                            userAgent: ""
                        }
                    end if
                    print "[vsrc] "; s.name; " segments not playable (PNG-wrapped or dead)"
                end if
            end if
        end if
    end for
    return invalid
end function

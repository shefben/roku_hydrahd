' ResolverVidy.brs - vidy.st (picker name usually "Golf").
'
' vidy.st is a Next.js front end. Its player asks api.wecollege.net for
' sources per named server ("miami", "boise", ...):
'
'   1. GET db.wecollege.net/3/<movie|tv>/<tmdb>   (TMDB proxy: title, year,
'      imdb id, season count - sent along as hints)
'   2. GET api.wecollege.net/seed?mediaId=<tmdb>  -> { seed, ttlMs }
'   3. GET api.wecollege.net/<server>/sources?title=..&mediaType=..&year=..
'      &totalSeasons=..&episodeId=..&seasonId=..&tmdbId=..&imdbId=..&enc=2
'      &seed=<seed>                               -> base64url text
'   4. Decrypt: XOR with a keystream from a small custom generator keyed by
'      (seed, tmdb id). Plaintext starts with "mvm1", then JSON
'      { sources: [{quality, url}], subtitles: [{lang, label?, url}] }.
'
' The generator lives in the shared chunk static/chunks/122-*.js (module
' with the server names MIAMI/BOISE/...). Its constants are the first 16
' SHA-256 round constants plus golden-ratio and murmur3-finaliser
' multipliers. Every request, playlist, segment and subtitle needs
' Referer: https://www.vidy.st/ (403 without).
'
' BrightScript integers are signed 32-bit, so the generator's unsigned
' 32-bit arithmetic is done in LongInteger, with XOR on 16-bit halves.

function VY_Pow2() as Object
    if m.vyPow2 = invalid then
        p = []
        v = 1&
        for i = 0 to 32
            p.Push(v)
            v = v * 2&
        end for
        m.vyPow2 = p
    end if
    return m.vyPow2
end function

function VY_U32(x as LongInteger) as LongInteger
    r = x MOD 4294967296&
    if r < 0 then r = r + 4294967296&
    return r
end function

function VY_Xor(a as LongInteger, b as LongInteger) as LongInteger
    lo = B_Xor(CInt(a MOD 65536&), CInt(b MOD 65536&))
    hi = B_Xor(CInt(a \ 65536&), CInt(b \ 65536&))
    return hi * 65536& + lo
end function

function VY_And(a as LongInteger, b as LongInteger) as LongInteger
    lo = CInt(a MOD 65536&) AND CInt(b MOD 65536&)
    hi = CInt(a \ 65536&) AND CInt(b \ 65536&)
    return hi * 65536& + lo
end function

function VY_Or(a as LongInteger, b as LongInteger) as LongInteger
    lo = CInt(a MOD 65536&) OR CInt(b MOD 65536&)
    hi = CInt(a \ 65536&) OR CInt(b \ 65536&)
    return hi * 65536& + lo
end function

' Low 32 bits of a * b (Math.imul, unsigned).
function VY_Mul(a as LongInteger, b as LongInteger) as LongInteger
    bl = b MOD 65536&
    bh = b \ 65536&
    return (a * bl + ((a * bh) MOD 65536&) * 65536&) MOD 4294967296&
end function

function VY_Rotl(x as LongInteger, t as Integer) as LongInteger
    t = t MOD 32
    if t = 0 then return x
    p = VY_Pow2()
    return ((x * p[t]) MOD 4294967296&) + (x \ p[32 - t])
end function

' murmur3 32-bit finaliser
function VY_Mix(e as LongInteger) as LongInteger
    p = VY_Pow2()
    e = VY_Xor(e, e \ p[16])
    e = VY_Mul(e, 2246822507&)
    e = VY_Xor(e, e \ p[13])
    e = VY_Mul(e, 3266489909&)
    e = VY_Xor(e, e \ p[16])
    return e
end function

function VY_Fnv(s as String) as LongInteger
    h = 2166136261&
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(s)
    for i = 0 to ba.Count() - 1
        h = VY_Mul(VY_Xor(h, ba[i]), 16777619&)
    end for
    return VY_Mix(h)
end function

' Keystream bytes for (seed, mediaId), as the site's generator produces them.
function VY_Keystream(seed as String, mediaId as LongInteger, length as Integer) as Object
    gold = 2654435769&
    table = {}
    s = VY_Mix(VY_Xor(VY_Fnv(seed), VY_Mix(VY_Xor(VY_U32(mediaId), gold))))
    for e = 0 to 7
        t = CInt(s MOD 61&)
        s = VY_Rotl(VY_U32(s + gold), 7 + (e AND 7))
        table[t.ToStr()] = VY_Xor(s, VY_Mix(s))
        s = VY_Mix(VY_U32(s + t))
    end for
    acc = VY_Mix(VY_Xor(2779096485&, s))

    out = CreateObject("roByteArray")
    counter = 0&
    while out.Count() < length
        n = acc
        d = CInt(n MOD 61&)
        key = d.ToStr()
        inTable = table.DoesExist(key)
        i = 0&
        if inTable then i = table[key]
        b = VY_Xor(i, VY_Mul(gold, counter + 1))
        l = VY_Xor(n, b)
        if inTable then l = VY_Or(l, VY_And(n, b))
        l = VY_Xor(VY_Rotl(VY_U32(l + n), d AND 31), VY_Rotl(n, (d * 7) AND 31))
        n = VY_Mix(VY_U32(l + gold))
        table[key] = n
        acc = n
        counter = counter + 1
        out.Push(CInt(n MOD 256&))
        out.Push(CInt((n \ 256&) MOD 256&))
        out.Push(CInt((n \ 65536&) MOD 256&))
        out.Push(CInt((n \ 16777216&) MOD 256&))
    end while
    return out
end function

' Decrypted JSON text, or "" if the payload does not open with this seed.
function VY_Decrypt(text as String, seed as String, mediaId as LongInteger) as String
    t = U_Trim(text)
    if Left(t, 1) = Chr(34) then t = Mid(t, 2, Len(t) - 2)
    raw = HC_Base64UrlDecode(t)
    if raw = invalid or raw.Count() < 5 then return ""
    stream = VY_Keystream(seed, mediaId, raw.Count())
    plain = CreateObject("roByteArray")
    for i = 0 to raw.Count() - 1
        plain.Push(B_Xor(raw[i], stream[i]))
    end for
    ' "mvm1"
    if plain[0] <> 109 or plain[1] <> 118 or plain[2] <> 109 or plain[3] <> 49 then return ""
    body = CreateObject("roByteArray")
    for i = 4 to plain.Count() - 1
        body.Push(plain[i])
    end for
    return body.ToAsciiString()
end function

function VY_Height(label as Dynamic) as Integer
    if label = invalid then return 0
    v = U_FirstMatch(label, "(\d{3,4})p")
    if v = "" then return 0
    return v.ToInt()
end function

function VY_Subtitles(list as Dynamic) as Object
    out = []
    if list = invalid or type(list) <> "roArray" then return out
    for each s in list
        if type(s) = "roAssociativeArray" and s.url <> invalid and s.url <> "" then
            lang = ""
            if s.lang <> invalid then lang = s.lang
            if lang = "" and s.language <> invalid then lang = s.language
            name = ""
            if s.label <> invalid then name = s.label
            if name = "" then name = UCase(lang)
            if name = "" then name = "Subtitles"
            out.Push({ url: s.url, language: LCase(lang), name: name })
        end if
    end for
    return out
end function

function RP_ResolveVidy(embedUrl as String, refer as String, session as Object) as Object
    parts = CreateObject("roRegex", "vidy\.[a-z]+/(movie|tv)/(\d+)(?:/(\d+)/(\d+))?", "i").Match(embedUrl)
    if parts = invalid or parts.Count() < 3 then return invalid
    kind = LCase(parts[1])
    tmdb = parts[2]
    season = "1"
    episode = "1"
    if kind = "tv" then
        if parts.Count() < 5 or parts[3] = "" then return invalid
        season = parts[3]
        episode = parts[4]
    end if
    site = "https://www.vidy.st/"
    headers = { "Referer": site, "Origin": "https://www.vidy.st" }
    api = "https://api.wecollege.net"

    ' Title hints. The API answers without them for most servers, so a
    ' failed lookup is not fatal.
    title = ""
    year = ""
    imdb = ""
    seasons = ""
    meta = HC_Get(session, "https://db.wecollege.net/3/" + kind + "/" + tmdb + "?language=en-US&append_to_response=external_ids", headers, 6000)
    if meta <> invalid and meta.body <> "" then
        info = ParseJson(meta.body)
        if info <> invalid and type(info) = "roAssociativeArray" then
            if info.title <> invalid then title = info.title
            if title = "" and info.name <> invalid then title = info.name
            date = ""
            if info.release_date <> invalid then date = info.release_date
            if date = "" and info.first_air_date <> invalid then date = info.first_air_date
            year = Left(date, 4)
            if info.imdb_id <> invalid then imdb = info.imdb_id
            if imdb = "" and info.external_ids <> invalid and info.external_ids.imdb_id <> invalid then imdb = info.external_ids.imdb_id
            if info.number_of_seasons <> invalid then seasons = info.number_of_seasons.ToStr()
        end if
    end if

    seedRes = HC_Get(session, api + "/seed?mediaId=" + tmdb, headers, 6000)
    if seedRes = invalid or seedRes.body = "" then return invalid
    seedObj = ParseJson(seedRes.body)
    if seedObj = invalid or seedObj.seed = invalid or seedObj.seed = "" then
        print "[vidy] no seed"
        return invalid
    end if
    seed = seedObj.seed
    mediaId = 0&
    for i = 1 to Len(tmdb)
        mediaId = mediaId * 10& + (Asc(Mid(tmdb, i, 1)) - 48)
    end for

    ' The page sends the title encodeURIComponent()-ed, and its HTTP
    ' client encodes query values again.
    query = "title=" + U_UrlEncode(U_UrlEncode(title)) + "&mediaType=" + kind + "&year=" + year
    query = query + "&totalSeasons=" + seasons + "&episodeId=" + episode + "&seasonId=" + season
    query = query + "&tmdbId=" + tmdb + "&imdbId=" + imdb + "&enc=2&seed=" + U_UrlEncode(seed)

    ' miami / boise carry a real quality ladder (480p..2160p, H.264 fMP4) and
    ' many subtitle tracks. The rest are single HLS streams used as backups.
    ' atlanta / chicago answer with raw gzip playlists, nashville with DASH,
    ' austin with Hindi audio: none of those suit the Roku player.
    clock = CreateObject("roTimespan")
    clock.mark()
    can4k = Left(CreateObject("roDeviceInfo").GetVideoMode(), 4) = "2160"
    for each server in ["miami", "boise", "seattle", "portland", "vegas", "oakland", "reno", "dallas"]
        if clock.totalMilliseconds() > 25000 then exit for
        res = HC_Get(session, api + "/" + server + "/sources?" + query, headers, 7000)
        if res <> invalid and res.status = 200 and res.body <> "" then
            data = ParseJson(VY_Decrypt(res.body, seed, mediaId))
            if data <> invalid and type(data) = "roAssociativeArray" and data.sources <> invalid and type(data.sources) = "roArray" then
                result = VY_PickSource(data, server, site, can4k, session)
                if result <> invalid then
                    result.subtitles = VY_Subtitles(data.subtitles)
                    return result
                end if
            else
                print "[vidy] "; server; " did not decrypt"
            end if
        end if
    end for
    return invalid
end function

' First playable source from one server's list, with its quality ladder.
function VY_PickSource(data as Object, server as String, site as String, can4k as Boolean, session as Object) as Object
    ladder = []
    for each src in data.sources
        if type(src) = "roAssociativeArray" and src.url <> invalid and src.url <> "" then
            h = VY_Height(src.quality)
            if h < 2000 or can4k then ladder.Push({ label: h.ToStr() + "p", height: h, url: src.url, bandwidth: 0, demuxed: false, raw: src.quality })
        end if
    end for
    if ladder.Count() = 0 then return invalid
    ' Highest first.
    for i = 1 to ladder.Count() - 1
        j = i
        while j > 0 and ladder[j - 1].height < ladder[j].height
            tmp = ladder[j - 1]
            ladder[j - 1] = ladder[j]
            ladder[j] = tmp
            j = j - 1
        end while
    end for

    for each entry in ladder
        playlist = HC_Get(session, entry.url, { "Referer": site }, 6000)
        if playlist <> invalid and Left(playlist.body, 7) = "#EXTM3U" and RP_HlsFirstSegmentOk(session, playlist.body, entry.url, site) then
            print "[vidy] using "; server; " "; entry.raw
            qualities = []
            if ladder.Count() > 1 then
                for each q in ladder
                    if q.height > 0 then qualities.Push({ label: q.label, height: q.height, rawHeight: q.height, width: 0, bandwidth: 0, url: q.url, demuxed: false })
                end for
            end if
            return {
                url: entry.url
                streamFormat: "hls"
                qualities: qualities
                subtitles: []
                chapters: []
                referer: site
                userAgent: ""
            }
        end if
    end for
    return invalid
end function

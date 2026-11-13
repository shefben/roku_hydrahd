' ResolverVaplayer.brs - airflix1.com and ythd.org (one backend, two skins).
'
' Both sites moved to the same gated chain:
'
'   1. embed page          -> <iframe data-api="...">            (wrapper)
'   2. GET data-api        -> { src: "https://<player host>/embed/...?va=<gate>" }
'   3. GET src             -> player config with a single-use, IP-bound apiToken
'                             (ythd adds one more hop through "playerUrl")
'   4. GET api.php?...&stream_urls&api_token=<apiToken>
'                          -> metadata + data.stream_urls as ONE encrypted string,
'                             plus { w, wasm_url } naming the decryptor
'   5. GET <stream origin>/generate.php?api_token=<apiToken> -> playback token
'   6. master.m3u8?token=<playback token>
'
' stream_urls is base64( nonce[12] || ChaCha20 ciphertext ). The site ships
' the key inside a small WebAssembly module that is regenerated every five
' minutes (w = unix time / 300). Roku cannot run WebAssembly, but it does
' not have to: the module's block function builds the key as
'   mem[0..31] XOR mem[K..K+31]
' from two plain data segments, with K the only constant that moves. So the
' key is lifted straight out of the module bytes and the cipher itself is
' ordinary RFC 8439 ChaCha20 with a zero initial counter.

' --- Binary fetch -----------------------------------------------------
'
' GetToString truncates at the first NUL, so the module is fetched to tmp:
' and read back as bytes.
function VA_GetBytes(url as String, headers as Object, deadlineMs as Integer) as Object
    out = CreateObject("roByteArray")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.EnableEncodings(true)
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.AddHeader("User-Agent", HC_DefaultUA())
    if headers <> invalid then
        for each name in headers
            xfer.AddHeader(name, headers[name])
        end for
    end if
    path = "tmp:/va_" + CreateObject("roDeviceInfo").GetRandomUUID() + ".bin"
    if not xfer.AsyncGetToFile(path) then return out
    msg = wait(deadlineMs, port)
    if type(msg) = "roUrlEvent" and msg.getResponseCode() = 200 then
        out.ReadFile(path)
    else
        xfer.AsyncCancel()
    end if
    DeleteFile(path)
    return out
end function

' --- WebAssembly key lift ---------------------------------------------

' Unsigned LEB128 at bytes[cursor]. Returns { value, next }.
function VA_Leb(bytes as Object, cursor as Integer) as Object
    value = 0
    scale = 1
    while cursor < bytes.Count()
        b = bytes[cursor]
        cursor = cursor + 1
        value = value + (b and 127) * scale
        if (b and 128) = 0 then exit while
        scale = scale * 128
    end while
    return { value: value, next: cursor }
end function

' Returns the 32-byte ChaCha20 key, or an empty array if the module does
' not have the expected shape.
function VA_WasmKey(wasm as Object) as Object
    key = CreateObject("roByteArray")
    n = wasm.Count()
    if n < 16 or wasm[0] <> 0 or wasm[1] <> 97 or wasm[2] <> 115 or wasm[3] <> 109 then return key

    ' Walk the section table for code (10) and data (11).
    codeStart = -1 : codeEnd = -1 : dataStart = -1
    cursor = 8
    while cursor < n
        id = wasm[cursor]
        size = VA_Leb(wasm, cursor + 1)
        if id = 10 then
            codeStart = size.next
            codeEnd = size.next + size.value
        else if id = 11 then
            dataStart = size.next
        end if
        cursor = size.next + size.value
    end while
    if codeStart < 0 or dataStart < 0 then return key

    ' Key setup opens with, for key word 0:
    '   i32.const 0 ; i32.load ; i32.const K ; i32.load ; i32.xor
    '   41 00         28 02 00   41 <K leb>    28 02 00   73
    maskAt = -1
    last = codeEnd - 12
    for i = codeStart to last
        if wasm[i] = 65 and wasm[i + 1] = 0 and wasm[i + 2] = 40 and wasm[i + 3] = 2 and wasm[i + 4] = 0 and wasm[i + 5] = 65 then
            k = VA_Leb(wasm, i + 6)
            p = k.next
            if p + 3 < n and wasm[p] = 40 and wasm[p + 1] = 2 and wasm[p + 2] = 0 and wasm[p + 3] = 115 then
                maskAt = k.value
                exit for
            end if
        end if
    end for
    if maskAt < 0 then return key

    ' Data segments: flag 0, "i32.const <offset> ; end", then the bytes.
    base = -1 : mask = -1
    count = VA_Leb(wasm, dataStart)
    p = count.next
    for i = 1 to count.value
        if p + 2 >= n or wasm[p] <> 0 or wasm[p + 1] <> 65 then return key
        offset = VA_Leb(wasm, p + 2)
        if wasm[offset.next] <> 11 then return key
        length = VA_Leb(wasm, offset.next + 1)
        if length.value >= 32 then
            if offset.value = 0 then base = length.next
            if offset.value = maskAt then mask = length.next
        end if
        p = length.next + length.value
    end for
    if base < 0 or mask < 0 then return key

    for i = 0 to 31
        key.Push(B_Xor(wasm[base + i], wasm[mask + i]))
    end for
    return key
end function

' --- ChaCha20 ----------------------------------------------------------
'
' BrightScript integers are signed 32-bit and there is no XOR operator, so
' each 32-bit word is carried as two 16-bit halves (h = high, l = low).
' Nothing here ever leaves the positive Integer range.

sub VA_Quarter(h as Object, l as Object, a as Integer, b as Integer, c as Integer, d as Integer)
    ' a += b ; d ^= a ; d <<<= 16
    t = l[a] + l[b]
    l[a] = t and 65535
    h[a] = (h[a] + h[b] + (t \ 65536)) and 65535
    t = B_Xor(h[d], h[a])
    h[d] = B_Xor(l[d], l[a])
    l[d] = t
    ' c += d ; b ^= c ; b <<<= 12
    t = l[c] + l[d]
    l[c] = t and 65535
    h[c] = (h[c] + h[d] + (t \ 65536)) and 65535
    x = B_Xor(h[b], h[c])
    y = B_Xor(l[b], l[c])
    h[b] = ((x * 4096) and 65535) + (y \ 16)
    l[b] = ((y * 4096) and 65535) + (x \ 16)
    ' a += b ; d ^= a ; d <<<= 8
    t = l[a] + l[b]
    l[a] = t and 65535
    h[a] = (h[a] + h[b] + (t \ 65536)) and 65535
    x = B_Xor(h[d], h[a])
    y = B_Xor(l[d], l[a])
    h[d] = ((x * 256) and 65535) + (y \ 256)
    l[d] = ((y * 256) and 65535) + (x \ 256)
    ' c += d ; b ^= c ; b <<<= 7
    t = l[c] + l[d]
    l[c] = t and 65535
    h[c] = (h[c] + h[d] + (t \ 65536)) and 65535
    x = B_Xor(h[b], h[c])
    y = B_Xor(l[b], l[c])
    h[b] = ((x * 128) and 65535) + (y \ 512)
    l[b] = ((y * 128) and 65535) + (x \ 512)
end sub

' XOR `data` with the ChaCha20 keystream for (key, nonce), block counter
' starting at 0. Encrypt and decrypt are the same operation.
function VA_ChaCha20(key as Object, nonce as Object, data as Object) as Object
    out = CreateObject("roByteArray")
    if key.Count() <> 32 or nonce.Count() <> 12 then return out

    ' "expand 32-byte k", then key, counter, nonce - all little-endian.
    sh = [24944, 13088, 31074, 27424]
    sl = [30821, 25710, 11570, 25972]
    for i = 0 to 7
        sl.Push(key[i * 4] + key[i * 4 + 1] * 256)
        sh.Push(key[i * 4 + 2] + key[i * 4 + 3] * 256)
    end for
    sl.Push(0)
    sh.Push(0)
    for i = 0 to 2
        sl.Push(nonce[i * 4] + nonce[i * 4 + 1] * 256)
        sh.Push(nonce[i * 4 + 2] + nonce[i * 4 + 3] * 256)
    end for

    total = data.Count()
    block = 0
    done = 0
    while done < total
        ' The counter stays far below 65536 for any payload this sees.
        sl[12] = block and 65535
        sh[12] = block \ 65536
        h = []
        l = []
        for i = 0 to 15
            h.Push(sh[i])
            l.Push(sl[i])
        end for
        for round = 1 to 10
            VA_Quarter(h, l, 0, 4, 8, 12)
            VA_Quarter(h, l, 1, 5, 9, 13)
            VA_Quarter(h, l, 2, 6, 10, 14)
            VA_Quarter(h, l, 3, 7, 11, 15)
            VA_Quarter(h, l, 0, 5, 10, 15)
            VA_Quarter(h, l, 1, 6, 11, 12)
            VA_Quarter(h, l, 2, 7, 8, 13)
            VA_Quarter(h, l, 3, 4, 9, 14)
        end for
        for i = 0 to 15
            if done >= total then exit for
            t = l[i] + sl[i]
            lo = t and 65535
            hi = (h[i] + sh[i] + (t \ 65536)) and 65535
            stream = [lo and 255, lo \ 256, hi and 255, hi \ 256]
            for each ks in stream
                if done < total then
                    out.Push(B_Xor(data[done], ks))
                    done = done + 1
                end if
            end for
        end for
        block = block + 1
    end while
    return out
end function

' base64( nonce || ciphertext ) + module bytes -> list of stream URLs.
function VA_DecryptStreams(encoded as String, wasm as Object) as Object
    urls = []
    key = VA_WasmKey(wasm)
    if key.Count() <> 32 then return urls
    raw = CreateObject("roByteArray")
    raw.FromBase64String(encoded)
    if raw.Count() <= 12 then return urls
    nonce = CreateObject("roByteArray")
    body = CreateObject("roByteArray")
    for i = 0 to raw.Count() - 1
        if i < 12 then nonce.Push(raw[i]) else body.Push(raw[i])
    end for
    plain = VA_ChaCha20(key, nonce, body).ToAsciiString()
    for each line in plain.Tokenize(Chr(10))
        line = U_Trim(line)
        if Left(line, 8) = "https://" then urls.Push(line)
    end for
    return urls
end function

' --- Subtitles ----------------------------------------------------------
'
' The API lists subtitles under up to four keys ("subs" is usually English
' only, "default_subs" every language). Entries look like
'   { "lang": "English (SDH)", "code": "en", "url": "https://..." }
' - `code` is the ISO 639-1 code, `lang` the display label.
function VA_Subtitles(envelope as Object) as Object
    all = []
    seen = {}
    data = envelope.data
    lists = [envelope.subs, envelope.default_subs]
    if data <> invalid and type(data) = "roAssociativeArray" then
        lists.Push(data.subs)
        lists.Push(data.default_subs)
    end if
    for each list in lists
        if list <> invalid and type(list) = "roArray" then
            for each entry in list
                if type(entry) = "roAssociativeArray" then
                    url = ""
                    if entry.url <> invalid then url = entry.url
                    if url = "" and entry.file <> invalid then url = entry.file
                    if url <> "" and not seen.DoesExist(url) then
                        seen[url] = true
                        language = ""
                        if entry.code <> invalid then language = LCase(entry.code)
                        if language = "" and entry.language <> invalid then language = LCase(entry.language)
                        if language = "" and entry.lang <> invalid and Len(entry.lang) >= 2 then language = LCase(Left(entry.lang, 2))
                        if language = "" then language = "en"
                        name = ""
                        if entry.label <> invalid then name = entry.label
                        if name = "" and entry.lang <> invalid then name = entry.lang
                        if name = "" then name = UCase(language)
                        all.Push({ url: url, language: language, name: name })
                    end if
                end if
            end for
        end if
    end for
    ' English first so the CC panel defaults to it.
    out = []
    for each track in all
        if track.language = "en" then out.Push(track)
    end for
    for each track in all
        if track.language <> "en" then out.Push(track)
    end for
    return out
end function

' --- Resolver -----------------------------------------------------------

' JSON string values come back with "\/" and "&" escapes.
function VA_Unescape(s as String) as String
    s = CreateObject("roRegex", "\\/", "").ReplaceAll(s, "/")
    s = CreateObject("roRegex", "\\u0026", "i").ReplaceAll(s, "&")
    return s
end function

' Build the stream API query from the embed URL when the player config
' only carries the bare endpoint (airflix1).
'   airflix1: /embed/movie/<id>   /embed/tv/<id>/<s>/<e>
'   ythd:     /embed/<id>/        /embed/<id>/<s>-<e>/
function VA_QueryFromEmbed(embedUrl as String) as String
    parts = CreateObject("roRegex", "/embed/(movie|tv)/(tt\d+|\d+)(?:/(\d+)/(\d+))?", "i").Match(embedUrl)
    kind = "" : id = "" : season = "" : episode = ""
    if parts <> invalid and parts.Count() >= 3 then
        kind = LCase(parts[1])
        id = parts[2]
        if parts.Count() >= 5 then
            season = parts[3]
            episode = parts[4]
        end if
    else
        parts = CreateObject("roRegex", "/embed/(tt\d+|\d+)(?:/(\d+)-(\d+))?", "i").Match(embedUrl)
        if parts = invalid or parts.Count() < 2 then return ""
        id = parts[1]
        kind = "movie"
        if parts.Count() >= 4 and parts[2] <> "" then
            kind = "tv"
            season = parts[2]
            episode = parts[3]
        end if
    end if
    idName = "tmdb"
    if Left(id, 2) = "tt" then idName = "imdb"
    query = idName + "=" + id + "&type=" + kind
    if kind = "tv" and season <> "" and episode <> "" then query = query + "&season=" + season + "&episode=" + episode
    return query
end function

function RP_ResolveVaplayer(embedUrl as String, refer as String, session as Object) as Object
    q = Chr(34)
    embedOrigin = HC_OriginOf(embedUrl)
    if embedOrigin = "" then return invalid
    if refer = "" then refer = embedOrigin + "/"

    ' 1-2. wrapper -> gated player URL
    page = HC_Get(session, embedUrl, { "Referer": refer }, 8000)
    if page = invalid or page.body = "" then return invalid
    api = U_HtmlDecode(U_FirstMatch(page.body, "data-api=[" + q + "']([^" + q + "']+)"))
    if api = "" then
        print "[vaplayer] no data-api on wrapper page"
        return invalid
    end if
    gate = HC_Get(session, RP_AbsUrl(api, embedUrl), { "Referer": embedUrl }, 8000)
    if gate = invalid or gate.body = "" then return invalid
    gateJson = ParseJson(gate.body)
    if gateJson = invalid or type(gateJson) <> "roAssociativeArray" or gateJson.src = invalid or gateJson.src = "" then return invalid
    playerUrl = gateJson.src
    playerOrigin = HC_OriginOf(playerUrl)

    ' 3. player config (ythd wraps the real player in one more page)
    inner = HC_Get(session, playerUrl, { "Referer": embedOrigin + "/" }, 8000)
    if inner = invalid or inner.body = "" then return invalid
    config = inner.body
    nested = U_FirstMatch(config, q + "playerUrl" + q + "\s*:\s*" + q + "([^" + q + "]+)" + q)
    if nested <> "" then
        inner = HC_Get(session, RP_AbsUrl(VA_Unescape(nested), playerUrl), { "Referer": playerUrl }, 8000)
        if inner = invalid or inner.body = "" then return invalid
        config = inner.body
    end if
    token = U_FirstMatch(config, q + "apiToken" + q + "\s*:\s*" + q + "([^" + q + "]+)" + q)
    ' The endpoint's field name differs per skin and per media type: ythd
    ' movies use "api", ythd episodes only "metaApi" (which already carries
    ' season and episode), airflix1 the bare "streamDataApiUrl".
    apiUrl = ""
    for each field in ["api", "metaApi", "streamDataApiUrl"]
        if apiUrl = "" then apiUrl = VA_Unescape(U_FirstMatch(config, q + field + q + "\s*:\s*" + q + "([^" + q + "]*api\.php[^" + q + "]*)" + q))
    end for
    if token = "" or apiUrl = "" then
        print "[vaplayer] player config has no apiToken / api url"
        return invalid
    end if
    if Instr(1, apiUrl, "?") = 0 then
        query = VA_QueryFromEmbed(embedUrl)
        if query = "" then return invalid
        apiUrl = apiUrl + "?" + query
    end if
    if Instr(1, apiUrl, "stream_urls") = 0 then apiUrl = apiUrl + "&stream_urls"
    apiHeaders = { "Referer": playerOrigin + "/", "Origin": playerOrigin, "Accept": "application/json" }

    ' 4. metadata + encrypted stream list
    res = HC_Get(session, apiUrl + "&api_token=" + U_UrlEncode(token), apiHeaders, 8000)
    if res = invalid or res.body = "" then return invalid
    envelope = ParseJson(res.body)
    if envelope = invalid or type(envelope) <> "roAssociativeArray" then return invalid
    data = envelope.data
    if data = invalid or type(data) <> "roAssociativeArray" or data.stream_urls = invalid then
        print "[vaplayer] api returned no stream_urls"
        return invalid
    end if

    streams = []
    if type(data.stream_urls) = "roArray" then
        streams = data.stream_urls
    else
        module = envelope.va
        if module = invalid then module = envelope.vp
        if module = invalid then module = envelope.vs
        if module = invalid or type(module) <> "roAssociativeArray" then return invalid
        wasm = CreateObject("roByteArray")
        if module.wasm_url <> invalid and module.wasm_url <> "" then
            wasm = VA_GetBytes(module.wasm_url, { "Referer": playerOrigin + "/" }, 8000)
        else if module.wasm <> invalid then
            wasm.FromBase64String(module.wasm)
        end if
        streams = VA_DecryptStreams(data.stream_urls, wasm)
        if streams.Count() = 0 then
            print "[vaplayer] could not decrypt stream_urls (module "; wasm.Count(); " bytes)"
            return invalid
        end if
    end if

    subs = VA_Subtitles(envelope)

    ' 5-6. playback token per stream host, then the first playlist that answers
    tokens = {}
    for each stream in streams
        if type(stream) = "String" or type(stream) = "roString" then
            origin = HC_OriginOf(stream)
            if origin <> "" then
                if not tokens.DoesExist(origin) then
                    tokens[origin] = ""
                    minted = HC_Get(session, origin + "/generate.php?api_token=" + U_UrlEncode(token), { "Referer": playerOrigin + "/", "Origin": playerOrigin }, 6000)
                    if minted <> invalid and minted.status = 200 then
                        text = U_Trim(minted.body)
                        if Left(text, 1) = "{" or Left(text, 1) = q then
                            parsed = ParseJson(text)
                            text = ""
                            if type(parsed) = "String" or type(parsed) = "roString" then
                                text = parsed
                            else if type(parsed) = "roAssociativeArray" then
                                for each field in ["token", "data", "string", "result"]
                                    if text = "" and parsed[field] <> invalid and (type(parsed[field]) = "String" or type(parsed[field]) = "roString") then text = parsed[field]
                                end for
                            end if
                        end if
                        tokens[origin] = text
                    end if
                end if
                url = stream
                if tokens[origin] <> "" then
                    if Instr(1, url, "__TOKEN__") > 0 then
                        url = url.Replace("__TOKEN__", tokens[origin])
                    else if Instr(1, url, "?") > 0 then
                        url = url + "&token=" + tokens[origin]
                    else
                        url = url + "?token=" + tokens[origin]
                    end if
                end if
                playlist = HC_Get(session, url, { "Referer": playerOrigin + "/" }, 6000)
                if playlist <> invalid and Left(playlist.body, 7) = "#EXTM3U" then
                    return {
                        url: url
                        streamFormat: "hls"
                        qualities: []
                        subtitles: subs
                        chapters: []
                        referer: playerOrigin + "/"
                        userAgent: ""
                    }
                end if
            end if
        end if
    end for
    return invalid
end function

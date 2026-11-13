' ResolverVidfast.brs - vidfast.vc ("Faststream" player) resolver.
'
' The embed page is a Next.js app that server-renders a one-time token
' (`en`) and a `variantIndex` selecting one of 20 player chunks. Each
' variant runs its own virtualized client with its own sealed-transport
' protocol. The server has only ever been seen serving variant 16, which
' is what this file ports:
'
'   1. GET  embed page                      -> en token
'   2. POST {base}/{ticket}/{seal(en)}      -> ticket (opaque text)
'   3. POST {base}/{servers}/{ticket}       -> sealed JSON [{name, data}]
'   4. POST {base}/{fetch}/{server.data}    -> sealed JSON {url, tracks, ...}
'
' Sealed transport ("vidfast/v16"): plaintext is cut into <=1024-byte
' records, each AES-256-CBC encrypted with a key from HKDF-SHA512(master,
' salt = record IV) and authenticated with HMAC-SHA256. Records alternate
' base64url / hex encoding and are joined with a separator; the trailer is
' base64url(directory JSON) + separator + hex(manifest HMAC).
'
' The constants in RP_VidfastConfig() live inside the variant chunk (most
' of them in an XOR-masked VM descriptor) and change whenever vidfast
' redeploys. Refresh them with:  python tools/vidfast_constants.py
' RP_ResolveVidfast bails out (so the fallback chain runs) when the page
' stops referencing the chunk these constants were lifted from.

function RP_VidfastConfig() as Object
    return {
        chunk: "304.df0b3d32fd5ef888.js"
        variant: "16"
        base: "/p/muh/fb480ddb-aac2-5518-a1ec-d3fdc38d3e17/APA910MAJe-VAyQt8yhnPwt_3jktQf7BJcicoXw1cK4OuXG6UTag0Xmct84SvLpiixjvhzXJvhA5yhS_Ly6P1hcU_SIztkMsL6ANVEII4EWk5HwkfnzagZTyortpXm3PpC0Nrhfwzq3t68jks3a8kRPbi_Vw-2iQaUcb1jVgqlP-QLftEkXDu_U/e03995b2928622e8281a47d7359ceab8c4a2f9459f7e6e36ab8e252f709bd0a5/1000019639980601/sukgakluj/12ae7109"
        csrf: "q037uAePWWqdo9ofqp28Rn7nfDIxMmlq"
        ticketId: "T4GBrF3cScU"
        serversId: "g9zPS7e1ryQ"
        fetchId: "atnP1JHRzsI"
        key: "e370ae1e0b09ab3c2e8c771003d58d639bbb37193fb236757703cacbac49ab79"
        first: "6771244154"
        second: "6843159337"
        build: "8rGefdRb2G-BTMM0lBAGdBh4L3KzbIrX_btZOXsNxjc"
        sep: "."
    }
end function

' --- Byte helpers -----------------------------------------------------
'
' BrightScript strings cannot hold NUL (Chr(0) is the empty string), and
' every vidfast label is NUL-delimited, so all protocol strings are built
' as byte arrays. VF_Cat takes a list whose items are strings (appended
' as ASCII), integers (appended as one byte) or roByteArrays.

function VF_Cat(parts as Object) as Object
    out = CreateObject("roByteArray")
    for each part in parts
        t = type(part)
        if t = "roByteArray" then
            out.Append(part)
        else if t = "Integer" or t = "roInt" or t = "roInteger" then
            out.Push(part)
        else if part <> invalid and part <> "" then
            piece = CreateObject("roByteArray")
            piece.FromAsciiString(part)
            out.Append(piece)
        end if
    end for
    return out
end function

function VF_Slice(bytes as Object, startIdx as Integer, count as Integer) as Object
    out = CreateObject("roByteArray")
    last = startIdx + count - 1
    if last > bytes.Count() - 1 then last = bytes.Count() - 1
    for i = startIdx to last
        out.Push(bytes[i])
    end for
    return out
end function

function VF_Hex(bytes as Object) as String
    return LCase(bytes.ToHexString())
end function

function VF_Hmac(digest as String, keyBytes as Object, dataBytes as Object) as Object
    mac = CreateObject("roHMAC")
    if mac.Setup(digest, keyBytes) <> 0 then return CreateObject("roByteArray")
    out = mac.Process(dataBytes)
    if out = invalid then return CreateObject("roByteArray")
    return out
end function

' HKDF-SHA512 (RFC 5869) limited to a single 64-byte output block, which
' is all the protocol ever asks for: bytes 0-31 are the AES key and bytes
' 32-63 the HMAC key.
function VF_Hkdf64(ikm as Object, salt as Object, info as Object) as Object
    prk = VF_Hmac("sha512", salt, ikm)
    return VF_Hmac("sha512", prk, VF_Cat([info, 1]))
end function

' AES-256-CBC with PKCS7 padding. Uses explicit Update + Final rather than
' Process so the padded tail is emitted exactly once on every firmware.
function VF_AesCbc(encrypt as Boolean, keyBytes as Object, ivBytes as Object, dataBytes as Object) as Object
    cipher = CreateObject("roEVPCipher")
    if cipher.Setup(encrypt, "aes-256-cbc", VF_Hex(keyBytes), VF_Hex(ivBytes), 1) <> 0 then return invalid
    cipher.Reinit()
    out = CreateObject("roByteArray")
    head = cipher.Update(dataBytes)
    if head <> invalid then out.Append(head)
    tail = cipher.Final()
    if tail <> invalid then out.Append(tail)
    return out
end function

function VF_RandomIv() as Object
    iv = CreateObject("roByteArray")
    for i = 1 to 16
        iv.Push(Rnd(256) - 1)
    end for
    return iv
end function

' --- Sealed transport --------------------------------------------------

function VF_Master(cfg as Object, direction as String) as Object
    keyBytes = HC_HexToBytes(cfg.key)
    if direction = "request" then
        return VF_Cat(["vidfast/v" + cfg.variant + "/request/master", 0, keyBytes, 0, cfg.first, 0, cfg.second, 0, cfg.build])
    end if
    return VF_Cat(["vidfast/v" + cfg.variant + "/response/master", 0, cfg.second, 0, keyBytes, 0, cfg.first, 0, cfg.build])
end function

function VF_RecordKeys(cfg as Object, master as Object, direction as String, kind as String, index as Integer, encoding as String, plainLen as Integer, cipherLen as Integer, iv as Object) as Object
    info = VF_Cat(["vidfast/v" + cfg.variant + "/record-keys", 0, direction, 0, kind, 0, cfg.build, 0, index.ToStr(), 0, encoding, 0, plainLen.ToStr(), 0, cipherLen.ToStr()])
    return VF_Hkdf64(master, iv, info)
end function

function VF_Quote(s as String) as String
    return Chr(34) + s + Chr(34)
end function

' Seal `plain` for the request direction. `ivs` is normally invalid (random
' IVs); tests pass a list of 16-byte arrays to make the output reproducible.
function VF_Seal(plain as String, cfg as Object, ivs = invalid as Object) as String
    direction = "request"
    kind = "request"
    data = HC_StringToBytes(plain)
    total = data.Count()
    master = VF_Master(cfg, direction)
    count = Int((total + 1023) / 1024)
    if count < 1 then count = 1

    encoded = []
    records = []
    offset = 0
    for index = 0 to count - 1
        chunk = VF_Slice(data, index * 1024, 1024)
        iv = invalid
        if ivs <> invalid and index < ivs.Count() then iv = ivs[index]
        if iv = invalid then iv = VF_RandomIv()
        cipherLen = (Int(chunk.Count() / 16) + 1) * 16
        encoding = "hex"
        if index mod 2 = 0 then encoding = "b64u"
        keys = VF_RecordKeys(cfg, master, direction, kind, index, encoding, chunk.Count(), cipherLen, iv)
        ct = VF_AesCbc(true, VF_Slice(keys, 0, 32), iv, chunk)
        if ct = invalid or ct.Count() <> cipherLen then return ""
        text = VF_Hex(ct)
        if encoding = "b64u" then text = HC_Base64UrlEncode(ct)
        macInput = VF_Cat(["vidfast/v" + cfg.variant + "/record-mac", 0, direction, 0, kind, 0, cfg.build, 0, index.ToStr(), 0, offset.ToStr(), 0, encoding, 0, chunk.Count().ToStr(), 0, cipherLen.ToStr(), 0, iv, ct])
        tag = VF_Hmac("sha256", VF_Slice(keys, 32, 32), macInput)
        encoded.Push(text)
        records.Push("{" + VF_Quote("offset") + ":" + offset.ToStr() + "," + VF_Quote("length") + ":" + Len(text).ToStr() + "," + VF_Quote("encoding") + ":" + VF_Quote(encoding) + "," + VF_Quote("plain") + ":" + chunk.Count().ToStr() + "," + VF_Quote("cipher") + ":" + cipherLen.ToStr() + "," + VF_Quote("iv") + ":" + VF_Quote(HC_Base64UrlEncode(iv)) + "," + VF_Quote("tag") + ":" + VF_Quote(HC_Base64UrlEncode(tag)) + "}")
        offset = offset + Len(text)
        if index + 1 < count then offset = offset + 1
    end for

    body = encoded.Join(cfg.sep)
    ' Key order matters: the server authenticates these exact bytes.
    directory = "{" + VF_Quote("version") + ":1," + VF_Quote("variant") + ":" + cfg.variant + "," + VF_Quote("build") + ":" + VF_Quote(cfg.build) + "," + VF_Quote("direction") + ":" + VF_Quote(direction) + "," + VF_Quote("kind") + ":" + VF_Quote(kind) + "," + VF_Quote("total") + ":" + total.ToStr() + "," + VF_Quote("dataLength") + ":" + Len(body).ToStr() + "," + VF_Quote("count") + ":" + count.ToStr() + "," + VF_Quote("records") + ":[" + records.Join(",") + "]}"
    manifestKeys = VF_Hkdf64(master, HC_StringToBytes(cfg.build), VF_Cat(["vidfast/v" + cfg.variant + "/manifest-keys", 0, direction, 0, kind]))
    manifestMac = VF_Hmac("sha256", VF_Slice(manifestKeys, 32, 32), VF_Cat(["vidfast/v" + cfg.variant + "/manifest", 0, direction, 0, kind, 0, cfg.build, 0, body, 0, directory]))
    return body + cfg.sep + HC_Base64UrlEncode(HC_StringToBytes(directory)) + cfg.sep + VF_Hex(manifestMac)
end function

' Open a sealed response. `kind` is "servers" or "fetch". Returns the
' plaintext, or "" when the transport does not parse or authenticate.
function VF_Open(sealed as String, kind as String, cfg as Object) as String
    direction = "response"
    if sealed = invalid or sealed = "" then return ""
    parts = U_Trim(sealed).Split(cfg.sep)
    if parts.Count() < 3 then return ""
    recordCount = parts.Count() - 2
    directoryBytes = HC_Base64UrlDecode(parts[recordCount])
    if directoryBytes.Count() = 0 then return ""
    directory = ParseJson(directoryBytes.ToAsciiString())
    if directory = invalid or type(directory) <> "roAssociativeArray" then return ""
    if directory.records = invalid or type(directory.records) <> "roArray" or directory.records.Count() <> recordCount then return ""

    master = VF_Master(cfg, direction)
    plain = CreateObject("roByteArray")
    for index = 0 to recordCount - 1
        record = directory.records[index]
        if type(record) <> "roAssociativeArray" or record.iv = invalid or record.tag = invalid or record.encoding = invalid then return ""
        ct = HC_HexToBytes(parts[index])
        if record.encoding = "b64u" then ct = HC_Base64UrlDecode(parts[index])
        iv = HC_Base64UrlDecode(record.iv)
        plainLen = Int(record.plain)
        cipherLen = Int(record.cipher)
        offset = Int(record.offset)
        if iv.Count() <> 16 or ct.Count() <> cipherLen or cipherLen = 0 then return ""
        keys = VF_RecordKeys(cfg, master, direction, kind, index, record.encoding, plainLen, cipherLen, iv)
        ' Authenticate before decrypting: a mismatch means the constants
        ' in RP_VidfastConfig() are stale, not that the stream is bad.
        macInput = VF_Cat(["vidfast/v" + cfg.variant + "/record-mac", 0, direction, 0, kind, 0, cfg.build, 0, index.ToStr(), 0, offset.ToStr(), 0, record.encoding, 0, plainLen.ToStr(), 0, cipherLen.ToStr(), 0, iv, ct])
        tag = VF_Hmac("sha256", VF_Slice(keys, 32, 32), macInput)
        if HC_Base64UrlEncode(tag) <> record.tag then return ""
        chunk = VF_AesCbc(false, VF_Slice(keys, 0, 32), iv, ct)
        if chunk = invalid or chunk.Count() <> plainLen then return ""
        plain.Append(chunk)
    end for
    return plain.ToAsciiString()
end function

' --- Resolver ----------------------------------------------------------

' ISO 639-2 code from a "/subs/eng.2.vtt" track path -> the two-letter
' code the rest of the channel keys subtitles on.
function VF_SubLanguage(fileUrl as String) as String
    code = LCase(U_FirstMatch(fileUrl, "/subs/([A-Za-z]{2,3})[.]"))
    if code = "" then return "en"
    if Len(code) = 2 then return code
    known = {
        eng: "en", spa: "es", fre: "fr", fra: "fr", ger: "de", deu: "de", ita: "it", por: "pt", ara: "ar"
        chi: "zh", zho: "zh", jpn: "ja", kor: "ko", rus: "ru", dut: "nl", nld: "nl", gre: "el", ell: "el"
        cze: "cs", ces: "cs", dan: "da", est: "et", fin: "fi", heb: "he", hin: "hi", hun: "hu", ind: "id"
        nor: "no", pol: "pl", rum: "ro", ron: "ro", swe: "sv", tha: "th", tur: "tr", ukr: "uk", vie: "vi"
        bul: "bg", hrv: "hr", slo: "sk", slk: "sk", slv: "sl", srp: "sr", may: "ms", msa: "ms", per: "fa"
        fas: "fa", lit: "lt", lav: "lv", ice: "is", isl: "is", cat: "ca", ben: "bn", tam: "ta", tel: "te"
    }
    if known.DoesExist(code) then return known[code]
    return Left(code, 2)
end function

' Turn the decrypted "fetch" payload into the resolver result envelope.
function RP_VidfastResult(payload as Dynamic, origin as String) as Object
    if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid
    url = payload.url
    if url = invalid or (type(url) <> "String" and type(url) <> "roString") or url = "" then return invalid
    result = {
        url: url
        streamFormat: U_StreamFormat(url)
        qualities: []
        subtitles: []
        chapters: []
        ' The CDN answers 403 without a vidfast Referer.
        referer: origin + "/"
        userAgent: ""
    }
    if payload.mp4 = true then result.streamFormat = "mp4"
    if payload.tracks <> invalid and type(payload.tracks) = "roArray" then
        for each track in payload.tracks
            if type(track) = "roAssociativeArray" and track.file <> invalid and track.file <> "" then
                name = "Subtitles"
                if track.label <> invalid and track.label <> "" then name = track.label
                result.subtitles.Push({ url: track.file, language: VF_SubLanguage(track.file), name: name })
            end if
        end for
    end if
    return result
end function

function RP_ResolveVidfast(embedUrl as String, refer as String, session as Object) as Object
    cfg = RP_VidfastConfig()
    origin = HC_OriginOf(embedUrl)
    if origin = "" then return invalid
    if refer = "" then refer = origin + "/"

    page = HC_Get(session, embedUrl, { "Referer": refer }, 8000)
    if page = invalid or page.body = "" then return invalid
    ' Server-rendered props arrive JSON-escaped inside a script tag:
    '   \"variantIndex\":16,\"en\":\"<token>\"
    token = U_FirstMatch(page.body, "en\\?" + Chr(34) + "\s*:\s*\\?" + Chr(34) + "([A-Za-z0-9_-]{20,})")
    if token = "" then
        print "[vidfast] no en token on embed page"
        return invalid
    end if
    if Instr(1, page.body, cfg.chunk) = 0 then
        print "[vidfast] player chunk changed (variant "; U_FirstMatch(page.body, "variantIndex\\?" + Chr(34) + "\s*:\s*(\d+)"); ") - run tools/vidfast_constants.py"
        return invalid
    end if

    headers = {
        "Referer": embedUrl
        "Origin": origin
        "X-Requested-With": "XMLHttpRequest"
        "X-Csrf-Token": cfg.csrf
    }
    api = origin + cfg.base + "/"

    sealed = VF_Seal(token, cfg)
    if sealed = "" then return invalid
    ticket = HC_Post(session, api + cfg.ticketId + "/" + sealed, headers, "", 8000)
    if ticket = invalid or ticket.status <> 200 or ticket.body = "" then
        print "[vidfast] ticket request failed"
        return invalid
    end if

    listing = HC_Post(session, api + cfg.serversId + "/" + U_Trim(ticket.body), headers, "", 8000)
    if listing = invalid or listing.status <> 200 then return invalid
    servers = ParseJson(VF_Open(listing.body, "servers", cfg))
    if servers = invalid or type(servers) <> "roArray" then
        print "[vidfast] server list did not open - constants stale?"
        return invalid
    end if

    ' Servers are listed best-first. Individual ones routinely 404 for a
    ' given title, so walk a few before giving up.
    tried = 0
    for each server in servers
        if type(server) = "roAssociativeArray" and server.data <> invalid and server.data <> "" then
            tried = tried + 1
            if tried > 8 then exit for
            source = HC_Post(session, api + cfg.fetchId + "/" + server.data, headers, "", 5000)
            if source <> invalid and source.status = 200 and source.body <> "" then
                result = RP_VidfastResult(ParseJson(VF_Open(source.body, "fetch", cfg)), origin)
                if result <> invalid then return result
            end if
        end if
    end for
    return invalid
end function

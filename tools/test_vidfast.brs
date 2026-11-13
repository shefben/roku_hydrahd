' Offline checks for the vidfast sealed transport, against exchanges
' captured from the live site (tools/fixtures/vidfast). Needs an interpreter
' with roHMAC / roEVPCipher: run via  python tools/test_vidfast.py
sub Main()
    cfg = RP_VidfastConfig()

    ' RFC 5869 has no SHA-512 vectors; this one is from the HKDF-SHA512
    ' Wycheproof-style set (IKM 0x0b*22, salt 000102..0c, info f0..f9).
    ikm = CreateObject("roByteArray")
    ikm.FromHexString("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    salt = CreateObject("roByteArray")
    salt.FromHexString("000102030405060708090a0b0c")
    info = CreateObject("roByteArray")
    info.FromHexString("f0f1f2f3f4f5f6f7f8f9")
    okm = VF_Hex(VF_Hkdf64(ikm, salt, info))
    check(Left(okm, 84) = "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb", "HKDF-SHA512 known answer")

    check(VF_Cat(["a", 0, "b"]).ToHexString() = "610062", "NUL-delimited labels survive as bytes")

    seal = ParseJson(ReadAsciiFile("pkg:/tools/fixtures/vidfast/seal.json"))
    iv = CreateObject("roByteArray")
    iv.FromHexString(seal.iv)
    check(VF_Seal(seal.token, cfg, [iv]) = seal.sealed, "sealed request matches the browser byte for byte")
    check(VF_Seal(seal.token, cfg) <> seal.sealed, "random IV changes the sealed request")

    servers = ParseJson(VF_Open(ReadAsciiFile("pkg:/tools/fixtures/vidfast/servers.txt"), "servers", cfg))
    check(servers <> invalid and type(servers) = "roArray" and servers.Count() > 0, "server list opens")
    if servers <> invalid and servers.Count() > 0 then
        check(servers[0].name <> invalid and Len(servers[0].data) > 40, "server entries carry name and data")
    end if

    sealedFetch = ReadAsciiFile("pkg:/tools/fixtures/vidfast/fetch.txt")
    check(sealedFetch.Split(cfg.sep).Count() > 3, "fetch fixture spans several records")
    payload = ParseJson(VF_Open(sealedFetch, "fetch", cfg))
    check(payload <> invalid and payload.url <> invalid, "multi-record fetch response opens")
    result = RP_VidfastResult(payload, "https://vidfast.vc")
    check(result <> invalid, "fetch payload becomes a resolver result")
    if result <> invalid then
        check(Instr(1, result.url, ".m3u8") > 0 and result.streamFormat = "hls", "HLS master URL extracted")
        check(result.referer = "https://vidfast.vc/", "CDN referer is the embed origin")
    end if
    ' Shape of a server that ships its own subtitle tracks (vRapid/vBlaze).
    result = RP_VidfastResult({ url: "https://cdn.example/v/master.m3u8?s=1", tracks: [{ file: "https://cdn.example/v/subs/eng.vtt", label: "English" }, { label: "no file" }] }, "https://vidfast.vc")
    check(result.subtitles.Count() = 1 and result.subtitles[0].language = "en" and result.subtitles[0].name = "English", "subtitle tracks mapped")

    check(VF_Open(sealedFetch, "servers", cfg) = "", "wrong response kind fails authentication")
    stale = RP_VidfastConfig()
    stale.key = "00" + Mid(stale.key, 3)
    check(VF_Open(sealedFetch, "fetch", stale) = "", "stale key fails closed")
    check(VF_Open("not-a-sealed-body", "fetch", cfg) = "", "garbage fails closed")
    check(RP_VidfastResult({ url: "" }, "https://vidfast.vc") = invalid, "empty url is not a result")
    check(RP_VidfastResult({ url: "https://cdn.example/a", mp4: true }, "https://vidfast.vc").streamFormat = "mp4", "mp4 flag honoured")
    check(VF_SubLanguage("https://cdn.example/x/subs/spa.2.vtt") = "es", "ISO 639-2 subtitle code mapped")
    print "FAILURES: "; failures()
end sub

function failures() as Integer
    if m.failures = invalid then m.failures = 0
    return m.failures
end function

sub check(ok as Boolean, label as String)
    if m.failures = invalid then m.failures = 0
    if not ok then
        print "FAIL: "; label
        m.failures = m.failures + 1
    end if
end sub

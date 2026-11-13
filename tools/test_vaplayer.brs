' Offline checks for the airflix1 / ythd decryptor against captured live
' modules (tools/fixtures/vaplayer). Run via  python tools/test_vidfast.py
sub Main()
    ' RFC 8439 section 2.4.2 keystream check, adapted to counter 0:
    ' key 00..1f, nonce 00 00 00 00 00 00 00 4a 00 00 00 00, all-zero input.
    key = CreateObject("roByteArray")
    for i = 0 to 31
        key.Push(i)
    end for
    nonce = CreateObject("roByteArray")
    nonce.FromHexString("000000000000004a00000000")
    zeros = CreateObject("roByteArray")
    for i = 1 to 130
        zeros.Push(0)
    end for
    stream = LCase(VA_ChaCha20(key, nonce, zeros).ToHexString())
    ' Block 1 of the RFC vector is this stream's second block.
    check(Mid(stream, 129, 64) = "224f51f3401bd9e12fde276fb8631ded8c131f823d2c06e27e4fcaec9ef3cf78", "ChaCha20 block 1 matches RFC 8439")
    check(Len(stream) = 260, "partial final block is truncated, not padded")

    for each name in ["airflix", "ythd"]
        fixture = ParseJson(ReadAsciiFile("pkg:/tools/fixtures/vaplayer/" + name + ".json"))
        wasm = CreateObject("roByteArray")
        wasm.FromBase64String(fixture.wasm)
        check(LCase(VA_WasmKey(wasm).ToHexString()) = fixture.keyHex, name + ": key lifted from module bytes")
        urls = VA_DecryptStreams(fixture.enc, wasm)
        expected = fixture.plain.Tokenize(Chr(10))
        check(urls.Count() = expected.Count() and urls.Count() > 0, name + ": stream list decrypts")
        if urls.Count() > 0 then check(urls[0] = expected[0], name + ": first stream URL exact")
    end for

    junk = CreateObject("roByteArray")
    junk.FromHexString("0061736d0100000001")
    check(VA_WasmKey(junk).Count() = 0, "module without code/data sections yields no key")
    check(VA_DecryptStreams("AAAA", junk).Count() = 0, "bad module fails closed")

    check(VA_QueryFromEmbed("https://airflix1.com/embed/movie/603") = "tmdb=603&type=movie", "airflix movie query")
    check(VA_QueryFromEmbed("https://airflix1.com/embed/tv/tt5875444/1/2") = "imdb=tt5875444&type=tv&season=1&episode=2", "airflix tv query by imdb")
    check(VA_QueryFromEmbed("https://ythd.org/embed/95480/1-1/") = "tmdb=95480&type=tv&season=1&episode=1", "ythd tv query")
    check(VA_QueryFromEmbed("https://ythd.org/embed/603/") = "tmdb=603&type=movie", "ythd movie query")

    subs = VA_Subtitles({ default_subs: [{ lang: "Portuguese - Brazilian", code: "pt", url: "https://s.example/pt.srt" }, { lang: "English (SDH)", code: "en", url: "https://s.example/en.srt" }], data: { subs: [{ lang: "English (SDH)", code: "en", url: "https://s.example/en.srt" }] } })
    check(subs.Count() = 2 and subs[0].language = "en" and subs[0].name = "English (SDH)", "subtitles deduplicated, English first")
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

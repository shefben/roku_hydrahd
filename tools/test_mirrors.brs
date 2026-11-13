' Offline checks for quality parsing and the xpass / fallback plumbing.
' Run via  python tools/test_vidfast.py
sub Main()
    q = Chr(34)
    nl = Chr(10)

    ' --- quality tiers ---------------------------------------------------
    check(HM_NominalHeight(1920, 800) = 1080, "2.40:1 1920x800 is a 1080p encode")
    check(HM_NominalHeight(1280, 534) = 720, "1280x534 is 720p")
    check(HM_NominalHeight(640, 266) = 360, "640x266 is 360p")
    check(HM_NominalHeight(3832, 1600) = 2160, "3832x1600 is 2160p")
    check(HM_NominalHeight(1440, 720) = 720, "2:1 1440x720 stays 720p")
    check(HM_NominalHeight(1440, 1080) = 1080, "4:3 1440x1080 is 1080p")
    check(HM_NominalHeight(854, 480) = 480, "854x480 is 480p")
    check(HM_NominalHeight(0, 1080) = 1080, "height-only falls back to height")
    check(HM_NominalHeight(0, 0) = 0, "no resolution is unknown")

    ' --- widescreen ladder, relative variant paths, CRLF ------------------
    cr = Chr(13)
    master = "#EXTM3U" + cr + nl + "#EXT-X-STREAM-INF:BANDWIDTH=1013160,CODECS=" + q + "mp4a.40.2,avc1.42c015" + q + ",RESOLUTION=640x266" + cr + nl + "low/index.m3u8?t=1" + cr + nl + "#EXT-X-STREAM-INF:BANDWIDTH=4200000,RESOLUTION=1920x800" + cr + nl + "high/index.m3u8?t=1" + cr + nl + "#EXT-X-STREAM-INF:BANDWIDTH=2100000,RESOLUTION=1280x534" + cr + nl + "/abs/mid.m3u8" + cr + nl
    out = HM_ParseMasterPlaylist(master, "https://cdn.example/pl/abc/master.m3u8?token=x")
    check(out.Count() = 3, "three variants parsed")
    if out.Count() = 3 then
        check(out[0].label = "1080p" and out[1].label = "720p" and out[2].label = "360p", "widescreen ladder labelled by tier, best first")
        check(out[0].url = "https://cdn.example/pl/abc/high/index.m3u8?t=1", "path-relative variant resolved against the playlist directory")
        check(out[1].url = "https://cdn.example/abs/mid.m3u8", "root-relative variant resolved against the origin")
        check(out[0].rawHeight = 800 and out[0].width = 1920, "raw dimensions kept")
        check(out[0].demuxed = false, "muxed variant not flagged")
        check(out[2].bandwidth = 1013160, "quoted CODECS with a comma does not break BANDWIDTH")
    end if

    ' --- separate audio renditions (vixsrc shape) ---------------------------
    master = "#EXTM3U" + nl + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=" + q + "audio" + q + ",NAME=" + q + "English" + q + ",DEFAULT=YES,URI=" + q + "https://v.example/playlist/1?type=audio" + q + nl + "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=" + q + "subs" + q + ",NAME=" + q + "English" + q + ",URI=" + q + "https://v.example/s" + q + nl + "#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS=" + q + "avc1.640028,mp4a.40.2" + q + ",RESOLUTION=854x480,AUDIO=" + q + "audio" + q + ",SUBTITLES=" + q + "subs" + q + nl + "https://v.example/playlist/1?type=video&rendition=480p" + nl + "#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080,AUDIO=" + q + "audio" + q + nl + "https://v.example/playlist/1?type=video&rendition=1080p" + nl
    out = HM_ParseMasterPlaylist(master, "https://v.example/playlist/1.m3u8?token=x")
    check(out.Count() = 2 and out[0].label = "1080p" and out[1].label = "480p", "separate-audio ladder parsed")
    if out.Count() = 2 then check(out[0].demuxed = true and out[1].demuxed = true, "variants with their own audio playlist flagged video-only")

    ' --- in-band audio group (no URI) is not demuxed -----------------------
    master = "#EXTM3U" + nl + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=" + q + "a" + q + ",NAME=" + q + "English" + q + ",DEFAULT=YES" + nl + "#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720,AUDIO=" + q + "a" + q + nl + "v.m3u8" + nl
    out = HM_ParseMasterPlaylist(master, "https://c.example/m.m3u8")
    check(out.Count() = 1 and out[0].demuxed = false, "audio group without URI is muxed")

    ' --- same tier twice, and no RESOLUTION ---------------------------------
    master = "#EXTM3U" + nl + "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080" + nl + "a.m3u8" + nl + "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080" + nl + "b.m3u8" + nl + "#EXT-X-STREAM-INF:BANDWIDTH=800000" + nl + "c.m3u8" + nl
    out = HM_ParseMasterPlaylist(master, "https://c.example/x/m.m3u8")
    check(out.Count() = 3, "duplicate tiers kept")
    if out.Count() = 3 then
        check(out[0].label = "1080p 6.0 Mbps" and out[1].label = "1080p 3.0 Mbps", "same-tier renditions told apart by bitrate, higher first")
        check(out[2].label = "800kbps" and out[2].height = 0, "variant without RESOLUTION labelled by bitrate")
    end if
    check(HM_ParseMasterPlaylist("#EXTM3U" + nl + "#EXTINF:6," + nl + "seg.ts" + nl, "https://c.example/m.m3u8").Count() = 0, "media playlist has no variants")

    ' --- xpass ---------------------------------------------------------------
    f = ParseJson(ReadAsciiFile("pkg:/tools/fixtures/xpass/data.json"))
    check(XP_ObfDecode(f.loaderToken) = f.playerPath, "loader string table entry decodes to the player script path")
    check(XP_ObfDecode(f.buildToken) = f.build, "player string table entry decodes to the build id")
    check(XP_FindObfString("['abc','" + f.buildToken + "','def']", "C3b2mY1IDwLS") = f.build, "build id found inside a string table")
    check(XP_Sha256Hex("spv3-data-response|" + f.build + "|" + f.path + "|" + f.token) = f.keyHex, "response key derivation")
    list = ParseJson(XP_Decrypt(f.build, f.path, f.token, f.body))
    check(list <> invalid and type(list) = "roArray" and list.Count() = f.count, "captured source list decrypts")
    if list <> invalid and list.Count() > 0 then check(list[0].name = f.firstName and list[0].url = f.firstUrl, "first source intact")
    check(XP_Decrypt("spv3-build-0-wrong", f.path, f.token, f.body) = "", "wrong build id fails closed")
    check(RP_XpassSrcRank({ label: "LUL 1", url: "https://play.xpass.top/mdata/a/0/playlist.json" }) < RP_XpassSrcRank({ label: "TIK 1", url: "https://play.xpass.top/mdata/b/1/playlist.json" }), "plain HLS backend ranked ahead of PNG-wrapped one")
    check(RP_XpassSrcRank({ label: "VIP 1", url: "https://play.xpass.top/vip/x" }) < RP_XpassSrcRank({ label: "MOL 1", url: "https://play.xpass.top/mdata/c/0/playlist.json" }), "known-good backend ahead of unknown")

    ' --- helpers ---------------------------------------------------------------
    check(VA_Unescape("https:\/\/h.example\/api.php?type=tv&tmdb=1") = "https://h.example/api.php?type=tv&tmdb=1", "JSON escapes removed from config URLs")
    check(RP_FirstUriLine("#EXTM3U" + nl + nl + "#EXT-X-VERSION:3" + nl + "  seg-1.ts  " + nl + "seg-2.ts") = "seg-1.ts", "first URI line")
    check(RP_CountOf("a#EXT-X-STREAM-INFb#EXT-X-STREAM-INF", "#EXT-X-STREAM-INF") = 2, "occurrence count")

    for each kind in ["movie", "tv"]
        pool = R_BuildFallbackCandidates(kind, "603", "tt0133093", 1, 2)
        check(pool.Count() >= 5, kind + " fallback pool populated")
        dead = false
        for each url in pool
            for each host in ["vidlove", "vidsrc.cc", "videasy", "vidking", "vidrock", "2embed", "moviesapi", "autoembed"]
                if Instr(1, url, host) > 0 then dead = true
            end for
        end for
        check(not dead, kind + " fallback pool has no retired hosts")
    end for
    check(R_BuildFallbackCandidates("movie", "", "tt0133093", 0, 0).Count() = 1, "imdb-only title still has a fallback")
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

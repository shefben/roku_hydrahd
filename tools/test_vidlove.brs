sub Main()
    payload = { source: {
        url: "https://cdn.example/api?token=test"
        qualities: [ { quality: "1080p", type: "mp4", url: "https://cdn.example/api?token=test" } ]
    }, subtitles: [ { url: "https://subs.example/en.vtt", language: "en", label: "English" } ] }
    result = RP_VidloveResult(payload)
    check(result <> invalid, "Vidlove envelope parsed")
    if result <> invalid then
        check(result.streamFormat = "mp4", "extensionless MP4 identified from source type")
        check(result.qualities[0].height = 1080, "quality height")
        check(result.subtitles[0].name = "English", "subtitle label")
        check(result.referer = "https://player.vidlove.cc/", "provider referer")
    end if
    check(RP_VidloveResult({ source: invalid }) = invalid, "empty source falls through")
    result = RP_VidloveResult({ source: { url: "https://cdn.example/api?token=test", type: "mp4" } })
    check(result.streamFormat = "mp4", "explicit source type without qualities")
    for each name in ["vidlove-movie.json", "vidlove-tv.json"]
        payload = ParseJSON(ReadAsciiFile("pkg:/tools/fixtures/hydra/" + name))
        result = RP_VidloveResult(payload)
        check(result.streamFormat = "mp4", "live API fixture uses MP4")
        check(result.qualities.Count() = payload.source.qualities.Count(), "live API fixture qualities preserved")
    end for
    print "FAILURES: "; m.failures
end sub

sub check(ok as Boolean, label as String)
    if m.failures = invalid then m.failures = 0
    if not ok then
        print "FAIL: "; label
        m.failures = m.failures + 1
    end if
end sub

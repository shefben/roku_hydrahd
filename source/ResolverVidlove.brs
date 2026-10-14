' Vidlove exposes the same JSON requests its embed page uses. Ask for AVC
' sources (no hevc flag), falling back when the preferred source is empty.
function RP_ResolveVidlove(embedUrl as String, refer as String, session as Object) as Object
    parts = CreateObject("roRegex", "/embed/(movie|tv)/(\d+)(?:/(\d+)/(\d+))?", "i").Match(embedUrl)
    if parts = invalid or parts.Count() < 3 then return invalid
    path = "/movie?id=" + parts[2]
    if parts[1] = "tv" then
        if parts.Count() < 5 or parts[3] = "" or parts[4] = "" then return invalid
        path = "/tv?id=" + parts[2] + "&season=" + parts[3] + "&episode=" + parts[4]
    end if
    headers = { "Referer": "https://player.vidlove.cc/", "Origin": "https://player.vidlove.cc", "Accept": "application/json" }
    for each sourceName in ["moviebox2", "moviebox"]
        url = "https://api.vidlove.cc" + path + "&mode=json&sources=" + sourceName
        response = HC_Get(session, url, headers, 8000)
        if response <> invalid and response.body <> "" then
            result = RP_VidloveResult(ParseJSON(response.body))
            if result <> invalid then return result
        end if
    end for
    return invalid
end function

function RP_VidloveResult(payload as Dynamic) as Object
    if payload = invalid or type(payload) <> "roAssociativeArray" then return invalid
    source = payload.source
    if source = invalid or type(source) <> "roAssociativeArray" then return invalid
    if source.url = invalid or type(source.url) <> "String" or source.url = "" then return invalid
    result = { url: source.url, streamFormat: U_StreamFormat(source.url), qualities: [], subtitles: [], chapters: [], referer: "https://player.vidlove.cc/", userAgent: "" }
    if source.type = "mp4" then result.streamFormat = "mp4"
    if source.type = "hls" then result.streamFormat = "hls"
    if source.qualities <> invalid and type(source.qualities) = "roArray" then
        for each quality in source.qualities
            if type(quality) = "roAssociativeArray" and quality.url <> invalid and quality.url <> "" then
                label = "Auto"
                if quality.quality <> invalid then label = quality.quality.ToStr()
                height = U_FirstMatch(label, "(\d{3,4})").ToInt()
                result.qualities.Push({ label: label, height: height, bandwidth: 0, url: quality.url })
                if result.qualities.Count() = 1 then
                    ' These signed proxy URLs have no file extension.
                    result.url = quality.url
                    if quality.type = "mp4" then result.streamFormat = "mp4"
                    if quality.type = "hls" then result.streamFormat = "hls"
                end if
            end if
        end for
    end if
    if payload.subtitles <> invalid and type(payload.subtitles) = "roArray" then
        for each track in payload.subtitles
            if type(track) = "roAssociativeArray" then
                url = ""
                if track.url <> invalid then url = track.url
                if url = "" and track.file <> invalid then url = track.file
                if url <> "" then
                    language = "en"
                    if track.language <> invalid then language = track.language
                    name = UCase(language)
                    if track.label <> invalid then name = track.label
                    result.subtitles.Push({ url: url, language: language, name: name })
                end if
            end if
        end for
    end if
    return result
end function

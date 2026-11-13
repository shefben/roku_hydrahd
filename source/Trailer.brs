' Trailer.brs - turn a YouTube trailer id (or a title) into a playable MP4.
'
' Roku has no web view, so an embed link is useless; the Video node needs a
' direct file. YouTube's app API ("innertube") hands the Android client one
' progressive MP4 with picture and sound together (itag 18, 360p), which is
' what a small preview box needs. Web / TV / iOS clients return either
' nothing or separate picture and sound files.
'
' This rides on an unofficial interface. When YouTube changes it these
' functions return "" and the banner simply shows no trailer.
' Synchronous: call from a Task.

function TR_AndroidUA() as String
    return "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
end function

function TR_IsVideoId(id as Dynamic) as Boolean
    if id = invalid then return false
    re = CreateObject("roRegex", "^[A-Za-z0-9_-]{11}$", "")
    return re.IsMatch(id)
end function

' Direct MP4 URL for a YouTube video id, or "".
function TR_StreamUrl(videoId as String) as String
    if not TR_IsVideoId(videoId) then return ""
    q = chr(34)
    body = "{" + q + "videoId" + q + ":" + q + videoId + q + ","
    body = body + q + "context" + q + ":{" + q + "client" + q + ":{"
    body = body + q + "clientName" + q + ":" + q + "ANDROID" + q + ","
    body = body + q + "clientVersion" + q + ":" + q + "20.10.38" + q + ","
    body = body + q + "androidSdkVersion" + q + ":30,"
    body = body + q + "osName" + q + ":" + q + "Android" + q + ","
    body = body + q + "osVersion" + q + ":" + q + "11" + q + ","
    body = body + q + "hl" + q + ":" + q + "en" + q + "," + q + "gl" + q + ":" + q + "US" + q + "}},"
    body = body + q + "contentCheckOk" + q + ":true," + q + "racyCheckOk" + q + ":true}"

    session = HC_NewSession()
    res = HC_Post(session, "https://www.youtube.com/youtubei/v1/player?prettyPrint=false", { "Content-Type": "application/json", "User-Agent": TR_AndroidUA() }, body, 8000)
    HC_Close(session)
    if not res.ok or res.body = "" then return ""
    data = ParseJson(res.body)
    if data = invalid then return ""
    sd = data["streamingData"]
    if sd = invalid then return ""
    formats = sd["formats"]
    if formats = invalid or type(formats) <> "roArray" then return ""
    for each f in formats
        u = f["url"]
        mime = f["mimeType"]
        if u <> invalid and u <> "" and mime <> invalid and Left(mime, 9) = "video/mp4" then return u
    end for
    return ""
end function

' First video YouTube returns for "<title> <year> official trailer", or "".
' Used for TV shows, whose HydraHD pages carry no trailer link.
function TR_SearchId(title as String, year as String, kind as String) as String
    if title = invalid or title = "" then return ""
    ' Keep the query to plain words so it drops into the JSON body as is.
    clean = CreateObject("roRegex", "[^A-Za-z0-9 ]+", "").ReplaceAll(title, " ")
    clean = U_Trim(clean)
    if clean = "" then return ""
    query = clean
    if year <> invalid and CreateObject("roRegex", "^\d{4}$", "").IsMatch(year) then query = query + " " + year
    if kind = "tv" then query = query + " tv series"
    query = query + " official trailer"

    q = chr(34)
    ' params = "videos only" filter; it also keeps the response small.
    body = "{" + q + "query" + q + ":" + q + query + q + "," + q + "params" + q + ":" + q + "EgIQAQ%3D%3D" + q + ","
    body = body + q + "context" + q + ":{" + q + "client" + q + ":{"
    body = body + q + "clientName" + q + ":" + q + "WEB" + q + ","
    body = body + q + "clientVersion" + q + ":" + q + "2.20250312.04.00" + q + ","
    body = body + q + "hl" + q + ":" + q + "en" + q + "," + q + "gl" + q + ":" + q + "US" + q + "}}}"

    session = HC_NewSession()
    res = HC_Post(session, "https://www.youtube.com/youtubei/v1/search?prettyPrint=false", { "Content-Type": "application/json" }, body, 8000)
    HC_Close(session)
    if not res.ok or res.body = "" then return ""
    return U_FirstMatch(res.body, chr(34) + "videoId" + chr(34) + ":" + chr(34) + "([A-Za-z0-9_-]{11})" + chr(34))
end function

' Trailer MP4 for a title. videoId may be "" (then it is searched for).
function TR_Resolve(videoId as String, title as String, year as String, kind as String) as String
    id = videoId
    if not TR_IsVideoId(id) then id = TR_SearchId(title, year, kind)
    if not TR_IsVideoId(id) then return ""
    return TR_StreamUrl(id)
end function

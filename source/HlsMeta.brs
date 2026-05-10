' HlsMeta.brs - HLS master-playlist parsing, chapter / "skip intro"
' detection, and generic subtitle scraping for the in-channel resolver.
'
' This is the post-resolve enrichment step. After a provider returns a
' stream URL, we fetch the master m3u8 and extract:
'   * `qualities` - one entry per #EXT-X-STREAM-INF rendition so the
'      PlayerView quality overlay shows real resolutions instead of
'      just "Auto".
'   * `chapters`  - skip-intro / skip-outro / recap markers from either
'      JSON config strings in the embed HTML or #EXT-X-DATERANGE entries
'      in the playlist itself.
'   * `subtitles` - any plain .vtt / .srt URLs embedded in the page,
'      used to top up subtitle lists from providers that don't expose
'      them via their JSON API.
'
' Direct port of server.py:348 (parse_master_playlist),
' server.py:430 (extract_chapters_from_html),
' server.py:478 (extract_chapters_from_hls),
' server.py:384 (collect_subtitles).

' --- Quality / variant parsing ---------------------------------------

' Fetch the master playlist at streamUrl and return an array of variant
' records. Returns [] if streamUrl is empty, not HLS, unreachable, or
' isn't actually a master (no #EXT-X-STREAM-INF).
function HM_FetchQualities(streamUrl as String, refer as String, session as Object) as Object
    out = []
    if streamUrl = invalid or streamUrl = "" then return out
    if Instr(1, LCase(streamUrl), ".m3u8") = 0 then return out

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, streamUrl, headers, 6000)
    if res = invalid or res.body = "" then return out
    if Instr(1, res.body, "#EXT-X-STREAM-INF") = 0 then return out
    return HM_ParseMasterPlaylist(res.body, streamUrl)
end function

function HM_ParseMasterPlaylist(text as String, baseUrl as String) as Object
    out = []
    if text = invalid or text = "" then return out
    lines = text.Tokenize(chr(10))
    if lines = invalid then return out

    n = lines.Count()
    for i = 0 to n - 1
        line = lines[i]
        if Left(line, 17) <> "#EXT-X-STREAM-INF" then continue for

        attrs = HM_ParseAttrs(line)
        bw = 0
        if attrs.BANDWIDTH <> invalid then bw = attrs.BANDWIDTH.ToInt()
        height = 0
        resStr = ""
        if attrs.RESOLUTION <> invalid then resStr = attrs.RESOLUTION
        if resStr <> "" then
            xIdx = Instr(1, resStr, "x")
            if xIdx > 0 and xIdx < Len(resStr) then
                height = Mid(resStr, xIdx + 1).ToInt()
            end if
        end if

        ' Variant URL is the next non-comment, non-empty line.
        varUrl = ""
        for j = i + 1 to n - 1
            cand = U_Trim(lines[j])
            if cand = "" then continue for
            if Left(cand, 1) = "#" then continue for
            varUrl = cand
            exit for
        end for
        if varUrl = "" then continue for
        varUrl = RP_AbsUrl(varUrl, baseUrl)

        label = "Variant"
        if height > 0 then
            label = height.ToStr() + "p"
        else if bw > 0 then
            label = (bw \ 1000).ToStr() + "kbps"
        end if

        out.Push({
            label: label
            height: height
            bandwidth: bw
            url: varUrl
        })
    end for

    ' Sort height-descending so PlayerView's auto-pick lands on the
    ' highest available rendition. Insertion sort is fine for the
    ' typical 3-6 variant count.
    for i = 1 to out.Count() - 1
        cur = out[i]
        curH = cur.height
        if curH = invalid then curH = 0
        j = i - 1
        while j >= 0
            prevH = out[j].height
            if prevH = invalid then prevH = 0
            if prevH >= curH then exit while
            out[j + 1] = out[j]
            j = j - 1
        end while
        out[j + 1] = cur
    end for
    return out
end function

' Parse a single #EXT-X-* line's KEY=VALUE pairs. Quoted values keep
' their content; bare values stop at the next comma.
function HM_ParseAttrs(line as String) as Object
    out = {}
    if line = invalid or line = "" then return out
    re = CreateObject("roRegex", "([A-Z0-9-]+)=(" + chr(34) + "[^" + chr(34) + "]*" + chr(34) + "|[^,]*)", "g")
    matches = re.matchAll(line)
    if matches = invalid then return out
    for each m in matches
        if m.Count() < 3 then continue for
        k = m[1]
        v = m[2]
        if Len(v) >= 2 and Left(v, 1) = chr(34) and Right(v, 1) = chr(34) then
            v = Mid(v, 2, Len(v) - 2)
        end if
        out[k] = v
    end for
    return out
end function

' --- Chapter / skip-intro detection ----------------------------------

' Map a free-form label ("intro", "opening", "credits", ...) to the
' three canonical kinds PlayerView understands.
function HM_CoerceKind(label as String) as String
    if label = invalid or label = "" then return ""
    s = LCase(label)
    if Instr(1, s, "intro") > 0 or Instr(1, s, "opening") > 0 then return "intro"
    if Instr(1, s, "outro") > 0 or Instr(1, s, "credit") > 0 or Instr(1, s, "ending") > 0 then return "outro"
    if Instr(1, s, "recap") > 0 then return "recap"
    return ""
end function

' Look for skipIntro / skipOutro / introStart-introEnd JSON blobs in the
' raw embed HTML. Returns array of { kind, start, end }.
function HM_ExtractChaptersHtml(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    seen = {}

    jsonRe = CreateObject("roRegex", chr(34) + "(?:skip)?(intro|outro|credits|recap|opening|ending)" + chr(34) + "\s*:\s*\{\s*" + chr(34) + "start" + chr(34) + "\s*:\s*(\d+(?:\.\d+)?)\s*,\s*" + chr(34) + "end" + chr(34) + "\s*:\s*(\d+(?:\.\d+)?)", "ig")
    jms = jsonRe.matchAll(html)
    if jms <> invalid then
        for each mt in jms
            if mt.Count() < 4 then continue for
            kind = HM_CoerceKind(mt[1])
            if kind = "" or seen.DoesExist(kind) then continue for
            startVal = mt[2].ToFloat()
            endVal = mt[3].ToFloat()
            if endVal > startVal then
                out.Push({ kind: kind, start: startVal, end: endVal })
                seen[kind] = true
            end if
        end for
    end if

    ' Numeric pair fallback: introStart=60, introEnd=90 (or with ":" / quotes
    ' between the two halves). The prefix and suffix names must match.
    pairRe = CreateObject("roRegex", "(intro|outro|credits|recap|opening|ending)[_\-]?start[" + chr(34) + "\s:=,]+(\d+(?:\.\d+)?)[\s\S]{0,200}?(?:\1)[_\-]?end[" + chr(34) + "\s:=,]+(\d+(?:\.\d+)?)", "ig")
    pms = pairRe.matchAll(html)
    if pms <> invalid then
        for each mt in pms
            if mt.Count() < 4 then continue for
            kind = HM_CoerceKind(mt[1])
            if kind = "" or seen.DoesExist(kind) then continue for
            startVal = mt[2].ToFloat()
            endVal = mt[3].ToFloat()
            if endVal > startVal then
                out.Push({ kind: kind, start: startVal, end: endVal })
                seen[kind] = true
            end if
        end for
    end if

    return out
end function

' Look for #EXT-X-DATERANGE entries in the HLS playlist. If the input
' is a master playlist that doesn't itself carry DATERANGE entries,
' descend into the first variant once and re-scan.
function HM_ExtractChaptersHls(streamUrl as String, refer as String, session as Object) as Object
    out = []
    if streamUrl = invalid or streamUrl = "" then return out

    headers = {}
    if refer <> "" then headers["Referer"] = refer
    res = HC_Get(session, streamUrl, headers, 6000)
    if res = invalid or res.body = "" then return out
    text = res.body
    if Instr(1, text, "#EXT-X-DATERANGE") = 0 then
        ' Master playlist often has no DATERANGE; check the first variant.
        if Instr(1, text, "#EXT-X-STREAM-INF") = 0 then return out
        firstVariant = ""
        lines = text.Tokenize(chr(10))
        if lines = invalid then return out
        for i = 0 to lines.Count() - 1
            cand = U_Trim(lines[i])
            if cand = "" or Left(cand, 1) = "#" then continue for
            firstVariant = cand
            exit for
        end for
        if firstVariant = "" then return out
        firstVariant = RP_AbsUrl(firstVariant, streamUrl)
        res2 = HC_Get(session, firstVariant, headers, 6000)
        if res2 = invalid or res2.body = "" then return out
        text = res2.body
        if Instr(1, text, "#EXT-X-DATERANGE") = 0 then return out
    end if

    seen = {}
    lines = text.Tokenize(chr(10))
    if lines = invalid then return out
    for i = 0 to lines.Count() - 1
        line = lines[i]
        if Left(line, 16) <> "#EXT-X-DATERANGE" then continue for
        attrs = HM_ParseAttrs(line)
        cls = ""
        if attrs.CLASS <> invalid then cls = attrs.CLASS
        kind = HM_CoerceKind(cls)
        if kind = "" and attrs.ID <> invalid then kind = HM_CoerceKind(attrs.ID)
        if kind = "" or seen.DoesExist(kind) then continue for
        startStr = ""
        if attrs.X_START <> invalid then startStr = attrs.X_START
        if startStr = "" and attrs["X-START"] <> invalid then startStr = attrs["X-START"]
        if startStr = "" and attrs["X-COM-INTRO-START"] <> invalid then startStr = attrs["X-COM-INTRO-START"]
        startVal = 0.0
        if startStr <> "" then startVal = startStr.ToFloat()
        endStr = ""
        if attrs["X-END"] <> invalid then endStr = attrs["X-END"]
        if endStr = "" and attrs["X-COM-INTRO-END"] <> invalid then endStr = attrs["X-COM-INTRO-END"]
        endVal = 0.0
        if endStr <> "" then
            endVal = endStr.ToFloat()
        else if attrs.DURATION <> invalid then
            endVal = startVal + attrs.DURATION.ToFloat()
        end if
        if endVal > startVal then
            out.Push({ kind: kind, start: startVal, end: endVal })
            seen[kind] = true
        end if
    end for
    return out
end function

' --- Generic subtitle scraping ---------------------------------------

' Pull every plain .vtt / .srt URL out of the page HTML. Used as a
' top-up for providers that surface tracks via static URLs in the page
' rather than via their JSON API.
function HM_ScrapeSubs(html as String) as Object
    out = []
    if html = invalid or html = "" then return out
    re = CreateObject("roRegex", "(https?://[^" + chr(34) + "'\\\s>]+\.(?:vtt|srt))", "ig")
    matches = re.matchAll(html)
    if matches = invalid then return out
    seen = {}
    for each mt in matches
        if mt.Count() < 2 then continue for
        url = mt[1]
        if seen.DoesExist(url) then continue for
        seen[url] = true
        lang = "en"
        langRe = CreateObject("roRegex", "[/_-]([a-z]{2})[/._-]", "i")
        lm = langRe.match(url)
        if lm <> invalid and lm.Count() >= 2 then lang = LCase(lm[1])
        out.Push({ url: url, language: lang, name: UCase(lang) })
    end for
    return out
end function

' Merge subtitle arrays, deduping on url. Provider-supplied subs
' (typed labels, language hints) take priority over scraped ones.
function HM_MergeSubs(primary as Object, extra as Object) as Object
    out = []
    seen = {}
    if primary <> invalid and type(primary) = "roArray" then
        for each s in primary
            if type(s) <> "roAssociativeArray" then continue for
            if s.url = invalid or s.url = "" then continue for
            if seen.DoesExist(s.url) then continue for
            seen[s.url] = true
            out.Push(s)
        end for
    end if
    if extra <> invalid and type(extra) = "roArray" then
        for each s in extra
            if type(s) <> "roAssociativeArray" then continue for
            if s.url = invalid or s.url = "" then continue for
            if seen.DoesExist(s.url) then continue for
            seen[s.url] = true
            out.Push(s)
        end for
    end if
    return out
end function

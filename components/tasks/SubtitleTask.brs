' SubtitleTask.brs - Fetch a WebVTT/SRT subtitle file and parse it into a
' flat array of timed cues so PlayerView can render captions itself (which
' is the only way to honor the user's caption size/color/background on
' Roku - native subtitleTrack rendering is styled by the system, not the
' app). Each cue: { s: startSec(float), e: endSec(float), text: string }.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    url = m.top.url
    if url = invalid or url = "" then
        m.top.cues = []
        return
    end if
    ref = ""
    if m.top.referer <> invalid then ref = m.top.referer
    body = HA_Get(url, ref)
    m.top.cues = ST_ParseCues(body)
end sub

function ST_ParseCues(text as Dynamic) as Object
    cues = []
    if text = invalid or text = "" then return cues
    text = text.Replace(Chr(13), "")
    lines = text.Tokenize(Chr(10))   ' skips blank lines; we detect cues by the "-->" line
    arrowRe = CreateObject("roRegex", "(\d{1,2}:)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->\s*(\d{1,2}:)?(\d{1,2}):(\d{2})[.,](\d{1,3})", "")
    numRe = CreateObject("roRegex", "^\d+$", "")
    cur = invalid
    for each ln in lines
        mm = arrowRe.Match(ln)
        if mm <> invalid and mm.Count() >= 9 then
            if cur <> invalid and cur.text <> "" then cues.Push(cur)
            cur = {
                s:    ST_ToSec(mm[1], mm[2], mm[3], mm[4])
                e:    ST_ToSec(mm[5], mm[6], mm[7], mm[8])
                text: ""
            }
        else if cur <> invalid then
            t = U_Trim(ln)
            if t <> "" and not numRe.IsMatch(t) then
                t = U_StripTags(t)         ' drop <i>/<b>/<c> VTT tags
                if t <> "" then
                    if cur.text = "" then
                        cur.text = t
                    else
                        cur.text = cur.text + Chr(10) + t
                    end if
                end if
            end if
        end if
    end for
    if cur <> invalid and cur.text <> "" then cues.Push(cur)
    return cues
end function

function ST_ToSec(hPart as String, mm as String, ss as String, ms as String) as Float
    h = 0
    if hPart <> invalid and hPart <> "" then h = Left(hPart, Len(hPart) - 1).ToInt()
    msPad = ms
    while Len(msPad) < 3
        msPad = msPad + "0"
    end while
    frac = msPad.ToInt() / 1000.0
    return (h * 3600) + (mm.ToInt() * 60) + (ss.ToInt() * 1.0) + frac
end function

' Utils.brs - String, regex, and JSON helpers reused by every screen.

function U_Trim(s as String) as String
    if s = invalid then return ""
    re = CreateObject("roRegex", "^\s+|\s+$", "g")
    return re.replaceAll(s, "")
end function

function U_HtmlDecode(s as String) as String
    if s = invalid or s = "" then return ""
    out = s
    out = out.Replace("&amp;", "&")
    out = out.Replace("&#039;", "'")
    out = out.Replace("&#39;", "'")
    out = out.Replace("&apos;", "'")
    out = out.Replace("&quot;", chr(34))
    out = out.Replace("&lt;", "<")
    out = out.Replace("&gt;", ">")
    out = out.Replace("&nbsp;", " ")
    out = out.Replace("&hellip;", "...")
    out = out.Replace("&mdash;", "-")
    out = out.Replace("&ndash;", "-")
    re = CreateObject("roRegex", "&#(\d{1,5});", "g")
    matches = re.matchAll(out)
    if matches <> invalid then
        for each mt in matches
            num = mt[1].ToInt()
            if num > 0 and num < 1114112 then
                out = out.Replace(mt[0], chr(num))
            end if
        end for
    end if
    return out
end function

function U_StripTags(s as String) as String
    if s = invalid then return ""
    re = CreateObject("roRegex", "<[^>]+>", "g")
    return U_Trim(re.replaceAll(s, ""))
end function

function U_FirstMatch(haystack as String, pattern as String) as String
    re = CreateObject("roRegex", pattern, "is")
    m = re.match(haystack)
    if m <> invalid and m.Count() >= 2 then return m[1]
    return ""
end function

function U_AllMatches(haystack as String, pattern as String) as Object
    re = CreateObject("roRegex", pattern, "is")
    out = []
    m = re.matchAll(haystack)
    if m = invalid then return out
    return m
end function

function U_UrlEncode(s as String) as String
    if s = invalid then return ""
    enc = CreateObject("roUrlTransfer")
    return enc.escape(s)
end function

function U_AbsUrl(href as String, base as String) as String
    if href = invalid or href = "" then return ""
    h = U_Trim(href)
    if h.Left(4) = "http" then return h
    if h.Left(2) = "//" then return "https:" + h
    if h.Left(1) = "/" then return base + h
    return base + "/" + h
end function

function U_TmdbImage(url as String, size as String) as String
    if url = invalid or url = "" then return ""
    re = CreateObject("roRegex", "image\.tmdb\.org/t/p/[^/]+", "i")
    if size = "" then size = "w500"
    return re.replace(url, "image.tmdb.org/t/p/" + size)
end function

function U_DefaultPoster() as String
    return "https://image.tmdb.org/t/p/w500/"
end function

function U_LooksHls(url as String) as Boolean
    if url = invalid then return false
    u = LCase(url)
    return Instr(1, u, ".m3u8") > 0 or Instr(1, u, "/hls/") > 0
end function

function U_LooksMp4(url as String) as Boolean
    if url = invalid then return false
    return Instr(1, LCase(url), ".mp4") > 0
end function

function U_StreamFormat(url as String) as String
    if U_LooksHls(url) then return "hls"
    if U_LooksMp4(url) then return "mp4"
    if Instr(1, LCase(url), ".mpd") > 0 then return "dash"
    return "hls"
end function

function U_PrefDefault(key as String, default as Dynamic) as Dynamic
    reg = CreateObject("roRegistrySection", "HydraHD")
    if reg.Exists(key) then
        v = reg.Read(key)
        if type(default) = "Boolean" then
            return v = "true"
        else if type(default) = "Integer" or type(default) = "roInt" then
            return v.ToInt()
        end if
        return v
    end if
    return default
end function

sub U_PrefSet(key as String, value as Dynamic)
    reg = CreateObject("roRegistrySection", "HydraHD")
    reg.Write(key, value.ToStr())
    reg.Flush()
end sub

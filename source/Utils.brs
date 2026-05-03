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

' Default resolver URL baked in at build time by tools/build_zip.bat.
' Keep the trailing comment marker - the build script searches for it
' to inject the user's LAN IP without disturbing anything else.
function U_DefaultResolverUrl() as String
    return "http://192.168.3.180:8787"  ' build:resolver-url
end function

' Stable per-(device, channel) opaque ID. The resolver uses this to
' isolate cookie jars / session state so two Rokus on the same LAN
' don't trample each other's playback. The first call generates the
' value; subsequent calls return the cached string.
function U_ClientId() as String
    di = CreateObject("roDeviceInfo")
    if di <> invalid then
        ' GetChannelClientId is stable per channel per device and the
        ' preferred opaque identifier on Roku OS 7.5+. It's already a
        ' UUID-shaped string so no encoding needed.
        cid = di.GetChannelClientId()
        if cid <> invalid and cid <> "" then return cid
    end if
    ' Fallback for ancient devices / firmware: cache a random id in the
    ' channel registry so the same Roku keeps the same cid across runs.
    reg = CreateObject("roRegistrySection", "HydraHD")
    if reg.Exists("clientId") then return reg.Read("clientId")
    rand = CreateObject("roDeviceInfo").GetRandomUUID()
    if rand = invalid or rand = "" then rand = "roku-" + CreateObject("roDateTime").AsSeconds().ToStr()
    reg.Write("clientId", rand)
    reg.Flush()
    return rand
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

' --- Favorite-toggle UI helpers -------------------------------------
'
' PosterItem watches each cell ContentNode's ``favBump`` field and
' re-queries the favorite state whenever it changes. Views call
' ``U_BumpCellFavorite(cell)`` after toggling a favorite so the star
' overlay refreshes without rebuilding the whole grid. Multiple cells
' can point at the same title (Continue Watching, My List, and a
' provider row all stack the same href) so ``U_BumpAllCellsByUrl``
' walks the content tree and bumps every match.

sub U_BumpCellFavorite(cell as Object)
    if cell = invalid then return
    if not cell.hasField("favBump") then
        cell.addField("favBump", "integer", true)
    end if
    cur = cell.favBump
    if cur = invalid then cur = 0
    cell.favBump = cur + 1
end sub

sub U_BumpAllCellsByUrl(content as Object, url as String)
    if content = invalid or url = invalid or url = "" then return
    n = content.getChildCount()
    if n <= 0 then return
    for i = 0 to n - 1
        child = content.getChild(i)
        if child <> invalid then
            cu = child.url
            if cu <> invalid and cu = url then
                U_BumpCellFavorite(child)
            end if
            ' RowList content nests cells under row containers; recurse
            ' so the bump reaches matches at any depth.
            if child.getChildCount() > 0 then
                U_BumpAllCellsByUrl(child, url)
            end if
        end if
    end for
end sub

' Toggle favorite state for a focused poster cell and bump every cell
' with the same URL so the star indicator refreshes everywhere it's
' currently visible. Returns true on toggle, false if the cell wasn't
' favoritable (no href/url).
function U_ToggleFavoriteForCell(cell as Object, content as Object) as Boolean
    if cell = invalid then return false
    href = ""
    if cell.url <> invalid then href = cell.url
    if href = "" then return false
    title = ""
    if cell.title <> invalid then title = cell.title
    poster = ""
    if cell.HDPosterUrl <> invalid then poster = cell.HDPosterUrl
    tmdb = ""
    if cell.id <> invalid then tmdb = cell.id
    kind = ""
    if cell.contentType <> invalid then kind = cell.contentType
    if W_IsFavorite("", href) then
        W_RemoveFavorite("", href)
    else
        W_AddFavorite({
            title:  title
            poster: poster
            href:   href
            imdb:   ""
            tmdb:   tmdb
            kind:   kind
        })
    end if
    U_BumpAllCellsByUrl(content, href)
    return true
end function

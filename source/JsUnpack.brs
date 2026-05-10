' JsUnpack.brs - Dean Edwards eval(p,a,c,k,e,d) unpacker.
'
' Despite living inside an eval() syntax, this isn't real JavaScript:
' it's a deterministic base-N digit-substitution algorithm. The packed
' header is shaped like:
'   eval(function(p,a,c,k,e,d){...}('payload',base,count,'key1|key2|...'.split('|')))
' We extract p (payload), a (base 2..62 typically), c (count), and the k
' word list, then for i=c-1..0 we replace every \b<digit-string-base-a>\b
' token in p with k[i] when k[i] is non-empty. The result is the original
' source the obfuscator started with.
'
' Reference port: server.py:947-967 (_to_base + unpack_packed).
'
' Used by: lookmovie2, vidora.stream, the JWPlayer-anywhere chain and
' the Mixdrop downstream extractor (Phase 4). All four can re-use this
' single file.

' --- _to_base -------------------------------------------------------
'
' Convert non-negative integer n to its base-`base` representation
' using the alphabet 0-9 a-z. Mirrors Python's _to_base: recursive
' but bounded by ceil(log_base(n)) so a 6-digit base-2 expansion is
' the worst we'll ever see on the small i values used by the packer.

function JU_ToBase(n as Integer, base as Integer) as String
    if base < 2 then base = 2
    if base > 62 then base = 62
    ' Dean Edwards convention: digits, then lowercase, then uppercase.
    ' Extending past base 36 is required for Mixdrop's packer (base 62).
    digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if n < 0 then n = 0
    if n < base then return Mid(digits, n + 1, 1)
    return JU_ToBase(n \ base, base) + Mid(digits, (n mod base) + 1, 1)
end function

' --- unpack_packed --------------------------------------------------
'
' Returns the decoded source on success or "" if the input doesn't
' contain a recognisable packed block.
'
' Notes on porting from Python re.sub(r"\b" + token + r"\b", ...):
' - roRegex IS PCRE-flavoured, so \b matches the same word-boundary
'   semantics on Roku. Confirmed via developer.roku.com/.../roregex.md.
' - Token contains only [0-9a-z] from JU_ToBase, so escaping isn't
'   needed in the regex - those are all literal characters.
' - replaceAll handles every occurrence in one pass, matching Python's
'   re.sub default behaviour.

function JU_UnpackPacked(packed as String) as String
    if packed = invalid or packed = "" then return ""

    ' Find the closing }(...) call site. The "is" flags make the regex
    ' match across newlines because some packed blobs are pretty-printed
    ' or contain inline comments.
    re = CreateObject("roRegex", "\}\('([\s\S]*?)',(\d+),(\d+),'([\s\S]*?)'\.split\('\|'\)", "is")
    m = re.match(packed)
    if m = invalid or m.Count() < 5 then return ""

    p = m[1]
    a = m[2].ToInt()
    c = m[3].ToInt()
    if a < 2 then a = 2
    if c < 0 then return ""

    kRaw = m[4]
    k = kRaw.Tokenize("|")
    ' Tokenize collapses runs of separators, but the packer relies on
    ' empty slots between consecutive '|' to skip indices whose token is
    ' the empty string. Rebuild the list manually instead.
    kList = []
    cur = ""
    i = 1
    while i <= Len(kRaw)
        ch = Mid(kRaw, i, 1)
        if ch = "|" then
            kList.Push(cur)
            cur = ""
        else
            cur = cur + ch
        end if
        i = i + 1
    end while
    kList.Push(cur)

    out = p
    idx = c - 1
    while idx >= 0
        if idx < kList.Count() then
            replacement = kList[idx]
            if replacement <> "" then
                token = JU_ToBase(idx, a)
                pat = "\b" + token + "\b"
                rx = CreateObject("roRegex", pat, "g")
                out = rx.replaceAll(out, replacement)
            end if
        end if
        idx = idx - 1
    end while

    return out
end function

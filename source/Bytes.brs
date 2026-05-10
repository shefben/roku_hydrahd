' Bytes.brs - byte-level math helpers shared by Phase 4b crypto code.
'
' BrightScript exposes bitwise AND / OR / NOT on Integer values but has
' no native XOR operator. We synthesize XOR via the math identity
' a XOR b = a + b - 2 * (a AND b), which works for any integer width
' and is faster than the bit-loop alternative.
'
' StrToLong is a manual decimal-string parser because roString.ToInt()
' truncates anything above 2^31-1 (so a 13-digit ms-since-epoch like
' 1746735123456 silently rounds), and Val(s, 10) returns Float which
' loses precision past ~7 digits.

function B_Xor(a as Integer, b as Integer) as Integer
    return a + b - 2 * (a AND b)
end function

' Element-wise XOR of two byte arrays. Output length is min of inputs.
function B_XorBytes(a as Object, b as Object) as Object
    out = CreateObject("roByteArray")
    if a = invalid or b = invalid then return out
    n = a.Count()
    if b.Count() < n then n = b.Count()
    for i = 0 to n - 1
        out.Push(B_Xor(a[i], b[i]))
    end for
    return out
end function

' Decimal string -> LongInteger. Skips non-digit characters defensively.
' Returns 0 on empty or all-non-digit input.
function B_StrToLong(s as String) as LongInteger
    n# = 0&
    if s = invalid or s = "" then return n#
    for i = 1 to Len(s)
        c = Asc(Mid(s, i, 1))
        if c >= 48 and c <= 57 then
            n# = n# * 10& + (c - 48)
        end if
    end for
    return n#
end function

' Two-digit zero-padded lowercase hex of a byte.
function B_ByteToHex(b as Integer) as String
    h = StrI(b AND 255, 16)
    h = U_Trim(h)
    if Len(h) = 1 then h = "0" + h
    return LCase(h)
end function

' Returns a sub-range of a byte array as a new byte array.
function B_Slice(ba as Object, startIdx as Integer, endIdx as Integer) as Object
    out = CreateObject("roByteArray")
    if ba = invalid then return out
    n = ba.Count()
    if startIdx < 0 then startIdx = 0
    if endIdx > n then endIdx = n
    if startIdx >= endIdx then return out
    for i = startIdx to endIdx - 1
        out.Push(ba[i])
    end for
    return out
end function

' Rc4.brs - RC4 stream cipher.
'
' Used by the Vidking / Videasy WASM-equivalent decryption pipeline
' (Phase 4b). All operations are byte-level via roByteArray to avoid
' the immutable-string concat penalty.
'
' RC4 is symmetric: the same KSA + PRGA round both encrypts and decrypts.
' Each PRGA call mutates the S-box passed in, so make a copy before
' running the same KSA output through PRGA twice if you need to.

' Key Scheduling Algorithm. Input: roByteArray of key bytes (any length).
' Returns: roByteArray of 256 bytes representing the initial S-box.
function R4_KSA(keyBytes as Object) as Object
    S = CreateObject("roByteArray")
    for i = 0 to 255
        S.Push(i)
    end for
    if keyBytes = invalid or keyBytes.Count() = 0 then return S
    keyLen = keyBytes.Count()
    j = 0
    for i = 0 to 255
        j = (j + S[i] + keyBytes[i mod keyLen]) AND 255
        tmp = S[i]
        S[i] = S[j]
        S[j] = tmp
    end for
    return S
end function

' Pseudo-Random Generation Algorithm. Mutates S in place. XORs the
' generated keystream with each input byte and returns the result.
function R4_PRGA(S as Object, dataBytes as Object) as Object
    out = CreateObject("roByteArray")
    if S = invalid or dataBytes = invalid then return out
    i = 0
    j = 0
    n = dataBytes.Count()
    for k = 0 to n - 1
        i = (i + 1) AND 255
        j = (j + S[i]) AND 255
        tmp = S[i]
        S[i] = S[j]
        S[j] = tmp
        ks = S[(S[i] + S[j]) AND 255]
        out.Push(B_Xor(dataBytes[k], ks))
    end for
    return out
end function

' Convenience: KSA + PRGA in one shot, leaving the caller's S-box copy
' alone. Used when you only need a single pass over data.
function R4_Crypt(keyBytes as Object, dataBytes as Object) as Object
    S = R4_KSA(keyBytes)
    return R4_PRGA(S, dataBytes)
end function

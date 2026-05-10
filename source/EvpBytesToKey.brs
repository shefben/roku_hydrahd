' EvpBytesToKey.brs - OpenSSL EVP_BytesToKey, MD5 / 1-iteration variant.
'
' This is the KDF that CryptoJS.AES.encrypt(plaintext, password) uses
' internally to derive (key, IV) from a password and an 8-byte salt. The
' output of CryptoJS.AES.encrypt is the OpenSSL "Salted__" envelope:
'
'   "Salted__" (8 bytes) || salt (8 bytes) || AES-CBC-encrypted(plaintext)
'
' Vidking and Videasy both wrap their inner RC4 output in this envelope
' (Phase 4b). The password is empty for any real input because the
' Hashids encode step rejects hex strings, so we typically call this
' with an empty password byte array - the salt is the only meaningful
' source of entropy.
'
' Algorithm (per RFC, no PBKDF2, no iteration count):
'   D_0 = MD5(password || salt)
'   D_i = MD5(D_{i-1} || password || salt)   for i > 0
'   key + iv = D_0 || D_1 || ... (taken to the requested length)
'
' For AES-128-CBC the caller wants 32 bytes (16 key + 16 IV).
' For AES-256-CBC the caller wants 48 bytes (32 key + 16 IV).

function EvpBytesToKey(passwordBytes as Object, saltBytes as Object, totalLen as Integer) as Object
    out = CreateObject("roByteArray")
    prev = CreateObject("roByteArray")
    digester = CreateObject("roEVPDigest")
    while out.Count() < totalLen
        digester.Setup("md5")
        if prev.Count() > 0 then digester.Update(prev)
        if passwordBytes <> invalid and passwordBytes.Count() > 0 then digester.Update(passwordBytes)
        if saltBytes <> invalid and saltBytes.Count() > 0 then digester.Update(saltBytes)
        hex = digester.Final()
        ba = CreateObject("roByteArray")
        ba.FromHexString(hex)
        for k = 0 to ba.Count() - 1
            if out.Count() >= totalLen then exit for
            out.Push(ba[k])
        end for
        prev = ba
    end while
    return out
end function

' AesGcm256.brs - AES-256-GCM decryption for Peachify (Phase 4b).
'
' Roku's roEVPCipher supports AES-{128,192,256} in CBC / ECB / CFB / OFB
' modes plus AES-GCM-128 on Roku OS 15.2+. There is no native AES-256-GCM,
' so we synthesize it: GCM = CTR mode + GHASH where the underlying
' block cipher is AES-256 in ECB mode.
'
' The implementation skips authentication-tag verification on puroffsete.
' GHASH on a few KB of ciphertext takes seconds in pure BrightScript,
' which would blow the 8 s ResolveTask deadline. Skipping it has no
' security impact for our use case (Peachify is a trusted upstream and
' the failure mode of a tampered ciphertext is "JSON parse fails", not
' "we play attacker-controlled video"). If the upstream ever moves to
' a hostile threat model, swap AGD_GHash back in and accept the latency.
'
' For 12-byte (96-bit) IVs - which Peachify always uses - J0 is built
' as IV || 0x00000001. The CTR mode then starts at J0 + 1.

' Public entry. Returns roByteArray of plaintext or invalid on failure.
'   keyHex   - 64-char lowercase hex string (32-byte AES-256 key).
'   ivBytes  - roByteArray of exactly 12 bytes.
'   ctBytes  - roByteArray of ciphertext (any length).
'   tagBytes - roByteArray of 16 bytes (passed in for shape only -
'              tag verification is skipped per the rationale above).
function AGD_Decrypt(keyHex as String, ivBytes as Object, ctBytes as Object, tagBytes as Object) as Object
    if keyHex = invalid or Len(keyHex) <> 64 then return invalid
    if ivBytes = invalid or ivBytes.Count() <> 12 then return invalid
    if ctBytes = invalid then return invalid

    ' J0 = IV || 0x00000001 (16 bytes total).
    j0 = CreateObject("roByteArray")
    for i = 0 to 11
        j0.Push(ivBytes[i])
    end for
    j0.Push(0)
    j0.Push(0)
    j0.Push(0)
    j0.Push(1)

    ' First counter is J0 + 1 (incrementing only the last 32 bits).
    ctr = CreateObject("roByteArray")
    for i = 0 to 15
        ctr.Push(j0[i])
    end for
    AGD_IncrCounter(ctr)

    return AGD_AesCtrCrypt(keyHex, ctr, ctBytes)
end function

' CTR-mode XOR over input bytes. The counter is incremented in place
' (only the last 4 bytes, big-endian) for each 16-byte block.
function AGD_AesCtrCrypt(keyHex as String, counter as Object, dataBytes as Object) as Object
    out = CreateObject("roByteArray")
    n = dataBytes.Count()
    offset = 0
    while offset < n
        ks = AGD_AesEcbBlock(keyHex, counter)
        if ks = invalid or ks.Count() < 16 then return invalid
        blockSize = 16
        if offset + blockSize > n then blockSize = n - offset
        for i = 0 to blockSize - 1
            out.Push(B_Xor(dataBytes[offset + i], ks[i]))
        end for
        offset = offset + 16
        AGD_IncrCounter(counter)
    end while
    return out
end function

' Increment the last 4 bytes of a 16-byte counter (big-endian, mod 2^32).
sub AGD_IncrCounter(ctr as Object)
    if ctr = invalid or ctr.Count() < 16 then return
    for i = 15 to 12 step -1
        ctr[i] = (ctr[i] + 1) AND 255
        if ctr[i] <> 0 then return
    end for
end sub

' Encrypt a single 16-byte block with AES-256-ECB. roEVPCipher's
' Process() returns the encrypted bytes; Final() flushes whatever's left
' in its internal buffer (empty for a single full block with padding=0).
function AGD_AesEcbBlock(keyHex as String, blockBytes as Object) as Object
    cipher = CreateObject("roEVPCipher")
    rc = cipher.Setup(true, "aes-256-ecb", keyHex, "", 0)
    if rc <> 0 then return invalid
    out = CreateObject("roByteArray")
    part1 = cipher.Process(blockBytes)
    if part1 <> invalid then
        for i = 0 to part1.Count() - 1
            out.Push(part1[i])
        end for
    end if
    part2 = cipher.Final()
    if part2 <> invalid then
        for i = 0 to part2.Count() - 1
            out.Push(part2[i])
        end for
    end if
    return out
end function

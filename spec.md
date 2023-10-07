NIP-44
======

Encrypted Payloads (Versioned)
------------------------------

`optional` `author:paulmillr` `author:staab`

The NIP introduces a new data format for keypair-based encryption. This NIP is versioned to allow multiple algorithm choices to exist simultaneously.

nostr is a key directory. Every nostr user has their own public key,
which solves key distribution problem, present in other solutions.
The main goal is to have at least *some* way to send messages between nostr accounts that cannot be read by everyone.

The scheme is not ideal, there are several points to consider:

- No deniability: it is possible to prove the event was signed by a particular key
- No forward secrecy: when a user key is compromised, it is possible to decrypt all previous conversations
- No post-compromise security: when a user key is compromised, it is possible to decrypt all future conversations
- No post-quantum security: a powerful quantum computer would be able to decrypt the messages
- Timing leak: Message date is public
- Location leak: User IP would be seen by relay and all intermediaries between user and relay
- Message length leak: Padding is obscuring true message length, but not entirely; attachments are not supported

For risky situations, users should chat in specialized E2EE messaging software and limit nostr to exchanging contacts.

# Versions

Currently defined encryption algorithms:

- `0x00` - Reserved
- `0x01` - Deprecated
- `0x02` - secp256k1 ECDH, HKDF, padding, ChaCha20, HMAC-SHA256, base64

## Version 2

The following cryptographic primitives are used:

```py
chacha20(key, nonce, data)                  # ChaCha20 (RFC 8439)
hmac_sha256(key, message)                   # HMAC (RFC 2104)
hkdf_sha256(key, salt, info, length)        # HKDF (RFC 5869)
secp256k1_ecdh(privA, pubB)                 # ECDH over secp256k1 curve, **32-byte output is not hashed**
base64_encode(string), base64_decode(bytes) # Base64 (RFC 4648, with padding)
secure_random_bytes(length)                 # Fetches randomness from CSPRNG
```

Helper methods:

```py
# Calculates static long-term key between users A and B.
# key(Apriv, Bpub) == key(Bpriv, Apub)
# Make sure to validate public keys.
# The method is slow, so, the output could be cached.
# Returns 32 bytes representing unhashed x coordinate.
get_conversation_key(private_key_a, public_key_b):
  secp256k1_ecdh(private_key_a, public_key_b).slice(1, 33)

# Calculates encryption and authentication keys for a message.
get_message_keys(conversation_key, salt):
  res = hkdf_sha256(conversation_key, salt: salt, info: 'nip44-v2', length: 76)
  { "encryption": res.slice(0, 32), "nonce": res.slice(32, 44), "auth": res.slice(44, 76) }

# Calculates length of the padded byte array.
calc_padding(unpadded_len):
  nextpower = 1 << (floor(log2(unpadded_len - 1)) + 1
  chunk = nextpower <= 256 ? 32 : nextpower / 8
  padded_length = unpadded_len <= 32 ? 32 : chunk * (floor((len - 1) / chunk) + 1)

# Language and platform-specific methods, we don't define them in the spec
utf8_encode(string), utf8_decode(bytes) # Transforms string to byte array and back
write_u16_be(number) # Encodes number into Big-Endian uint16 byte array
zeros(length) # Creates byte array of length "length", filled with zeros. Can be 0-length
```

#### Encryption

```py
# input: `sender_privkey, recipient_pubkey, plaintext` OR `conversation_key, plaintext`
salt = secure_random_bytes(32)
conversation_key = get_conversation_key(sender_privkey, recipient_pubkey)
keys = get_message_keys(conversation_key, salt)
unpadded = utf8_encode(plaintext)
unpadded_len = plaintext.length
if (unpadded_len == 0 or unpadded_len > 65536 - 128): throw Error('invalid plaintext length')
padded = write_u16_be(unpadded_len) || unpadded || zeros(calc_padding(unpadded_len) - unpadded_len)
ciphertext = chacha20(key: keys["encryption"], nonce: keys["nonce"], data: padded)
mac = hmac_sha256(key: keys["auth"], message: ciphertext)
payload = base64_encode(2 || salt || ciphertext || mac)
```

1. Generate random 32-byte `salt`
    * Secure random (CSPRNG) must always be used for such generation
    * Reusing `salt` between messages would make them decryptable, but would not leak long-term key
2. Calculate message keys
    * Generate `conversation_key`: take 32 bytes from unhashed secp256k1 ECDH of private key A and public key B, without parity byte
    * Pass `conversation_key` to hkdf-sha256, with salt from step 1 and info: `nip44-v2`. HKDF's outputLength must be 76 bytes.
    * The HKDF output is sliced into: `encryption_key` (bytes 0..32), `nonce` (bytes 32..44), `auth` (bytes 44..76)
3. Encode plaintext from utf8 to bytes and pad them
    * Validate plaintext length. Minimum is 1 byte, maximum is 65536 - 128 bytes
    * Padding format is: `[plaintext_length: u16][plaintext][zero_bytes]`
    * Padding algorithm is related to powers-of-two, with min padded msg size of 32
    * Plaintext length is encoded in big-endian as first two bytes of the padded blob
    * In some cases, there is no padding: for example, 320-byte msg is padded to 320 bytes
    * Padding test vectors are provided below: ensure your padding calculator output matches them
5. Produce ciphertext, by calling ChaCha20
6. Calculate MAC (message authentication code) over ciphertext
7. Base64-encode the version and concatenated params

#### Decryption

Before decryption, it is mandatory to validate event's pubkey and signature: `validate_public_key(event.pubkey) and validate_signature(event)`

```py
# input: `recipient_privkey, sender_pubkey, payload` OR `conversation_key, payload`
if payload[0] == '#': throw Error('unknown version')
d = base64_decode(payload)
vers = d[0]
if (vers != 2): throw Error('unknown version')

dlen = d.length
salt, ciphertext, mac = d.slice(1, 33), d.slice(33, dlen - 32), d.slice(dlen - 32, dlen)
conversation_key = get_conversation_key(sender_privkey, recipient_pubkey)
keys = get_message_keys(conversation_key, salt)
calculated_mac = hmac_sha256(key: keys["auth"], message: ciphertext)
if (calculated_mac != mac): throw Error('invalid MAC')

padded = chacha20(key: keys["encryption"], nonce: keys["nonce"], data: ciphertext)
unpadded_len = read_uint16_be(padded.slice(0, 2))
unpadded = padded_plaintext.slice(2, 2 + unpadded_len)
if (unpadded_len == 0 or
    unpadded.length != unpadded_len or
    padded.length != 2 + calc_padding(unpadded_len)): throw Error('invalid padding')
plaintext = utf8_decode(unpadded)
```

1. Validate the message's pubkey and signature
    * public key must be a valid secp256k1 curve point
    * signature must be valid secp256k1 schnorr signature; message serialization is specified in NIP1
2. Check if first payload's character is `#`. Throw a descriptive error if so
    * `#` is an optional flag that means non-base64 encoding is used
    * Instead of throwing `base64 is invalid`, an app must say the encryption version is not yet supported
3. Decode base64
    * Base64 is decoded into `version, salt, ciphertext, mac`
    * If the version is unknown, the app, an app must say the encryption version is not yet supported
4. Calculate message keys
    * Reuse algorithm from encryption's step 2
5. Calculate and compare MAC using `auth_key` from step 4, reusing the algorithm from encryption's step 5
    * Stop and throw an error if MAC doesn't match the decoded one from step 2
6. Decrypt ciphertext into plaintext, using ChaCha20
7. Unpad plaintext
    * Read the first two BE bytes of plaintext that correspond to plaintext length
    * Verify that the length of sliced plaintext matches the value of the two BE bytes
    * Verify that calculated padding from encryption's step 3 matches the actual padding

Example:

- Alice's private key: `5c0c523f52a5b6fad39ed2403092df8cebc36318b39383bca6c00808626fab3a`
- Bob's private key: `4b22aa260e4acb7021e32f38a6cdf4b673c6a277755bfce287e370c924dc936d`
- Message salt: `b635236c42db20f021bb8d1cdff5ca75dd1a0cc72ea742ad750f33010b24f73b`

Encrypting the message `hello` from Alice to Bob results in the following base-64 encoded payload:

```
ArY1I2xC2yDwIbuNHN/1ynXdGgzHLqdCrXUPMwELJPc7ysu7m8bzLLv3LyxbtMit2SsnmvFjnrJN9Qqoenb/M2mwWjcfA92Xeb92ZrTKcaQOi6jdXajWgRcRxO/TWJo93il3
```

# Implementations

A collection of implementations in different languages is available [on GitHub](https://github.com/paulmillr/nip44-implementations).

# Test Vectors

Steps that must be tested:

- `valid_sec` - encrypt (calculate and compare shared key, calculate and compare ciphertext), decrypt (compare plaintext)
- `valid_pub` - encrypt (calculate and compare shared key, calculate and compare ciphertext), decrypt (compare plaintext)
- `invalid` - decrypt must throw an error
- `invalid_conversation_key` - encrypt or get_conversation_key must throw an error
- `padding` - tests for calc_padding utility method

```json
{
  "v2": {
    "valid_sec": [
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000001",
        "sec2": "0000000000000000000000000000000000000000000000000000000000000002",
        "shared": "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
        "salt": "0000000000000000000000000000000000000000000000000000000000000001",
        "plaintext": "a",
        "ciphertext": "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABYNpT9ESckRbRUY7bUF5P+1rObpA4BNoksAUQ8myMDd9/37W/J2YHvBpRjvy9uC0+ovbpLc0WLaMFieqAMdIYqR14",
        "note": "sk1 = 1, sk2 = random, 0x02"
      },
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000002",
        "sec2": "0000000000000000000000000000000000000000000000000000000000000001",
        "shared": "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
        "salt": "f00000000000000000000000000000f00000000000000000000000000000000f",
        "plaintext": "🍕🫃",
        "ciphertext": "AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPKY68BwdF7PIT205jBoaZHSs7OMpKsULW5F5ClOJWiy6XjZy7s2v85KugYmbBKgEC2LytbXbxkr7Jpgfk529K3/pP",
        "note": "sk1 = 1, sk2 = random, 0x02"
      },
      {
        "sec1": "5c0c523f52a5b6fad39ed2403092df8cebc36318b39383bca6c00808626fab3a",
        "sec2": "4b22aa260e4acb7021e32f38a6cdf4b673c6a277755bfce287e370c924dc936d",
        "shared": "94da47d851b9c1ed33b3b72f35434f56aa608d60e573e9c295f568011f4f50a4",
        "salt": "b635236c42db20f021bb8d1cdff5ca75dd1a0cc72ea742ad750f33010b24f73b",
        "plaintext": "表ポあA鷗ŒéＢ逍Üßªąñ丂㐀𠀀",
        "ciphertext": "ArY1I2xC2yDwIbuNHN/1ynXdGgzHLqdCrXUPMwELJPc7yuU7XwJ8wCYUrq4aXX86HLnkMx7fPFvNeMk0uek9ma01magfEBIf+vJvZdWKiv48eUu9Cv31plAJsH6kSIsGc5TVYBYipkrQUNRxxJA15QT+uCURF96v3XuSS0k2Pf108AI=",
        "note": "unicode-heavy string"
      },
      {
        "sec1": "8f40e50a84a7462e2b8d24c28898ef1f23359fff50d8c509e6fb7ce06e142f9c",
        "sec2": "b9b0a1e9cc20100c5faa3bbe2777303d25950616c4c6a3fa2e3e046f936ec2ba",
        "shared": "ab99c122d4586cdd5c813058aa543d0e7233545dbf6874fc34a3d8d9a18fbbc3",
        "salt": "b20989adc3ddc41cd2c435952c0d59a91315d8c5218d5040573fc3749543acaf",
        "plaintext": "ability🤝的 ȺȾ",
        "ciphertext": "ArIJia3D3cQc0sQ1lSwNWakTFdjFIY1QQFc/w3SVQ6yvPSc+7YCIFTmGk5OLuh1nhl6TvID7sGKLFUCWRW1eRfV/0a7sT46N3nTQzD7IE67zLWrYqGnE+0DDNz6sJ4hAaFrT"
      },
      {
        "sec1": "875adb475056aec0b4809bd2db9aa00cff53a649e7b59d8edcbf4e6330b0995c",
        "sec2": "9c05781112d5b0a2a7148a222e50e0bd891d6b60c5483f03456e982185944aae",
        "shared": "a449f2a85c6d3db0f44c64554a05d11a3c0988d645e4b4b2592072f63662f422",
        "salt": "8d4442713eb9d4791175cb040d98d6fc5be8864d6ec2f89cf0895a2b2b72d1b1",
        "plaintext": "pepper👀їжак",
        "ciphertext": "Ao1EQnE+udR5EXXLBA2Y1vxb6IZNbsL4nPCJWisrctGx1TkkMfiHJxEeSdQ/4Rlaghn0okDCNYLihBsHrDzBsNRC27APmH9mmZcpcg66Mb0exH9V5/lLBWdQW+fcY9GpvXv0"
      },
      {
        "sec1": "eba1687cab6a3101bfc68fd70f214aa4cc059e9ec1b79fdb9ad0a0a4e259829f",
        "sec2": "dff20d262bef9dfd94666548f556393085e6ea421c8af86e9d333fa8747e94b3",
        "shared": "decde9938ffcb14fa7ff300105eb1bf239469af9baf376e69755b9070ae48c47",
        "salt": "2180b52ae645fcf9f5080d81b1f0b5d6f2cd77ff3c986882bb549158462f3407",
        "plaintext": "( ͡° ͜ʖ ͡°)",
        "ciphertext": "AiGAtSrmRfz59QgNgbHwtdbyzXf/PJhogrtUkVhGLzQHiR8Hljs6Nl/XsNDAmCz6U1Z3NUGhbCtczc3wXXxDzFkjjMimxsf/74OEzu7LphUadM9iSWvVKPrNXY7lTD0B2muz"
      },
      {
        "sec1": "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
        "sec2": "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
        "shared": "c6f2fde7aa00208c388f506455c31c3fa07caf8b516d43bf7514ee19edcda994",
        "salt": "e4cd5f7ce4eea024bc71b17ad456a986a74ac426c2c62b0a15eb5c5c8f888b68",
        "plaintext": "مُنَاقَشَةُ سُبُلِ اِسْتِخْدَامِ اللُّغَةِ فِي النُّظُمِ الْقَائِمَةِ وَفِيم يَخُصَّ التَّطْبِيقَاتُ الْحاسُوبِيَّةُ،",
        "ciphertext": "AuTNX3zk7qAkvHGxetRWqYanSsQmwsYrChXrXFyPiItohfde4vHVRHUupr+Glh9JW4f9EY+w795hvRZbixs0EQgDZ7zwLlymVQI3NNvMqvemQzHUA1I5+9gSu8XSMwX9gDCUAjUJtntCkRt9+tjdy2Wa2ZrDYqCvgirvzbJTIC69Ve3YbKuiTQCKtVi0PA5ZLqVmnkHPIqfPqDOGj/a3dvJVzGSgeijcIpjuEgFF54uirrWvIWmTBDeTA+tlQzJHpB2wQnUndd2gLDb8+eKFUZPBifshD3WmgWxv8wRv6k3DeWuWEZQ70Z+YDpgpeOzuzHj0MDBwMAlY8Qq86Rx6pxY76PLDDfHh3rE2CHJEKl2MhDj7pGXao2o633vSRd9ueG8W"
      },
      {
        "sec1": "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
        "sec2": "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
        "shared": "c6f2fde7aa00208c388f506455c31c3fa07caf8b516d43bf7514ee19edcda994",
        "salt": "38d1ca0abef9e5f564e89761a86cee04574b6825d3ef2063b10ad75899e4b023",
        "plaintext": "الكل في المجمو عة (5)",
        "ciphertext": "AjjRygq++eX1ZOiXYahs7gRXS2gl0+8gY7EK11iZ5LAjTHmhdBC3meTY4A7Lv8s8B86MnmlUBJ8ebzwxFQzDyVCcdSbWFaKe0gigEBdXew7TjrjH8BCpAbtYjoa4YHa8GNjj7zH314ApVnwoByHdLHLB9Vr6VdzkxcJgA6oL4MAsRLg="
      },
      {
        "sec1": "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
        "sec2": "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
        "shared": "c6f2fde7aa00208c388f506455c31c3fa07caf8b516d43bf7514ee19edcda994",
        "salt": "4f1a31909f3483a9e69c8549a55bbc9af25fa5bbecf7bd32d9896f83ef2e12e0",
        "plaintext": "𝖑𝖆𝖟𝖞 社會科學院語學研究所",
        "ciphertext": "Ak8aMZCfNIOp5pyFSaVbvJryX6W77Pe9MtmJb4PvLhLg/25Q5uBC88jl5ghtEREXX6o4QijPzM0uwmkeQ54/6aIqUyzGNVdryWKZ0mee2lmVVWhU+26X6XGFQ5DGRn+1v0POsFUCZ/REh35+beBNHnyvjxD/rbrMfhP2Blc8X5m8Xvk="
      },
      {
        "sec1": "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
        "sec2": "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
        "shared": "c6f2fde7aa00208c388f506455c31c3fa07caf8b516d43bf7514ee19edcda994",
        "salt": "a3e219242d85465e70adcd640b564b3feff57d2ef8745d5e7a0663b2dccceb54",
        "plaintext": "🙈 🙉 🙊 0️⃣ 1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣ 6️⃣ 7️⃣ 8️⃣ 9️⃣ 🔟 Powerلُلُصّبُلُلصّبُررً ॣ ॣh ॣ ॣ冗",
        "ciphertext": "AqPiGSQthUZecK3NZAtWSz/v9X0u+HRdXnoGY7LczOtU9bUC2ji2A2udRI2VCEQZ7IAmYRRgxodBtd5Yi/5htCUczf1jLHxIt9AhVAZLKuRgbWOuEMq5RBybkxPsSeAkxzXVOlWHZ1Febq5ogkjqY/6Xj8CwwmaZxfbx+d1BKKO3Wa+IFuXwuVAZa1Xo+fan+skyf+2R5QSj10QGAnGO7odAu/iZ9A28eMoSNeXsdxqy1+PRt5Zk4i019xmf7C4PDGSzgFZSvQ2EzusJN5WcsnRFmF1L5rXpX1AYo8HusOpWcGf9PjmFbO+8spUkX1W/T21GRm4o7dro1Y6ycgGOA9BsiQ=="
      }
    ],
    "valid_pub": [
      {
        "sec1": "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364139",
        "pub2": "0000000000000000000000000000000000000000000000000000000000000002",
        "shared": "7a1ccf5ce5a08e380f590de0c02776623b85a61ae67cfb6a017317e505b7cb51",
        "salt": "a000000000000000000000000000000000000000000000000000000000000001",
        "plaintext": "⁰⁴⁵₀₁₂",
        "ciphertext": "AqAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB2+xmGnjIMPMqqJGmjdYAYZUDUyEEUO3/evHUaO40LePeR91VlMVZ7I+nKJPkaUiKZ3cQiQnA86Uwti2IxepmzOFN",
        "note": "sec1 = n-2, pub2: random, 0x02"
      },
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000002",
        "pub2": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdeb",
        "shared": "aa971537d741089885a0b48f2730a125e15b36033d089d4537a4e1204e76b39e",
        "salt": "b000000000000000000000000000000000000000000000000000000000000002",
        "plaintext": "A Peer-to-Peer Electronic Cash System",
        "ciphertext": "ArAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACyuqG6RycuPyDPtwxzTcuMQu+is3N5XuWTlvCjligVaVBRydexaylXbsX592MEd3/Jt13BNL/GlpYpGDvLS4Tt/+2s9FX/16e/RDc+czdwXglc4DdSHiq+O06BvvXYfEQOPw=",
        "note": "sec1 = 2, pub2: "
      },
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000001",
        "pub2": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "shared": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "salt": "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        "plaintext": "A purely peer-to-peer version of electronic cash would allow online payments to be sent directly from one party to another without going through a financial institution. Digital signatures provide part of the solution, but the main benefits are lost if a trusted third party is still required to prevent double-spending.",
        "ciphertext": "Anm+Zn753LusVaBilc6HCwcCm/zbLc4o2VnygVsW+BeYb9wHyKevpe7ohJ6OkpceFcb0pySY8TLGwT7Q3zWNDKxc9blXanxKborEXkQH8xNaB2ViJfgxpkutbwbYd0Grix34xzaZBASufdsNm7R768t51tI6sdS0nms6kWLVJpEGu6Ke4Bldv4StJtWBLaTcgsgN+4WxDbBhC/nhwjEQiBBbbmUrPWjaVZXjl8dzzPrYtkSoeBNJs/UNvDwym4+qrmhv4ASTvVflpZgLlSe4seqeu6dWoRqn8uRHZQnPs+XhqwbdCHpeKGB3AfGBykZY0RIr0tjarWdXNasGbIhGM3GiLasioJeabAZw0plCevDkKpZYDaNfMJdzqFVJ8UXRIpvDpQad0SOm8lLum/aBzUpLqTjr3RvSlhYdbuODpd9pR5K60k4L2N8nrPtBv08wlilQg2ymwQgKVE6ipxIzzKMetn8+f0nQ9bHjWFJqxetSuMzzArTUQl9c4q/DwZmCBhI2",
        "note": "sec1 == pub2 == salt"
      }
    ],
    "invalid": [
      {
        "sec1": "2573d1e9b9ac5de5d570f652cbb9e8d4f235e3d3d334181448e87c417f374e83",
        "pub2": "8348c2d35549098706e5bab7966d9a9c72fbf6554e918f41c2b6cb275f79ec13",
        "sharedKey": "8673ec68393a997bfad7eab8661461daf8b3931b7e885d78312a3fb7fe17f41a",
        "salt": "daaea5ca345b268e5b62060ca72c870c48f713bc1e00ff3fc0ddb78e826f10db",
        "plaintext": "n o b l e",
        "ciphertext": "##Atqupco0WyaOW2IGDKcshwxI9xO8HgD/P8Ddt46CbxDbOsrsqIEyf8ccwhlrnI/Cx03mDSmeweOLKD7dw5BDZQDxXe2FwUJ8Ag25VoJ4MGhjlPCNmCU/Uqk4k0jwbhgR3fRh",
        "note": "unknown encryption version"
      },
      {
        "sec1": "11063318c5cb3cd9cafcced42b4db5ea02ec976ed995962d2bc1fa1e9b52e29f",
        "pub2": "5c49873b6eac3dd363325250cc55d5dd4c7ce9a885134580405736d83506bb74",
        "sharedKey": "e2aad10de00913088e5cb0f73fa526a6a17e95763cc5b2a127022f5ea5a73445",
        "salt": "ad408d4be8616dc84bb0bf046454a2a102edac937c35209c43cd7964c5feb781",
        "plaintext": "⚠️",
        "ciphertext": "AK1AjUvoYW3IS7C/BGRUoqEC7ayTfDUgnEPNeWTF/reBA4fZmoHrtrz5I5pCHuwWZ22qqL/Xt1VidEZGMLds0yaJ5VwUbeEifEJlPICOFt1ssZJxCUf43HvRwCVTFskbhSMh",
        "note": "unknown encryption version 0"
      },
      {
        "sec1": "2573d1e9b9ac5de5d570f652cbb9e8d4f235e3d3d334181448e87c417f374e83",
        "pub2": "8348c2d35549098706e5bab7966d9a9c72fbf6554e918f41c2b6cb275f79ec13",
        "sharedKey": "8673ec68393a997bfad7eab8661461daf8b3931b7e885d78312a3fb7fe17f41a",
        "salt": "daaea5ca345b268e5b62060ca72c870c48f713bc1e00ff3fc0ddb78e826f10db",
        "plaintext": "n o s t r",
        "ciphertext": "Atqupco0WyaOW2IGDKcshwxI9xO8HgD/P8Ddt46CbxDbOsrsqIEybscEwg5rnI/Cx03mDSmeweOLKD,7dw5BDZQDxXSlCwX1LIcTJEZaJPTz98Ftu0zSE0d93ED7OtdlvNeZx",
        "note": "invalid base64"
      },
      {
        "sec1": "5a2f39347fed3883c9fe05868a8f6156a292c45f606bc610495fcc020ed158f7",
        "pub2": "775bbfeba58d07f9d1fbb862e306ac780f39e5418043dadb547c7b5900245e71",
        "sharedKey": "2e70c0a1cde884b88392458ca86148d859b273a5695ede5bbe41f731d7d88ffd",
        "salt": "09ff97750b084012e15ecb84614ce88180d7b8ec0d468508a86b6d70c0361a25",
        "plaintext": "¯\\_(ツ)_/¯",
        "ciphertext": "Agn/l3ULCEAS4V7LhGFM6IGA17jsDUaFCKhrbXDANholdUejFZPARM22IvOqp1U/UmFSkeSyTBYbbwy5ykmi+mKiEcWL+nVmTOf28MMiC+rTpZys/8p1hqQFpn+XWZRPrVay",
        "note": "invalid MAC"
      },
      {
        "sec1": "067eda13c4a36090ad28a7a183e9df611186ca01f63cb30fcdfa615ebfd6fb6d",
        "pub2": "32c1ece2c5dd2160ad03b243f50eff12db605b86ac92da47eacc78144bf0cdd3",
        "sharedKey": "a808915e31afc5b853d654d2519632dac7298ee2ecddc11695b8eba925935c2a",
        "salt": "65b14b0b949aaa7d52c417eb753b390e8ad6d84b23af4bec6d9bfa3e03a08af4",
        "plaintext": "🥎",
        "ciphertext": "AmWxSwuUmqp9UsQX63U7OQ6K1thLI69L7G2b+j4DoIr0U0P/M1/oKm95z8qz6Kg0zQawLzwk3DskvWA2drXP4zK+tzHpKvWq0KOdx5MdypboSQsP4NXfhh2KoUffjkyIOiMA",
        "note": "invalid MAC"
      },
      {
        "sec1": "3e7be560fb9f8c965c48953dbd00411d48577e200cf00d7cc427e49d0e8d9c01",
        "pub2": "e539e5fee58a337307e2a937ee9a7561b45876fb5df405c5e7be3ee564b239cc",
        "sharedKey": "6ee3efc4255e3b8270e5dd3f7dc7f6b60878cda6218c8df34a3261cd48744931",
        "salt": "7ab65dbb8bbc2b8e35cafb5745314e1f050325a864d11d0475ef75b3660d91c1",
        "plaintext": "elliptic-curve cryptography",
        "ciphertext": "Anq2XbuLvCuONcr7V0UxTh8FAyWoZNEdBHXvdbNmDZHBu7F9m36yBd58mVUBB5ktBTOJREDaQT1KAyPmZidP+IRea1lNw5YAEK7+pbnpfCw8CD0i2n8Pf2IDWlKDhLiVvatw",
        "note": "invalid padding"
      },
      {
        "sec1": "c22e1d4de967aa39dc143354d8f596cec1d7c912c3140831fff2976ce3e387c1",
        "pub2": "4e405be192677a2da95ffc733950777213bf880cf7c3b084eeb6f3fe5bd43705",
        "sharedKey": "1675a773dbf6fbcbef6a293004a4504b6c856978be738b10584b0269d437c8d1",
        "salt": "7d4283e3b54c885d6afee881f48e62f0a3f5d7a9e1cb71ccab594a7882c39330",
        "plaintext": "Peer-to-Peer",
        "ciphertext": "An1Cg+O1TIhdav7ogfSOYvCj9dep4ctxzKtZSniCw5MwhT0hvSnF9Xjp9Lml792qtNbmAVvR6laukTe9eYEjeWPpZFxtkVpYTbbL9wDKFeplDMKsUKVa+roSeSvv0ela9seDVl2Sfso=",
        "note": "invalid padding"
      },
      {
        "sec1": "be1edab14c5912e5c59084f197f0945242e969c363096cccb59af8898815096f",
        "pub2": "9eaf0775d971e4941c97189232542e1daefcdb7dddafc39bcea2520217710ba2",
        "sharedKey": "1741a44c052d5ae363c7845441f73d2b6c28d9bfb3006190012bba12eb4c774b",
        "salt": "6f9fd72667c273acd23ca6653711a708434474dd9eb15c3edb01ce9a95743e9b",
        "plaintext": "censorship-resistant and global social network",
        "ciphertext": "Am+f1yZnwnOs0jymZTcRpwhDRHTdnrFcPtsBzpqVdD6bL9HUMo3Mjkz4bjQo/FJF2LWHmaCr9Byc3hU9D7we+EkNBWenBHasT1G52fZk9r3NKeOC1hLezNwBLr7XXiULh+NbMBDtJh9/aQh1uZ9EpAfeISOzbZXwYwf0P5M85g9XER8hZ2fgJDLb4qMOuQRG6CrPezhr357nS3UHwPC2qHo3uKACxhE+2td+965yDcvMTx4KYTQg1zNhd7PA5v/WPnWeq2B623yLxlevUuo/OvXplFho3QVy7s5QZVop6qV2g2/l/SIsvD0HIcv3V35sywOCBR0K4VHgduFqkx/LEF3NGgAbjONXQHX8ZKushsEeR4TxlFoRSovAyYjhWolz+Ok3KJL2Ertds3H+M/Bdl2WnZGT0IbjZjn3DS+b1Ke0R0X4Onww2ZG3+7o6ncIwTc+lh1O7YQn00V0HJ+EIp03heKV2zWdVSC615By/+Yt9KAiV56n5+02GAuNqA",
        "note": "invalid padding"
      }
    ],
    "invalid_conversation_key": [
      {
        "sec1": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "pub2": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "note": "sec1 higher than curve.n"
      },
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000000",
        "pub2": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "note": "sec1 is 0"
      },
      {
        "sec1": "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364139",
        "pub2": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "note": "pub2 is invalid, no sqrt, all-ff"
      },
      {
        "sec1": "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
        "pub2": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "note": "sec1 == curve.n"
      },
      {
        "sec1": "0000000000000000000000000000000000000000000000000000000000000002",
        "pub2": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        "note": "pub2 is invalid, no sqrt"
      }
    ],
    "padding": [
      [16, 32],
      [32, 32],
      [33, 64],
      [37, 64],
      [45, 64],
      [49, 64],
      [64, 64],
      [65, 96],
      [100, 128],
      [111, 128],
      [200, 224],
      [250, 256],
      [320, 320],
      [383, 384],
      [384, 384],
      [400, 448],
      [500, 512],
      [512, 512],
      [515, 640],
      [700, 768],
      [800, 896],
      [900, 1024],
      [1020, 1024],
      [74123, 81920]
    ]
  }
}
```
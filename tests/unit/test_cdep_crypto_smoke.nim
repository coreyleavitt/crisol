## test_cdep_crypto_smoke.nim — RFC-0005 C-dep: compile-smoke test for the
## two crypto dependencies this slice adds (`milpa.kdl`: sello v0.4.0,
## nimcrypto v0.7.3). Gate for C4/C5 (RFC-0005 "Dependency decision" /
## "No dispose (round 3)").
##
## Three independent checks, each a real correctness assertion against a
## known vector -- not merely "it compiles":
##
##   (a) RFC 4231 Test Case 2 — HMAC-SHA256("Jefe", "what do ya want for
##       nothing?") via nimcrypto.
##   (b) RFC 8032 §7.1 TEST 1 — ed25519 keypair derivation from a fixed
##       32-byte seed, sign + verify over the empty message, via sello.
##       Byte vectors transcribed from sello's own
##       tests/unit/test_ed25519.nim (tv1_sk/tv1_pk/tv1_sig), which cites
##       the same RFC section.
##   (c) THE MOVE-ONLY-CAPTURE SPIKE — a closure built once from a fixed
##       seed, capturing the resulting `sello.Keypair` in its environment,
##       invoked TWICE. sello's `Seed`/`Keypair` are move-only
##       (`=copy {.error.}`) and carry `=destroy` wipes; this compile-
##       verifies (under `--mm:orc`, this project's mm) that a closure
##       environment can hold a move-only `Keypair` across two calls
##       without a copy ever being requested, before C5a's `ed25519Policy`
##       does exactly this for real ("the `Keypair` captured in the `sign`
##       closure is destroyed when the `CacheRuntime` drops" — RFC-0005
##       "No `dispose` (round 3)"). Correctness, not just compilation: both
##       invocations' signatures verify against a PublicKey independently
##       re-derived from the same seed bytes.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cdep_crypto_smoke.nim

import std/[strutils, unittest]
import nimcrypto
import sello

proc hexToBytes(s: string): seq[byte] =
  doAssert s.len mod 2 == 0
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[2 * i .. 2 * i + 1]))

proc hexToArray32(s: string): array[32, byte] =
  let bytes = hexToBytes(s)
  doAssert bytes.len == 32
  for i in 0 ..< 32: result[i] = bytes[i]

proc hexToArray64(s: string): array[64, byte] =
  let bytes = hexToBytes(s)
  doAssert bytes.len == 64
  for i in 0 ..< 64: result[i] = bytes[i]

# RFC 8032 §7.1 TEST 1 (transcribed from sello's own test_ed25519.nim).
const
  Rfc8032T1Seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
  Rfc8032T1Pub  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  Rfc8032T1Sig  = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555" &
                  "fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"

suite "RFC-0005 C-dep — crypto dependency compile-smoke":

  test "(a) RFC 4231 Test Case 2: HMAC-SHA256(\"Jefe\", \"what do ya want for nothing?\")":
    let digest = sha256.hmac("Jefe", "what do ya want for nothing?")
    check $digest == "5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843"

  test "(b) RFC 8032 7.1 TEST 1: ed25519 keypair derivation + sign + verify (empty message)":
    let kp = keypair(toSeed(hexToArray32(Rfc8032T1Seed)))
    check toBytes(kp.public) == hexToArray32(Rfc8032T1Pub)
    let sig = kp.sign("")
    check toBytes(sig) == hexToArray64(Rfc8032T1Sig)
    check kp.public.verify("", sig)

  test "(c) the move-only-capture spike: a closure captures a Keypair, invoked twice":
    # A fresh, independent Keypair for verification -- proves the closure's
    # OWN captured Keypair (below) is the real, correctly-derived thing,
    # not merely "some object that didn't crash the compiler".
    let referencePublic = keypair(toSeed(hexToArray32(Rfc8032T1Seed))).public

    proc makeSigner(seed: sink Seed): proc(msg: string): Signature =
      ## Mirrors C5a's `ed25519Policy` shape: `keypair(seed)` built ONCE
      ## inside the closure environment from a moved-in `Seed`, then
      ## captured by the returned closure -- exactly the pattern
      ## RFC-0005's "No dispose (round 3)" describes for the real
      ## `sign` closure.
      let kp = keypair(seed)
      result = proc(msg: string): Signature = kp.sign(msg)

    let signer = makeSigner(toSeed(hexToArray32(Rfc8032T1Seed)))
    let sig1 = signer("first message")
    let sig2 = signer("second message")

    # Invoked twice: the captured move-only Keypair survives across both
    # calls (no copy, no premature destroy) and signs correctly both times.
    check referencePublic.verify("first message", sig1)
    check referencePublic.verify("second message", sig2)
    check toBytes(sig1) != toBytes(sig2)

echo "test_cdep_crypto_smoke: done"

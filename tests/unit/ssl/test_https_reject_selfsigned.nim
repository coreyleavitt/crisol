## test_https_reject_selfsigned.nim — RFC-0005 review fix (T5): an
## AUTOMATED, in-suite TLS-certificate-verification test.
##
## Before this slice, certificate/hostname verification was exercised ONLY
## by `tools/verify_https_manual.sh` (a human-run script, never part of any
## automated gate) — T5's finding. This file closes that gap: it drives a
## REAL TLS handshake, in-process, against a REAL `openssl s_server` on
## loopback serving a cert generated fresh at runtime (never committed key
## material — the cert/key are written to a scratch tempdir and removed at
## the end of the test), and asserts `httpraw.rawHttpFetcher` REJECTS it —
## `reply.transport == toUnreachable`, never `toOk` with a served body.
## This is exactly `httpraw.nim`'s own documented "secure-by-default"
## judgment call (module doc, "Judgment call: TLS (C1b-iii)": `newContext
## (verifyMode = CVerifyPeer)` against the system CA store, no insecure/
## skip-verify knob) — a self-signed cert is, by construction, not in that
## store, so `CVerifyPeer` must reject it.
##
## Lives in tests/unit/ssl/ (this directory's `config.nims` scopes `-d:ssl`
## to exactly this directory, the same convention `test_ssl_link.nim`/
## `test_https_handshake_compiles.nim` already use) so it runs in the
## NORMAL suite (`nimble test` -> `ci/run-tests.sh`), not as a manual,
## easily-forgotten script.
##
## Requires the `openssl` CLI (both `req`, to generate the throwaway
## self-signed cert, and `s_server`, to serve it) — present in the dev
## container's base image (verified: `which openssl` -> `/usr/bin/openssl`,
## OpenSSL 3.5.3) and, per `Dockerfile`'s own comment, expected on
## `ghcr.io/coreyleavitt/nim:2.2.10` (the exact image CI's `test`/`timing`
## jobs run against) as a normal Debian-bookworm package.
##
## A REJECTED-cert probe (this file) is the T5 requirement; a positive-path
## handshake against a cert the client TRUSTS would need a custom CA
## injected into `newContext`, which `httpraw.nim`'s current
## `performTlsHandshake` does not expose (and should not grow solely to
## make this test convenient — see this slice's own judgment call record).
## `tools/verify_https_manual.sh`'s check 1 (a real public endpoint) is
## still the closest thing to that positive-path proof, and stays manual.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/ssl/test_https_reject_selfsigned.nim

import std/[net, os, osproc, strutils, times, unittest]
import crisol/cachewire
import crisol/httpraw

proc freePort(): Port =
  ## Same "reserve then release" pattern
  ## tests/integration/test_httpraw_real.nim already uses to find a
  ## currently-unused loopback port: bind to port 0 (OS-assigned), read
  ## back the assigned port, then close immediately so `openssl s_server`
  ## can bind it itself. Small window for another process to grab it first
  ## (accepted precedent, same tradeoff the existing test already makes).
  var s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = s.getLocalAddr()
  s.close()
  port

proc waitForTcpOpen(port: Port; timeoutMs: int): bool =
  ## Polls a PLAIN TCP connect (no TLS) until `openssl s_server` is
  ## actually listening, or `timeoutMs` elapses. Decouples "is the server
  ## up yet" from the test's real assertion below: `rawHttpFetcher`'s
  ## `toUnreachable` is the SAME outcome for "nobody's listening" and "the
  ## peer rejected our handshake" (both httpraw.nim code paths resolve to
  ## it), so without this the test could pass for the wrong reason (racing
  ## the server's startup) instead of the one it claims to prove.
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    var probe: Socket
    try:
      probe = newSocket()
      probe.connect("127.0.0.1", port, timeout = 200)
      probe.close()
      return true
    except OSError, TimeoutError:
      try:
        if probe != nil: probe.close()
      except CatchableError:
        discard
      sleep(20)
  false

suite "T5 -- httpraw rejects a self-signed TLS certificate (automated, in-suite)":

  test "a fresh self-signed openssl s_server on loopback is rejected -- never a served body":
    let workDir = getTempDir() / ("crisol_selfsigned_" & $getCurrentProcessId() & "_" &
                                   $int64(epochTime() * 1_000_000))
    createDir(workDir)
    defer: removeDir(workDir)

    let keyPath = workDir / "key.pem"
    let certPath = workDir / "cert.pem"

    # Generate a throwaway self-signed cert AT TEST RUNTIME -- never commit
    # key material. -days 1 keeps its validity window minimal; -nodes skips
    # a passphrase (this key exists for the length of one test run and is
    # removed with workDir above).
    let genCmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyPath.quoteShell &
                 " -out " & certPath.quoteShell &
                 " -days 1 -nodes -subj \"/CN=crisol-test-selfsigned.invalid\""
    let (genOutput, genExit) = execCmdEx(genCmd)
    check genExit == 0
    check fileExists(certPath)
    check fileExists(keyPath)
    if genExit != 0:
      echo "openssl req failed:\n", genOutput

    let port = freePort()
    var server = startProcess("openssl",
      args = @["s_server", "-quiet", "-accept", $port.int,
               "-cert", certPath, "-key", keyPath, "-www"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      try:
        server.terminate()
      except CatchableError:
        discard
      discard server.waitForExit(2000)
      server.close()

    check waitForTcpOpen(port, 5000)

    let fetcher = rawHttpFetcher(connectTimeoutMs = 2000, recvTimeoutMs = 2000)
    let req = HttpRequest(meth: "GET", url: "https://127.0.0.1:" & $port.int & "/",
                          headers: @[], body: "")
    let reply = fetcher(req)

    # The self-signed cert is, by construction, not in the system CA store
    # -- `CVerifyPeer` (httpraw.nim's secure-by-default `newContext`) must
    # reject the handshake. Never `toOk`: that would mean either the
    # handshake silently succeeded against an untrusted cert (the exact
    # permissiveness httpraw.nim's module doc says this build never does)
    # or a response was parsed over an unverified channel. `HttpReply` is a
    # `case` object (`cachewire.nim`) -- `status`/`headers`/`body` are only
    # accessible under `toOk`, so asserting the `transport` tag alone is
    # both necessary and sufficient to prove no body was ever served.
    check reply.transport == toUnreachable

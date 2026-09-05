# crisol development image. Mirrors the sibling-lib Docker-for-tooling pattern.
#
# All toolchain operations (nim, nimble, tests) run inside this image, built
# and run with podman. The base already ships Nim 2.2.10 + gcc + git.
FROM ghcr.io/coreyleavitt/nim:2.2.10

# RFC-0005 C1a: TLS toolchain readiness for the raw std/net HttpFetcher's
# TLS path (C1b-iii, `wrapConnectedSocket` under `-d:ssl`). The RFC bullet
# says "libssl-dev" (the Debian idiom), but this base image is openSUSE
# Tumbleweed, not Debian — verified via `cat /etc/os-release` in the base
# image directly — so the equivalent package is `libopenssl-3-devel`.
# The current base tag already carries it (and the libssl.so.3/libcrypto.so.3
# runtime Nim's `-d:ssl` dlopen's at call time — Nim's openssl wrapper
# declares its own C prototypes and never links libssl at compile/link time),
# so this install is a fast no-op today; it's here so that property is a
# declared contract of this Dockerfile, not an accident of the current base
# tag that a future bump could silently drop.
RUN zypper --non-interactive install --no-recommends libopenssl-3-devel && \
    zypper clean --all

WORKDIR /workspace

# crisol development image. Mirrors the sibling-lib Docker-for-tooling pattern.
#
# All toolchain operations (nim, nimble, tests) run inside this image, built
# and run with podman. The base already ships Nim 2.2.10 + gcc + git, so this
# image only needs project-specific tweaks (none yet — pure-Nim, glibc-only).
FROM ghcr.io/coreyleavitt/nim:2.2.10

WORKDIR /workspace

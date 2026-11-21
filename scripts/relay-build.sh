#!/usr/bin/env bash
# Builds the relay for the feature sheets: the step `relay` of the testing ci pipeline (.testing.lua).
#
# The hosted macOS image has Go in its tool cache but not on PATH (ubuntu and windows have it on PATH), so a missing
# `go` is looked up in the GOROOT_<major>_<minor>_<arch> variables the hosted images set, the newest first; under CI
# brew installs it as a last resort. An older Go fetches the version of native/server/go.mod itself (GOTOOLCHAIN=auto).
set -euo pipefail

if ! command -v go >/dev/null 2>&1; then
  newest=$(env | sed -n 's/^\(GOROOT_[0-9]*_[0-9]*_[A-Z0-9]*\)=.*/\1/p' | sort -t_ -k2,2nr -k3,3nr | head -n 1 || true)
  if [ -n "$newest" ] && [ -x "${!newest}/bin/go" ]; then
    PATH="${!newest}/bin:$PATH"
    echo "relay: go from \$$newest (${!newest})"
  elif [ "${CI:-}" = "true" ] && command -v brew >/dev/null 2>&1; then
    brew install go
  fi
fi

if ! command -v go >/dev/null 2>&1; then
  echo "relay: Go is not on PATH (and no GOROOT_* of a hosted runner); install Go to build the relay" >&2
  exit 1
fi

exec node scripts/build-go.mjs

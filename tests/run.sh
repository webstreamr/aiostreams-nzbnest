#!/usr/bin/env bash
# Runs both scripts against tests/mock_server.py and diffs their output with
# tests/expected/. Exits non-zero if anything differs.
set -euo pipefail
cd "$(dirname "$0")"
export LC_ALL=C  # stable glob, ls and sort order

T="$(mktemp -d)" PID=""
trap '[ -z "$PID" ] || kill "$PID"; rm -rf "$T"' EXIT
failed=0
check() { # <name> <expected file> <actual file>
  if diff -u "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; failed=1; fi
}

# AIOStreams data folder: every fixture NZB is cached unless "_cached": false.
mkdir -p "$T/data/cache/grab-nzb" "$T/data/usenet-nzbs"
jq -r '.[] | select(._cached != false) | .nzbUrl' fixtures/library.json | while read -r url; do
  case "$url" in
    local-nzb://*) echo '<nzb/>' >"$T/data/usenet-nzbs/${url#local-nzb://}.nzb" ;;
    *) echo '<nzb/>' >"$T/data/cache/grab-nzb/$(printf '%s' "$url" | sha1sum | cut -d' ' -f1)" ;;
  esac
done

python3 -I mock_server.py "$T" & PID=$!
for _ in {1..50}; do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { echo "mock server did not start" >&2; exit 1; }
AIOS_URL="http://127.0.0.1:$(cat "$T/port")"
export AIOS_URL AIOS_USER=u AIOS_PASS=p AIOS_DATA="$T/data"
export NZBNEST_URL="$AIOS_URL" NZBNEST_KEY=k

LIST_SOURCES=1 ../aiostreams-export.sh >"$T/sources.txt"
check sources expected/sources.txt "$T/sources.txt"

export EXCLUDE_SOURCES=localhost:9696/6
{ ../aiostreams-export.sh "$T/out" 2>&1; ls "$T/out"; } >"$T/export.txt"
check export expected/export.txt "$T/export.txt"
for nfo in expected/nfo/*.nfo; do check "nfo $(basename "$nfo")" "$nfo" "$T/out/$(basename "$nfo")"; done

../aiostreams-export.sh "$T/out" >"$T/rerun.txt" 2>&1
check rerun expected/rerun.txt "$T/rerun.txt"

# categories.txt is both the input (release names) and the expected output.
mkdir "$T/names"
cut -c7- expected/categories.txt | while read -r name; do touch "$T/names/$name.nzb"; done
DRY_RUN=1 ../nzbnest-upload.sh "$T/names" | sort >"$T/categories.txt"
check categories expected/categories.txt "$T/categories.txt"

{ ../nzbnest-upload.sh "$T/out"; cat "$T/uploads.log"; ls "$T/out"; } >"$T/upload.txt" 2>&1
check upload expected/upload.txt "$T/upload.txt"

exit "$failed"

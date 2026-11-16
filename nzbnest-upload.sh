#!/usr/bin/env bash
# Upload .nzb files to NzbNest, each with its same-named .nfo if there is one
# and a Newznab category detected from the release name. See README.md.
#
#   NZBNEST_KEY=... ./nzbnest-upload.sh <dir>
#
# DRY_RUN=1      print categories, upload nothing
# NZBNEST_URL    API base, default https://nzbnest.com (tests point it at a mock)
# ANIME_TITLES   anime title list, default <dir>/.anime-titles (from aiostreams-export.sh)
set -euo pipefail

DIR="${1:?usage: nzbnest-upload.sh <dir>}"; DIR="${DIR%/}"
[ -d "$DIR" ] || { echo "not a folder: $DIR" >&2; exit 2; }
[ -n "${DRY_RUN:-}" ] || : "${NZBNEST_KEY:?}"

# Tests category_for's $name against an extended regex.
has() { grep -Eiq "$1" <<<"$name"; }

# Each line lowercased, apostrophes dropped, anything but ASCII letters and
# digits as one space.
normalize() {
  sed "s/'//g; s/’//g" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9\n' ' ' | sed -E 's/^ //; s/ $//'
}

TITLES="$(mktemp)"; trap 'rm -f "$TITLES"' EXIT
ANIME_TITLES="${ANIME_TITLES:-$DIR/.anime-titles}"
[ ! -s "$ANIME_TITLES" ] || normalize <"$ANIME_TITLES" | sort -u >"$TITLES"

# Show title of release name $1: the part before the season, year or resolution.
title_of() {
  normalize <<<"$1" |
    sed -E 's/(^| )(s[0-9]{1,2}(e[0-9]+)?|[0-9]{1,2}x[0-9]{2}|(19|20)[0-9]{2}|[0-9]{3,4}[pi]|season|complete)( |$).*//'
}

# True if the first audio track in .nfo $1 is Japanese, so added dubs don't count.
japanese_audio() {
  awk '{ sub(/\r$/, "") } /^Audio( #1)?$/ { a = 1 } /^$/ { a = 0 } a && /^Language +: Japanese$/ { f = 1 } END { exit !f }' "$1"
}

# True if release $1 has a listed anime title and .nfo $2 Japanese first audio;
# the title alone also matches Friends (an anime synonym), the audio live action.
anime() {
  local title
  [ -n "$2" ] && title="$(title_of "$1")" && [ -n "$title" ] &&
    grep -qxF "$title" "$TITLES" && japanese_audio "$2"
}

# Category for release name $1 with optional .nfo $2; the first matching rule wins.
category_for() {
  local name="$1"
  if has '(^|[._ -])S[0-9]{1,2}(E[0-9]{1,3})?([._ -]|$)|[._ ][0-9]{1,2}x[0-9]{2}[._ ]|(19|20)[0-9]{2}[._-][01][0-9][._-][0-3][0-9]' ||
     has '^\[[^]]+\].* - [0-9]{2,4}([^0-9]|$)'; then
    if   has '^\[[^]]+\]' || anime "$name" "${2:-}"; then echo 5070
    elif has '2160p|[._ ]UHD[._ ]|[._ ]4K[._ ]'; then echo 5045
    elif has 'WEB[._ -]?(DL|Rip)|[._ ]WEB[._ -]'; then echo 5010
    elif has 'x265|h[._ ]?265|HEVC';             then echo 5090
    elif has '720p|1080[pi]';                    then echo 5040
    else echo 5000; fi
  else
    if   has '[._ ](3D|H?SBS|H?OU)[._ ]';        then echo 2050
    elif has 'COMPLETE[._ ]+(UHD[._ ]+)?BLU-?RAY|BDMV|[._ ]BD(25|50|66|100)[._ ]|AVC[._ ]REMUX'; then echo 2060
    elif has '[._ ]DVD(9|5|R)[._ -]|[._ ](NTSC|PAL)[._ ]+DVD'; then echo 2070
    elif has '2160p|[._ ]UHD[._ ]|[._ ]4K[._ ]'; then echo 2045
    elif has 'WEB[._ -]?(DL|Rip)|[._ ]WEB[._ -]'; then echo 2080
    elif has 'x265|h[._ ]?265|HEVC';             then echo 2090
    elif has '720p|1080[pi]';                    then echo 2040
    elif has '480p|576p|DVDRip|XviD|[._ ]SD[._ ]'; then echo 2030
    else echo 2000; fi
  fi
}

shopt -s nullglob nocaseglob
files=("$DIR"/*.nzb)
[ "${#files[@]}" -gt 0 ] || { echo "no .nzb files"; exit 0; }

ok=0 failed=0
for f in "${files[@]}"; do
  release="${f##*/}"; release="${release%.*}"
  nfo="$DIR/$release.nfo"; [ -f "$nfo" ] || nfo=""
  category="$(category_for "$release" "$nfo")"

  if [ -n "${DRY_RUN:-}" ]; then
    echo "$category  $release${nfo:+  +nfo}"; continue
  fi

  # Quoted so curl doesn't split paths on ';' or ','.
  form=(-F "file=@\"$f\";type=application/x-nzb")
  [ -z "$nfo" ] || form+=(-F "nfo=@\"$nfo\";type=text/plain")

  resp="$(mktemp)"
  code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST \
    "${NZBNEST_URL:-https://nzbnest.com}/v1/upload?apikey=$NZBNEST_KEY&cat=$category" "${form[@]}" || echo 000)"

  if [[ "$code" == 2* ]]; then
    rm -f "$f" ${nfo:+"$nfo"}
    ok=$((ok + 1)); echo "up   [$category] $release${nfo:+ +nfo}"
  else
    failed=$((failed + 1)); echo "FAIL $release (HTTP $code): $(head -c 300 "$resp")" >&2
  fi
  rm -f "$resp"
  sleep 3
done

[ -n "${DRY_RUN:-}" ] || echo "uploaded $ok, failed $failed"
[ "$failed" -eq 0 ]

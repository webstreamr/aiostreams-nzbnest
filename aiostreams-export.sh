#!/usr/bin/env bash
# Export playable NZBs from an AIOStreams usenet library, each with an .nfo
# built from its probed media info. See README.md.
#
#   AIOS_URL=... AIOS_USER=... AIOS_PASS=... AIOS_DATA=... ./aiostreams-export.sh <out-dir>
#
# AIOS_DATA        server data folder; NZBs are only copied from its cache
# AIOS_CACHE       cache folder, if not $AIOS_DATA/cache (DISK_CACHE_DIR)
# SINCE_HOURS      only entries added in the last N hours
# INCLUDE_SOURCES  comma list; keep only entries whose source contains one
# EXCLUDE_SOURCES  comma list; drop entries whose source contains one
# LIST_SOURCES=1   print source hosts with counts and exit; needs no <out-dir>/AIOS_DATA
set -euo pipefail
shopt -s inherit_errexit

: "${AIOS_URL:?}" "${AIOS_USER:?}" "${AIOS_PASS:?}"
if [ -z "${LIST_SOURCES:-}" ]; then
  OUT="${1:?usage: aiostreams-export.sh <out-dir>}"
  : "${AIOS_DATA:?}"
fi
BASE="${AIOS_URL%/}/api/v1"
LIBRARY="dashboard/usenet/library?statuses=available,degraded,streaming&sort=added&dir=desc&limit=500"
CUTOFF=0
[ -z "${SINCE_HOURS:-}" ] || CUTOFF=$(( $(date +%s) - SINCE_HOURS * 3600 ))

JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
curl -fsS -c "$JAR" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$AIOS_USER" --arg p "$AIOS_PASS" '{username:$u,password:$p}')" \
  "$BASE/auth/login" >/dev/null

api() { curl -fsS -b "$JAR" "$BASE/$1"; }

# One line per entry, newest first. Fields are \x1f-separated because read
# collapses empty tab-separated fields: hash, release, url, added (epoch),
# source, probed file count, {size, postedAt} JSON.
# shellcheck disable=SC2016  # jq variables, not shell
ROWS_JQ='.data.entries[] | (.nzbUrl // "") as $u | [
  .nzbHash,
  ((.name // .nzbHash) | sub("\\.nzb$"; ""; "i")
    | gsub("[[:cntrl:]/\\\\:*?\"<>|]"; "_") | .[0:200]),
  $u,
  (.addedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
  (if $u == "" then "none" elif $u | startswith("local-nzb://") then "local"
   else $u | sub("\\?.*$"; "") | sub("^[a-zA-Z]+://"; "") end),
  (.probedFiles // 0),
  ({size, postedAt} | tojson)
] | map(tostring) | join("\u001f")'

# Rows down to CUTOFF, page by page.
rows() {
  local offset=0 page n out
  while :; do
    page="$(api "$LIBRARY&offset=$offset")"
    n="$(jq '.data.entries | length' <<<"$page")"
    [ "$n" -gt 0 ] || break
    out="$(jq -r "$ROWS_JQ" <<<"$page")"
    printf '%s\n' "$out"
    offset=$((offset + n))
    [ "$(tail -n1 <<<"$out" | cut -d$'\x1f' -f4)" -ge "$CUTOFF" ] || break
    [ "$offset" -lt "$(jq '.data.total' <<<"$page")" ] || break
  done
}

# shellcheck disable=SC2016  # jq variables, not shell
NFO_JQ='
def pad2: tostring | if length < 2 then "0" + . else . end;
def human: if . == null then "?"
  elif . >= 1099511627776 then "\(. / 1099511627776 * 100 | round / 100) TiB"
  elif . >= 1073741824 then "\(. / 1073741824 * 100 | round / 100) GiB"
  elif . >= 1048576 then "\(. / 1048576 * 10 | round / 10) MiB"
  else "\(. / 1024 | round) KiB" end;
def dur: if . == null then "?" else floor as $s
  | "\($s / 3600 | floor):\(($s % 3600) / 60 | floor | pad2):\($s % 60 | pad2)" end;
def kbps: if . == null then empty else "\(. / 1000 | round) kb/s" end;
def codec: ((.codec // "?") | ascii_upcase) + (if .profile then " " + .profile else "" end);
def lang: .language // "und";
def flags: [ (if .default then "default" else empty end),
             (if .forced then "forced" else empty end),
             (if .hearingImpaired then "SDH" else empty end),
             (if .commentary then "commentary" else empty end) ]
  | if length > 0 then " (" + join(", ") + ")" else "" end;
def hdr: [ (if .dvProfile then "DV P\(.dvProfile)" else empty end),
           (if .hdr10Plus then "HDR10+" elif .colorTransfer == "smpte2084" then "HDR10" else empty end),
           (if .colorTransfer == "arib-std-b67" then "HLG" else empty end),
           ((.hdr // [])[]) ] | unique | join(" / ");
def video: [ codec,
             (if .width then "\(.width)x\(.height)" else empty end),
             ((.avgFps // .fps) | if . then "\(. * 1000 | round / 1000) fps" else empty end),
             (if .bitDepth then "\(.bitDepth)-bit" else empty end),
             (hdr | select(length > 0)),
             (.bitrate | kbps) ] | join(", ");
def audio: ([ lang, codec,
              (.channelLayout // (if .channels then "\(.channels)ch" else empty end)),
              (.bitrate | kbps),
              (if .title then "\"\(.title)\"" else empty end) ] | join(", ")) + flags;
def subtitle: lang + (if .codec then " [\(.codec)]" else "" end)
  + (if .title then " \"\(.title)\"" else "" end) + flags;

"Release   : \($release)",
"Size      : \($meta.size | human)",
(if $meta.postedAt then "Posted    : \($meta.postedAt | todate | .[0:10])" else empty end),
"Files     : \($files | length)",
"",
($files | sort_by(.file)[] |
  "File      : \(.file)",
  "Container : \(.info.container // "?"), \(.info.duration | dur), \((.size // .info.size) | human)"
    + (.info.bitrate | if . then ", \(kbps)" else "" end)
    + (if .info.chapters then ", chapters" else "" end),
  (.info.tracks | map(select(.type == "video"))[] | "Video     : " + video),
  (.info.tracks | map(select(.type == "audio")) | to_entries[]
    | "Audio \(.key + 1 | tostring | . + "   " | .[0:3]) : " + (.value | audio)),
  (.info.tracks | map(select(.type == "subtitle"))
    | if length > 0 then "Subtitles : " + (map(subtitle) | join(", ")) else empty end),
  ""),
"Generated from probed media info by aiostreams-export"'

# True if $1 contains any item of the comma list $2, ignoring case.
matches() {
  local item items
  IFS=',' read -ra items <<<"${2,,}"
  for item in "${items[@]}"; do
    item="${item// /}"
    [ -n "$item" ] && [[ "${1,,}" == *"$item"* ]] && return 0
  done
  return 1
}

if [ -n "${LIST_SOURCES:-}" ]; then
  rows | cut -d$'\x1f' -f5 | cut -d/ -f1 | sort | uniq -c | sort -rn
  exit 0
fi

CACHE="${AIOS_CACHE:-$AIOS_DATA/cache}"
STATE="$OUT/.exported"
mkdir -p "$OUT"; touch "$STATE"
entries="$(rows)"
[ -n "$entries" ] || exit 0

while IFS=$'\x1f' read -r hash release url added src probed meta; do
  [ "$added" -ge "$CUTOFF" ] || break
  grep -qxF "$hash" "$STATE" && continue
  if [ -n "${INCLUDE_SOURCES:-}" ] && ! matches "$src" "$INCLUDE_SOURCES"; then continue; fi
  if [ -n "${EXCLUDE_SOURCES:-}" ] && matches "$src" "$EXCLUDE_SOURCES"; then continue; fi

  file="$OUT/$release.nzb"
  if [ -e "$file" ]; then
    echo "dup  $release" >&2; echo "$hash" >>"$STATE"; continue
  fi

  # Cache files are named sha1(source URL); uploads keep their own folder.
  case "$url" in
    local-nzb://*) from="$AIOS_DATA/usenet-nzbs/${url#local-nzb://}.nzb" ;;
    '') from="" ;;
    *) from="$CACHE/grab-nzb/$(printf '%s' "$url" | sha1sum | cut -d' ' -f1)" ;;
  esac
  if [ -z "$from" ] || [ ! -s "$from" ]; then echo "miss $release" >&2; continue; fi
  cp "$from" "$file"

  nfo="$OUT/$release.nfo" note=""
  if [ "$probed" -gt 0 ] &&
     files="$(api "dashboard/media-info/files?nzb=$hash&limit=100" | jq -ce '.data.items | select(length > 0)')" &&
     jq -nr --arg release "$release" --argjson meta "$meta" --argjson files "$files" "$NFO_JQ" >"$nfo"; then
    note=" +nfo"
  else
    rm -f "$nfo"   # partial or failed
  fi

  echo "$hash" >>"$STATE"; echo "ok   $release$note"
done <<<"$entries"

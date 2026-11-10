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
# source, probed file count, {files} JSON.
# unproxy: an AIOStreams proxy URL's upstream URL, read from the base64url JSON
# in /proxy/u.<auth>.<data>; undecodable proxy URLs are cut to .../proxy.
# shellcheck disable=SC2016  # jq variables, not shell
ROWS_JQ='
def unproxy: (try (capture("/proxy/u\\.[^./]+\\.(?<d>[^./]+)").d
  | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4))
  | @base64d | fromjson | .url | strings)) // sub("/proxy/.*$"; "/proxy");
.data.entries[] | (.nzbUrl // "") as $u | [
  .nzbHash,
  ((.name // .nzbHash)
    | sub("(\\.(vol[0-9]+[+-][0-9]+|part[0-9]+|par2|rar|r[0-9]{2}|7z|zip|nzb))+$"; ""; "i")
    | gsub("[[:cntrl:]/\\\\:*?\"<>|]"; "_") | .[0:200]),
  $u,
  (.addedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
  (if $u == "" then "none" elif $u | startswith("local-nzb://") then "local"
   else $u | unproxy | sub("\\?.*$"; "") | sub("^[a-zA-Z]+://"; "") end),
  (.probedFiles // 0),
  ({files: [(.files // [])[] | {name: (.path // .name), size}]} | tojson)
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

# MediaInfo-style report from AIOStreams' ffprobe records.
# shellcheck disable=SC2016  # jq variables, not shell
NFO_JQ='
def size: if . == null then null
  elif . >= 1073741824 then "\(. / 1073741824 * 100 | round / 100) GiB"
  elif . >= 1048576 then "\(. / 1048576 * 10 | round / 10) MiB"
  else "\(. / 1024 * 10 | round / 10) KiB" end;
def dur: if . == null then null else floor as $s
  | if $s >= 3600 then "\($s / 3600 | floor) h \(($s % 3600) / 60 | floor) min"
    elif $s >= 60 then "\($s / 60 | floor) min \($s % 60) s" else "\($s) s" end end;
def rate: if . == null then null elif . >= 1000000 then "\(. / 100000 | round / 10) Mb/s"
  else "\(. / 1000 | round) kb/s" end;
def yn: if . == null then null elif . then "Yes" else "No" end;
def yes: if . then "Yes" else null end;
def pretty($m): . as $c | $m[$c // ""] // $c;
def color: pretty({"bt709": "BT.709", "bt2020": "BT.2020", "bt2020nc": "BT.2020 non-constant",
  "bt470bg": "BT.601", "smpte170m": "BT.601", "smpte2084": "PQ", "arib-std-b67": "HLG"});
# ISO 639 language codes to the English names MediaInfo uses.
def language: pretty({
  "afr": "Afrikaans", "alb": "Albanian", "sqi": "Albanian", "amh": "Amharic",
  "grc": "Ancient Greek", "ara": "Arabic", "arm": "Armenian", "hye": "Armenian", "asm": "Assamese",
  "ast": "Asturian", "aym": "Aymara", "aze": "Azerbaijani", "bak": "Bashkir", "baq": "Basque",
  "eus": "Basque", "bel": "Belarusian", "ben": "Bengali", "bho": "Bhojpuri", "bos": "Bosnian",
  "bre": "Breton", "bul": "Bulgarian", "bur": "Burmese", "mya": "Burmese", "yue": "Cantonese",
  "cat": "Catalan", "ceb": "Cebuano", "che": "Chechen", "chi": "Chinese", "zho": "Chinese",
  "cos": "Corsican", "hrv": "Croatian", "scr": "Croatian", "cze": "Czech", "ces": "Czech",
  "dan": "Danish", "prs": "Dari", "div": "Dhivehi", "dut": "Dutch", "nld": "Dutch",
  "dzo": "Dzongkha", "eng": "English", "epo": "Esperanto", "est": "Estonian", "fao": "Faroese",
  "fij": "Fijian", "fil": "Filipino", "fin": "Finnish", "fre": "French", "fra": "French",
  "ful": "Fulah", "glg": "Galician", "geo": "Georgian", "kat": "Georgian", "ger": "German",
  "deu": "German", "gre": "Greek", "ell": "Greek", "kal": "Greenlandic", "grn": "Guarani",
  "guj": "Gujarati", "hat": "Haitian", "hak": "Hakka", "hau": "Hausa", "haw": "Hawaiian",
  "heb": "Hebrew", "hin": "Hindi", "hmn": "Hmong", "hun": "Hungarian", "ice": "Icelandic",
  "isl": "Icelandic", "ibo": "Igbo", "ilo": "Iloko", "ind": "Indonesian", "ina": "Interlingua",
  "iku": "Inuktitut", "gle": "Irish", "ita": "Italian", "jpn": "Japanese", "jav": "Javanese",
  "kan": "Kannada", "kas": "Kashmiri", "kaz": "Kazakh", "khm": "Khmer", "kin": "Kinyarwanda",
  "tlh": "Klingon", "kok": "Konkani", "kor": "Korean", "kur": "Kurdish", "kir": "Kyrgyz",
  "lao": "Lao", "lat": "Latin", "lav": "Latvian", "lit": "Lithuanian", "ltz": "Luxembourgish",
  "mac": "Macedonian", "mkd": "Macedonian", "mai": "Maithili", "mlg": "Malagasy", "may": "Malay",
  "msa": "Malay", "mal": "Malayalam", "mlt": "Maltese", "cmn": "Mandarin", "mao": "Maori",
  "mri": "Maori", "mar": "Marathi", "nan": "Min Nan", "mon": "Mongolian", "cnr": "Montenegrin",
  "nav": "Navajo", "nep": "Nepali", "sme": "Northern Sami", "nor": "Norwegian",
  "nob": "Norwegian Bokmal", "nno": "Norwegian Nynorsk", "oci": "Occitan", "ori": "Oriya",
  "orm": "Oromo", "pus": "Pashto", "per": "Persian", "fas": "Persian", "pol": "Polish",
  "por": "Portuguese", "pan": "Punjabi", "que": "Quechua", "rum": "Romanian", "ron": "Romanian",
  "roh": "Romansh", "rom": "Romany", "rus": "Russian", "smo": "Samoan", "san": "Sanskrit",
  "srd": "Sardinian", "gla": "Scottish Gaelic", "srp": "Serbian", "scc": "Serbian",
  "hbs": "Serbo-Croatian", "sna": "Shona", "sgn": "Sign languages", "snd": "Sindhi",
  "sin": "Sinhala", "slo": "Slovak", "slk": "Slovak", "slv": "Slovenian", "som": "Somali",
  "sot": "Sotho", "spa": "Spanish", "sun": "Sundanese", "swa": "Swahili", "swe": "Swedish",
  "syr": "Syriac", "tgl": "Tagalog", "tah": "Tahitian", "tgk": "Tajik", "tam": "Tamil",
  "tat": "Tatar", "tel": "Telugu", "tha": "Thai", "tib": "Tibetan", "bod": "Tibetan",
  "tir": "Tigrinya", "ton": "Tongan", "tsn": "Tswana", "tur": "Turkish", "tuk": "Turkmen",
  "ukr": "Ukrainian", "urd": "Urdu", "uig": "Uyghur", "uzb": "Uzbek", "vie": "Vietnamese",
  "wel": "Welsh", "cym": "Welsh", "fry": "Western Frisian", "wol": "Wolof", "xho": "Xhosa",
  "yid": "Yiddish", "yor": "Yoruba", "zul": "Zulu",
  "mul": "Multiple languages", "zxx": "No linguistic content"});
# One "Key<padding>: value" line; nothing when the value is null or empty.
def row($k; $v): $v | select(. != null and . != "") | "\($k + " " * (41 - ($k | length))): \(.)";

def general: [
  "General",
  row("Complete name"; .file),
  row("Format"; .info.container | if . == null then null
    elif test("matroska") then "Matroska" elif test("mp4") then "MPEG-4"
    elif test("mpegts") then "MPEG-TS" elif test("avi") then "AVI" else . end),
  row("File size"; (.size // .info.size) | size),
  row("Duration"; .info.duration | dur),
  row("Overall bit rate"; .info.bitrate | rate),
  row("Chapters"; .info.chapters | yes) ];

def video: . as $v | [
  row("Format"; .codec | pretty({"h264": "AVC", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9",
    "mpeg2video": "MPEG Video", "mpeg4": "MPEG-4 Visual", "vc1": "VC-1"})),
  row("Format profile"; .profile | if . == null then null else . + (
    if ($v.level // 0) <= 0 then "" elif $v.codec == "h264" then "@L\($v.level / 10)"
    elif $v.codec == "hevc" then "@L\($v.level / 30 * 10 | round / 10)" else "" end) end),
  row("HDR format"; [ (if .dvProfile then "Dolby Vision, Profile \(.dvProfile)" else empty end),
    (if .hdr10Plus then "HDR10+" elif .colorTransfer == "smpte2084" then "HDR10" else empty end),
    (if .colorTransfer == "arib-std-b67" then "HLG" else empty end),
    ((.hdr // [])[]) ] | unique | join(" / ")),
  row("Bit rate"; .bitrate | rate),
  row("Width"; .width | if . then "\(.) pixels" else null end),
  row("Height"; .height | if . then "\(.) pixels" else null end),
  # ffprobe gives "479:200"; MediaInfo writes that as "2.40:1".
  row("Display aspect ratio"; .aspectRatio | if . == null or . == "16:9" or . == "4:3" then .
    else split(":") | map(tonumber) | .[0] / .[1] * 100 | round
      | "\(. / 100 | floor).\(. % 100 | tostring | if length < 2 then "0" + . else . end):1" end),
  row("Frame rate"; (.avgFps // .fps) | if . then "\(. * 1000 | round / 1000) FPS" else null end),
  row("Bit depth"; .bitDepth | if . then "\(.) bits" else null end),
  row("Scan type"; .interlaced | if . == null then null elif . then "Interlaced" else "Progressive" end),
  row("Color range"; .colorRange | pretty({"tv": "Limited", "pc": "Full"})),
  row("Color primaries"; .colorPrimaries | color),
  row("Transfer characteristics"; .colorTransfer | color),
  row("Matrix coefficients"; .colorSpace | color) ];

def audio: [
  row("Format"; .codec | pretty({"eac3": "E-AC-3", "ac3": "AC-3", "truehd": "TrueHD", "dts": "DTS",
    "aac": "AAC", "flac": "FLAC", "opus": "Opus", "mp3": "MPEG Audio", "vorbis": "Vorbis"})),
  row("Format profile"; .profile),
  row("Bit rate"; .bitrate | rate),
  row("Channel(s)"; .channels | if . then "\(.) channels" else null end),
  row("Channel layout"; .channelLayout | if . then sub("\\(side\\)$"; "")
    | pretty({"stereo": "2.0", "mono": "1.0"}) else null end),
  row("Sampling rate"; .sampleRate | if . then "\(. / 100 | round / 10) kHz" else null end) ];

def subtitle: [
  row("Format"; .codec | pretty({"subrip": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT",
    "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub", "mov_text": "Timed Text"})) ];

def common: [
  row("Title"; .title),
  row("Language"; .language | select(. != "und") | language),
  row("Default"; .default | yn),
  row("Forced"; .forced | yn),
  row("Hearing impaired"; .hearingImpaired | yes),
  row("Commentary"; .commentary | yes) ];

def tracks($type; $title; f):
  (.info.tracks | map(select(.type == $type))) as $ts
  | $ts | to_entries[] | .key as $i | .value as $v
  | ["", if ($ts | length) > 1 then "\($title) #\($i + 1)" else $title end]
    + ($v | f) + ($v | common) | .[];

"Release name: \($release)",
"",
"Release contents:",
(if ($meta.files | length) > 0 then $meta.files else $files | map({name: .file, size}) end
  | sort_by(.name)[] | "  \(.name)" + (.size | size | if . then "  (\(.))" else "" end)),
($files | sort_by(.file)[] |
  "", (general | .[]),
  tracks("video"; "Video"; video),
  tracks("audio"; "Audio"; audio),
  tracks("subtitle"; "Text"; subtitle)),
"",
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
  rows | cut -d$'\x1f' -f5 | cut -d/ -f1-2 | sort | uniq -c | sort -rn
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

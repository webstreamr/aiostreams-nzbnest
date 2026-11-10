# aiostreams-nzbnest

[![ci](https://github.com/webstreamr/aiostreams-nzbnest/actions/workflows/ci.yml/badge.svg)](https://github.com/webstreamr/aiostreams-nzbnest/actions/workflows/ci.yml)

Two small, independent bash scripts:

- **`aiostreams-export.sh`**: exports playable NZBs from an [AIOStreams](https://github.com/Viren070/AIOStreams) usenet library, each with an `.nfo` built from AIOStreams' probed media info when there is any.
- **`nzbnest-upload.sh`**: uploads `.nzb` files (plus a matching `.nfo`, if present) to [NzbNest](https://nzbnest.com), with a Newznab category picked from the release name. Works with any NZBs, not just exported ones.

Together they share the NZBs your AIOStreams instance has already grabbed, without touching your indexers again.

## Install

Requirements: `bash` 4.4+ (macOS ships 3.2; use Homebrew's), `curl`, `jq` and `sha1sum` (both export only).

Clone the repository; the scripts need no other setup:

```bash
git clone https://github.com/webstreamr/aiostreams-nzbnest.git
cd aiostreams-nzbnest
```

## aiostreams-export.sh

```bash
AIOS_URL=https://aio.example.com AIOS_USER=admin AIOS_PASS=secret AIOS_DATA=/srv/aiostreams/data \
  ./aiostreams-export.sh ./nzbs
```

- It reads the library through the dashboard API as an AIOStreams admin, so password login must be enabled on the instance.
- It copies NZBs from AIOStreams' NZB cache on disk and never contacts an indexer. It has to run where the AIOStreams data folder is readable: on the same host or in the container (for Docker, use the volume's host path). Entries whose NZB is no longer cached are skipped (`miss`).
- Only playable entries are exported (available, degraded or streaming); dead and not yet inspected ones are skipped.
- For each entry it writes `<release>.nzb`, plus `<release>.nfo` if the release was probed (example below).
- Exported hashes are recorded in `<out-dir>/.exported`, so each entry is exported once, even after you move or delete the files.

| Variable | Default | Meaning |
|---|---|---|
| `AIOS_URL` | required | AIOStreams base URL. |
| `AIOS_USER`, `AIOS_PASS` | required | AIOStreams admin login. |
| `AIOS_DATA` | required | Path to the AIOStreams data folder (the directory holding the SQLite file, or `data/` in the server's working directory with Postgres). |
| `AIOS_CACHE` | `$AIOS_DATA/cache` | Cache folder, if `DISK_CACHE_DIR` is set on the server. |
| `SINCE_HOURS` | unset (all) | Only entries added in the last N hours. |
| `INCLUDE_SOURCES` | unset | Comma list; only export entries whose source contains one of these. |
| `EXCLUDE_SOURCES` | unset | Comma list; skip entries whose source contains one of these. |
| `LIST_SOURCES` | unset | Set to `1` to print your library's sources (host and first path segment) with counts, then exit. `<out-dir>` and `AIOS_DATA` aren't needed. |

A **source** is the NZB's URL as `host/path` without the query string (e.g. `api.nzbgeek.info/api`), `local` for NZBs uploaded to AIOStreams by hand, or `none` if the entry has no URL. Matching is a case-insensitive substring match.

- **AIOStreams proxy URLs** (`…/api/v1/proxy/u.…`) are unwrapped to the indexer URL inside them. Encrypted ones (`…/proxy/e.…`) can't be, so they all share one source, `<your-aiostreams-host>/api/v1/proxy`.
- **Prowlarr and NZBHydra:** the host is the proxy's. Prowlarr's path includes the indexer ID (`localhost:9696/6`), so that still works as a filter; NZBHydra's doesn't.

Use these filters to leave out indexers that don't allow sharing (see [Before uploading publicly](#before-uploading-publicly)).

Example `.nfo` (MediaInfo-style, from AIOStreams' ffprobe data):

```
Release name: Dune.2021.2160p.UHD.BluRay.x265-GRP

Release contents:
  Dune.2021.2160p.UHD.BluRay.x265-GRP.mkv  (20 GiB)

General
Complete name                            : Dune.2021.2160p.UHD.BluRay.x265-GRP.mkv
Format                                   : Matroska
File size                                : 20 GiB
Duration                                 : 2 h 35 min
Overall bit rate                         : 18.3 Mb/s

Video
Format                                   : HEVC
Format profile                           : Main 10@L5.1
HDR format                               : Dolby Vision, Profile 8 / HDR10
Width                                    : 3840 pixels
Height                                   : 1600 pixels
Frame rate                               : 23.976 FPS
Bit depth                                : 10 bits

Audio
Format                                   : TrueHD
Channel(s)                               : 8 channels
Channel layout                           : 7.1
Title                                    : Atmos
Language                                 : English
Default                                  : Yes

Generated from probed media info by aiostreams-export
```

## nzbnest-upload.sh

```bash
NZBNEST_KEY=... ./nzbnest-upload.sh ./nzbs    # every .nzb in the folder
DRY_RUN=1 ./nzbnest-upload.sh ./nzbs          # show detected categories only
```

For `Release.Name.nzb` it also uploads `Release.Name.nfo` if that file exists in the same folder. After a successful upload both files are deleted. Failed uploads are left in place, so the next run retries them. Uploads are 3 seconds apart.

| Variable | Default | Meaning |
|---|---|---|
| `NZBNEST_KEY` | required | Your NzbNest API key. |
| `DRY_RUN` | unset | Print categories, upload nothing. |
| `NZBNEST_URL` | `https://nzbnest.com` | API base URL; the tests point it at a mock. |

Category detection uses the usual scene/P2P naming. A name with `S01E02`, `S01`, `1x02`, an air date, or a `[Group] Title - 12` anime pattern is TV; anything else is a movie. The subcategory is the first match, in this order:

- **TV:** Anime (names starting with `[Group]`), UHD, WEB-DL, x265, HD, otherwise TV (5000).
- **Movies:** 3D, full BluRay/DVD disc, UHD, WEB-DL, x265, HD, SD, otherwise Movies (2000).

Foreign, Sport and Documentary aren't detected.

## Scheduling

```cron
0 * * * * cd /path/to/aiostreams-nzbnest && { AIOS_URL=... AIOS_USER=... AIOS_PASS=... AIOS_DATA=... SINCE_HOURS=6 ./aiostreams-export.sh ./nzbs; NZBNEST_KEY=... ./nzbnest-upload.sh ./nzbs; } >> upload.log 2>&1
```

Make `SINCE_HOURS` a few hours longer than the interval. Entries that are still being inspected at run time get picked up by a later run, and the state file prevents duplicates.

For the first run, leave `SINCE_HOURS` unset to export the whole library.

## Before uploading publicly

Check the rules of every indexer your NZBs come from and follow them. Many indexers don't allow their NZBs to be shared or re-uploaded elsewhere. That's what `INCLUDE_SOURCES` and `EXCLUDE_SOURCES` are for: run `LIST_SOURCES=1 AIOS_URL=... AIOS_USER=... AIOS_PASS=... ./aiostreams-export.sh` to see where your NZBs come from, then exclude every indexer that doesn't allow sharing, or include only the ones that do.

## Tests

`tests/run.sh` runs both scripts against a mock AIOStreams/NzbNest server (`tests/mock_server.py`, Python standard library only) using the fixtures in `tests/fixtures/`, and diffs the output with `tests/expected/`. If you change the output on purpose, update the matching file in `tests/expected/`.

## License

[MIT](LICENSE)

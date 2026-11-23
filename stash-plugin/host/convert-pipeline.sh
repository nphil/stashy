#!/bin/bash
# Convert pipeline: FileFlows -> Stash.  Runs every 5 minutes (User Scripts, custom schedule).
#
#  1. HAND-OFF  Asks the Stashy Companion plugin in Stash to run "Re-attach Converted Files": each file
#     FileFlows has converted is moved into the Stash scene it replaced, so play history, tags,
#     performers and rating stay and no duplicate scene appears.
#  1b. NEW VIDEOS  Stash never scans on its own, so a converted video that has no scene to merge into would
#     never show up. This hands Stash every new video in the Stuff library that it has no scene for.
#  2. WATCHDOG  Sends an ntfy alert (topic "homelabber") when something breaks: FileFlows stopped, no
#     working ffmpeg, an add-on failing, videos stuck in the RecycleBin, failed conversions, a FileFlows
#     image update, or an error from the Stash hand-off. Each problem repeats at most once a day.
#
# The ntfy token is in .ntfytoken next to this script (write-only access to that one topic).
# Run it by hand with --test to send a single test alert.  /boot is mounted noexec: run it as `bash <file>`.

export LC_ALL=C
TOKEN_FILE=/boot/config/plugins/user.scripts/scripts/convert-pipeline/.ntfytoken
STATE=/mnt/user/appdata/fileflows/watchdog
FFDB=/mnt/user/appdata/fileflows/data/Data/FileFlows.sqlite
BIN=/mnt/user/Download/torrents/RecycleBin
LIB_HOST=/mnt/user/Stuff      # the Stash library that FileFlows writes into ...
LIB_STASH=/stuff2             # ... as Stash sees it
NTFY=http://127.0.0.1:8150/homelabber
STASH=http://localhost:6969/graphql
FF=FileFlows

mkdir -p "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || exit 0
now=$(date +%s)
log() { echo "$(date '+%F %T') $*"; }

# notify <key> <hours between repeats> <title> <message> [priority 1-5] [emoji tag]
notify() {
  local key="$1" hours="$2" title="$3" msg="$4" prio="${5:-4}" tag="${6:-warning}" last
  last=$(cat "$STATE/sent.$key" 2>/dev/null || echo 0)
  [ $((now - last)) -lt $((hours * 3600)) ] && return 0
  if [ -s "$TOKEN_FILE" ] && curl -fsS -m 20 -o /dev/null -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
       -H "Title: $title" -H "Priority: $prio" -H "Tags: $tag" --data-binary "$msg" "$NTFY"; then
    echo "$now" > "$STATE/sent.$key"
    log "alert sent: $title"
  else
    log "ALERT NOT DELIVERED: $title"
  fi
}

if [ "$1" = "--test" ]; then
  notify test 0 "Converter watchdog test" \
    "Test alert from BeastNAS. The FileFlows to Stash watchdog can reach you here. You only hear from it when something breaks." 3 white_check_mark
  exit 0
fi

ffq() { sqlite3 -readonly -cmd ".timeout 5000" "$FFDB" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 1. Stash hand-off
KEY="$(sed -n 's/^api_key: *//p' /mnt/user/appdata/stash/config.yml | tr -d '"' | head -1)"
gql() { curl -fsS -m 30 -H "ApiKey: $KEY" -H "Content-Type: application/json" --data "$1" "$STASH"; }
stash_fail() {
  local n=$(( $(cat "$STATE/stash.fail" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE/stash.fail"
  [ "$n" -ge 3 ] && notify stash 6 "Stash hand-off is not running" \
    "$1 Converted videos will not be moved into their Stash scenes until this is fixed."
}

stash_ok=0
reply=$(gql '{"query":"{ jobQueue { description } }"}')
if echo "$reply" | jq -e '.data' > /dev/null 2>&1; then
  stash_ok=1
  if ! echo "$reply" | jq -e '[.data.jobQueue[]? | select((.description // "") | test("re-attach"; "i"))] | length > 0' > /dev/null; then
    out=$(gql '{"query":"mutation { runPluginTask(plugin_id: \"stashy-companion\", task_name: \"Re-attach Converted Files\", description: \"re-attach converted files (scheduled)\", args_map: {auto: true}) }"}')
    if echo "$out" | jq -e '.data.runPluginTask' > /dev/null 2>&1; then
      rm -f "$STATE/stash.fail"
    else
      stash_fail "Stash refused the re-attach task."
    fi
  fi
else
  stash_fail "Stash is not answering."
fi

# Errors the plugin reported about merging (first run only remembers what is already in the log).
plog=$(gql '{"query":"{ logs { time level message } }"}' | jq -r '.data.logs[]? | select(.message | test("Plugin / Stashy Companion")) | select(.level == "Error" or .level == "Warning") | select(.message | test("re-?attach|merge|converted"; "i")) | "\(.time) \(.message)"' 2>/dev/null)
if [ ! -f "$STATE/seen.logs" ]; then
  printf '%s\n' "$plog" > "$STATE/seen.logs"
else
  sent=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    grep -qxF -- "$line" "$STATE/seen.logs" && continue
    printf '%s\n' "$line" >> "$STATE/seen.logs"
    if [ "$sent" -lt 3 ]; then
      notify stashlog 0 "A converted video needs a look in Stash" "${line#* }"
      sent=$((sent + 1))
    fi
  done <<< "$plog"
  tail -n 300 "$STATE/seen.logs" > "$STATE/seen.logs.tmp" && mv "$STATE/seen.logs.tmp" "$STATE/seen.logs"
fi

# ---------------------------------------------------------------- 1b. New videos that have no Stash scene
# The generate flags Stash's own Tasks page shows ticked. Stash applies NO defaults itself: a scan that omits
# them generates nothing (no cover, preview, sprite or phash) and cannot be repaired by scanning again.
scan_options() {
  local d
  d=$(gql '{"query":"{ configuration { defaults { scan { scanGenerateCovers scanGeneratePreviews scanGenerateImagePreviews scanGenerateSprites scanGeneratePhashes scanGenerateImagePhashes scanGenerateThumbnails scanGenerateClipPreviews } } } }"}' \
    | jq -c '.data.configuration.defaults.scan // empty | with_entries(select(.value | type == "boolean"))' 2> /dev/null)
  if [ -z "$d" ] || ! echo "$d" | jq -e 'any(.[]; . == true)' > /dev/null 2>&1; then
    d='{"scanGenerateCovers":true,"scanGeneratePreviews":true,"scanGenerateSprites":true,"scanGeneratePhashes":true}'
  fi
  echo "$d"
}

# A file must keep the same size for one whole run first (the converter may still be copying it), is only
# handed over when Stash has no scene at that exact path, and is handed over once. Only top-level videos
# changed in the last 2 days are looked at (the converter drops its output there). Scoped to those paths.
TAB=$'\t'
if [ "$stash_ok" = 1 ] && [ -d "$LIB_HOST" ]; then
  touch "$STATE/new.prev" "$STATE/new.scanned"
  find "$LIB_HOST" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.avi' \
    -o -iname '*.wmv' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' -o -iname '*.flv' \) \
    -cmin -2880 -printf '%s\t%f\n' 2> /dev/null | sort -t "$TAB" -k2 > "$STATE/new.now"
  scan_busy=$(echo "$reply" | jq -r '[.data.jobQueue[]? | select((.description // "") | test("scan"; "i"))] | length')
  ready=()
  keys=()
  if [ "${scan_busy:-0}" = 0 ]; then
    while IFS="$TAB" read -r size name; do
      [ -z "$name" ] && continue
      key="$size$TAB$name"
      grep -qxF -- "$key" "$STATE/new.scanned" && continue
      grep -qxF -- "$key" "$STATE/new.prev" || continue
      cnt=$(gql "$(jq -nc --arg p "$LIB_STASH/$name" '{query: "query($p: String!) { findScenes(scene_filter: {path: {value: $p, modifier: EQUALS}}) { count } }", variables: {p: $p}}')" | jq -r '.data.findScenes.count // empty')
      if [ "$cnt" = 0 ]; then
        ready+=("$LIB_STASH/$name")
        keys+=("$key")
      elif [ -n "$cnt" ]; then
        echo "$key" >> "$STATE/new.scanned"
      fi
    done < "$STATE/new.now"
  fi
  if [ "${#ready[@]}" -gt 0 ]; then
    input=$(jq -nc --argjson o "$(scan_options)" --argjson p "$(printf '%s\n' "${ready[@]}" | jq -R . | jq -sc .)" '$o + {paths: $p}')
    out=$(gql "$(jq -nc --argjson i "$input" '{query: "mutation($i: ScanMetadataInput!) { metadataScan(input: $i) }", variables: {i: $i}}')")
    if echo "$out" | jq -e '.data.metadataScan' > /dev/null 2>&1; then
      printf '%s\n' "${keys[@]}" >> "$STATE/new.scanned"
      log "queued a Stash scan of ${#ready[@]} new video(s) that had no scene"
    else
      log "Stash refused the scan of ${#ready[@]} new video(s); will retry next run"
    fi
  fi
  cp "$STATE/new.now" "$STATE/new.prev"
  tail -n 3000 "$STATE/new.scanned" > "$STATE/new.scanned.tmp" && mv "$STATE/new.scanned.tmp" "$STATE/new.scanned"
fi

# ---------------------------------------------------------------- 2. FileFlows watchdog
if [ "$(docker inspect -f '{{.State.Running}}' "$FF" 2>/dev/null)" != true ]; then
  notify down 6 "FileFlows is not running" \
    "The FileFlows container is stopped, so videos in the RecycleBin are not being converted." 5 rotating_light
else
  started=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$FF")" +%s)
  img=$(docker inspect -f '{{.Image}}' "$FF" | cut -c8-19)

  # An image update (FileFlows auto-updates on :stable): tell Nitin once per change.
  if [ -f "$STATE/image" ]; then
    old=$(cat "$STATE/image")
    if [ "$old" != "$img" ]; then
      until_ts=$(date -u -d "@$((started + 180))" +%FT%TZ)
      ver=$(docker logs --since "$started" --until "$until_ts" "$FF" 2>&1 | grep -m1 -o 'Starting FileFlows [0-9.]*' | cut -d' ' -f3)
      notify "image-$img" 0 "FileFlows was updated" \
        "FileFlows changed image ${old} -> ${img}${ver:+ (version $ver)}. Nothing to do unless another alert follows." 3 arrows_counterclockwise
      echo "$img" > "$STATE/image"
    fi
  else
    echo "$img" > "$STATE/image"
  fi

  # ffmpeg must work inside the container (skipped while it is still installing its add-ons).
  if [ $((now - started)) -gt 300 ]; then
    if docker exec "$FF" /usr/local/bin/ffmpeg -version > /dev/null 2>&1; then
      rm -f "$STATE/ffmpeg.fail"
    else
      n=$(( $(cat "$STATE/ffmpeg.fail" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$STATE/ffmpeg.fail"
      [ "$n" -ge 2 ] && notify ffmpeg 24 "FileFlows has no working ffmpeg" \
        "FileFlows cannot encode video right now. Open fileflows.nateshome.net, Config, DockerMods, and check the FFmpeg add-on." 5 rotating_light
    fi
  fi

  # Add-on failures in the log since the last run (the 2026-10-29 outage left exactly these lines).
  last=$(cat "$STATE/lastrun" 2>/dev/null || echo $((now - 300)))
  [ $((now - last)) -gt 3600 ] && last=$((now - 3600))
  bad=$(docker logs --since "$last" "$FF" 2>&1 | grep -m1 -E "DockerMod '[^']*' not installed|Docker Mod Failed|Failed to run DockerMods")
  [ -n "$bad" ] && notify mods 24 "A FileFlows add-on is failing" \
    "FileFlows refuses files while an add-on is broken. Log line: ${bad:0:180}" 5 rotating_light

  # New failed conversions.
  failed=$(ffq "select count(*) from LibraryFile where Status=4")
  if [ -n "$failed" ]; then
    prev=$(cat "$STATE/failed" 2>/dev/null)
    if [ -n "$prev" ] && [ "$failed" -gt "$prev" ]; then
      names=$(ffq "select replace(Name, rtrim(Name, replace(Name, '/', '')), '') from LibraryFile where Status=4 order by ProcessingEnded desc limit 3")
      notify failed 0 "FileFlows could not convert $((failed - prev)) video(s)" "$names" 4 x
    fi
    echo "$failed" > "$STATE/failed"
  fi
fi

# Videos stuck in the RecycleBin: waiting over a day while nothing has converted for over a day.
find "$BIN" -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.wmv' \
  -o -iname '*.m4v' -o -iname '*.ts' -o -iname '*.webm' -o -iname '*.mpg' -o -iname '*.flv' \) -print 2> /dev/null | sort > "$STATE/bin.now"
touch "$STATE/bin.seen"
awk -F'\t' -v now="$now" 'FILENAME == ARGV[1] { s[$2]=$1; next } { print (($0 in s) ? s[$0] : now) "\t" $0 }' "$STATE/bin.seen" "$STATE/bin.now" > "$STATE/bin.new" \
  && mv "$STATE/bin.new" "$STATE/bin.seen"
stuck=$(awk -F'\t' -v lim=$((now - 86400)) '$1 < lim' "$STATE/bin.seen" | wc -l)
lastok=$(ffq "select coalesce(strftime('%s', max(ProcessingEnded)), 0) from LibraryFile where Status=1")
if [ "$stuck" -gt 0 ] && [ -n "$lastok" ] && [ $((now - lastok)) -gt 86400 ]; then
  notify stalled 24 "Videos are stuck in the RecycleBin" \
    "$stuck video(s) have waited over a day and nothing has been converted for $(( (now - lastok) / 86400 )) day(s). Check fileflows.nateshome.net." 4 hourglass
fi

echo "$now" > "$STATE/lastrun"

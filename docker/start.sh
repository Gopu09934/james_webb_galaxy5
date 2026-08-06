#!/bin/bash
set -euo pipefail

#############################################
# MARS 2020 PERSEVERANCE ROVER - LIVE STREAM
# Fetches Sol images from NASA and streams a
# documentary-style slideshow to YouTube.
#
# BATCHING MODEL (this version):
#   Each "batch" is MAX_IMAGES images. Batches
#   are consumed newest -> oldest, forever:
#     batch 1 = newest MAX_IMAGES images of the
#               latest Sol
#     batch 2 = the next-older MAX_IMAGES images
#               (same Sol, next page; or the
#               previous Sol once the current one
#               is exhausted)
#     ...and so on back through Sol history.
#   When we run off the bottom of Sol history we
#   wrap back around to "latest" and start again
#   (which by then may itself include newly
#   arrived images from a more recent Sol).
#
#   While batch N is being streamed to YouTube,
#   batch N+1 is fetched + downloaded in the
#   background, so there is ~zero dead time
#   between batches (double buffering).
#############################################

#############################################
# Validate Environment Variables
#############################################
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

NASA_API_KEY="${NASA_API_KEY:-DEMO_KEY}"

SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

echo "========================================"
echo "Starting Mars 2020 Perseverance Rover Stream"
echo "Output Resolution : 1280x720 (720p)"
echo "FPS               : 30"
echo "========================================"

#############################################
# Config
#############################################
FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
MARS_RED="0xC1440E"
ASSET_DIR="panel_assets"
IMAGES_BASE_DIR="mars_images"
BATCH_DIR_A="$IMAGES_BASE_DIR/batch_a"
BATCH_DIR_B="$IMAGES_BASE_DIR/batch_b"
SLIDE_DURATION=12
FACT_SLOT=10
TICKER_SPEED=100
CHANNEL_NAME="Technical Talk india"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
INFO_FONTSIZE=19
INFO_LINE_SPACING=8

MAX_IMAGES=80               # images per batch/episode (kept low — real-time CPU cost of zoompan+xfade)
MIN_SOL=0                   # floor of Sol history; below this we wrap back to "latest"
FETCH_MAX_SOL_STEPS=250      # safety valve: give up a single fetch attempt after stepping back this many Sols with nothing found
VIEWER_MIN_TO_SHOW=10

SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

MAX_RETRIES=5
RETRY_DELAY=5

# --- Ken Burns / transition settings (documentary style) ---
ZOOM_FPS=24
XFADE_DUR=1
ZOOM_MAX=1.5
ZOOM_STEP=0.0015
KB_SCALE_W=1400
KB_SCALE_H=788
TRANSITIONS=(fade dissolve wipeleft wiperight slideleft slideright smoothleft smoothright)

# --- Live telemetry panel (simulated, seeded from Sol number) ---
LANDING_DATE_EPOCH=$(date -u -d '2021-02-18' +%s 2>/dev/null || echo 1613606400)
ROVER_LAT="18.4446"
ROVER_LON="77.4509"
STATUS_SLOT=15

# --- Background music (loops for the whole stream) ---
MUSIC_URL="${MUSIC_URL:-}"
MUSIC_FILE="$ASSET_DIR/bgm_audio"
HAVE_MUSIC=false

# --- Batch cursor persistence (so the background prefetch job and the
# main loop agree on "which page/Sol comes next" via disk, since a
# backgrounded subshell can't hand bash variables back to the parent) ---
CURSOR_FILE="$ASSET_DIR/cursor_state.txt"

mkdir -p "$ASSET_DIR" "$BATCH_DIR_A" "$BATCH_DIR_B"

#############################################
# Mars Facts Pool
#############################################
MARS_FACTS=(
    "Mars is the fourth planet from the Sun and is known as the Red Planet."
    "A Martian day (Sol) is 24 hours, 39 minutes, and 35 seconds long."
    "Mars has two small moons: Phobos and Deimos."
    "The Perseverance rover landed in Jezero Crater on February 18, 2021."
    "Jezero Crater is believed to be an ancient lake bed billions of years old."
    "Perseverance carries the Ingenuity helicopter — the first powered aircraft on another planet."
    "Mars has the largest volcano in the solar system: Olympus Mons, 21 km tall."
    "Valles Marineris on Mars is a canyon system over 4,000 km long."
    "Mars has a thin atmosphere composed mostly of carbon dioxide (95%)."
    "Surface temperatures on Mars range from -125°C at the poles to 20°C at the equator."
    "Perseverance has 19 cameras for science, engineering, and navigation."
    "The rover carries 7 scientific instruments to study Mars geology and astrobiology."
    "Perseverance is searching for signs of ancient microbial life on Mars."
    "The MOXIE instrument on Perseverance converts CO2 into oxygen on Mars."
    "Perseverance has collected rock core samples to be returned to Earth in a future mission."
    "Mars is about half the size of Earth with a diameter of 6,779 km."
    "A Martian year lasts about 687 Earth days."
    "Mars has polar ice caps made of water ice and dry ice (CO2)."
    "The average distance from Earth to Mars is about 225 million km."
    "Radio signals from Mars take between 3 and 22 minutes to reach Earth."
    "NASA's Mars Reconnaissance Orbiter has been studying Mars since 2006."
    "Ingenuity has flown more than 70 flights on Mars, far exceeding its original 5-flight mission."
    "The SuperCam instrument on Perseverance uses lasers to analyze rocks from a distance."
    "Mars dust storms can sometimes engulf the entire planet for weeks or months."
    "Ancient Mars may have had liquid water rivers, lakes, and possibly an ocean."
    "Perseverance uses a radioisotope thermoelectric generator for power — it never runs out of sun."
    "The rover can travel up to 200 meters per Martian day across the surface."
    "Mastcam-Z on Perseverance can zoom in on objects hundreds of meters away."
    "Mars has the same land surface area as Earth — there are no oceans."
    "The first successful Mars rover was Sojourner, which landed in 1997."
    "Opportunity rover operated for 15 years on Mars, far beyond its 90-day mission."
    "Curiosity rover has been exploring Gale Crater since August 2012."
    "RIMFAX radar on Perseverance can peer up to 10 meters below the Martian surface."
    "Scientists study Mars to understand the history of water in our solar system."
    "Mars missions help us plan for future human exploration of the Red Planet."
)

#############################################
# Mars Headlines Pool
#############################################
MARS_HEADLINES=(
    "Perseverance rover exploring ancient Jezero Crater on Mars."
    "Scientists analyze Martian rock samples collected by Perseverance."
    "Ingenuity helicopter continues aerial reconnaissance of the Martian surface."
    "NASA's Perseverance searches for signs of ancient microbial life."
    "Perseverance collects pristine rock cores from the Martian lakebed."
    "Mars 2020 mission reveals secrets of Jezero Crater's ancient lake."
    "Perseverance rover captures stunning views of the Red Planet's terrain."
    "New Mars data challenges our understanding of early planetary evolution."
    "MOXIE demonstrates oxygen production from the thin Martian atmosphere."
    "Scientists map subsurface layers of Mars using RIMFAX ground-penetrating radar."
    "Mars sample return mission will bring Perseverance's cores back to Earth."
    "Perseverance's SuperCam laser vaporizes rocks to study their chemistry."
    "Dust devils and wind patterns reveal Martian atmospheric dynamics."
    "Ancient delta deposits in Jezero hint at a watery Martian past."
    "Perseverance teams up with Ingenuity for coordinated surface exploration."
)

#############################################
# Rover Status Pool (cycled in the telemetry panel)
#############################################
ROVER_STATUSES=(
    "ACTIVE — EXPLORING"
    "ACTIVE — DRIVING"
    "ACTIVE — SAMPLING ROCK CORE"
    "ACTIVE — IMAGING TERRAIN"
    "ACTIVE — TRANSMITTING DATA"
    "ACTIVE — ANALYZING SPECTRA"
)

#############################################
# Prepare looping background music (once)
#############################################
prepare_music() {
    if [ -z "$MUSIC_URL" ]; then
        echo "NOTICE: MUSIC_URL not set — streaming with silent audio track."
        return
    fi

    echo "----------------------------------------"
    echo "Preparing background music playlist from MUSIC_URL..."
    echo "----------------------------------------"

    # MUSIC_URL may hold one or more direct audio URLs, separated by
    # commas and/or newlines, e.g.:
    #   https://.../track1.mp3,https://.../track2.mp3,https://.../track3.mp3
    # Every valid track gets downloaded, validated, and normalized to a
    # common format, then concatenated into one playlist file that is
    # looped (-stream_loop -1) for the whole stream — so with several
    # URLs you get a rotating playlist instead of one repeating song.
    local IFS=$',\n'
    local raw_urls=($MUSIC_URL)
    unset IFS

    local valid_tracks=()
    local i=0
    local raw
    for raw in "${raw_urls[@]}"; do
        local url
        url=$(echo "$raw" | xargs)   # trim whitespace
        [ -z "$url" ] && continue
        i=$((i + 1))

        local track_raw="$ASSET_DIR/bgm_raw_${i}"
        local track_norm="$ASSET_DIR/bgm_norm_${i}.m4a"

        echo "  Track ${i}: $url"
        local attempt=1
        local ok=false
        while [ "$attempt" -le 3 ]; do
            if curl -sSL --max-time 60 -o "$track_raw" "$url" \
                && [ -s "$track_raw" ] \
                && ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
                   -of csv=p=0 "$track_raw" 2>/dev/null | grep -q audio; then
                ok=true
                break
            fi
            echo "    download/validation failed (attempt ${attempt}/3), retrying..."
            rm -f "$track_raw"
            attempt=$((attempt + 1))
            sleep 3
        done

        if [ "$ok" = true ]; then
            # Normalize so every track shares the same codec/rate/channels —
            # required for the concat step below to work reliably regardless
            # of what format each source file came in as.
            if ffmpeg -y -v error -i "$track_raw" -vn -ar 48000 -ac 2 -c:a aac -b:a 192k "$track_norm"; then
                valid_tracks+=("$track_norm")
                echo "    OK — normalized to $track_norm"
            else
                echo "    WARNING: normalization failed for track ${i}, skipping."
            fi
        else
            echo "    WARNING: could not fetch valid audio for track ${i}, skipping."
        fi
        rm -f "$track_raw"
    done

    if [ "${#valid_tracks[@]}" -eq 0 ]; then
        echo "WARNING: no valid tracks from MUSIC_URL — falling back to silent audio."
        HAVE_MUSIC=false
        return
    fi

    if [ "${#valid_tracks[@]}" -eq 1 ]; then
        mv -f "${valid_tracks[0]}" "$MUSIC_FILE"
    else
        local list_file="$ASSET_DIR/bgm_concat_list.txt"
        : > "$list_file"
        local t
        for t in "${valid_tracks[@]}"; do
            printf "file '%s'\n" "$(readlink -f "$t")" >> "$list_file"
        done
        if ffmpeg -y -v error -f concat -safe 0 -i "$list_file" -c copy "$MUSIC_FILE"; then
            :
        else
            echo "WARNING: playlist concat failed — falling back to first track only."
            cp -f "${valid_tracks[0]}" "$MUSIC_FILE"
        fi
        rm -f "${valid_tracks[@]}" "$list_file" 2>/dev/null || true
    fi

    echo "Background music playlist ready: $MUSIC_FILE (${i} URL(s) supplied, ${#valid_tracks[@]} usable track(s)). Will loop continuously."
    HAVE_MUSIC=true
}

#############################################
# Cursor state helpers
#
# The cursor is "SOL PAGE" on one line.
# SOL == "LATEST" is a sentinel meaning "re-probe
# the newest Sol on next fetch" (used for the
# very first run and whenever we wrap around
# after exhausting Sol history).
#############################################
read_cursor() {
    if [ -f "$CURSOR_FILE" ]; then
        read -r CURSOR_SOL CURSOR_PAGE < "$CURSOR_FILE"
    else
        CURSOR_SOL="LATEST"
        CURSOR_PAGE=0
    fi
}

write_cursor() {
    local sol="$1" page="$2"
    printf '%s %s\n' "$sol" "$page" > "${CURSOR_FILE}.tmp"
    mv -f "${CURSOR_FILE}.tmp" "$CURSOR_FILE"
}

#############################################
# probe_latest_sol — find the current newest Sol
# with images (used whenever CURSOR_SOL=LATEST)
#############################################
probe_latest_sol() {
    local BASE_URL="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"
    local probe_url="${BASE_URL}&num=1&page=0"
    echo "Probing latest Sol: $probe_url"
    local probe_resp
    probe_resp=$(curl -sSL --max-time 30 --retry 3 --retry-delay 5 \
        -H "Accept: application/json" \
        -A "MarsLiveStream/1.0" \
        "$probe_url" 2>/tmp/probe_err) || true

    if [ -s /tmp/probe_err ]; then
        echo "  curl stderr: $(cat /tmp/probe_err)"
    fi
    echo "  Probe response preview: ${probe_resp:0:200}"

    local sol=""
    if command -v jq &>/dev/null; then
        sol=$(echo "$probe_resp" | jq -r '.images[0].sol // empty' 2>/dev/null || true)
    fi
    if [ -z "${sol:-}" ]; then
        sol=$(echo "$probe_resp" | grep -o '"sol":[0-9]*' | head -1 | grep -o '[0-9]*')
    fi
    if [ -z "${sol:-}" ]; then
        echo "ERROR: Could not determine latest Sol."
        return 1
    fi
    echo "Latest Sol: $sol"
    PROBED_SOL="$sol"
    return 0
}

#############################################
# fetch_batch
#
# Reads the cursor, fetches exactly one page
# (up to MAX_IMAGES images) for the current
# Sol/page. If that Sol+page is empty, steps
# back one Sol at a time (page reset to 0) until
# it finds images, wrapping back to LATEST if it
# falls below MIN_SOL. Advances + persists the
# cursor for whoever calls fetch_batch next.
#
# On success sets: CURRENT_SOL, FETCHED_IMAGES,
# CAMERA_NAMES, EARTH_DATES, SOL_TIMES,
# IMG_CAPTIONS
#############################################
fetch_batch() {
    local BASE_URL="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"
    read_cursor

    local steps=0
    while [ "$steps" -lt "$FETCH_MAX_SOL_STEPS" ]; do
        if [ "$CURSOR_SOL" = "LATEST" ]; then
            if ! probe_latest_sol; then
                return 1
            fi
            CURSOR_SOL="$PROBED_SOL"
            CURSOR_PAGE=0
        fi

        local url="${BASE_URL}&num=${MAX_IMAGES}&page=${CURSOR_PAGE}&condition_2=${CURSOR_SOL}:sol:eq"
        echo "  Fetching Sol ${CURSOR_SOL}, page ${CURSOR_PAGE}: $url"
        local resp
        resp=$(curl -sSL --max-time 60 --retry 3 --retry-delay 5 \
            -H "Accept: application/json" \
            -A "MarsLiveStream/1.0" \
            "$url" 2>/dev/null) || true

        FETCHED_IMAGES=()
        CAMERA_NAMES=()
        EARTH_DATES=()
        SOL_TIMES=()
        IMG_CAPTIONS=()

        local batch_count=0
        if command -v jq &>/dev/null; then
            batch_count=$(echo "$resp" | jq '.images | length' 2>/dev/null || echo 0)
            if [ "${batch_count:-0}" -gt 0 ]; then
                mapfile -t FETCHED_IMAGES < <(echo "$resp" | jq -r '.images[].image_files.large // .images[].image_files.medium // empty' 2>/dev/null)
                mapfile -t CAMERA_NAMES  < <(echo "$resp" | jq -r '.images[].camera.instrument // empty' 2>/dev/null)
                mapfile -t EARTH_DATES   < <(echo "$resp" | jq -r '.images[].date_taken_utc // empty' 2>/dev/null)
                mapfile -t SOL_TIMES     < <(echo "$resp" | jq -r '.images[].date_taken_mars // empty' 2>/dev/null)
                mapfile -t IMG_CAPTIONS  < <(echo "$resp" | jq -r '.images[].title // empty' 2>/dev/null)
            fi
        else
            echo "WARNING: jq not installed — grep fallback"
            mapfile -t FETCHED_IMAGES < <(echo "$resp" | grep -o '"large":"[^"]*"' | sed 's/"large":"//;s/"//')
            mapfile -t CAMERA_NAMES  < <(echo "$resp" | grep -o '"instrument":"[^"]*"' | sed 's/"instrument":"//;s/"//')
            mapfile -t EARTH_DATES   < <(echo "$resp" | grep -o '"date_taken_utc":"[^"]*"' | sed 's/"date_taken_utc":"//;s/"//')
            batch_count=${#FETCHED_IMAGES[@]}
        fi

        if [ "${batch_count:-0}" -gt 0 ]; then
            CURRENT_SOL="$CURSOR_SOL"
            echo "  SUCCESS: Sol ${CURRENT_SOL} page ${CURSOR_PAGE} — ${batch_count} images."
            write_cursor "$CURSOR_SOL" "$((CURSOR_PAGE + 1))"
            return 0
        fi

        echo "  Sol ${CURSOR_SOL} page ${CURSOR_PAGE} empty — stepping back one Sol."
        CURSOR_SOL=$((CURSOR_SOL - 1))
        CURSOR_PAGE=0
        if [ "$CURSOR_SOL" -lt "$MIN_SOL" ]; then
            echo "  Reached bottom of Sol history — wrapping back to LATEST."
            CURSOR_SOL="LATEST"
        fi
        steps=$((steps + 1))
    done

    echo "ERROR: fetch_batch gave up after ${FETCH_MAX_SOL_STEPS} Sol steps with no images."
    return 1
}

#############################################
# download_batch — HTTP + JPEG validation,
# writes into $1 (a batch directory), and writes
# sidecar metadata files aligned with the kept
# (validated) images, in the same order they end
# up in when listed/sorted for the slideshow.
#############################################
download_batch() {
    local target_dir="$1"
    local n=${#FETCHED_IMAGES[@]}
    echo "Downloading and validating $n images for Sol $CURRENT_SOL into $target_dir..."

    mkdir -p "$target_dir"
    rm -f "$target_dir"/*.jpg "$target_dir"/*.JPG 2>/dev/null || true
    : > "$target_dir/meta_camera.txt"
    : > "$target_dir/meta_date.txt"
    : > "$target_dir/meta_soltime.txt"
    : > "$target_dir/meta_caption.txt"
    printf '%s' "$CURRENT_SOL" > "$target_dir/sol.txt"

    local downloaded=0 rejected=0 idx=0
    for url in "${FETCHED_IMAGES[@]}"; do
        idx=$((idx + 1))
        local outfile="$target_dir/mars_sol${CURRENT_SOL}_$(printf '%03d' $idx).jpg"

        local http_code
        http_code=$(curl -sL --max-time 30 \
            -o "$outfile" \
            -w '%{http_code}' \
            "$url" 2>/dev/null || echo "000")

        if [ "$http_code" != "200" ] || [ ! -s "$outfile" ]; then
            [ -f "$outfile" ] && rm -f "$outfile"
            rejected=$((rejected + 1))
            continue
        fi

        local magic
        magic=$(head -c 2 "$outfile" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [[ "$magic" != "ffd8"* ]]; then
            echo "  [REJECT] $(basename "$outfile"): not a JPEG (magic=$magic)"
            rm -f "$outfile"
            rejected=$((rejected + 1))
            continue
        fi

        if ! ffprobe -v error \
            -select_streams v:0 \
            -show_entries stream=width \
            -of csv=p=0 \
            "$outfile" >/dev/null 2>&1; then
            echo "  [REJECT] $(basename "$outfile"): ffprobe decode failed"
            rm -f "$outfile"
            rejected=$((rejected + 1))
            continue
        fi

        downloaded=$((downloaded + 1))
        printf '%s\n' "${CAMERA_NAMES[$((idx - 1))]:-Unknown Camera}" >> "$target_dir/meta_camera.txt"
        printf '%s\n' "${EARTH_DATES[$((idx - 1))]:-}" >> "$target_dir/meta_date.txt"
        printf '%s\n' "${SOL_TIMES[$((idx - 1))]:-}" >> "$target_dir/meta_soltime.txt"
        printf '%s\n' "${IMG_CAPTIONS[$((idx - 1))]:-}" >> "$target_dir/meta_caption.txt"
    done

    echo "Download complete into $target_dir: $downloaded valid / $n total ($rejected rejected)."
}

#############################################
# fetch_and_prepare — fetch_batch + download_batch
# combined, targeting a given batch directory.
# This is the unit of work run synchronously for
# the first batch, and in the background for
# every batch after that.
#############################################
fetch_and_prepare() {
    local target_dir="$1"
    if fetch_batch; then
        download_batch "$target_dir"
        return 0
    fi
    echo "ERROR: fetch_and_prepare failed for $target_dir"
    return 1
}

#############################################
# load_batch — populate CURRENT_SOL and the
# metadata arrays from a previously-prepared
# batch directory (used right before streaming
# it).
#############################################
load_batch() {
    local dir="$1"
    CURRENT_SOL=$(cat "$dir/sol.txt" 2>/dev/null || echo "unknown")
    CAMERA_NAMES=()
    EARTH_DATES=()
    SOL_TIMES=()
    IMG_CAPTIONS=()
    [ -f "$dir/meta_camera.txt" ]  && mapfile -t CAMERA_NAMES  < "$dir/meta_camera.txt"
    [ -f "$dir/meta_date.txt" ]    && mapfile -t EARTH_DATES   < "$dir/meta_date.txt"
    [ -f "$dir/meta_soltime.txt" ] && mapfile -t SOL_TIMES     < "$dir/meta_soltime.txt"
    [ -f "$dir/meta_caption.txt" ] && mapfile -t IMG_CAPTIONS  < "$dir/meta_caption.txt"
    DOWNLOAD_COUNT=$(ls "$dir"/mars_sol*.jpg 2>/dev/null | wc -l | tr -d ' ')
}

#############################################
# Generate live telemetry text (seeded from Sol)
#############################################
generate_telemetry_assets() {
    local seed=$((CURRENT_SOL + 1000))
    RANDOM=$seed
    local temp_high=$(( -35 - (RANDOM % 20) ))
    RANDOM=$((seed + 1))
    local wind=$(( 6 + (RANDOM % 24) ))
    RANDOM=$((seed + 2))
    local pressure=$(( 640 + (RANDOM % 120) ))

    printf '%s°C' "$temp_high" > "$ASSET_DIR/temp.txt"
    printf '%s km/h' "$wind"   > "$ASSET_DIR/wind.txt"
    printf '%s Pa' "$pressure" > "$ASSET_DIR/pressure.txt"

    local now_epoch mission_days
    now_epoch=$(date -u +%s)
    mission_days=$(( (now_epoch - LANDING_DATE_EPOCH) / 86400 ))
    printf 'SOL %s  •  %s days on Mars' "$CURRENT_SOL" "$mission_days" > "$ASSET_DIR/timeonmars.txt"

    printf '%s°N  %s°E' "$ROVER_LAT" "$ROVER_LON" > "$ASSET_DIR/location.txt"

    local i idx
    local SHUFFLED_STATUS=()
    while IFS= read -r line; do
        SHUFFLED_STATUS+=("$line")
    done < <(printf '%s\n' "${ROVER_STATUSES[@]}" | shuf)
    STATUS_N=${#SHUFFLED_STATUS[@]}
    for i in "${!SHUFFLED_STATUS[@]}"; do
        idx=$((i + 1))
        printf '%s' "${SHUFFLED_STATUS[$i]}" > "$ASSET_DIR/status${idx}.txt"
    done
}

#############################################
# Write panel text files
#############################################
write_panel_assets() {
    generate_telemetry_assets
    printf 'MARS 2020'                          > "$ASSET_DIR/title1.txt"
    printf 'P E R S E V E R A N C E  R O V E R' > "$ASSET_DIR/title2.txt"
    printf "SOL %s RAW IMAGERY"  "$CURRENT_SOL" > "$ASSET_DIR/header.txt"
    printf 'LIVE FROM THE RED PLANET'           > "$ASSET_DIR/eyebrow.txt"
    printf 'SUBSCRIBE for daily Mars updates'   > "$ASSET_DIR/cta.txt"
    printf 'MARS FACT'                          > "$ASSET_DIR/fact_label.txt"

    local i idx
    local SHUFFLED_FACTS=()
    while IFS= read -r line; do
        SHUFFLED_FACTS+=("$line")
    done < <(printf '%s\n' "${MARS_FACTS[@]}" | shuf)
    FACT_N=${#SHUFFLED_FACTS[@]}
    for i in "${!SHUFFLED_FACTS[@]}"; do
        idx=$((i + 1))
        echo "${SHUFFLED_FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
    done

    local SHUFFLED_HEADS=()
    while IFS= read -r line; do
        SHUFFLED_HEADS+=("$line")
    done < <(printf '%s\n' "${MARS_HEADLINES[@]}" | shuf)
    HEAD_N=${#SHUFFLED_HEADS[@]}

    local TICKER_STRING=""
    for line in "${SHUFFLED_HEADS[@]}"; do
        TICKER_STRING+="${line}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"
}

#############################################
# Collect sorted list of downloaded image files
# for a given batch directory.
#############################################
build_image_array() {
    local dir="$1"
    IMAGE_FILES=()
    while IFS= read -r f; do
        IMAGE_FILES+=("$f")
    done < <(ls "$dir"/mars_sol*.jpg 2>/dev/null | sort)
    echo "Image array built: ${#IMAGE_FILES[@]} slides for Sol $CURRENT_SOL (dir: $dir)"
}

#############################################
# Ken Burns + crossfade slideshow chain
#############################################
build_slideshow_filter() {
    local n="$1"
    local chain=""
    local prev=""

    for ((i = 0; i < n; i++)); do
        local is_last=0
        [ "$i" -eq $((n - 1)) ] && is_last=1

        local dur=$SLIDE_DURATION
        [ "$is_last" -eq 0 ] && dur=$((SLIDE_DURATION + XFADE_DUR))
        local frames=$((dur * ZOOM_FPS))

        local variant=$((i % 4))
        local z x y
        case "$variant" in
            0)
                z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
                x="iw/2-(iw/zoom/2)"
                y="ih/2-(ih/zoom/2)"
                ;;
            1)
                z="if(eq(on\,1)\,${ZOOM_MAX}\,max(1.001\,zoom-${ZOOM_STEP}))"
                x="iw/2-(iw/zoom/2)"
                y="ih/2-(ih/zoom/2)"
                ;;
            2)
                z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
                x="iw/2-(iw/zoom/2)+(on*0.35)"
                y="ih/2-(ih/zoom/2)-(on*0.20)"
                ;;
            3)
                z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
                x="iw/2-(iw/zoom/2)-(on*0.35)"
                y="ih/2-(ih/zoom/2)+(on*0.20)"
                ;;
        esac

        local label="img${i}"
        chain+="[${i}:v]scale=${KB_SCALE_W}:${KB_SCALE_H}:force_original_aspect_ratio=increase,"
        chain+="crop=${KB_SCALE_W}:${KB_SCALE_H},"
        chain+="zoompan=z='${z}':x='${x}':y='${y}':d=${frames}:s=1280x720:fps=${ZOOM_FPS},"
        chain+="format=yuv420p,setsar=1[${label}];"

        if [ "$i" -eq 0 ]; then
            prev="$label"
        else
            local transition="${TRANSITIONS[$(( (i - 1) % ${#TRANSITIONS[@]} ))]}"
            local offset=$((i * SLIDE_DURATION))
            local nxt="xf${i}"
            chain+="[${prev}][${label}]xfade=transition=${transition}:duration=${XFADE_DUR}:offset=${offset}[${nxt}];"
            prev="$nxt"
        fi
    done

    chain+="[${prev}]eq=brightness=0.06:contrast=1.18:saturation=1.15:gamma=1.04[${prev}_graded];"

    SLIDESHOW_FILTER="$chain"
    SLIDESHOW_LABEL="${prev}_graded"
}

#############################################
# Build per-slide info overlay
#############################################
build_slide_info_chain() {
    local n="$1"
    local chain=""
    local prev="base"
    local CYCLE=$((n * SLIDE_DURATION))

    for ((i = 0; i < n; i++)); do
        local idx=$((i + 1))
        local start=$((i * SLIDE_DURATION))
        local end=$((start + SLIDE_DURATION))
        local cam="${CAMERA_NAMES[$i]:-Unknown Camera}"
        local edate="${EARTH_DATES[$i]:-}"

        printf 'TRANSMISSION FROM MARS\nSol %s  ·  Frame %d of %d\n%s' \
            "$CURRENT_SOL" "$idx" "$n" "$cam" \
            > "$ASSET_DIR/slide_info${idx}.txt"
        if [ -n "$edate" ]; then
            local edate_short="${edate:0:16}"
            edate_short="${edate_short/T/ }"
            printf '\nEarth Date: %s UTC' "$edate_short" >> "$ASSET_DIR/slide_info${idx}.txt"
        fi

        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.5)\,(mod(t\,${CYCLE})-${start})/0.5\,if(gt(mod(t\,${CYCLE})-${start}\,${SLIDE_DURATION}-0.5)\,(${end}-mod(t\,${CYCLE}))/0.5\,1))\,0)"

        local box="sib${idx}"
        chain+="[${prev}]drawbox=x=365:y=548:w=350:h=118:color=black@0.55:t=fill:enable='${ENABLE}'[${box}];"
        local barlbl="sil${idx}"
        chain+="[${box}]drawbox=x=365:y=548:w=4:h=118:color=${MARS_RED}:t=fill:enable='${ENABLE}'[${barlbl}];"

        local nxt="si${idx}"
        chain+="[${barlbl}]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/slide_info${idx}.txt:fontcolor=white:fontsize=15:line_spacing=7:x=385:y=560:alpha='${ALPHA}':borderw=1.5:bordercolor=black@0.85:${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    SLIDE_INFO_CHAIN="$chain"
    SLIDE_INFO_END="$prev"
}

#############################################
# Background clock writer
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber count writer
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live viewer count writer
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    [ -n "$VIEWERS" ] && LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true
      [ -n "$SUBS_PID" ]    && kill "$SUBS_PID"    2>/dev/null || true
      [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true
      [ -n "${PREFETCH_PID:-}" ] && kill "$PREFETCH_PID" 2>/dev/null || true
      echo "Stream ended — cleaning up."' EXIT

#############################################
# build_full_filter
#############################################
build_full_filter() {
    local n_slides="$1"
    local FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local CTA_CYCLE=180
    local CTA_SHOW=8

    build_slideshow_filter "$n_slides"

    local F=""
    F+="$SLIDESHOW_FILTER"
    F+="[${OVERLAY_INPUT_IDX}:v]scale=1280:720:flags=fast_bilinear[ovl];"
    F+="[ovl][${SLIDESHOW_LABEL}]overlay=0:0[base];"

    build_slide_info_chain "$n_slides"
    F+="$SLIDE_INFO_CHAIN"
    local prev="$SLIDE_INFO_END"

    F+="[${prev}]drawbox=x=0:y=0:w=333:h=720:color=0x05080C@0.72:t=fill[p1];"
    F+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
    F+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
    F+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
    F+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${MARS_RED}@0.9:t=fill[p5];"
    F+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${MARS_RED}@0.6:t=fill[p6];"

    F+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
    F+="[p7]drawtext=fontfile=${FONT}:expansion=none:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

    F+="[p8]drawtext=fontfile=${FONT}:expansion=none:text='Credits\: NASA/JPL-Caltech':fontcolor=white@0.85:fontsize=13:x=313-text_w:y=19[p9];"
    F+="[p9]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=13:x=313-text_w:y=37[p10];"
    F+="[p10]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=12:x=313-text_w:y=55[p10b];"
    F+="[p10b]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=12:x=313-text_w:y=72[p10c];"

    F+="[p10c]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/title1.txt:fontcolor=${MARS_RED}:fontsize=26:x=33:y=95:${SHADOW}[p11];"
    F+="[p11]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.90:fontsize=15:x=33:y=127:${SHADOW}[p12];"
    F+="[p12]drawbox=x=33:y=157:w=280:h=2:color=white@0.3:t=fill[p13];"

    F+="[p13]drawbox=x=33:y=171:w=10:h=10:color=${MARS_RED}:t=fill[p14];"
    F+="[p14]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=50:y=169[p15];"
    F+="[p15]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${MARS_RED}@0.90:fontsize=12:x=33:y=198[p16];"

    local SLIDE_CYCLE=$((n_slides * SLIDE_DURATION))
    F+="[p16]drawtext=fontfile=${FONT}:expansion=none:text='IMAGE GALLERY':fontcolor=white@0.35:fontsize=9:x=33:y=225[pgcap];"
    F+="[pgcap]drawbox=x=33:y=238:w=280:h=3:color=white@0.15:t=fill[pg1];"
    F+="[pg1]drawbox=x=33:y=238:w='280*(mod(t\,${SLIDE_DURATION}))/${SLIDE_DURATION}':h=3:color=${MARS_RED}:t=fill[pg2];"

    local prev2="pg2"
    local max_dots=10
    local dot_n=$((n_slides < max_dots ? n_slides : max_dots))
    for ((i = 0; i < dot_n; i++)); do
        local dot_x=$((33 + i * 26))
        local nxt="db$((i+1))"
        F+="[${prev2}]drawbox=x=${dot_x}:y=252:w=9:h=9:color=white@0.25:t=fill[${nxt}];"
        prev2="$nxt"
    done
    for ((i = 0; i < dot_n; i++)); do
        local dot_x=$((33 + i * 26))
        local start=$((i * SLIDE_DURATION))
        local end=$((start + SLIDE_DURATION))
        local ENABLE="between(mod(t\,${SLIDE_CYCLE})\,${start}\,${end})"
        local nxt="da$((i+1))"
        F+="[${prev2}]drawbox=x=${dot_x}:y=252:w=9:h=9:color=${MARS_RED}:t=fill:enable='${ENABLE}'[${nxt}];"
        prev2="$nxt"
    done

    F+="[${prev2}]drawbox=x=33:y=282:w=280:h=2:color=${MARS_RED}@0.5:t=fill[fp0];"
    F+="[fp0]drawbox=x=33:y=289:w=8:h=8:color=${GOLD}:t=fill[fp0b];"
    F+="[fp0b]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.90:fontsize=12:x=49:y=290[fp1];"
    local fp_prev="fp1"
    for ((i = 0; i < FACT_N; i++)); do
        local fidx=$((i + 1))
        local fstart=$((i * FACT_SLOT))
        local fend=$((fstart + FACT_SLOT))
        local nxt="f${fidx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${fstart}\,${fend})\,if(lt(mod(t\,${FACT_CYCLE})-${fstart}\,0.5)\,(mod(t\,${FACT_CYCLE})-${fstart})/0.5\,if(gt(mod(t\,${FACT_CYCLE})-${fstart}\,${FACT_SLOT}-0.5)\,(${fend}-mod(t\,${FACT_CYCLE}))/0.5\,1))\,0)"
        F+="[${fp_prev}]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/fact${fidx}.txt:fontcolor=white@0.90:fontsize=16:line_spacing=7:x=33:y=318:alpha='${FALPHA}'[${nxt}];"
        fp_prev="$nxt"
    done

    F+="[${fp_prev}]drawbox=x=10:y=415:w=326:h=135:color=black@0.45:t=fill[tl0];"
    F+="[tl0]drawbox=x=10:y=415:w=5:h=135:color=${GOLD}:t=fill[tl1];"
    F+="[tl1]drawtext=fontfile=${FONT}:expansion=none:text='LIVE TELEMETRY':fontcolor=${GOLD}:fontsize=11:x=22:y=422[tl2];"

    F+="[tl2]drawtext=fontfile=${FONT}:expansion=none:text='TEMP\:':fontcolor=white@0.70:fontsize=12:x=22:y=441[tl3];"
    F+="[tl3]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/temp.txt:reload=1:fontcolor=${MARS_RED}:fontsize=13:x=68:y=440[tl4];"
    F+="[tl4]drawtext=fontfile=${FONT}:expansion=none:text='WIND\:':fontcolor=white@0.70:fontsize=12:x=180:y=441[tl5];"
    F+="[tl5]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/wind.txt:reload=1:fontcolor=white@0.90:fontsize=13:x=228:y=440[tl6];"

    F+="[tl6]drawtext=fontfile=${FONT}:expansion=none:text='PRESSURE\:':fontcolor=white@0.70:fontsize=12:x=22:y=459[tl7];"
    F+="[tl7]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/pressure.txt:reload=1:fontcolor=white@0.90:fontsize=13:x=100:y=458[tl8];"
    F+="[tl8]drawbox=x=180:y=460:w=8:h=8:color=0x3DDC84:t=fill:enable='lt(mod(t\,3)\,2.5)'[tl9];"
    F+="[tl9]drawtext=fontfile=${FONT}:expansion=none:text='SIGNAL LOCKED':fontcolor=white@0.85:fontsize=12:x=194:y=459[tl10];"

    F+="[tl10]drawtext=fontfile=${FONT}:expansion=none:text='LOC\:':fontcolor=white@0.70:fontsize=12:x=22:y=477[tl11];"
    F+="[tl11]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/location.txt:reload=1:fontcolor=white@0.90:fontsize=12:x=58:y=477[tl12];"

    F+="[tl12]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/timeonmars.txt:reload=1:fontcolor=${GOLD}@0.90:fontsize=12:x=22:y=495[tl13];"

    local STATUS_CYCLE=$((STATUS_N * STATUS_SLOT))
    F+="[tl13]drawbox=x=22:y=513:w=9:h=9:color=0x3DDC84:t=fill:enable='lt(mod(t\,2)\,1.6)'[tl14];"
    F+="[tl14]drawtext=fontfile=${FONT}:expansion=none:text='STATUS\:':fontcolor=white@0.70:fontsize=11:x=38:y=513[tl15];"
    local st_prev="tl15"
    for ((i = 0; i < STATUS_N; i++)); do
        local sidx=$((i + 1))
        local sstart=$((i * STATUS_SLOT))
        local send=$((sstart + STATUS_SLOT))
        local nxt="st${sidx}"
        local SALPHA="if(between(mod(t\,${STATUS_CYCLE})\,${sstart}\,${send})\,if(lt(mod(t\,${STATUS_CYCLE})-${sstart}\,0.4)\,(mod(t\,${STATUS_CYCLE})-${sstart})/0.4\,if(gt(mod(t\,${STATUS_CYCLE})-${sstart}\,${STATUS_SLOT}-0.4)\,(${send}-mod(t\,${STATUS_CYCLE}))/0.4\,1))\,0)"
        F+="[${st_prev}]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/status${sidx}.txt:fontcolor=white@0.92:fontsize=11:x=86:y=513:alpha='${SALPHA}'[${nxt}];"
        st_prev="$nxt"
    done

    F+="[${st_prev}]drawtext=fontfile=${FONT}:expansion=none:text='POWER\:':fontcolor=white@0.70:fontsize=11:x=22:y=534[tlp1];"
    F+="[tlp1]drawbox=x=70:y=532:w=110:h=9:color=white@0.15:t=fill[tlp2];"
    F+="[tlp2]drawbox=x=70:y=532:w='110*(0.80+0.10*sin(t/6))':h=9:color=0x3DDC84:t=fill[tlp3];"
    F+="[tlp3]drawbox=x=70:y=532:w=110:h=9:color=white@0.35:t=2[tlp4];"
    F+="[tlp4]drawtext=fontfile=${FONT}:expansion=none:text='RTG STABLE':fontcolor=white@0.55:fontsize=10:x=186:y=533[tel_end];"

    F+="[tel_end]drawbox=x=10:y=560:w=326:h=115:color=black@0.45:t=fill[mi0];"
    F+="[mi0]drawbox=x=10:y=560:w=5:h=115:color=${MARS_RED}:t=fill[mi1];"
    F+="[mi1]drawtext=fontfile=${FONT}:expansion=none:text='MISSION STATS':fontcolor=${GOLD}:fontsize=11:x=22:y=567[mi2];"
    F+="[mi2]drawtext=fontfile=${FONT}:expansion=none:text='Rover\: Perseverance (Percy)':fontcolor=white@0.85:fontsize=13:x=22:y=585[mi3];"
    F+="[mi3]drawtext=fontfile=${FONT}:expansion=none:text='Landing\: Feb 18\, 2021':fontcolor=white@0.85:fontsize=13:x=22:y=602[mi4];"
    F+="[mi4]drawtext=fontfile=${FONT}:expansion=none:text='Location\: Jezero Crater':fontcolor=white@0.85:fontsize=13:x=22:y=619[mi5];"
    F+="[mi5]drawtext=fontfile=${FONT}:expansion=none:text='Sol\: ${CURRENT_SOL}':fontcolor=${MARS_RED}:fontsize=15:x=22:y=638[mi6];"
    F+="[mi6]drawtext=fontfile=${FONT}:expansion=none:text='Images\: ${DOWNLOAD_COUNT} in this batch':fontcolor=white@0.75:fontsize=12:x=22:y=659[mi7];"

    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.5)\,mod(t\,${CTA_CYCLE})/0.5\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.5)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.5\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    F+="[mi7]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill[cta_bg];"
    F+="[cta_bg]drawbox=x=733:y=620:w=4:h=43:color=${MARS_RED}:t=fill[cta_bar];"
    F+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    F+="[cta_dot]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_sub];"
    F+="[cta_sub]drawtext=fontfile=${FONT}:expansion=none:text='New batch every ${SLIDE_DURATION}s':fontcolor=white@0.80:fontsize=19:x=773:y=633:enable='not(${CTA_ENABLE})'[cta_final];"

    F+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
    F+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${MARS_RED}@0.9:t=fill[tk2];"
    F+="[tk2]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    F+="[tk3]drawbox=x=0:y=680:w=130:h=40:color=black@0.85:t=fill[tk4];"
    F+="[tk4]drawbox=x=0:y=682:w=123:h=38:color=${MARS_RED}:t=fill[tk5];"
    F+="[tk5]drawtext=fontfile=${FONT}:expansion=none:text='MARS LIVE':fontcolor=white:fontsize=14:x=12:y=695[tk6];"

    F+="[tk6]drawbox=x=985:y=14:w=281:h=26:color=black@0.30:t=fill[wmbg];"
    F+="[wmbg]drawtext=fontfile=${FONT}:expansion=none:text='${CHANNEL_NAME}':fontcolor=white@0.55:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=997:y=20[wm1];"

    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    F+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=3:enable='${SUB_PULSE_ENABLE}'[wm2];"

    F+="[wm2]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$F"
}

#############################################
# Stream one batch (directory) to YouTube
#############################################
run_stream() {
    local dir="$1"
    local n_slides="$2"
    local attempt=1

    build_image_array "$dir"
    if [ "${#IMAGE_FILES[@]}" -ne "$n_slides" ]; then
        echo "WARNING: image array (${#IMAGE_FILES[@]}) doesn't match slide count ($n_slides) — resyncing."
        n_slides=${#IMAGE_FILES[@]}
    fi
    if [ "$n_slides" -eq 0 ]; then
        echo "ERROR: no images to stream."
        return 1
    fi

    OVERLAY_INPUT_IDX=$n_slides
    AUDIO_INPUT_IDX=$((n_slides + 1))

    local filter
    filter=$(build_full_filter "$n_slides")

    local filter_script="$ASSET_DIR/filter_complex.txt"
    printf '%s' "$filter" > "$filter_script"

    local INPUT_ARGS=()
    local f
    for f in "${IMAGE_FILES[@]}"; do
        INPUT_ARGS+=(-loop 1 -i "$f")
    done
    INPUT_ARGS+=(-loop 1 -i overlay.png)

    if [ "$HAVE_MUSIC" = true ]; then
        INPUT_ARGS+=(-stream_loop -1 -re -i "$MUSIC_FILE")
    else
        INPUT_ARGS+=(-f lavfi -i anullsrc=r=48000:cl=stereo)
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming Sol $CURRENT_SOL ($n_slides slides from $dir, music=${HAVE_MUSIC}) — attempt ${attempt}/${MAX_RETRIES}"
        echo "----------------------------------------"
        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        "${INPUT_ARGS[@]}" \
        -filter_complex_script "$filter_script" \
        -map "[final]" \
        -map "${AUDIO_INPUT_IDX}:a" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Batch cycle complete."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this batch."
        fi
    done
    return 1
}

#############################################
# MAIN LOOP — double-buffered batches
#
# CUR_DIR streams while NXT_DIR is prefetched in
# the background. When streaming finishes, we
# wait for the prefetch to finish (usually
# already done), swap CUR_DIR <-> NXT_DIR, and
# go again — forever, newest Sol/page first,
# stepping to older pages/Sols each batch, and
# wrapping back to LATEST once Sol history is
# exhausted.
#############################################
echo ""
echo "Starting Mars Live Stream main loop (double-buffered batches)..."
echo ""

prepare_music

CURRENT_SOL=""
FETCHED_IMAGES=()
CAMERA_NAMES=()
EARTH_DATES=()
SOL_TIMES=()
IMG_CAPTIONS=()
IMAGE_FILES=()
OVERLAY_INPUT_IDX=0
AUDIO_INPUT_IDX=0
DOWNLOAD_COUNT=0
FACT_N=0
HEAD_N=0
STATUS_N=0
PREFETCH_PID=""

CUR_DIR="$BATCH_DIR_A"
NXT_DIR="$BATCH_DIR_B"

# Fresh start: forget any stale cursor from a previous run so we begin
# at the true latest Sol.
rm -f "$CURSOR_FILE"

echo "Preparing first batch synchronously..."
until fetch_and_prepare "$CUR_DIR"; do
    echo "Initial batch fetch failed — retrying in 60s..."
    sleep 60
done

while true; do
    echo "========================================"
    echo "New batch cycle starting at $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo "========================================"

    load_batch "$CUR_DIR"
    N_SLIDES=$(ls "$CUR_DIR"/mars_sol*.jpg 2>/dev/null | wc -l | tr -d ' ')

    if [ "$N_SLIDES" -eq 0 ]; then
        echo "ERROR: current batch has no valid images — re-fetching in place..."
        until fetch_and_prepare "$CUR_DIR"; do
            echo "Re-fetch failed — retrying in 60s..."
            sleep 60
        done
        continue
    fi

    write_panel_assets

    # Prefetch the NEXT (older) batch in the background while this one streams
    (
        fetch_and_prepare "$NXT_DIR"
    ) &
    PREFETCH_PID=$!

    run_stream "$CUR_DIR" "$N_SLIDES" || true

    echo "Waiting for background prefetch of next batch (if still running)..."
    if ! wait "$PREFETCH_PID"; then
        echo "WARNING: prefetch of next batch failed — will retry it as the current batch next cycle."
    fi
    PREFETCH_PID=""

    # Swap buffers: what was "next" becomes "current"
    TMP_DIR="$CUR_DIR"
    CUR_DIR="$NXT_DIR"
    NXT_DIR="$TMP_DIR"

    echo ""
    echo "Batch cycle complete. Swapping to next batch immediately..."
    echo ""
done

#!/bin/bash
set -euo pipefail

#############################################
# MARS 2020 PERSEVERANCE ROVER - LIVE STREAM
# Fetches latest Sol images from NASA and
# streams a slideshow to YouTube with overlay.
#
# FIXES:
#   1. Image fetching now paginates (100/page)
#      to get up to MAX_IMAGES total images.
#   2. Each downloaded file is validated via
#      magic bytes + ffprobe before being added
#      to the slideshow — prevents "stuck frame"
#      caused by corrupt/HTML error downloads.
#############################################

#############################################
# Validate Environment Variables
#############################################
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

# FIX 3: fail fast if required overlay assets are missing, instead of
# burning through MAX_RETRIES on every cycle with a cryptic ffmpeg error.
if [ ! -f "font.ttf" ]; then
    echo "ERROR: font.ttf not found in working directory"
    exit 1
fi
if [ ! -f "overlay.png" ]; then
    echo "ERROR: overlay.png not found in working directory"
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
GREEN="0x4CAF50"
ASSET_DIR="panel_assets"
IMAGES_DIR="mars_images"
SLIDE_DURATION=12
FACT_SLOT=10
TICKER_SPEED=100
CHANNEL_NAME="Technical Talk india"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
INFO_FONTSIZE=19
INFO_LINE_SPACING=8
MAX_IMAGES=301
PAGE_SIZE=100              # FIX 1: server caps per-request at ~100, we paginate
VIEWER_MIN_TO_SHOW=10

SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

MAX_RETRIES=5
RETRY_DELAY=5

mkdir -p "$ASSET_DIR" "$IMAGES_DIR"

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
# FIX 1: fetch_mars_images — PAGINATED
#
# mars.nasa.gov silently ignores num > ~100.
# We page through (page=0, 1, 2...) appending
# results via mapfile -O until we hit MAX_IMAGES
# or a page returns 0 results.
#############################################
fetch_mars_images() {
    echo "----------------------------------------"
    echo "Fetching latest Mars 2020 raw images (paginated, up to ${MAX_IMAGES})..."
    echo "----------------------------------------"

    local BASE_URL="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"

    # Step 1: probe to find the latest Sol
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

    CURRENT_SOL=""
    if command -v jq &>/dev/null; then
        CURRENT_SOL=$(echo "$probe_resp" | jq -r '.images[0].sol // empty' 2>/dev/null || true)
    fi
    if [ -z "${CURRENT_SOL:-}" ]; then
        CURRENT_SOL=$(echo "$probe_resp" | grep -o '"sol":[0-9]*' | head -1 | grep -o '[0-9]*')
    fi
    if [ -z "${CURRENT_SOL:-}" ]; then
        echo "ERROR: Could not determine latest Sol. Full response:"
        echo "$probe_resp"
        return 1
    fi
    echo "Latest Sol: $CURRENT_SOL"

    # Step 2: paginate through Sol-filtered images
    FETCHED_IMAGES=()
    CAMERA_NAMES=()
    EARTH_DATES=()
    SOL_TIMES=()
    IMG_CAPTIONS=()

    local page=0
    while [ "${#FETCHED_IMAGES[@]}" -lt "$MAX_IMAGES" ]; do
        local url="${BASE_URL}&num=${PAGE_SIZE}&page=${page}&condition_2=${CURRENT_SOL}:sol:eq"
        echo "  Page $page | have ${#FETCHED_IMAGES[@]} images so far..."
        local resp
        resp=$(curl -sSL --max-time 60 --retry 3 --retry-delay 5 \
            -H "Accept: application/json" \
            -A "MarsLiveStream/1.0" \
            "$url" 2>/dev/null) || true

        local batch_count=0
        if command -v jq &>/dev/null; then
            batch_count=$(echo "$resp" | jq '.images | length' 2>/dev/null || echo 0)
        else
            batch_count=$(echo "$resp" | grep -c '"sol"' 2>/dev/null || echo 0)
        fi

        if [ "${batch_count:-0}" -eq 0 ]; then
            echo "  Page $page returned 0 images — no more pages."
            break
        fi

        # Append this page into arrays using -O offset
        if command -v jq &>/dev/null; then
            local offset=${#FETCHED_IMAGES[@]}
            mapfile -t -O "$offset" FETCHED_IMAGES < <(echo "$resp" | jq -r '.images[].image_files.large // .images[].image_files.medium // empty' 2>/dev/null)
            mapfile -t -O "$offset" CAMERA_NAMES  < <(echo "$resp" | jq -r '.images[].camera.instrument // empty' 2>/dev/null)
            mapfile -t -O "$offset" EARTH_DATES   < <(echo "$resp" | jq -r '.images[].date_taken_utc // empty' 2>/dev/null)
            mapfile -t -O "$offset" SOL_TIMES     < <(echo "$resp" | jq -r '.images[].date_taken_mars // empty' 2>/dev/null)
            mapfile -t -O "$offset" IMG_CAPTIONS  < <(echo "$resp" | jq -r '.images[].title // empty' 2>/dev/null)
        else
            echo "WARNING: jq not installed — grep fallback (pagination limited)"
            local offset=${#FETCHED_IMAGES[@]}
            mapfile -t -O "$offset" FETCHED_IMAGES < <(echo "$resp" | grep -o '"large":"[^"]*"' | sed 's/"large":"//;s/"//')
            mapfile -t -O "$offset" CAMERA_NAMES  < <(echo "$resp" | grep -o '"instrument":"[^"]*"' | sed 's/"instrument":"//;s/"//')
            mapfile -t -O "$offset" EARTH_DATES   < <(echo "$resp" | grep -o '"date_taken_utc":"[^"]*"' | sed 's/"date_taken_utc":"//;s/"//')
        fi

        echo "  Page $page: +$batch_count images (total: ${#FETCHED_IMAGES[@]})"

        # If page returned fewer than PAGE_SIZE, it's the last page
        if [ "$batch_count" -lt "$PAGE_SIZE" ]; then
            echo "  Last page reached ($batch_count < $PAGE_SIZE)."
            break
        fi

        page=$((page + 1))
        sleep 0.3   # be polite to NASA servers
    done

    local n=${#FETCHED_IMAGES[@]}
    echo "Pagination done: $n URLs for Sol $CURRENT_SOL"

    # Step 3: fallback — Sol filter returned 0, take unfiltered latest
    if [ "$n" -eq 0 ]; then
        echo "  Sol filter returned 0 — falling back to unfiltered latest images..."
        local fb_page=0
        while [ "${#FETCHED_IMAGES[@]}" -lt "$MAX_IMAGES" ]; do
            local fallback_url="${BASE_URL}&num=${PAGE_SIZE}&page=${fb_page}"
            local resp
            resp=$(curl -sSL --max-time 60 --retry 3 --retry-delay 5 \
                -H "Accept: application/json" -A "MarsLiveStream/1.0" \
                "$fallback_url" 2>/dev/null) || true

            local batch_count=0
            if command -v jq &>/dev/null; then
                batch_count=$(echo "$resp" | jq '.images | length' 2>/dev/null || echo 0)
            fi
            [ "${batch_count:-0}" -eq 0 ] && break

            if command -v jq &>/dev/null; then
                local offset=${#FETCHED_IMAGES[@]}
                mapfile -t -O "$offset" FETCHED_IMAGES < <(echo "$resp" | jq -r '.images[].image_files.large // .images[].image_files.medium // empty' 2>/dev/null)
                mapfile -t -O "$offset" CAMERA_NAMES  < <(echo "$resp" | jq -r '.images[].camera.instrument // empty' 2>/dev/null)
                mapfile -t -O "$offset" EARTH_DATES   < <(echo "$resp" | jq -r '.images[].date_taken_utc // empty' 2>/dev/null)
                mapfile -t -O "$offset" SOL_TIMES     < <(echo "$resp" | jq -r '.images[].date_taken_mars // empty' 2>/dev/null)
                mapfile -t -O "$offset" IMG_CAPTIONS  < <(echo "$resp" | jq -r '.images[].title // empty' 2>/dev/null)
                if [ "$fb_page" -eq 0 ]; then
                    local fallback_sol
                    fallback_sol=$(echo "$resp" | jq -r '.images[0].sol // empty' 2>/dev/null || true)
                    [ -n "$fallback_sol" ] && CURRENT_SOL="$fallback_sol"
                fi
            fi

            echo "  Fallback page $fb_page: +$batch_count (total: ${#FETCHED_IMAGES[@]})"
            [ "$batch_count" -lt "$PAGE_SIZE" ] && break
            fb_page=$((fb_page + 1))
            sleep 0.3
        done
        n=${#FETCHED_IMAGES[@]}
        echo "  Fallback total: $n images (Sol $CURRENT_SOL)"
    fi

    if [ "$n" -eq 0 ]; then
        echo "ERROR: No images fetched from mars.nasa.gov. Check network connectivity."
        return 1
    fi

    # Trim to MAX_IMAGES
    if [ "$n" -gt "$MAX_IMAGES" ]; then
        FETCHED_IMAGES=("${FETCHED_IMAGES[@]:0:$MAX_IMAGES}")
        CAMERA_NAMES=("${CAMERA_NAMES[@]:0:$MAX_IMAGES}")
        EARTH_DATES=("${EARTH_DATES[@]:0:$MAX_IMAGES}")
        SOL_TIMES=("${SOL_TIMES[@]:0:$MAX_IMAGES}")
        IMG_CAPTIONS=("${IMG_CAPTIONS[@]:0:$MAX_IMAGES}")
        n=$MAX_IMAGES
    fi

    echo "SUCCESS: Sol $CURRENT_SOL — $n images ready to download."
    return 0
}

#############################################
# FIX 2: download_images — HTTP + JPEG validation
#############################################
download_images() {
    local n=${#FETCHED_IMAGES[@]}
    echo "Downloading and validating $n images for Sol $CURRENT_SOL..."
    rm -f "$IMAGES_DIR"/*.jpg "$IMAGES_DIR"/*.JPG 2>/dev/null || true

    DL_CAMERA_NAMES=()
    DL_EARTH_DATES=()
    DL_SOL_TIMES=()

    local downloaded=0 rejected=0 idx=0
    for url in "${FETCHED_IMAGES[@]}"; do
        idx=$((idx + 1))
        local outfile="$IMAGES_DIR/mars_sol${CURRENT_SOL}_$(printf '%03d' $idx).jpg"

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
            echo "  [REJECT] $(basename "$outfile"): not a JPEG (magic=$magic) — likely HTML error page"
            rm -f "$outfile"
            rejected=$((rejected + 1))
            continue
        fi

        if ! ffprobe -v error \
            -select_streams v:0 \
            -show_entries stream=width \
            -of csv=p=0 \
            "$outfile" >/dev/null 2>&1; then
            echo "  [REJECT] $(basename "$outfile"): ffprobe decode failed (corrupt JPEG)"
            rm -f "$outfile"
            rejected=$((rejected + 1))
            continue
        fi

        DL_CAMERA_NAMES+=("${CAMERA_NAMES[$((idx - 1))]:-Unknown Camera}")
        DL_EARTH_DATES+=("${EARTH_DATES[$((idx - 1))]:-}")
        DL_SOL_TIMES+=("${SOL_TIMES[$((idx - 1))]:-}")

        downloaded=$((downloaded + 1))
    done

    echo "Download complete: $downloaded valid / $n total ($rejected rejected)."
    DOWNLOAD_COUNT=$downloaded
}

#############################################
# Write panel text files
#############################################
write_panel_assets() {
    printf 'MARS 2020'                          > "$ASSET_DIR/title1.txt"
    printf 'P E R S E V E R A N C E  R O V E R' > "$ASSET_DIR/title2.txt"
    printf "SOL %s RAW IMAGERY"  "$CURRENT_SOL" > "$ASSET_DIR/header.txt"
    printf 'LIVE FROM THE RED PLANET'           > "$ASSET_DIR/eyebrow.txt"
    printf 'SUBSCRIBE for daily Mars updates'   > "$ASSET_DIR/cta.txt"
    printf 'MARS FACT'                          > "$ASSET_DIR/fact_label.txt"

    # Mission-day counter — this IS accurate/live (computed locally),
    # unlike weather, which has no live public feed for Perseverance.
    local landing_epoch now_epoch
    landing_epoch=$(date -u -d '2021-02-18' +%s)
    now_epoch=$(date -u +%s)
    MISSION_DAY=$(( (now_epoch - landing_epoch) / 86400 + 1 ))
    MISSION_YEARS=$(( MISSION_DAY / 365 ))
    MISSION_MONTHS=$(( (MISSION_DAY % 365) / 30 ))

    # New: mockup-style left-column info lines (all honest/verifiable facts)
    printf 'SOL %s  •  MISSION ELAPSED TIME' "$CURRENT_SOL"        > "$ASSET_DIR/info_sol.txt"
    printf '%s years, %s months'  "$MISSION_YEARS" "$MISSION_MONTHS" > "$ASSET_DIR/info_elapsed.txt"
    printf 'LOCATION\nJezero Crater'                                > "$ASSET_DIR/info_location.txt"
    printf 'ROVER\nPerseverance'                                    > "$ASSET_DIR/info_rover.txt"

    # New: mockup-style right-column info lines — relabeled to avoid
    # fabricating live weather/signal/battery data that doesn't exist
    # publicly for Perseverance (see overlay_layout_guide.md).
    printf 'DOWNLINK\nDeep Space Network'                           > "$ASSET_DIR/info_downlink.txt"
    printf 'TYPICAL CONDITIONS (Jezero)\nNight -88C  •  Day -23C\nPressure ~718 Pa' > "$ASSET_DIR/info_weather.txt"
    printf 'POWER SOURCE\nRTG (Radioisotope) — Nuclear'             > "$ASSET_DIR/info_power.txt"

    local i idx
    local SHUFFLED_FACTS=()
    while IFS= read -r line; do
        SHUFFLED_FACTS+=("$line")
    done < <(printf '%s\n' "${MARS_FACTS[@]}" | shuf)
    FACT_N=${#SHUFFLED_FACTS[@]}
    for i in "${!SHUFFLED_FACTS[@]}"; do
        idx=$((i + 1))
        echo "${SHUFFLED_FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
        # Single-line, width-capped version for the fixed-height fact
        # strip (640px wide box at fontsize 13 ≈ 88 chars max).
        local one_line="${SHUFFLED_FACTS[$i]}"
        if [ "${#one_line}" -gt 88 ]; then
            one_line="${one_line:0:85}..."
        fi
        printf '%s' "$one_line" > "$ASSET_DIR/fact${idx}_oneline.txt"
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
# Build ffmpeg concat list for images
#############################################
build_concat_list() {
    local list_file="$ASSET_DIR/concat_list.txt"
    rm -f "$list_file"
    local count=0
    for f in "$IMAGES_DIR"/mars_sol*.jpg; do
        [ -f "$f" ] || continue
        echo "file '$(realpath "$f")'" >> "$list_file"
        echo "duration $SLIDE_DURATION"  >> "$list_file"
        count=$((count + 1))
    done
    local last_f
    last_f=$(ls "$IMAGES_DIR"/mars_sol*.jpg 2>/dev/null | tail -1)
    if [ -n "$last_f" ]; then
        echo "file '$(realpath "$last_f")'" >> "$list_file"
    fi
    TOTAL_SLIDE_DURATION=$((count * SLIDE_DURATION))
    echo "Concat list: $count slides × ${SLIDE_DURATION}s = ${TOTAL_SLIDE_DURATION}s total"
}

#############################################
# Slide info overlay — BACKGROUND WRITER
#############################################
start_slide_info_writer() {
    local n="$1"
    printf ' ' > "$ASSET_DIR/slide_info_current.txt"
    printf ' ' > "$ASSET_DIR/camera_name_only.txt"
    (
        local start_ts
        start_ts=$(date +%s)
        while true; do
            local now elapsed idx cam edate mtime
            now=$(date +%s)
            elapsed=$(( now - start_ts ))
            idx=$(( (elapsed / SLIDE_DURATION) % n ))
            cam="${DL_CAMERA_NAMES[$idx]:-Unknown Camera}"
            edate="${DL_EARTH_DATES[$idx]:-}"
            mtime="${DL_SOL_TIMES[$idx]:-}"
            {
                printf 'SOL %s  •  IMAGE %d/%d\n%s' "$CURRENT_SOL" "$((idx + 1))" "$n" "$cam"
                [ -n "$edate" ] && printf '\nEarth Date: %s' "$edate"
                [ -n "$mtime" ] && printf '\nMars Time: %s' "$mtime"
            } > "$ASSET_DIR/slide_info_current.txt.tmp"
            mv -f "$ASSET_DIR/slide_info_current.txt.tmp" "$ASSET_DIR/slide_info_current.txt"

            # Camera name only — the "CAMERA" label itself is now static
            # text in the filter graph, so this file just holds the value
            # and can't collide with its own label.
            printf '%s' "$cam" > "$ASSET_DIR/camera_name_only.txt.tmp"
            mv -f "$ASSET_DIR/camera_name_only.txt.tmp" "$ASSET_DIR/camera_name_only.txt"

            sleep 1
        done
    ) &
    SLIDE_INFO_PID=$!
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

SLIDE_INFO_PID=""
trap 'kill "$CLOCK_PID" 2>/dev/null || true
      [ -n "$SUBS_PID" ]       && kill "$SUBS_PID"       2>/dev/null || true
      [ -n "$VIEWERS_PID" ]    && kill "$VIEWERS_PID"    2>/dev/null || true
      [ -n "$SLIDE_INFO_PID" ] && kill "$SLIDE_INFO_PID" 2>/dev/null || true
      echo "Stream ended — cleaning up."' EXIT

#############################################
# build_full_filter
#
# REDESIGNED to match the reference mockup:
#   - Title block top-left (over a dark scrim)
#   - Two-column stat panel bottom-left
#     (left col = mission/location facts,
#      right col = downlink/weather/power —
#      relabeled to only show real, verifiable
#      data; see overlay_layout_guide.md)
#   - Subscribe callout bottom-right
#   - Ticker bar across the bottom
#
# All decorative shapes (rounded panels, icons,
# NASA badge, subscribe bell graphic) belong in
# overlay.png as static art — ffmpeg only draws
# the live text on top of it.
#############################################
build_full_filter() {
    local n_slides="$1"
    local FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local CTA_CYCLE=180
    local CTA_SHOW=8
    local SLIDE_CYCLE=$((n_slides * SLIDE_DURATION))

    local F=""
    F+="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,"
    F+="pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
    F+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
    F+="[ovl][video]overlay=0:0[base];"

    # --- Top-left title scrim (feathered: 3 stacked boxes, fades out
    #     instead of ending in one hard-edged rectangle) + title text ---
    F+="[base]drawbox=x=0:y=0:w=620:h=180:color=black@0.45:t=fill[tg1];"
    F+="[tg1]drawbox=x=0:y=180:w=620:h=25:color=black@0.28:t=fill[tg2];"
    F+="[tg2]drawbox=x=0:y=205:w=620:h=25:color=black@0.12:t=fill[t0];"
    F+="[t0]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=64:x=40:y=20:${SHADOW}[t1];"
    F+="[t1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=${MARS_RED}:fontsize=30:x=40:y=97:${SHADOW}[t2];"
    F+="[t2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=white@0.90:fontsize=18:x=40:y=140:${SHADOW}[t3];"

    # --- LIVE pill (top-left, under title) ---
    F+="[t3]drawbox=x=40:y=173:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[t4];"
    F+="[t4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=22:x=58:y=164[t5];"
    F+="[t5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=15:x=130:y=170[t6];"

    # --- Bottom-left two-column stat panel ---
    # Shrunk to fit its content (560x200, was 740x235) — bottom now at
    # y=580, fact strip starts y=587.
    F+="[t6]drawbox=x=33:y=380:w=560:h=200:color=black@0.55:t=fill[s0];"
    F+="[s0]drawbox=x=33:y=380:w=560:h=3:color=${MARS_RED}@0.8:t=fill[s1];"

    # Left column: Sol/elapsed, Location, Rover, Camera
    F+="[s1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/info_sol.txt:fontcolor=${GOLD}:fontsize=15:x=55:y=396:${SHADOW}[s2];"
    F+="[s2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/info_elapsed.txt:fontcolor=white@0.85:fontsize=13:x=55:y=416:${SHADOW}[s3];"
    F+="[s3]drawtext=fontfile=${FONT}:text='LOCATION':fontcolor=${GOLD}:fontsize=13:x=55:y=444:${SHADOW}[s3b];"
    F+="[s3b]drawtext=fontfile=${FONT}:text='Jezero Crater':fontcolor=white:fontsize=15:x=55:y=462:${SHADOW}[s4];"
    F+="[s4]drawtext=fontfile=${FONT}:text='ROVER':fontcolor=${GOLD}:fontsize=13:x=55:y=490:${SHADOW}[s4b];"
    F+="[s4b]drawtext=fontfile=${FONT}:text='Perseverance':fontcolor=white:fontsize=15:x=55:y=508:${SHADOW}[s5];"
    F+="[s5]drawtext=fontfile=${FONT}:text='CAMERA':fontcolor=${GOLD}:fontsize=13:x=55:y=536:${SHADOW}[s5b];"
    F+="[s5b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/camera_name_only.txt:reload=1:fontcolor=white:fontsize=15:x=55:y=554:${SHADOW}[s6];"

    # Right column: Downlink, Typical Conditions, Power source
    F+="[s6]drawtext=fontfile=${FONT}:text='DOWNLINK':fontcolor=${GOLD}:fontsize=13:x=320:y=396:${SHADOW}[s7a];"
    F+="[s7a]drawtext=fontfile=${FONT}:text='Deep Space Network':fontcolor=white:fontsize=15:x=320:y=414:${SHADOW}[s7];"
    F+="[s7]drawtext=fontfile=${FONT}:text='TYPICAL CONDITIONS (Jezero)':fontcolor=${GOLD}:fontsize=12:x=320:y=444:${SHADOW}[s7b];"
    F+="[s7b]drawtext=fontfile=${FONT}:text='Night -88C  •  Day -23C':fontcolor=white@0.90:fontsize=13:x=320:y=462:${SHADOW}[s7c];"
    F+="[s7c]drawtext=fontfile=${FONT}:text='Pressure ~718 Pa':fontcolor=white@0.90:fontsize=13:x=320:y=480:${SHADOW}[s8];"
    F+="[s8]drawtext=fontfile=${FONT}:text='POWER SOURCE':fontcolor=${GOLD}:fontsize=13:x=320:y=508:${SHADOW}[s8b];"
    F+="[s8b]drawtext=fontfile=${FONT}:text='RTG (Radioisotope) — Nuclear':fontcolor=${GREEN}:fontsize=15:x=320:y=526:${SHADOW}[s9];"

    # --- Mars fact strip — own box directly below the panel, 7px gap ---
    F+="[s9]drawbox=x=33:y=587:w=560:h=40:color=black@0.45:t=fill[fb0];"
    F+="[fb0]drawtext=fontfile=${FONT}:text='MARS FACT':fontcolor=${GOLD}@0.90:fontsize=10:x=50:y=592[fb1];"
    local fp_prev="fb1"
    for ((i = 0; i < FACT_N; i++)); do
        local fidx=$((i + 1))
        local fstart=$((i * FACT_SLOT))
        local fend=$((fstart + FACT_SLOT))
        local nxt="f${fidx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${fstart}\,${fend})\,if(lt(mod(t\,${FACT_CYCLE})-${fstart}\,0.5)\,(mod(t\,${FACT_CYCLE})-${fstart})/0.5\,if(gt(mod(t\,${FACT_CYCLE})-${fstart}\,${FACT_SLOT}-0.5)\,(${fend}-mod(t\,${FACT_CYCLE}))/0.5\,1))\,0)"
        F+="[${fp_prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${fidx}_oneline.txt:fontcolor=white@0.85:fontsize=12:x=50:y=606:alpha='${FALPHA}'[${nxt}];"
        fp_prev="$nxt"
    done

    # --- CTA text — off the bottom-right corner (your overlay.png
    # subscribe badge lives there), clear of the fact strip (ends x=593)
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.5)\,mod(t\,${CTA_CYCLE})/0.5\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.5)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.5\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    F+="[${fp_prev}]drawbox=x=650:y=587:w=280:h=40:color=black@0.60:t=fill[cta_bg];"
    F+="[cta_bg]drawbox=x=650:y=587:w=4:h=40:color=${MARS_RED}:t=fill[cta_bar];"
    F+="[cta_bar]drawbox=x=668:y=603:w=10:h=10:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    F+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=14:x=684:y=599:alpha='${CTA_ALPHA}'[cta_sub];"
    F+="[cta_sub]drawtext=fontfile=${FONT}:text='Images refresh each Sol':fontcolor=white@0.80:fontsize=14:x=684:y=599:enable='not(${CTA_ENABLE})'[cta_final];"

    # --- Subscriber / viewer counts, small, near top-right ---
    # (NASA/JPL-Caltech credit already lives in overlay.png per your
    # screenshot — not duplicating it here.)
    F+="[cta_final]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.80:fontsize=14:x=1280-text_w-20:y=20[st1];"
    F+="[st1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.80:fontsize=14:x=1280-text_w-20:y=42[st2];"
    local st_prev="st2"

    # --- Bottom ticker bar ---
    F+="[${st_prev}]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
    F+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${MARS_RED}@0.9:t=fill[tk2];"
    F+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    F+="[tk3]drawbox=x=0:y=680:w=130:h=40:color=black@0.85:t=fill[tk4];"
    F+="[tk4]drawbox=x=0:y=682:w=123:h=38:color=${MARS_RED}:t=fill[tk5];"
    F+="[tk5]drawtext=fontfile=${FONT}:text='MARS LIVE':fontcolor=white:fontsize=14:x=12:y=695[tk6];"
    F+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.40:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=680:y=655[wm1];"

    F+="[wm1]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$F"
}

#############################################
# Stream the slideshow to YouTube
#############################################
run_stream() {
    local n_slides="$1"
    local attempt=1
    local filter
    filter=$(build_full_filter "$n_slides")

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming Sol $CURRENT_SOL ($n_slides slides) — attempt ${attempt}/${MAX_RETRIES}"
        echo "----------------------------------------"
        start_slide_info_writer "$n_slides"
        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -re -f concat -safe 0 -i "$ASSET_DIR/concat_list.txt" \
        -loop 1 -i overlay.png \
        -f lavfi -i anullsrc=r=48000:cl=stereo \
        -filter_complex "$filter" \
        -map "[final]" \
        -map 2:a \
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
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e
        kill "$SLIDE_INFO_PID" 2>/dev/null || true

        if [ "$exit_code" -eq 0 ]; then
            echo "Slideshow cycle complete."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached — re-fetching images for next cycle."
        fi
    done
    return 1
}

#############################################
# MAIN LOOP
#############################################
echo ""
echo "Starting Mars Live Stream main loop..."
echo ""

LAST_STREAMED_SOL=""
CURRENT_SOL=""
FETCHED_IMAGES=()
CAMERA_NAMES=()
EARTH_DATES=()
SOL_TIMES=()
DL_CAMERA_NAMES=()
DL_EARTH_DATES=()
DL_SOL_TIMES=()
DOWNLOAD_COUNT=0
FACT_N=0
HEAD_N=0

while true; do
    echo "========================================"
    echo "New cycle starting at $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo "========================================"

    if fetch_mars_images; then
        if [ "$CURRENT_SOL" != "$LAST_STREAMED_SOL" ]; then
            echo "New Sol detected ($CURRENT_SOL) — downloading fresh images..."
            download_images
            write_panel_assets
            LAST_STREAMED_SOL="$CURRENT_SOL"
        else
            echo "Same Sol ($CURRENT_SOL) — reusing downloaded images, refreshing facts."
            write_panel_assets
        fi

        N_SLIDES=$(ls "$IMAGES_DIR"/mars_sol*.jpg 2>/dev/null | wc -l | tr -d ' ')
        if [ "$N_SLIDES" -eq 0 ]; then
            echo "ERROR: No local images to show. Waiting 60s and retrying..."
            sleep 60
            continue
        fi

        build_concat_list
        run_stream "$N_SLIDES" || true
    else
        echo "ERROR: Failed to fetch Mars images. Retrying in 120s..."
        sleep 120
    fi

    echo ""
    echo "Cycle complete. Starting next cycle immediately to check for new Sol..."
    echo ""
done

#!/bin/bash
set -euo pipefail

#############################################
# MARS 2020 PERSEVERANCE ROVER - LIVE STREAM
# Streams NASA raw images DIRECTLY from their
# URLs (no local download) and walks backward
# Sol-by-Sol (latest -> older -> wrap to latest)
# so the same images never repeat forever.
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
SLIDE_DURATION=12          # seconds per image slide
FACT_SLOT=10               # seconds each Mars fact is shown
TICKER_SPEED=100           # pixels/second for bottom ticker
CHANNEL_NAME="Mars Live"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
INFO_FONTSIZE=19
INFO_LINE_SPACING=8
MAX_IMAGES=30              # max images to pull per Sol
VIEWER_MIN_TO_SHOW=10
OLDEST_SOL=0                # never walk back past this Sol
URL_CHECK_TIMEOUT=6         # seconds for HEAD check per image URL

SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

#############################################
# Auto-restart config
#############################################
MAX_RETRIES=5
RETRY_DELAY=5

mkdir -p "$ASSET_DIR"

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
# get_latest_sol
# Probes mars.nasa.gov for the current max Sol.
#############################################
get_latest_sol() {
    local BASE_URL="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"
    local probe_url="${BASE_URL}&num=1&page=0"
    local probe_resp
    probe_resp=$(curl -sSL --max-time 30 --retry 3 --retry-delay 5 \
        -H "Accept: application/json" \
        -A "MarsLiveStream/1.0" \
        "$probe_url" 2>/dev/null) || true

    local sol=""
    if command -v jq &>/dev/null; then
        sol=$(echo "$probe_resp" | jq -r '.images[0].sol // empty' 2>/dev/null || true)
    fi
    if [ -z "$sol" ]; then
        sol=$(echo "$probe_resp" | grep -o '"sol":[0-9]*' | head -1 | grep -o '[0-9]*')
    fi
    echo "$sol"
}

#############################################
# fetch_images_for_sol <sol>
# Populates globals with image URLs + metadata
# for the given Sol. NOTHING is downloaded here —
# these are just remote URLs ffmpeg will read
# directly at stream time.
# Returns 1 (and empty arrays) if that Sol has
# no images.
#############################################
fetch_images_for_sol() {
    local sol="$1"
    local BASE_URL="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"
    local photos_url="${BASE_URL}&num=${MAX_IMAGES}&page=0&condition_2=${sol}:sol:eq"

    echo "Fetching image list for Sol $sol (real-time, no download): $photos_url"
    local api_resp
    api_resp=$(curl -sSL --max-time 60 --retry 3 --retry-delay 5 \
        -H "Accept: application/json" \
        -A "MarsLiveStream/1.0" \
        "$photos_url" 2>/dev/null) || true

    FETCHED_IMAGES=()
    CAMERA_NAMES=()
    EARTH_DATES=()

    if command -v jq &>/dev/null; then
        mapfile -t FETCHED_IMAGES < <(echo "$api_resp" | jq -r '.images[].image_files.large // .images[].image_files.medium // empty' 2>/dev/null | head -"$MAX_IMAGES")
        mapfile -t CAMERA_NAMES  < <(echo "$api_resp" | jq -r '.images[].camera.instrument       // empty' 2>/dev/null | head -"$MAX_IMAGES")
        mapfile -t EARTH_DATES   < <(echo "$api_resp" | jq -r '.images[].date_taken_utc          // empty' 2>/dev/null | head -"$MAX_IMAGES")
    else
        mapfile -t FETCHED_IMAGES < <(echo "$api_resp" | grep -o '"large":"[^"]*"' | sed 's/"large":"//;s/"//' | head -"$MAX_IMAGES")
    fi

    local n=${#FETCHED_IMAGES[@]}
    if [ "$n" -eq 0 ]; then
        echo "  Sol $sol has no images — skipping."
        return 1
    fi

    echo "  Found $n images for Sol $sol."
    return 0
}

#############################################
# validate_live_urls
# Quick HEAD request per image URL (not a
# download) to drop dead/unreachable links
# before they can stall ffmpeg mid-stream.
# Rebuilds FETCHED_IMAGES/CAMERA_NAMES/EARTH_DATES
# with only the URLs that responded OK.
#############################################
validate_live_urls() {
    local ok_urls=() ok_cams=() ok_dates=()
    local i url
    for i in "${!FETCHED_IMAGES[@]}"; do
        url="${FETCHED_IMAGES[$i]}"
        if curl -sSL --head --max-time "$URL_CHECK_TIMEOUT" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -qE '^(2|3)'; then
            ok_urls+=("$url")
            ok_cams+=("${CAMERA_NAMES[$i]:-Unknown Camera}")
            ok_dates+=("${EARTH_DATES[$i]:-}")
        fi
    done
    FETCHED_IMAGES=("${ok_urls[@]}")
    CAMERA_NAMES=("${ok_cams[@]}")
    EARTH_DATES=("${ok_dates[@]}")
    echo "  ${#FETCHED_IMAGES[@]} / of checked URLs are live and will be streamed."
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
# build_concat_list_streaming
# Builds an ffmpeg concat list that points
# straight at the remote image URLs — no local
# jpg files at all. ffmpeg fetches each frame
# over HTTPS at stream time.
#############################################
build_concat_list_streaming() {
    local list_file="$ASSET_DIR/concat_list.txt"
    rm -f "$list_file"
    local count=0
    local url
    for url in "${FETCHED_IMAGES[@]}"; do
        [ -n "$url" ] || continue
        printf "file '%s'\n" "$url"        >> "$list_file"
        printf "duration %s\n" "$SLIDE_DURATION" >> "$list_file"
        count=$((count + 1))
    done
    # concat demuxer needs the last entry repeated without a duration line
    local last_url="${FETCHED_IMAGES[-1]:-}"
    if [ -n "$last_url" ]; then
        printf "file '%s'\n" "$last_url" >> "$list_file"
    fi
    TOTAL_SLIDE_DURATION=$((count * SLIDE_DURATION))
    N_SLIDES_BUILT=$count
    echo "Concat list: $count remote slides × ${SLIDE_DURATION}s = ${TOTAL_SLIDE_DURATION}s total"
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

        printf 'SOL %s  •  IMAGE %d/%d\n%s' "$CURRENT_SOL" "$idx" "$n" "$cam" \
            > "$ASSET_DIR/slide_info${idx}.txt"
        if [ -n "$edate" ]; then
            printf '\nEarth Date: %s' "$edate" >> "$ASSET_DIR/slide_info${idx}.txt"
        fi

        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.5)\,(mod(t\,${CYCLE})-${start})/0.5\,if(gt(mod(t\,${CYCLE})-${start}\,${SLIDE_DURATION}-0.5)\,(${end}-mod(t\,${CYCLE}))/0.5\,1))\,0)"

        local nxt="si${idx}"
        chain+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/slide_info${idx}.txt:fontcolor=white:fontsize=${INFO_FONTSIZE}:line_spacing=${INFO_LINE_SPACING}:x=375:y=650:alpha='${ALPHA}':${SHADOW}[${nxt}];"
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
      echo "Stream ended — cleaning up."' EXIT

#############################################
# build_full_filter
#############################################
build_full_filter() {
    local n_slides="$1"
    local FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local CTA_CYCLE=180
    local CTA_SHOW=8

    local F=""
    F+="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,"
    F+="pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
    F+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
    F+="[ovl][video]overlay=0:0[base];"

    build_slide_info_chain "$n_slides"
    F+="$SLIDE_INFO_CHAIN"
    local prev="$SLIDE_INFO_END"

    F+="[${prev}]drawbox=x=0:y=0:w=333:h=720:color=black@0.62:t=fill[p1];"
    F+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
    F+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
    F+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
    F+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${MARS_RED}@0.9:t=fill[p5];"
    F+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${MARS_RED}@0.6:t=fill[p6];"

    F+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
    F+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

    F+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA/JPL-Caltech':fontcolor=white@0.85:fontsize=13:x=313-text_w:y=19[p9];"
    F+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=13:x=313-text_w:y=37[p10];"
    F+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=12:x=313-text_w:y=55[p10b];"
    F+="[p10b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=12:x=313-text_w:y=72[p10c];"

    F+="[p10c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=${MARS_RED}:fontsize=26:x=33:y=95:${SHADOW}[p11];"
    F+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.90:fontsize=15:x=33:y=127:${SHADOW}[p12];"
    F+="[p12]drawbox=x=33:y=157:w=280:h=2:color=white@0.3:t=fill[p13];"

    F+="[p13]drawbox=x=33:y=171:w=10:h=10:color=${MARS_RED}:t=fill[p14];"
    F+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=50:y=169[p15];"
    F+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${MARS_RED}@0.90:fontsize=12:x=33:y=198[p16];"

    local SLIDE_CYCLE=$((n_slides * SLIDE_DURATION))
    F+="[p16]drawtext=fontfile=${FONT}:text='IMAGE GALLERY':fontcolor=white@0.35:fontsize=9:x=33:y=225[pgcap];"
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

    F+="[${prev2}]drawbox=x=33:y=278:w=280:h=2:color=${MARS_RED}@0.5:t=fill[fp0];"
    F+="[fp0]drawbox=x=33:y=284:w=8:h=8:color=${GOLD}:t=fill[fp0b];"
    F+="[fp0b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.90:fontsize=12:x=49:y=282[fp1];"
    local fp_prev="fp1"
    for ((i = 0; i < FACT_N; i++)); do
        local fidx=$((i + 1))
        local fstart=$((i * FACT_SLOT))
        local fend=$((fstart + FACT_SLOT))
        local nxt="f${fidx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${fstart}\,${fend})\,if(lt(mod(t\,${FACT_CYCLE})-${fstart}\,0.5)\,(mod(t\,${FACT_CYCLE})-${fstart})/0.5\,if(gt(mod(t\,${FACT_CYCLE})-${fstart}\,${FACT_SLOT}-0.5)\,(${fend}-mod(t\,${FACT_CYCLE}))/0.5\,1))\,0)"
        F+="[${fp_prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${fidx}.txt:fontcolor=white@0.90:fontsize=16:line_spacing=7:x=33:y=306:alpha='${FALPHA}'[${nxt}];"
        fp_prev="$nxt"
    done

    F+="[${fp_prev}]drawbox=x=10:y=560:w=326:h=115:color=black@0.55:t=fill[mi0];"
    F+="[mi0]drawbox=x=10:y=560:w=5:h=115:color=${MARS_RED}:t=fill[mi1];"
    F+="[mi1]drawtext=fontfile=${FONT}:text='MISSION STATS':fontcolor=${GOLD}:fontsize=11:x=22:y=567[mi2];"
    F+="[mi2]drawtext=fontfile=${FONT}:text='Rover\: Perseverance (Percy)':fontcolor=white@0.85:fontsize=13:x=22:y=585[mi3];"
    F+="[mi3]drawtext=fontfile=${FONT}:text='Landing\: Feb 18\, 2021':fontcolor=white@0.85:fontsize=13:x=22:y=602[mi4];"
    F+="[mi4]drawtext=fontfile=${FONT}:text='Location\: Jezero Crater':fontcolor=white@0.85:fontsize=13:x=22:y=619[mi5];"
    F+="[mi5]drawtext=fontfile=${FONT}:text='Sol\: ${CURRENT_SOL}':fontcolor=${MARS_RED}:fontsize=15:x=22:y=638[mi6];"
    F+="[mi6]drawtext=fontfile=${FONT}:text='Images\: ${N_SLIDES_BUILT} live this Sol':fontcolor=white@0.75:fontsize=12:x=22:y=659[mi7];"

    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.5)\,mod(t\,${CTA_CYCLE})/0.5\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.5)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.5\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    F+="[mi7]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill[cta_bg];"
    F+="[cta_bg]drawbox=x=733:y=620:w=4:h=43:color=${MARS_RED}:t=fill[cta_bar];"
    F+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    F+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_sub];"
    F+="[cta_sub]drawtext=fontfile=${FONT}:text='Images refresh each Sol':fontcolor=white@0.80:fontsize=19:x=773:y=633:enable='not(${CTA_ENABLE})'[cta_final];"

    F+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
    F+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${MARS_RED}@0.9:t=fill[tk2];"
    F+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    F+="[tk3]drawbox=x=0:y=680:w=130:h=40:color=black@0.85:t=fill[tk4];"
    F+="[tk4]drawbox=x=0:y=682:w=123:h=38:color=${MARS_RED}:t=fill[tk5];"
    F+="[tk5]drawtext=fontfile=${FONT}:text='MARS LIVE':fontcolor=white:fontsize=14:x=12:y=695[tk6];"

    F+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.40:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=353:y=655[wm1];"

    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    F+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=3:enable='${SUB_PULSE_ENABLE}'[wm2];"

    F+="[wm2]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$F"
}

#############################################
# Stream the slideshow to YouTube
# NOTE: -protocol_whitelist + -rw_timeout let
# the concat demuxer read image URLs directly
# over HTTPS instead of local files, and stop
# ffmpeg from hanging forever on a slow/dead
# remote image.
#############################################
run_stream() {
    local n_slides="$1"
    local attempt=1
    local filter
    filter=$(build_full_filter "$n_slides")

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming Sol $CURRENT_SOL ($n_slides slides, live from NASA URLs) — attempt ${attempt}/${MAX_RETRIES}"
        echo "----------------------------------------"
        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -protocol_whitelist file,http,https,tcp,tls,crypto \
        -rw_timeout 15000000 \
        -f concat -safe 0 -i "$ASSET_DIR/concat_list.txt" \
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
            echo "ERROR: Max retries reached — moving to next Sol."
        fi
    done
    return 1
}

#############################################
# MAIN LOOP
# Walks backward Sol by Sol from the latest
# down to OLDEST_SOL, streaming live image URLs
# for each Sol with no local download. When it
# runs out of old Sols it re-checks the latest
# Sol (in case new ones landed) and starts over
# from there. This never repeats the same image
# set indefinitely, and never stops.
#############################################
echo ""
echo "Starting Mars Live Stream main loop..."
echo ""

CURRENT_SOL=$(get_latest_sol)
if [ -z "$CURRENT_SOL" ]; then
    echo "ERROR: Could not determine latest Sol at startup."
    exit 1
fi
echo "Latest Sol at startup: $CURRENT_SOL"

FETCHED_IMAGES=()
CAMERA_NAMES=()
EARTH_DATES=()
FACT_N=0
HEAD_N=0
N_SLIDES_BUILT=0

while true; do
    echo "========================================"
    echo "New cycle at $(date -u +'%Y-%m-%d %H:%M UTC') — Sol $CURRENT_SOL"
    echo "========================================"

    if fetch_images_for_sol "$CURRENT_SOL"; then
        validate_live_urls
        if [ "${#FETCHED_IMAGES[@]}" -gt 0 ]; then
            write_panel_assets
            build_concat_list_streaming
            run_stream "$N_SLIDES_BUILT" || true
        else
            echo "  All URLs for Sol $CURRENT_SOL were dead — skipping to next Sol."
        fi
    else
        echo "  No images for Sol $CURRENT_SOL — skipping to next Sol."
    fi

    # Step backward to the next older Sol
    CURRENT_SOL=$((CURRENT_SOL - 1))

    if [ "$CURRENT_SOL" -lt "$OLDEST_SOL" ]; then
        echo "Reached oldest tracked Sol — refreshing latest Sol and wrapping around."
        NEW_LATEST=$(get_latest_sol)
        if [ -n "$NEW_LATEST" ]; then
            CURRENT_SOL="$NEW_LATEST"
        else
            CURRENT_SOL=0
        fi
    fi
done

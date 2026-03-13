#!/bin/bash

# ==============================================================================
# Arr-Telegram-Notifier v3.0 (Master Release - Silent Mode)
# Features: Season Pack Loop, Native Album, DB Auto-Discovery, Awk Math, UI.
# ==============================================================================

# --- CONFIGURATION ---
TELEGRAM_TOKEN="YOUR_TELEGRAM_TOKEN"
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"
SONARR_API_KEY="YOUR_SONARR_API_KEY"
RADARR_API_KEY="YOUR_RADARR_API_KEY"
LIDARR_API_KEY="YOUR_LIDARR_API_KEY"
SERVER_IP="YOUR_SERVER_IP"

# LOG SWITCH (Set to "true" for debugging, "false" to disable)
ENABLE_LOGGING="false"

# --- DYNAMIC PATHS ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
TMP_DIR="$BASE_DIR/temp"
DEBUG_LOG="$LOG_DIR/debug.log"

mkdir -p "$LOG_DIR" "$TMP_DIR"
chmod -R 777 "$LOG_DIR" "$TMP_DIR"

# Log Function (writes only if enabled)
log_msg() {
    if [ "$ENABLE_LOGGING" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG"
    fi
}

log_msg "================ START EVENT ================"

# Variables Dump (only if log is enabled)
if [ "$ENABLE_LOGGING" = "true" ]; then
    env | grep -iE "^(sonarr|radarr|lidarr)_" >> "$DEBUG_LOG"
fi

format_size() {
    local bytes=$1
    if [[ "$2" == "MUSIC" ]]; then
        echo "$bytes" | awk '{printf "%.2f MB", $1/1024/1024}'
    else
        echo "$bytes" | awk '{if ($1 < 1073741824) printf "%.2f MB", $1/1024/1024; else printf "%.2f GB", $1/1024/1024/1024}'
    fi
}

fetch_data() {
    local url=$1; local attempt=1
    while [ $attempt -le 6 ]; do
        local resp=$(curl -s -m 10 "$url")
        if [ -n "$resp" ] && [[ "$resp" == *"id"* || "$resp" == *"["* ]]; then echo "$resp"; return 0; fi
        log_msg "API WAIT ($attempt/6)..."
        sleep 5; ((attempt++))
    done
    log_msg "API ERROR: $url"; return 1
}

# --- 1. APP DETECTION & EVENT FILTER ---
EVENT_TYPE="${sonarr_eventtype:-}${radarr_eventtype:-}${lidarr_eventtype:-}"

if [[ ! "$EVENT_TYPE" =~ ^(Download|AlbumDownload)$ ]]; then
    log_msg "EXIT: Event ignored ($EVENT_TYPE)."
    exit 0
fi

if [ -n "${sonarr_eventtype:-}" ]; then
    APP="Sonarr"; API_KEY="$SONARR_API_KEY"; PORT="8989"; ENDPOINT="series"; VER="v3"; TYPE="TV"
    ID="$sonarr_series_id"; ALB_ID="$sonarr_series_id"
    # SONARR FIX: Handles both singular and plural IDs for Season Packs
    FILE_IDS=$(echo "${sonarr_episodefile_ids:-${sonarr_episodefile_id:-}}" | tr '|' ' ' | tr ',' ' ')
    FILE_ID=$(echo "$FILE_IDS" | awk '{print $1}')
    
    # AUTO-DISCOVERY: If ID is missing, fetch the last imported file from the DB
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "0" ]; then
        log_msg "Sonarr: Empty FILE_ID, retrieving last file from DB..."
        FILE_ID=$(curl -s "http://$SERVER_IP:$PORT/api/$VER/episodefile?seriesId=$ID&apikey=$API_KEY" | jq -r 'sort_by(.id) | last | .id // empty')
    fi

elif [ -n "${radarr_eventtype:-}" ]; then
    APP="Radarr"; API_KEY="$RADARR_API_KEY"; PORT="7878"; ENDPOINT="movie"; VER="v3"; TYPE="MOVIE"
    ID="$radarr_movie_id"
    FILE_IDS=$(echo "${radarr_moviefile_ids:-${radarr_moviefile_id:-}}" | tr '|' ' ' | tr ',' ' ')
    FILE_ID=$(echo "$FILE_IDS" | awk '{print $1}')
    
    # AUTO-DISCOVERY
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "0" ]; then
        log_msg "Radarr: Empty FILE_ID, retrieving file associated with the movie..."
        FILE_ID=$(curl -s "http://$SERVER_IP:$PORT/api/$VER/movie/$ID?apikey=$API_KEY" | jq -r '.movieFile.id // empty')
    fi

elif [ -n "${lidarr_eventtype:-}" ]; then
    APP="Lidarr"; API_KEY="$LIDARR_API_KEY"; PORT="8686"; ENDPOINT="artist"; VER="v1"; TYPE="MUSIC"
    ID="$lidarr_artist_id"; ALB_ID="$lidarr_album_id"; FILE_ID="${lidarr_trackfile_id:-}"
fi

log_msg "DETECTED: $APP | EVENT: $EVENT_TYPE | ID: $ID | FILE_ID: $FILE_ID"

if [ -z "$FILE_ID" ] && [ "$EVENT_TYPE" != "AlbumDownload" ]; then
    log_msg "CRITICAL: FILE_ID unrecoverable. Ignored."
    exit 0
fi

# --- 2. DATA COLLECTION & DEBOUNCE ---
TEMP_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.list"
LOCK_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.lock"
INFO_STR=""

if [ "$TYPE" = "TV" ]; then
    E_INFO=$(fetch_data "http://$SERVER_IP:8989/api/v3/episode?seriesId=$ID&apikey=$SONARR_API_KEY")
    for FID in $FILE_IDS; do
        [ -z "$FID" ] && continue
        log_msg "Processing Episode ID: $FID"
        F_JSON=$(fetch_data "http://$SERVER_IP:8989/api/v3/episodefile/$FID?apikey=$SONARR_API_KEY")
        EP_S_NUM=$(echo "$F_JSON" | jq -r '.seasonNumber // 0')
        EP_SIZE=$(echo "$F_JSON" | jq -r '.size // 0')
        EP_QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
        EP_DATA=$(echo "$E_INFO" | jq -r ".[] | select(.episodeFileId == $FID) | \"\(.episodeNumber)|\(.title)\"" | head -n1)
        EP_NUM=$(echo "$EP_DATA" | cut -d'|' -f1)
        EP_TITLE=$(echo "$EP_DATA" | cut -d'|' -f2-)
        LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')
        D_RAW=$(echo "$F_JSON" | jq -r '.mediaInfo.runTime // "00:00"')
        DUR_MIN=$(echo "$D_RAW" | cut -d: -f1 | sed 's/^0*//')

        echo "${EP_NUM:-00}|${EP_TITLE:-Episode}|${EP_SIZE:-0}|$EP_QUAL|${LANGS:-ND}|${DUR_MIN:-0}|${EP_S_NUM:-0}" >> "$TEMP_FILE"
    done
    INFO_STR=""

elif [ "$TYPE" = "MUSIC" ]; then
    TRACKS_JSON=$(fetch_data "http://$SERVER_IP:8686/api/v1/track?albumId=$ALB_ID&apikey=$LIDARR_API_KEY")
    if [ "$EVENT_TYPE" = "AlbumDownload" ]; then
        FILES_JSON=$(fetch_data "http://$SERVER_IP:8686/api/v1/trackfile?albumId=$ALB_ID&apikey=$LIDARR_API_KEY")
        echo "$FILES_JSON" | jq -c '.[]' | while read -r file_obj; do
            F_ID=$(echo "$file_obj" | jq -r '.id')
            T_SIZE=$(echo "$file_obj" | jq -r '.size // 0')
            T_QUAL=$(echo "$file_obj" | jq -r '.quality.quality.name // "N/A"')
            
            # DUAL FALLBACK: Fetch from DB first, if empty (race condition) fetch from file tags
            TRACK_OBJ=$(echo "$TRACKS_JSON" | jq -c ".[] | select(.trackFileId == $F_ID)" | head -n1)
            T_TITLE=$(echo "$TRACK_OBJ" | jq -r '.title // empty')

            if [ -n "$T_TITLE" ]; then
                T_INDEX=$(echo "$TRACK_OBJ" | jq -r '.trackNumber // 0')
                D_RAW=$(echo "$TRACK_OBJ" | jq -r '.duration // 0')
                T_D_SEC=$((D_RAW / 1000))
            else
                T_TITLE=$(echo "$file_obj" | jq -r '.audioTags.title // "Track"')
                T_INDEX=$(echo "$file_obj" | jq -r '.audioTags.trackNumbers[0] // 0')
                D_RAW_STR=$(echo "$file_obj" | jq -r '.audioTags.duration // "00:00"')
                T_D_SEC=$(echo "$D_RAW_STR" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }' | cut -d. -f1)
            fi
            echo "${T_INDEX}|${T_TITLE}|${T_SIZE}|${T_QUAL}|${T_D_SEC:-0}" >> "$TEMP_FILE"
        done
        INFO_STR=""
    else
        F_JSON=$(fetch_data "http://$SERVER_IP:8686/api/v1/trackfile/$FILE_ID?apikey=$LIDARR_API_KEY")
        T_SIZE=$(echo "$F_JSON" | jq -r '.size // 0'); T_QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
        TRACK_OBJ=$(echo "$TRACKS_JSON" | jq -c ".[] | select(.trackFileId == $FILE_ID)" | head -n1)
        T_TITLE=$(echo "$TRACK_OBJ" | jq -r '.title // empty')
        
        if [ -n "$T_TITLE" ]; then
            T_INDEX=$(echo "$TRACK_OBJ" | jq -r '.trackNumber // 0')
            D_RAW=$(echo "$TRACK_OBJ" | jq -r '.duration // 0'); T_D_SEC=$((D_RAW / 1000))
        else
            T_TITLE=$(echo "$F_JSON" | jq -r '.audioTags.title // "Track"')
            T_INDEX=$(echo "$F_JSON" | jq -r '.audioTags.trackNumbers[0] // 0')
            D_RAW_STR=$(echo "$F_JSON" | jq -r '.audioTags.duration // "00:00"')
            T_D_SEC=$(echo "$D_RAW_STR" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }' | cut -d. -f1)
        fi
        INFO_STR="${T_INDEX}|${T_TITLE}|${T_SIZE}|${T_QUAL}|${T_D_SEC:-0}"
    fi
fi

if [ "$TYPE" != "MOVIE" ] && [ -n "$INFO_STR" ]; then
    echo "$INFO_STR" >> "$TEMP_FILE"
fi

if [ "$TYPE" != "MOVIE" ]; then
    echo "$$" > "$LOCK_FILE"
    sleep 15
    if [ "$(cat "$LOCK_FILE")" != "$$" ]; then exit 0; fi
    sort -V "$TEMP_FILE" -o "$TEMP_FILE"
fi

# --- 3. METADATA FETCH & UI ---
MAIN_JSON=$(curl -s "http://$SERVER_IP:$PORT/api/$VER/$ENDPOINT/$ID?apikey=$API_KEY")
GENRES=$(echo "$MAIN_JSON" | jq -r '.genres | join(", ")')
OVERVIEW=$(echo "$MAIN_JSON" | jq -r '.overview // empty' | sed 's/<[^>]*>//g' | cut -c1-300)

if [ "$TYPE" = "MOVIE" ]; then
    F_JSON=$(curl -s "http://$SERVER_IP:7878/api/v3/moviefile/$FILE_ID?apikey=$RADARR_API_KEY")
    QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
    SIZE=$(format_size $(echo "$F_JSON" | jq -r '.size // 0') "MOVIE")
    RUNTIME=$(echo "$MAIN_JSON" | jq -r '.runtime // 0')
    RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.imdb.value // .ratings.value // "N/A"')
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')

    HEADER="🎬 [MOVIE AVAILABLE] - Radarr"
    BODY="<b>TITLE:</b> <i>$(echo "$MAIN_JSON" | jq -r '.title')</i>\n<b>GENRE:</b> <i>$GENRES</i>\n<b>QUALITY:</b> <i>$QUAL</i>\n<b>LANGUAGE:</b> <i>${LANGS:-ND}</i>\n<b>DURATION:</b> <i>${RUNTIME} min</i>\n<b>IMDB RATING:</b> <i>$RATING</i>\n<b>WEIGHT:</b> <i>$SIZE</i>\n\n<b>PLOT:</b> <i>$OVERVIEW...</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "TV" ]; then
    TITLE=$(echo "$MAIN_JSON" | jq -r '.title')
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId')
    RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.value // "N/A"')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LIST=""; TOTAL_SIZE=0; ALL_DUR=0; COUNT=$(wc -l < "$TEMP_FILE")

    while IFS='|' read -r NUM T_TITLE SIZE QUAL LNG DUR S_NUM; do
        LIST="${LIST}• $(printf "%02d" "$NUM")_${T_TITLE} (${DUR} min)\n"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE)); FINAL_QUAL="$QUAL"; ALL_LANGS="$LNG"; ALL_DUR=$((ALL_DUR + DUR)); FINAL_S="$S_NUM"
        SINGLE_NUM="$NUM"; SINGLE_TITLE="$T_TITLE"
    done < "$TEMP_FILE"

    if [ "$COUNT" -gt 1 ]; then
        HEADER="🔵 [SEASON AVAILABLE] - Sonarr"
        BODY="<b>TITLE:</b> <i>$TITLE</i>\n<b>SEASON:</b> <i>$(printf "%02d" "${FINAL_S:-0}")</i>\n<b>EPISODE COUNT:</b> <i>$COUNT</i>\n<b>EPISODES:</b>\n<i>$LIST</i>\n"
    else
        HEADER="🔵 [EPISODE AVAILABLE] - Sonarr"
        BODY="<b>TITLE:</b> <i>$TITLE</i>\n<b>SEASON:</b> <i>$(printf "%02d" "${FINAL_S:-0}")</i>\n<b>EPISODE:</b> <i>$(printf "%02d" "${SINGLE_NUM:-0}")</i>\n<b>EPISODE TITLE:</b> <i>${SINGLE_TITLE}</i>\n"
    fi
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n<b>LANGUAGE:</b> <i>${ALL_LANGS:-ND}</i>\n<b>QUALITY:</b> <i>$FINAL_QUAL</i>\n<b>DURATION:</b> <i>${ALL_DUR:-0} min</i>\n<b>IMDB RATING:</b> <i>$RATING</i>\n<b>WEIGHT:</b> <i>$(format_size $TOTAL_SIZE "TV")</i>\n\n<b>PLOT:</b> <i>$OVERVIEW...</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "MUSIC" ]; then
    ALB_JSON=$(curl -s "http://$SERVER_IP:8686/api/v1/album/$ALB_ID?apikey=$LIDARR_API_KEY")
    ART_NAME=$(echo "$MAIN_JSON" | jq -r '.artistName')
    ALB_NAME=$(echo "$ALB_JSON" | jq -r '.title')
    IMAGE_URL=$(echo "$ALB_JSON" | jq -r '.images[] | select(.coverType=="cover") | .remoteUrl' | head -n1)
    LIST=""; TOTAL_SIZE=0; TOTAL_SEC=0; COUNT=$(wc -l < "$TEMP_FILE")

    while IFS='|' read -r NUM T_TITLE SIZE QUAL DUR; do
        MIN=$((DUR/60)); SEC=$((DUR%60)); DUR_F=$(printf "%02d:%02d" $MIN $SEC)
        LIST="${LIST}• $(printf "%02d" "$NUM")_${T_TITLE} (${DUR_F})\n"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE)); TOTAL_SEC=$((TOTAL_SEC + DUR)); FINAL_QUAL="$QUAL"
        S_TITLE="$T_TITLE"; S_NUM="$NUM"
    done < "$TEMP_FILE"

    T_MIN=$((TOTAL_SEC/60)); T_SEC=$((TOTAL_SEC%60)); T_DUR_F=$(printf "%02d:%02d" $T_MIN $T_SEC)

    if [ "$COUNT" -gt 1 ]; then
        HEADER="🟢 [ALBUM AVAILABLE] - Lidarr"
        BODY="<b>ALBUM:</b> <i>$ALB_NAME</i>\n<b>ARTIST:</b> <i>$ART_NAME</i>\n<b>TRACKS:</b>\n<i>$LIST</i>\n"
    else
        HEADER="🟢 [SONG AVAILABLE] - Lidarr"
        BODY="<b>TITLE:</b> <i>$S_TITLE</i>\n<b>ALBUM:</b> <i>$ALB_NAME</i>\n<b>TRACK:</b> <i>$(printf "%02d" "${S_NUM:-0}")</i>\n<b>ARTIST:</b> <i>$ART_NAME</i>\n"
    fi
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n<b>QUALITY:</b> <i>$FINAL_QUAL</i>\n<b>DURATION:</b> <i>$T_DUR_F</i>\n<b>WEIGHT:</b> <i>$(format_size $TOTAL_SIZE "MUSIC")</i>\n"

    SPOTIFY=$(echo "$MAIN_JSON" | jq -r '.links[] | select(.name=="spotify") | .url' | head -n1)
    YOUTUBE=$(echo "$MAIN_JSON" | jq -r '.links[] | select(.name=="youtube") | .url' | head -n1)
    BUTTONS="{\"inline_keyboard\": [["
    [[ -n "$SPOTIFY" ]] && BUTTONS="$BUTTONS {\"text\": \"🎧 Spotify\", \"url\": \"$SPOTIFY\"},"
    [[ -n "$YOUTUBE" ]] && BUTTONS="$BUTTONS {\"text\": \"📺 YouTube\", \"url\": \"$YOUTUBE\"}"
    BUTTONS="${BUTTONS%,} ]]}"
fi

# --- 4. SEND NOTIFICATION ---
rm -f "$TEMP_FILE" "$LOCK_FILE"
MSG=$(printf "<b>$HEADER</b>\n\n$BODY")

TG_RESP=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendPhoto" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "photo=$IMAGE_URL" \
    --data-urlencode "caption=$MSG" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "reply_markup=$BUTTONS")

log_msg "FINISH: Notification Sent."
log_msg "================= END EVENT ================="

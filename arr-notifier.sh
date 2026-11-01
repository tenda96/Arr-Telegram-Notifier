#!/bin/bash

# ==============================================================================
# Arr-Telegram-Notifier v4.0 (Telegram Destination Routing)
# Based on v3.0 Master Release - Silent Mode
# Features: Season Pack Loop, Native Album, DB Auto-Discovery, Awk Math, UI,
#           private chat / group forum topic routing.
# ==============================================================================

# --- CONFIGURATION ---
TELEGRAM_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"

# Telegram destination mode:
# "private"      = send directly to a private user/chat
# "group_thread" = send to a Telegram group/forum topic
TELEGRAM_DESTINATION_MODE="group_thread"

# Used when TELEGRAM_DESTINATION_MODE="private"
TELEGRAM_PRIVATE_CHAT_ID="YOUR_PRIVATE_CHAT_ID"

# Used when TELEGRAM_DESTINATION_MODE="group_thread"
TELEGRAM_GROUP_CHAT_ID="YOUR_GROUP_CHAT_ID"

# Telegram forum topic/thread IDs, used only in group_thread mode
SONARR_THREAD_ID="YOUR_SONARR_THREAD_ID"
RADARR_THREAD_ID="YOUR_RADARR_THREAD_ID"
LIDARR_THREAD_ID="YOUR_LIDARR_THREAD_ID"

# Legacy fallback:
# If TELEGRAM_PRIVATE_CHAT_ID is still unchanged/empty, the script can use this old v3 value.
# This helps avoid breaking existing private-chat installs during migration.
TELEGRAM_CHAT_ID="YOUR_PRIVATE_CHAT_ID"

SONARR_API_KEY="YOUR_SONARR_API_KEY"
RADARR_API_KEY="YOUR_RADARR_API_KEY"
LIDARR_API_KEY="YOUR_LIDARR_API_KEY"
SERVER_IP="YOUR_SERVER_IP"

# APP PORTS
# Change these if your Sonarr/Radarr/Lidarr services use non-standard ports.
SONARR_PORT="${SONARR_PORT:-8989}"
RADARR_PORT="${RADARR_PORT:-7878}"
LIDARR_PORT="${LIDARR_PORT:-8686}"

# LOG SWITCH (Set to "true" for debugging, "false" to disable)
# Can also be overridden for tests: ENABLE_LOGGING=true ./notifiche_arr_v4.sh
ENABLE_LOGGING="${ENABLE_LOGGING:-false}"

# ASYNC MODE
# true  = the Arr app exits immediately; this script continues in a background worker.
# false = old synchronous behavior, useful only for debugging.
ASYNC_MODE="${ASYNC_MODE:-true}"

# Wait time used to merge Sonarr season packs / Lidarr album events before sending one notification.
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-15}"

# SINGLE EPISODE DETAILS (Sonarr)
# true  = for a single episode, show that episode's own plot and use its screenshot as the image.
#         Falls back to the series plot / poster when the episode has none.
# false = always show the series plot and poster.
EPISODE_DETAILS="${EPISODE_DETAILS:-true}"

# --- DYNAMIC PATHS ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
TMP_DIR="$BASE_DIR/temp"
DEBUG_LOG="$LOG_DIR/debug.log"
WORKER_LOG="$LOG_DIR/worker.log"

MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-5}"

rotate_log_if_needed() {
    local file="$1"
    local max_mb="${MAX_LOG_SIZE_MB:-5}"

    [[ "$max_mb" =~ ^[0-9]+$ ]] || max_mb=5
    [ "$max_mb" -gt 0 ] || return 0
    [ -f "$file" ] || return 0

    local max_bytes=$((max_mb * 1024 * 1024))
    local size
    size=$(wc -c < "$file" 2>/dev/null || echo 0)

    if [ "$size" -gt "$max_bytes" ]; then
        mv -f "$file" "$file.1" 2>/dev/null || true
        : > "$file" 2>/dev/null || true
    fi
}

mkdir -p "$LOG_DIR" "$TMP_DIR"
chmod -R 777 "$LOG_DIR" "$TMP_DIR" 2>/dev/null || true

# Log Function (writes only if enabled)
log_msg() {
    if [ "$ENABLE_LOGGING" = "true" ]; then
        rotate_log_if_needed "$DEBUG_LOG"
        local role="MAIN"
        if [ "${ARR_NOTIFIER_WORKER:-0}" = "1" ]; then
            role="WORKER"
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$role] $1" >> "$DEBUG_LOG"
    fi
}

log_telegram_response() {
    local resp="$1"

    if command -v jq >/dev/null 2>&1; then
        local ok message_id thread_id error_code description
        ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo "parse_error")
        message_id=$(echo "$resp" | jq -r '.result.message_id // "N/A"' 2>/dev/null || echo "N/A")
        thread_id=$(echo "$resp" | jq -r '.result.message_thread_id // "N/A"' 2>/dev/null || echo "N/A")
        error_code=$(echo "$resp" | jq -r '.error_code // empty' 2>/dev/null || echo "")
        description=$(echo "$resp" | jq -r '.description // empty' 2>/dev/null || echo "")

        if [ "$ok" = "true" ]; then
            log_msg "Telegram response: ok=true message_id=$message_id thread_id=$thread_id"
        else
            log_msg "Telegram response: ok=$ok error_code=${error_code:-N/A} description=${description:-N/A}"
        fi
    else
        log_msg "Telegram response: jq_not_found raw_preview=${resp:0:300}"
    fi
}

# In async mode, the process called by Sonarr/Radarr/Lidarr exits immediately.
# The worker inherits the original Arr environment variables and does the slow work
# in the background: API calls, debounce sleep and Telegram upload.
start_async_worker_if_needed() {
    if [ "$ASYNC_MODE" = "true" ] && [ "${ARR_NOTIFIER_WORKER:-0}" != "1" ]; then
        log_msg "ASYNC: starting background worker and exiting parent process."

        (
            export ARR_NOTIFIER_WORKER=1
            if [ "$ENABLE_LOGGING" = "true" ]; then
                rotate_log_if_needed "$WORKER_LOG"
                nohup "$0" "$@" >> "$WORKER_LOG" 2>&1 &
            else
                nohup "$0" "$@" >/dev/null 2>&1 &
            fi
        )

        exit 0
    fi
}

start_async_worker_if_needed "$@"

resolve_telegram_destination() {
    TELEGRAM_TARGET_CHAT_ID=""
    TELEGRAM_TARGET_THREAD_ID=""

    case "$TELEGRAM_DESTINATION_MODE" in
        private)
            TELEGRAM_TARGET_CHAT_ID="$TELEGRAM_PRIVATE_CHAT_ID"

            # Backward compatibility with v3 config.
            if [ -z "$TELEGRAM_TARGET_CHAT_ID" ] || [ "$TELEGRAM_TARGET_CHAT_ID" = "YOUR_PRIVATE_CHAT_ID" ]; then
                TELEGRAM_TARGET_CHAT_ID="$TELEGRAM_CHAT_ID"
            fi
            ;;

        group_thread)
            TELEGRAM_TARGET_CHAT_ID="$TELEGRAM_GROUP_CHAT_ID"

            case "$APP" in
                Sonarr)
                    TELEGRAM_TARGET_THREAD_ID="$SONARR_THREAD_ID"
                    ;;
                Radarr)
                    TELEGRAM_TARGET_THREAD_ID="$RADARR_THREAD_ID"
                    ;;
                Lidarr)
                    TELEGRAM_TARGET_THREAD_ID="$LIDARR_THREAD_ID"
                    ;;
            esac
            ;;

        *)
            log_msg "ERROR: Invalid TELEGRAM_DESTINATION_MODE: $TELEGRAM_DESTINATION_MODE"
            exit 1
            ;;
    esac

    if [ -z "$TELEGRAM_TARGET_CHAT_ID" ] || [ "$TELEGRAM_TARGET_CHAT_ID" = "YOUR_TELEGRAM_CHAT_ID" ] || [ "$TELEGRAM_TARGET_CHAT_ID" = "YOUR_GROUP_CHAT_ID" ]; then
        log_msg "ERROR: Telegram chat ID is empty or still using placeholder."
        exit 1
    fi

    if [ "$TELEGRAM_DESTINATION_MODE" = "group_thread" ]; then
        if [ -z "$TELEGRAM_TARGET_THREAD_ID" ] || [[ "$TELEGRAM_TARGET_THREAD_ID" == YOUR_* ]]; then
            log_msg "ERROR: Telegram thread ID is empty or still using placeholder for app: $APP"
            exit 1
        fi
    fi

    log_msg "Telegram destination resolved: mode=$TELEGRAM_DESTINATION_MODE chat=$TELEGRAM_TARGET_CHAT_ID thread=${TELEGRAM_TARGET_THREAD_ID:-none}"
}

log_msg "================ START EVENT ================"

# Variables Dump (only if log is enabled)
if [ "$ENABLE_LOGGING" = "true" ]; then
    env | grep -iE "^(sonarr|radarr|lidarr)_" >> "$DEBUG_LOG"
fi


# Detect whether this import is a new download or an upgrade/replacement.
# Servarr exposes *_isupgrade=True for Sonarr/Radarr and deleted paths when files are replaced.
# Lidarr mainly exposes Lidarr_DeletedPaths on album upgrades; lowercase fallbacks are kept for compatibility.
detect_import_action() {
    IMPORT_ACTION="AVAILABLE"
    IMPORT_ACTION_REASON="new_import"

    case "$APP" in
        Sonarr)
            if [[ "${sonarr_isupgrade:-}" =~ ^([Tt]rue|true|TRUE|1|yes|YES)$ ]] || \
               [ -n "${sonarr_deletedrelativepaths:-}" ] || \
               [ -n "${sonarr_deletedpaths:-}" ]; then
                IMPORT_ACTION="UPGRADED"
                IMPORT_ACTION_REASON="sonarr_upgrade_or_deleted_paths"
            fi
            ;;

        Radarr)
            if [[ "${radarr_isupgrade:-}" =~ ^([Tt]rue|true|TRUE|1|yes|YES)$ ]] || \
               [ -n "${radarr_deletedrelativepaths:-}" ] || \
               [ -n "${radarr_deletedpaths:-}" ]; then
                IMPORT_ACTION="UPGRADED"
                IMPORT_ACTION_REASON="radarr_upgrade_or_deleted_paths"
            fi
            ;;

        Lidarr)
            if [[ "${lidarr_isupgrade:-}${Lidarr_IsUpgrade:-}" =~ ^([Tt]rue|true|TRUE|1|yes|YES)$ ]] || \
               [ -n "${lidarr_deletedpaths:-}" ] || \
               [ -n "${lidarr_deletedrelativepaths:-}" ] || \
               [ -n "${Lidarr_DeletedPaths:-}" ]; then
                IMPORT_ACTION="UPGRADED"
                IMPORT_ACTION_REASON="lidarr_upgrade_or_deleted_paths"
            fi
            ;;
    esac

    log_msg "IMPORT ACTION: $IMPORT_ACTION ($IMPORT_ACTION_REASON)"
}
format_size() {
    local bytes=$1
    if [[ "$2" == "MUSIC" ]]; then
        echo "$bytes" | awk '{printf "%.2f MB", $1/1024/1024}'
    else
        echo "$bytes" | awk '{if ($1 < 1073741824) printf "%.2f MB", $1/1024/1024; else printf "%.2f GB", $1/1024/1024/1024}'
    fi
}

format_track_number() {
    local value="${1:-0}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf "%02d" "$value"
    else
        printf "%s" "$value"
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

# Field separator of the temp list files (a "|" can legitimately appear in a title).
SEP=$'\x1f'

# Telegram parse_mode=HTML: "&", "<" and ">" in titles/plots must be escaped or the whole message is rejected.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Telegram counts the visible characters of a caption (tags excluded).
visible_len() {
    printf '%s' "$1" | sed 's/<[^>]*>//g' | wc -m | tr -d ' '
}

# Calls a Telegram Bot API method. Retries on rate limit (429) and on network errors.
# Prints the last response; returns 0 only if Telegram answered ok=true.
telegram_call() {
    local method="$1"; shift
    local attempt=1 resp retry
    while [ $attempt -le 3 ]; do
        resp=$(curl -s -m 30 -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/$method" "$@")
        if echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
            echo "$resp"; return 0
        fi
        retry=$(echo "$resp" | jq -r '.parameters.retry_after // empty' 2>/dev/null)
        if [ $attempt -lt 3 ] && { [ -n "$retry" ] || [ -z "$resp" ]; }; then
            log_msg "Telegram $method: ${retry:+rate limited, }retrying ($attempt/3)..."
            sleep "${retry:-3}"; attempt=$((attempt + 1)); continue
        fi
        echo "$resp"; return 1
    done
}

# --- 1. APP DETECTION & EVENT FILTER ---
EVENT_TYPE="${sonarr_eventtype:-}${radarr_eventtype:-}${lidarr_eventtype:-}${Lidarr_EventType:-}"

if [[ ! "$EVENT_TYPE" =~ ^(Download|AlbumDownload)$ ]]; then
    log_msg "EXIT: Event ignored ($EVENT_TYPE)."
    exit 0
fi

if [ -n "${sonarr_eventtype:-}" ]; then
    APP="Sonarr"; API_KEY="$SONARR_API_KEY"; PORT="$SONARR_PORT"; ENDPOINT="series"; VER="v3"; TYPE="TV"
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
    APP="Radarr"; API_KEY="$RADARR_API_KEY"; PORT="$RADARR_PORT"; ENDPOINT="movie"; VER="v3"; TYPE="MOVIE"
    ID="$radarr_movie_id"
    FILE_IDS=$(echo "${radarr_moviefile_ids:-${radarr_moviefile_id:-}}" | tr '|' ' ' | tr ',' ' ')
    FILE_ID=$(echo "$FILE_IDS" | awk '{print $1}')

    # AUTO-DISCOVERY
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "0" ]; then
        log_msg "Radarr: Empty FILE_ID, retrieving file associated with the movie..."
        FILE_ID=$(curl -s "http://$SERVER_IP:$PORT/api/$VER/movie/$ID?apikey=$API_KEY" | jq -r '.movieFile.id // empty')
    fi

elif [ -n "${lidarr_eventtype:-}${Lidarr_EventType:-}" ]; then
    APP="Lidarr"; API_KEY="$LIDARR_API_KEY"; PORT="$LIDARR_PORT"; ENDPOINT="artist"; VER="v1"; TYPE="MUSIC"
    ID="${lidarr_artist_id:-${Lidarr_Artist_Id:-}}"
    ALB_ID="${lidarr_album_id:-${Lidarr_Album_Id:-}}"
    FILE_ID="${lidarr_trackfile_id:-${Lidarr_TrackFile_Id:-}}"

    # Real Lidarr Connect imports use Title_Case variables and AlbumDownload.
    # Manual shell tests can still use lowercase variables.
    if [ "${Lidarr_EventType:-}" = "AlbumDownload" ]; then
        EVENT_TYPE="AlbumDownload"
    fi
fi

log_msg "DETECTED: $APP | EVENT: $EVENT_TYPE | ID: $ID | FILE_ID: $FILE_ID"

detect_import_action

if [ -z "$FILE_ID" ] && [ "$EVENT_TYPE" != "AlbumDownload" ]; then
    log_msg "CRITICAL: FILE_ID unrecoverable. Ignored."
    exit 0
fi

# --- 2. DATA COLLECTION & DEBOUNCE ---
TEMP_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.list"
LOCK_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.lock"
INFO_STR=""

if [ "$TYPE" = "TV" ]; then
    E_INFO=$(fetch_data "http://$SERVER_IP:$SONARR_PORT/api/v3/episode?seriesId=$ID&apikey=$SONARR_API_KEY")
    for FID in $FILE_IDS; do
        [ -z "$FID" ] && continue
        log_msg "Processing Episode ID: $FID"
        F_JSON=$(fetch_data "http://$SERVER_IP:$SONARR_PORT/api/v3/episodefile/$FID?apikey=$SONARR_API_KEY")
        EP_S_NUM=$(echo "$F_JSON" | jq -r '.seasonNumber // 0')
        EP_SIZE=$(echo "$F_JSON" | jq -r '.size // 0')
        EP_QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
        EP_DATA=$(echo "$E_INFO" | jq -r ".[] | select(.episodeFileId == $FID) | \"\(.id)|\(.episodeNumber)|\(.title)\"" | head -n1)
        EP_ID=$(echo "$EP_DATA" | cut -d'|' -f1)
        EP_NUM=$(echo "$EP_DATA" | cut -d'|' -f2)
        EP_TITLE=$(echo "$EP_DATA" | cut -d'|' -f3-)
        LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')
        D_RAW=$(echo "$F_JSON" | jq -r '.mediaInfo.runTime // "00:00"')
        DUR_MIN=$(echo "$D_RAW" | cut -d: -f1 | sed 's/^0*//')

        echo "${EP_NUM:-00}${SEP}${EP_TITLE:-Episode}${SEP}${EP_SIZE:-0}${SEP}$EP_QUAL${SEP}${LANGS:-ND}${SEP}${DUR_MIN:-0}${SEP}${EP_S_NUM:-0}${SEP}${EP_ID:-0}" >> "$TEMP_FILE"
    done
    INFO_STR=""

elif [ "$TYPE" = "MUSIC" ]; then
    TRACKS_JSON=$(fetch_data "http://$SERVER_IP:$LIDARR_PORT/api/v1/track?albumId=$ALB_ID&apikey=$LIDARR_API_KEY")
    if [ "$EVENT_TYPE" = "AlbumDownload" ]; then
        FILES_JSON=$(fetch_data "http://$SERVER_IP:$LIDARR_PORT/api/v1/trackfile?albumId=$ALB_ID&apikey=$LIDARR_API_KEY")
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
            echo "${T_INDEX}${SEP}${T_TITLE}${SEP}${T_SIZE}${SEP}${T_QUAL}${SEP}${T_D_SEC:-0}" >> "$TEMP_FILE"
        done
        INFO_STR=""
    else
        F_JSON=$(fetch_data "http://$SERVER_IP:$LIDARR_PORT/api/v1/trackfile/$FILE_ID?apikey=$LIDARR_API_KEY")
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
        INFO_STR="${T_INDEX}${SEP}${T_TITLE}${SEP}${T_SIZE}${SEP}${T_QUAL}${SEP}${T_D_SEC:-0}"
    fi
fi

if [ "$TYPE" != "MOVIE" ] && [ -n "$INFO_STR" ]; then
    echo "$INFO_STR" >> "$TEMP_FILE"
fi

if [ "$TYPE" != "MOVIE" ]; then
    echo "$$" > "$LOCK_FILE"
    log_msg "DEBOUNCE: waiting ${DEBOUNCE_SECONDS}s for grouped TV/music imports."
    sleep "$DEBOUNCE_SECONDS"
    if [ "$(cat "$LOCK_FILE")" != "$$" ]; then
        log_msg "DEBOUNCE: newer worker detected, exiting this worker to avoid duplicate notification."
        exit 0
    fi
    sort -V "$TEMP_FILE" -o "$TEMP_FILE"
fi

# --- 3. METADATA FETCH & UI ---
BUTTONS=""
MAIN_JSON=$(curl -s -m 10 "http://$SERVER_IP:$PORT/api/$VER/$ENDPOINT/$ID?apikey=$API_KEY")
GENRES=$(echo "$MAIN_JSON" | jq -r '.genres | join(", ")' | html_escape)
OVERVIEW=$(echo "$MAIN_JSON" | jq -r '.overview // empty' | sed 's/<[^>]*>//g' | cut -c1-300 | html_escape)
LIST_ARR=()

if [ "$TYPE" = "MOVIE" ]; then
    F_JSON=$(curl -s -m 10 "http://$SERVER_IP:$RADARR_PORT/api/v3/moviefile/$FILE_ID?apikey=$RADARR_API_KEY")
    QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
    SIZE=$(format_size $(echo "$F_JSON" | jq -r '.size // 0') "MOVIE")
    RUNTIME=$(echo "$MAIN_JSON" | jq -r '.runtime // 0')
    RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.imdb.value // .ratings.value // "N/A"')
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')

    HEADER="🎬 [MOVIE $IMPORT_ACTION] - Radarr"
    BODY="<b>TITLE:</b> <i>$(echo "$MAIN_JSON" | jq -r '.title' | html_escape)</i>\n<b>GENRE:</b> <i>$GENRES</i>\n<b>QUALITY:</b> <i>$QUAL</i>\n<b>LANGUAGE:</b> <i>${LANGS:-ND}</i>\n<b>DURATION:</b> <i>${RUNTIME} min</i>\n<b>IMDB RATING:</b> <i>$RATING</i>\n<b>WEIGHT:</b> <i>$SIZE</i>\n\n<b>PLOT:</b> <i>$OVERVIEW...</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "TV" ]; then
    TITLE=$(echo "$MAIN_JSON" | jq -r '.title' | html_escape)
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId')
    RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.value // "N/A"')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LIST=""; TOTAL_SIZE=0; ALL_DUR=0; COUNT=$(wc -l < "$TEMP_FILE")

    while IFS="$SEP" read -r NUM T_TITLE SIZE QUAL LNG DUR S_NUM EP_ID; do
        T_TITLE=$(printf '%s' "$T_TITLE" | html_escape)
        LIST_ARR+=("• $(printf "%02d" "$NUM")_${T_TITLE} (${DUR} min)\n")
        LIST="${LIST}${LIST_ARR[${#LIST_ARR[@]}-1]}"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE)); FINAL_QUAL="$QUAL"; ALL_LANGS="$LNG"; ALL_DUR=$((ALL_DUR + DUR)); FINAL_S="$S_NUM"
        SINGLE_NUM="$NUM"; SINGLE_TITLE="$T_TITLE"; SINGLE_EP_ID="$EP_ID"
    done < "$TEMP_FILE"

    # Single episode: the episode's own plot and screenshot (only returned by the single-episode endpoint).
    OVERVIEW_END="..."
    if [ "$COUNT" -eq 1 ] && [ "$EPISODE_DETAILS" = "true" ] && [ "${SINGLE_EP_ID:-0}" != "0" ]; then
        EP_JSON=$(curl -s -m 10 "http://$SERVER_IP:$SONARR_PORT/api/v3/episode/$SINGLE_EP_ID?apikey=$SONARR_API_KEY")
        EP_OVERVIEW=$(echo "$EP_JSON" | jq -r '.overview // empty' 2>/dev/null | sed 's/<[^>]*>//g')
        EP_IMAGE=$(echo "$EP_JSON" | jq -r '[.images[]? | select(.coverType=="screenshot") | .remoteUrl][0] // empty' 2>/dev/null)
        if [ -n "$EP_OVERVIEW" ]; then
            [ "${#EP_OVERVIEW}" -le 300 ] && OVERVIEW_END=""
            OVERVIEW=$(printf '%s' "$EP_OVERVIEW" | cut -c1-300 | html_escape)
        fi
        [ -n "$EP_IMAGE" ] && IMAGE_URL="$EP_IMAGE"
        log_msg "Episode details: plot=${#EP_OVERVIEW} chars, screenshot=${EP_IMAGE:+yes}"
    fi

    if [ "$COUNT" -gt 1 ]; then
        HEADER="🔵 [SEASON $IMPORT_ACTION] - Sonarr"
        BODY="<b>TITLE:</b> <i>$TITLE</i>\n<b>SEASON:</b> <i>$(printf "%02d" "${FINAL_S:-0}")</i>\n<b>EPISODE COUNT:</b> <i>$COUNT</i>\n<b>EPISODES:</b>\n<i>$LIST</i>\n"
    else
        HEADER="🔵 [EPISODE $IMPORT_ACTION] - Sonarr"
        BODY="<b>TITLE:</b> <i>$TITLE</i>\n<b>SEASON:</b> <i>$(printf "%02d" "${FINAL_S:-0}")</i>\n<b>EPISODE:</b> <i>$(printf "%02d" "${SINGLE_NUM:-0}")</i>\n<b>EPISODE TITLE:</b> <i>${SINGLE_TITLE}</i>\n"
    fi
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n<b>LANGUAGE:</b> <i>${ALL_LANGS:-ND}</i>\n<b>QUALITY:</b> <i>$FINAL_QUAL</i>\n<b>DURATION:</b> <i>${ALL_DUR:-0} min</i>\n<b>IMDB RATING:</b> <i>$RATING</i>\n<b>WEIGHT:</b> <i>$(format_size $TOTAL_SIZE "TV")</i>\n\n<b>PLOT:</b> <i>${OVERVIEW}${OVERVIEW_END}</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "MUSIC" ]; then
    ALB_JSON=$(curl -s -m 10 "http://$SERVER_IP:$LIDARR_PORT/api/v1/album/$ALB_ID?apikey=$LIDARR_API_KEY")
    ART_NAME=$(echo "$MAIN_JSON" | jq -r '.artistName' | html_escape)
    ALB_NAME=$(echo "$ALB_JSON" | jq -r '.title' | html_escape)
    IMAGE_URL=$(echo "$ALB_JSON" | jq -r '.images[] | select(.coverType=="cover") | .remoteUrl' | head -n1)
    LIST=""; TOTAL_SIZE=0; TOTAL_SEC=0; COUNT=$(wc -l < "$TEMP_FILE")

    while IFS="$SEP" read -r NUM T_TITLE SIZE QUAL DUR; do
        T_TITLE=$(printf '%s' "$T_TITLE" | html_escape)
        MIN=$((DUR/60)); SEC=$((DUR%60)); DUR_F=$(printf "%02d:%02d" $MIN $SEC)
        LIST_ARR+=("• $(format_track_number "$NUM")_${T_TITLE} (${DUR_F})\n")
        LIST="${LIST}${LIST_ARR[${#LIST_ARR[@]}-1]}"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE)); TOTAL_SEC=$((TOTAL_SEC + DUR)); FINAL_QUAL="$QUAL"
        S_TITLE="$T_TITLE"; S_NUM="$NUM"
    done < "$TEMP_FILE"

    T_MIN=$((TOTAL_SEC/60)); T_SEC=$((TOTAL_SEC%60)); T_DUR_F=$(printf "%02d:%02d" $T_MIN $T_SEC)

    if [ "$COUNT" -gt 1 ]; then
        HEADER="🟢 [ALBUM $IMPORT_ACTION] - Lidarr"
        BODY="<b>ALBUM:</b> <i>$ALB_NAME</i>\n<b>ARTIST:</b> <i>$ART_NAME</i>\n<b>TRACKS:</b>\n<i>$LIST</i>\n"
    else
        HEADER="🟢 [SONG $IMPORT_ACTION] - Lidarr"
        BODY="<b>TITLE:</b> <i>$S_TITLE</i>\n<b>ALBUM:</b> <i>$ALB_NAME</i>\n<b>TRACK:</b> <i>$(format_track_number "${S_NUM:-0}")</i>\n<b>ARTIST:</b> <i>$ART_NAME</i>\n"
    fi
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n<b>QUALITY:</b> <i>$FINAL_QUAL</i>\n<b>DURATION:</b> <i>$T_DUR_F</i>\n<b>WEIGHT:</b> <i>$(format_size $TOTAL_SIZE "MUSIC")</i>\n"

    SPOTIFY=$(echo "$MAIN_JSON" | jq -r '.links[] | select(.name=="spotify") | .url' | head -n1)
    YOUTUBE=$(echo "$MAIN_JSON" | jq -r '.links[] | select(.name=="youtube") | .url' | head -n1)
    BUTTONS=""
    BTN_ITEMS=""
    [[ -n "$SPOTIFY" && "$SPOTIFY" != "null" ]] && BTN_ITEMS="${BTN_ITEMS}{\"text\":\"🎧 Spotify\",\"url\":\"${SPOTIFY}\"},"
    [[ -n "$YOUTUBE" && "$YOUTUBE" != "null" ]] && BTN_ITEMS="${BTN_ITEMS}{\"text\":\"📺 YouTube\",\"url\":\"${YOUTUBE}\"},"
    BTN_ITEMS="${BTN_ITEMS%,}"
    if [ -n "$BTN_ITEMS" ]; then
        BUTTONS="{\"inline_keyboard\":[[$BTN_ITEMS]]}"
    fi
fi

# --- 4. SEND NOTIFICATION ---
rm -f "$TEMP_FILE" "$LOCK_FILE"
MSG=$(printf '<b>%s</b>\n\n%b' "$HEADER" "$BODY")

# A photo caption is limited to 1024 characters: shorten long episode/track lists ("... +N more").
CAPTION_LIMIT=1000
if [ "${#LIST_ARR[@]}" -gt 3 ] && [ "$(visible_len "$MSG")" -gt "$CAPTION_LIMIT" ]; then
    TOTAL_ITEMS=${#LIST_ARR[@]}; KEEP=$TOTAL_ITEMS
    while [ "$KEEP" -gt 3 ]; do
        KEEP=$((KEEP - 1))
        NEW_LIST=""
        for ((i = 0; i < KEEP; i++)); do NEW_LIST="${NEW_LIST}${LIST_ARR[i]}"; done
        NEW_LIST="${NEW_LIST}• ... +$((TOTAL_ITEMS - KEEP)) more\n"
        MSG=$(printf '<b>%s</b>\n\n%b' "$HEADER" "${BODY/"$LIST"/"$NEW_LIST"}")
        [ "$(visible_len "$MSG")" -le "$CAPTION_LIMIT" ] && break
    done
    log_msg "Caption too long: list shortened to $KEEP of $TOTAL_ITEMS items."
fi

resolve_telegram_destination

TG_COMMON=(--data-urlencode "chat_id=$TELEGRAM_TARGET_CHAT_ID")
if [ -n "${BUTTONS:-}" ]; then
    TG_COMMON+=(--data-urlencode "reply_markup=$BUTTONS")
fi
if [ "$TELEGRAM_DESTINATION_MODE" = "group_thread" ] && [ -n "$TELEGRAM_TARGET_THREAD_ID" ]; then
    TG_COMMON+=(--data-urlencode "message_thread_id=$TELEGRAM_TARGET_THREAD_ID")
fi

SENT=false

# 1) Photo + caption.
if [ -n "${IMAGE_URL:-}" ] && [ "$IMAGE_URL" != "null" ]; then
    if TG_RESP=$(telegram_call sendPhoto "${TG_COMMON[@]}" \
            --data-urlencode "photo=$IMAGE_URL" --data-urlencode "caption=$MSG" --data-urlencode "parse_mode=HTML"); then
        SENT=true
    fi
    log_telegram_response "$TG_RESP"
else
    log_msg "No image available: skipping sendPhoto."
fi

# 2) Fallback: text only (image unreachable, caption rejected...). Allows up to 4096 characters.
if [ "$SENT" != "true" ]; then
    log_msg "FALLBACK: sending text-only message."
    if TG_RESP=$(telegram_call sendMessage "${TG_COMMON[@]}" \
            --data-urlencode "text=$MSG" --data-urlencode "parse_mode=HTML" --data-urlencode "disable_web_page_preview=true"); then
        SENT=true
    fi
    log_telegram_response "$TG_RESP"
fi

# 3) Last resort: plain text without formatting (in case Telegram still rejects the HTML).
if [ "$SENT" != "true" ]; then
    log_msg "FALLBACK: sending plain text message."
    PLAIN=$(printf '%s' "$MSG" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')
    if TG_RESP=$(telegram_call sendMessage "${TG_COMMON[@]}" --data-urlencode "text=$PLAIN"); then
        SENT=true
    fi
    log_telegram_response "$TG_RESP"
fi

if [ "$SENT" = "true" ]; then
    log_msg "FINISH: Notification Sent."
else
    log_msg "FINISH: ERROR - notification NOT sent."
fi
log_msg "================= END EVENT ================="

#!/bin/bash

# ==============================================================================
# Arr-Telegram-Notifier v2.0
# Description: Professional Telegram notifications for Sonarr, Radarr, and Lidarr.
# Features: Grouping logic, Precise Metadata (Size, Duration, Language), 
#           Rich UI with Bold/Italic formatting.
# ==============================================================================

# --- CONFIGURATION (Anonymized for Privacy) ---
TELEGRAM_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"
SONARR_API_KEY="YOUR_SONARR_API_KEY"
RADARR_API_KEY="YOUR_RADARR_API_KEY"
LIDARR_API_KEY="YOUR_LIDARR_API_KEY"
SERVER_IP="YOUR_SERVER_IP" # Your server ip

TMP_DIR="/tmp/arr_collector"
mkdir -p "$TMP_DIR"

# Helper function to convert bytes into human-readable format
format_size() {
    local bytes=$1
    local type=$2
    if [[ "$type" == "MUSIC" ]]; then
        printf "%.2f MB" "$(echo "scale=2; $bytes/1024/1024" | bc)"
    else
        if [[ "$bytes" -lt 1073741824 ]]; then
            printf "%.2f MB" "$(echo "scale=2; $bytes/1024/1024" | bc)"
        else
            printf "%.2f GB" "$(echo "scale=2; $bytes/1024/1024/1024" | bc)"
        fi
    fi
}

# --- 1. APP DETECTION ---
if [ -n "$sonarr_eventtype" ] && [[ "$sonarr_eventtype" != "Grab" ]]; then
    APP="Sonarr"; COLOR="🔵"; API_KEY="$SONARR_API_KEY"; PORT="8989"; ENDPOINT="series"; VER="v3"; TYPE="TV"
    ID="$sonarr_series_id"; ALB_ID="$sonarr_series_id"; FILE_ID="$sonarr_episodefile_id"
elif [ -n "$radarr_eventtype" ] && [[ "$radarr_eventtype" != "Grab" ]]; then
    APP="Radarr"; COLOR="🔴"; API_KEY="$RADARR_API_KEY"; PORT="7878"; ENDPOINT="movie"; VER="v3"; TYPE="MOVIE"
    ID="$radarr_movie_id"; FILE_ID="$radarr_moviefile_id"
elif [ -n "$lidarr_eventtype" ] && [[ "$lidarr_eventtype" != "Grab" ]]; then
    APP="Lidarr"; COLOR="🟢"; API_KEY="$LIDARR_API_KEY"; PORT="8686"; ENDPOINT="artist"; VER="v1"; TYPE="MUSIC"
    ID="$lidarr_artist_id"; ALB_ID="$lidarr_album_id"; FILE_ID="$lidarr_trackfile_id"
else
    exit 0
fi

# --- 2. DEBOUNCE & COLLECTION ---
# Uses temporary files to group multiple downloads (Albums/Seasons)
TEMP_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.list"
LOCK_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.lock"

sleep 8 # Wait for DB consistency

if [ "$TYPE" = "TV" ]; then
    F_JSON=$(curl -s "http://localhost:8989/api/v3/episodefile/$FILE_ID?apikey=$SONARR_API_KEY")
    EP_S_NUM=$(echo "$F_JSON" | jq -r '.seasonNumber // 0')
    EP_SIZE=$(echo "$F_JSON" | jq -r '.size // 0')
    EP_QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
    # Targeted episode lookup to avoid incorrect "Specials" names
    E_INFO=$(curl -s "http://localhost:8989/api/v3/episode?seriesId=$ID&apikey=$SONARR_API_KEY")
    EP_DATA=$(echo "$E_INFO" | jq -r ".[] | select(.episodeFileId == $FILE_ID) | \"\(.episodeNumber)|\(.title)\"")
    EP_NUM=$(echo "$EP_DATA" | cut -d'|' -f1 | head -n1)
    EP_TITLE=$(echo "$EP_DATA" | cut -d'|' -f2- | head -n1)
    LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')
    D_RAW=$(echo "$F_JSON" | jq -r '.mediaInfo.runTime // "00:00"')
    DUR_MIN=$(echo "$D_RAW" | cut -d: -f1 | sed 's/^0*//')
    INFO_STR="${EP_NUM:-00}|${EP_TITLE:-Episode}|${EP_SIZE:-0}|$EP_QUAL|${LANGS:-ND}|${DUR_MIN:-0}|${EP_S_NUM:-0}"
elif [ "$TYPE" = "MUSIC" ]; then
    F_JSON=$(curl -s "http://localhost:8686/api/v1/trackfile/$FILE_ID?apikey=$LIDARR_API_KEY")
    T_TITLE=$(echo "$F_JSON" | jq -r '.audioTags.title // "Track"')
    T_INDEX=$(echo "$F_JSON" | jq -r '.audioTags.trackNumbers[0] // 0')
    T_SIZE=$(echo "$F_JSON" | jq -r '.size // 0')
    T_QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
    D_RAW=$(echo "$F_JSON" | jq -r '.audioTags.duration' | cut -d. -f1)
    T_D_SEC=$(echo "$D_RAW" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
    INFO_STR="${T_INDEX:-0}|$T_TITLE|${T_SIZE:-0}|$T_QUAL|${T_D_SEC:-0}"
fi

[[ -n "$INFO_STR" ]] && echo "$INFO_STR" >> "$TEMP_FILE"
echo "$$" > "$LOCK_FILE"
sleep 15 # Wait to group potential concurrent downloads
if [ "$(cat "$LOCK_FILE")" != "$$" ]; then exit 0; fi

sort -V "$TEMP_FILE" -o "$TEMP_FILE"

# --- 3. METADATA FETCH ---
MAIN_JSON=$(curl -s "http://localhost:$PORT/api/$VER/$ENDPOINT/$ID?apikey=$API_KEY")
GENRES=$(echo "$MAIN_JSON" | jq -r '.genres | join(", ")')
OVERVIEW=$(echo "$MAIN_JSON" | jq -r '.overview // empty' | sed 's/<[^>]*>//g' | cut -c1-300)

if [ "$TYPE" = "MOVIE" ]; then
    F_JSON=$(curl -s "http://localhost:7878/api/v3/moviefile/$FILE_ID?apikey=$RADARR_API_KEY")
    QUAL=$(echo "$F_JSON" | jq -r '.quality.quality.name // "N/A"')
    SIZE=$(format_size $(echo "$F_JSON" | jq -r '.size // 0') "MOVIE")
    RUNTIME=$(echo "$MAIN_JSON" | jq -r '.runtime // 0')
    RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.imdb.value // .ratings.value // "N/A"')
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LANGS=$(echo "$F_JSON" | jq -r '.languages[].name' | tr '\n' '/' | sed 's/\/$//' | tr '[:lower:]' '[:upper:]')
    HEADER="🎬 [MOVIE AVAILABLE] - $APP"
    BODY="<b>TITLE:</b> <i>$(echo "$MAIN_JSON" | jq -r '.title')</i>\n"
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n"
    BODY="${BODY}<b>QUALITY:</b> <i>$QUAL</i>\n"
    BODY="${BODY}<b>LANGUAGE:</b> <i>${LANGS:-ND}</i>\n"
    BODY="${BODY}<b>DURATION:</b> <i>${RUNTIME} min</i>\n"
    BODY="${BODY}<b>IMDB RATING:</b> <i>$RATING</i>\n"
    BODY="${BODY}<b>WEIGHT:</b> <i>$SIZE</i>\n\n"
    BODY="${BODY}<b>PLOT:</b> <i>$OVERVIEW...</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "TV" ]; then
    TITLE=$(echo "$MAIN_JSON" | jq -r '.title')
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId'); RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.value // "N/A"')
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | head -n1)
    LIST=""; TOTAL_SIZE=0; ALL_DUR=0; COUNT=$(wc -l < "$TEMP_FILE")
    while IFS='|' read -r NUM T_TITLE SIZE QUAL LNG DUR S_NUM; do
        LIST="${LIST}• $(printf "%02d" "$NUM")_${T_TITLE} (${DUR} min)\n"
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE)); FINAL_QUAL="$QUAL"; ALL_LANGS="$LNG"; ALL_DUR=$((ALL_DUR + DUR)); FINAL_S="$S_NUM"
        SINGLE_NUM="$NUM"; SINGLE_TITLE="$T_TITLE"
    done < "$TEMP_FILE"
    HEADER="🔵 [SERIE AVAILABLE] - $APP"
    BODY="<b>TITLE:</b> <i>$TITLE</i>\n"
    BODY="${BODY}<b>SEASON:</b> <i>$(printf "%02d" "${FINAL_S:-0}")</i>\n"
    if [ "$COUNT" -gt 1 ]; then
        BODY="${BODY}<b>EPISODE COUNT:</b> <i>$COUNT</i>\n"
        BODY="${BODY}<b>EPISODES:</b>\n<i>$LIST</i>\n"
    else
        BODY="${BODY}<b>EPISODE:</b> <i>$(printf "%02d" "${SINGLE_NUM:-0}")</i>\n"
        BODY="${BODY}<b>EPISODE TITLE:</b> <i>${SINGLE_TITLE}</i>\n"
    fi
    BODY="${BODY}<b>GENRE:</b> <i>$GENRES</i>\n"
    BODY="${BODY}<b>LANGUAGE:</b> <i>${ALL_LANGS:-ND}</i>\n"
    BODY="${BODY}<b>QUALITY:</b> <i>$FINAL_QUAL</i>\n"
    BODY="${BODY}<b>DURATION:</b> <i>${ALL_DUR:-0} min</i>\n"
    BODY="${BODY}<b>IMDB RATING:</b> <i>$RATING</i>\n"
    BODY="${BODY}<b>WEIGHT:</b> <i>$(format_size $TOTAL_SIZE "TV")</i>\n\n"
    BODY="${BODY}<b>PLOT:</b> <i>$OVERVIEW...</i>"
    [[ -n "$IMDB_ID" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"

elif [ "$TYPE" = "MUSIC" ]; then
    ALB_JSON=$(curl -s "http://localhost:8686/api/v1/album/$ALB_ID?apikey=$LIDARR_API_KEY")
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
        HEADER="🟢 [ALBUM AVAILABLE] - $APP"
        BODY="<b>ALBUM:</b> <i>$ALB_NAME</i>\n<b>ARTIST:</b> <i>$ART_NAME</i>\n"
        BODY="${BODY}<b>TRACKS:</b>\n<i>$LIST</i>\n"
    else
        HEADER="🟢 [SONG AVAILABLE] - $APP"
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

rm -f "$TEMP_FILE" "$LOCK_FILE"
MSG=$(printf "<b>$HEADER</b>\n\n$BODY")
curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendPhoto" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "photo=$IMAGE_URL" --data-urlencode "caption=$MSG" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$BUTTONS" > /dev/null

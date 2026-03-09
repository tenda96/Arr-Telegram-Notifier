#!/bin/bash

# ==============================================================================
# Arr-Telegram-Notifier
# Description: Enhanced Telegram notifications for Sonarr, Radarr, and Lidarr.
# Features: Metadata extraction, Album/Season grouping, and Media Covers.
# ==============================================================================

# --- CONFIGURATION (Fill in your details) ---
TELEGRAM_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"
SONARR_API_KEY="YOUR_SONARR_API_KEY"
RADARR_API_KEY="YOUR_RADARR_API_KEY"
LIDARR_API_KEY="YOUR_LIDARR_API_KEY"
UNRAID_IP="192.168.1.X" # Your server IP

# Temporary directory for grouping logic
TMP_DIR="/tmp/arr_collector"
mkdir -p "$TMP_DIR"

# --- 1. APP DETECTION ---
if [ -n "$sonarr_eventtype" ] && [[ "$sonarr_eventtype" == "Download" || "$sonarr_eventtype" == "Upgrade" ]]; then
    APP="SONARR"; COLOR="🔵"; API_KEY="$SONARR_API_KEY"; PORT="8989"; ENDPOINT="series"; VER="v3"; TYPE="TV"
    ID="$sonarr_series_id"; ALB_ID="$sonarr_series_id"; FILE_ID="$sonarr_episodefile_id"
elif [ -n "$radarr_eventtype" ] && [[ "$radarr_eventtype" == "Download" || "$radarr_eventtype" == "Upgrade" ]]; then
    APP="RADARR"; COLOR="🔴"; API_KEY="$RADARR_API_KEY"; PORT="7878"; ENDPOINT="movie"; VER="v3"; TYPE="MOVIE"
    ID="$radarr_movie_id"
elif [ -n "$lidarr_eventtype" ] && [[ "$lidarr_eventtype" == "Download" || "$lidarr_eventtype" == "Upgrade" ]]; then
    APP="LIDARR"; COLOR="🟢"; API_KEY="$LIDARR_API_KEY"; PORT="8686"; ENDPOINT="artist"; VER="v1"; TYPE="MUSIC"
    ID="$lidarr_artist_id"; ALB_ID="$lidarr_album_id"; FILE_ID="$lidarr_trackfile_id"
else
    # Exit for Grab events or unmanaged triggers
    exit 0
fi

# --- 2. DEBOUNCE & GROUPING LOGIC ---
# Grouping files arriving together (e.g., full album or season)
TEMP_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.list"
LOCK_FILE="$TMP_DIR/${TYPE}_${ALB_ID:-$ID}.lock"

# Wait for DB sync (Apps need time to register the file after import)
sleep 8

if [ "$TYPE" = "MUSIC" ]; then
    JSON=$(curl -s "http://localhost:8686/api/v1/trackfile/$FILE_ID?apikey=$LIDARR_API_KEY")
    T_TITLE=$(echo "$JSON" | jq -r '.tracks[0].title // "Acquired Track"')
    T_SEC=$(echo "$JSON" | jq -r '.duration // 0' | cut -d'.' -f1)
    T_QUAL=$(echo "$JSON" | jq -r '.quality.quality.name // "N/A"')
    INFO_STR="$T_TITLE|$T_SEC|$T_QUAL"
elif [ "$TYPE" = "TV" ]; then
    JSON=$(curl -s "http://localhost:8989/api/v3/episodefile/$FILE_ID?apikey=$SONARR_API_KEY")
    # Path mapping (Update /tv to match your container path)
    PATH_TV="${sonarr_episodefile_path/\/mnt\/hdd\/Serie/\/tv}"
    LANGS=$(/app/sonarr/bin/ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$PATH_TV" | tr '\n' ',' | sed 's/,$//' | tr '[:lower:]' '[:upper:]' 2>/dev/null)
    EP_NUM=$(echo "$JSON" | jq -r '.tracks[0].episodeNumber // "??"')
    EP_TITLE=$(echo "$JSON" | jq -r '.tracks[0].title // "Episode"')
    INFO_STR="Ep. $EP_NUM - $EP_TITLE|${LANGS:-ND}|$(echo "$JSON" | jq -r '.quality.quality.name // "N/A"')"
elif [ "$TYPE" = "MOVIE" ]; then
    INFO_STR="$radarr_movie_title|${radarr_moviefile_quality:-N/A}"
fi

# Append to temp list
echo "$INFO_STR" >> "$TEMP_FILE"
echo "$$" > "$LOCK_FILE"

# Wait to see if more tracks/episodes follow
sleep 15
if [ "$(cat "$LOCK_FILE")" != "$$" ]; then exit 0; fi

# --- 3. METADATA FETCHING ---
MAIN_JSON=$(curl -s "http://localhost:$PORT/api/$VER/$ENDPOINT/$ID?apikey=$API_KEY")
TITLE=$(echo "$MAIN_JSON" | jq -r '.title // .artistName')
RATING=$(echo "$MAIN_JSON" | jq -r '.ratings.value // .ratings[0].value // "N/A"')

if [ "$TYPE" = "MUSIC" ]; then
    ALB_JSON=$(curl -s "http://localhost:8686/api/v1/album/$ALB_ID?apikey=$LIDARR_API_KEY")
    SUB_TITLE=$(echo "$ALB_JSON" | jq -r '.title')
    OVERVIEW=$(echo "$ALB_JSON" | jq -r '.overview // empty' | sed 's/<[^>]*>//g' | cut -c1-300)
    [[ -z "$OVERVIEW" ]] && OVERVIEW=$(echo "$MAIN_JSON" | jq -r '.overview // .biography // empty' | sed 's/<[^>]*>//g' | cut -c1-250)
    IMAGE_URL=$(echo "$ALB_JSON" | jq -r '.images[] | select(.coverType=="cover") | .remoteUrl' | grep "^http" | head -n1)
    SPOTIFY=$(echo "$MAIN_JSON" | jq -r '.links[] | select(.name=="spotify") | .url' | head -n1)
    [[ -n "$SPOTIFY" && "$SPOTIFY" != "null" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🎧 Spotify\", \"url\": \"$SPOTIFY\"}]]}"
else
    IMDB_ID=$(echo "$MAIN_JSON" | jq -r '.imdbId // empty')
    OVERVIEW=$(echo "$MAIN_JSON" | jq -r '.overview // empty' | cut -c1-300)
    IMAGE_URL=$(echo "$MAIN_JSON" | jq -r '.images[] | select(.coverType=="poster") | .remoteUrl' | grep "^http" | head -n1)
    [[ -n "$IMDB_ID" && "$IMDB_ID" != "null" ]] && BUTTONS="{\"inline_keyboard\": [[{\"text\": \"🌐 IMDb ($RATING)\", \"url\": \"https://www.imdb.com/title/$IMDB_ID\"}]]}"
fi

# --- 4. MESSAGE CONSTRUCTION ---
LIST_MSG=""; COUNT=0; FINAL_QUAL=""
while IFS='|' read -r NAME EXTRA QUAL; do
    if [ "$TYPE" = "MUSIC" ]; then
        MIN=$((EXTRA/60)); SEC=$((EXTRA%60)); DUR=$(printf "%02d:%02d" $MIN $SEC)
        LIST_MSG="${LIST_MSG}• $NAME ($DUR)\n"; FINAL_QUAL="$QUAL"
    elif [ "$TYPE" = "TV" ]; then
        LIST_MSG="${LIST_MSG}• $NAME (🔊 $EXTRA)\n"; FINAL_QUAL="$QUAL"
    else
        FINAL_QUAL="$EXTRA"
    fi
    ((COUNT++))
done < "$TEMP_FILE"

# Format Headers
[ "$COUNT" -gt 1 ] && TAG="COMPLETE" || TAG="AVAILABLE"

if [ "$TYPE" = "MUSIC" ]; then
    DESC="💿 <b>$SUB_TITLE</b>\n\n🎼 <b>Tracks:</b>\n$LIST_MSG"
elif [ "$TYPE" = "TV" ]; then
    [ "$COUNT" -gt 1 ] && DESC="💿 <b>Full Season</b>\n\n📺 <b>Episodes:</b>\n$LIST_MSG" || DESC="💿 <b>Season $(printf "%02d" "$sonarr_episodefile_seasonnumber")</b>\n$LIST_MSG"
else
    DESC="🎬 <b>Movie</b>\n• $radarr_movie_title\n"
fi

MSG=$(printf "<b>$COLOR [$APP] - ✅ $TAG</b>\n\n<b>👤 $TITLE</b>\n$DESC\n✨ <b>Quality:</b> $FINAL_QUAL\n\n📖 ${OVERVIEW:-No description available.}")
rm -f "$TEMP_FILE" "$LOCK_FILE"

# --- 5. DISPATCH ---
if [[ -n "$IMAGE_URL" && "$IMAGE_URL" != "null" ]]; then
    RES=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendPhoto" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "photo=$IMAGE_URL" --data-urlencode "caption=$MSG" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$BUTTONS")
    [[ $RES != *"\"ok\":true"* ]] && curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$MSG" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$BUTTONS" > /dev/null
else
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$MSG" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$BUTTONS" > /dev/null
fi

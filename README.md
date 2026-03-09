# Arr-Telegram-Notifier (v1.0)

A powerful bash script for **Sonarr**, **Radarr**, and **Lidarr** that sends detailed Telegram notifications. It groups multiple files (like full albums or seasons) into a single, clean notification.

## ⚠️ Important Prerequisites
Before starting, ensure the following:
* **File Visibility**: If you are using Docker (e.g., on Unraid), the script **must** be located in a folder visible to all containers. 
    * *Example*: Map a host folder like `/mnt/user/appdata/scripts/` to `/scripts/` in each container's volume settings.
* **IP Configuration**: You must edit the `UNRAID_IP` variable inside the script to match your server's local IP address.
* **Dependencies**: Ensure `jq` and `curl` are installed (usually present in LinuxServer.io images).

## 🚀 Installation
1.  Download `arr-notifier.sh` and place it in your shared scripts folder.
2.  Give it execution permissions: `chmod +x arr-notifier.sh`.
3.  Open the script and configure:
    * `TELEGRAM_TOKEN` & `TELEGRAM_CHAT_ID`.
    * `SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`.
    * `UNRAID_IP` (Your server's local IP).

## ⚙️ App Configuration
In **Sonarr**, **Radarr**, and **Lidarr**, go to `Settings > Connect`:
1.  Add a new **Custom Script** notification.
2.  **Path**: Set the path *as seen by the container* (e.g., `/scripts/arr-notifier.sh`).
3.  **Triggers**: Select only `On Download` and `On Upgrade`. 
    * *Note*: Disable `On Grab` to avoid duplicate "searching" notifications.

## 📝 Changelog (v1.0)
- Initial release with English localization.
- Integrated "Collector" logic to debounce multiple triggers for Albums/Seasons.
- Added `ffprobe` support for real-time audio language detection.

## 🐛 Known Issues & Limitations
- **Album/Season Display**: Currently, if the "Arr" database updates too slowly, track names or episode titles might appear as "Unknown" or "00:00" duration. A 15-second delay is included to mitigate this.
- **Image Caching**: Telegram may occasionally fail to display covers if the URL provided by the API is not publicly reachable.

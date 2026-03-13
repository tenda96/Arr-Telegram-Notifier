![Views](https://komarev.com/ghpvc/?username=tenda96&repo=Arr-Telegram-Notifier&color=blue&style=for-the-badge)
![Stars](https://img.shields.io/github/stars/tenda96/Arr-Telegram-Notifier?style=for-the-badge&color=yellow)
![Forks](https://img.shields.io/github/forks/tenda96/Arr-Telegram-Notifier?style=for-the-badge&color=lightgrey)

# Arr-Telegram-Notifier

A professional bash script for **Sonarr**, **Radarr**, and **Lidarr** that sends rich Telegram notifications. It features a "Collector" logic that groups concurrent downloads (like full albums or season packs) into a single, clean message.

## 🌟 How it behaves
- **Grouping Engine**: Automatically detects multiple incoming files (e.g., an entire album or a batch of episodes/Season Packs) and sends one single notification with the full list after a short delay.
- **Auto-Discovery**: If the apps fail to provide proper File IDs during mass imports, the script securely queries their internal databases to fetch the missing data.
- **Precision**: Queries the internal APIs of the "Arr" apps (and the MusicBrainz DB for Lidarr) to retrieve exact titles, durations, and file sizes.
- **Mobile Optimized**: Designed specifically for Telegram mobile, using clean line breaks and styling.

## ⚠️ Prerequisites
* **File Visibility**: The script must be in a folder accessible by all containers (e.g., map `/mnt/user/appdata/scripts/` to `/scripts/` in Docker Compose).
* **Dependencies**: Requires `jq`, `curl`, and native `awk` (compatible with Unraid/Alpine).

## 🚀 Installation & Configuration
1.  Download `arr-notifier.sh` and place it in your shared scripts folder.
2.  Set permissions: `chmod +x arr-notifier.sh`.
3.  Edit the script variables:
    * `TELEGRAM_TOKEN` & `TELEGRAM_CHAT_ID`.
    * `SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY`.
    * `SERVER_IP` (Your local Unraid/Server IP).

### 🛠️ Debug Logging
The script includes a built-in logging system to help troubleshoot missing IDs or API errors. By default, it is **disabled** to keep your storage clean.
To enable it, open the script and set:
`ENABLE_LOGGING="true"`
Logs will be written to a `logs/debug.log` file in the same folder as the script.

## ⚙️ App Configuration
In Sonarr, Radarr, and Lidarr, go to **Settings > Connect**:
1.  Add a new **Custom Script**.
2.  **Path**: Set the container path (e.g., `/scripts/arr-notifier.sh`).
3.  **Triggers**: Select ONLY `On Import` and `On Upgrade` (In Lidarr, select `On Release Import` and `On Track Import`).
    * *Important*: This script is designed to run when the file import is completed. Do not select "On Grab" or "On Rename".

---

## 📸 Notification Gallery

| Radarr (Movie) | Sonarr (Single) | Sonarr (Season) |
| :---: | :---: | :---: |
| ![Radarr](examples/radarr.png) | ![Sonarr Single](examples/sonarr_single.png) | ![Sonarr Season](examples/sonarr_season.png) |
| *Movie Details* | *Single Episode* | *Full Season Grouping* |

| Lidarr (Song) | Lidarr (Album) |
| :---: | :---: |
| ![Lidarr Single](examples/lidarr_single.png) | ![Lidarr Album](examples/lidarr_album.png) |
| *Single Track* | *Full Album Grouping* |

---

## 📝 Changelog

### v3.0 (Master Release)
- **Advanced Season Pack Handling**: Added logic to parse multiple IDs divided by pipe `|` in Sonarr v4, perfectly grouping 10+ episodes in a single Season notification.
- **Lidarr Dual-Sync**: Completely rebuilt Lidarr logic. It now checks the internal MusicBrainz DB first, then falls back to file ID3 tags to prevent "Track 00" errors during fast mass-imports.
- **ID Auto-Discovery**: Added a fallback feature for Sonarr and Radarr. If the apps fail to send a File ID during mass imports, the script queries the DB to find it.
- **Built-in Logging**: Introduced a toggleable `ENABLE_LOGGING` switch to dump variables and API responses for easy troubleshooting.
- **Dependency Update**: Replaced `bc` with native `awk` for math calculations, ensuring better out-of-the-box compatibility with Unraid and lightweight containers.
- **Strict Event Filter**: Script now actively ignores "Test" or "Rename" events, preventing false-positive blank notifications.

### v2.0
- **UI Redesign**: Complete overhaul of the notification layout (Mobile Optimized).
- **Grouping Engine**: Improved debounce logic for Albums and Seasons with natural sorting.
- **Precision Data**: Fixed "00" episode numbers and "Unknown" titles by targeting specific API endpoints.
- **Compact Lists**: Redesigned list format: `• 01_Title (Duration)`.
- **Text Styling**: Added Bold headers and Italic values (removed monospace blue text).

### v1.0
- Initial release with English localization.
- Integrated "Collector" logic to debounce multiple triggers for Albums/Seasons.
- Added `ffprobe` support for real-time audio language detection.

## 🛠️ Upcoming Features (Roadmap)
- ♻️ **Enhanced Upgrade Support**: Specific notification tags when a higher quality replaces an old file.
- 🖼️ **Fallback Image Handling**: Smarter artist/series poster selection if specific album/episode covers are missing.

## License
This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

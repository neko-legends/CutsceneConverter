# Cutscene Converter

Cutscene Converter is a small workflow tool for preparing AI-generated videos for game engines such as Godot and Unity.

I originally made it because I needed a fast way to take generated video clips, clean up the front and back, convert them into game-friendly formats, scale them down when needed, and combine related clips before dropping them into a project. It is not trying to be a full video editor. It is just a focused helper for getting video into video games. No pun intended.

## What It Does

- Converts queued videos or folders into MP4, WebM VP9, or OGV.
- Supports MP4 H.264 and H.265 output.
- Trims the beginning and end of clips.
- Keeps native resolution or scales output to common game-ready sizes.
- Combines queued videos in alphabetical order.
- Handles recursive folder input, overwrite control, and parallel batch jobs.
- Finds FFmpeg from settings, the portable app folder, the app-managed fallback install, `D:\Tools`, or `PATH`.

## FFmpeg

On Windows, use the Install button if FFmpeg is missing. The app downloads FFmpeg essentials into `ffmpeg\bin` next to the portable exe when that folder is writable. If Windows blocks that location, it falls back to the app data folder. Install retries reuse a valid cached ZIP and only fill in missing FFmpeg files.

On Linux, install `ffmpeg` and `ffprobe` with your package manager before running.

## Windows Builds

- Portable executable: `dist-portable\CutsceneConverter-v26.6.9-windows-x64\Cutscene Converter.exe`
- Portable zip: `dist-portable\CutsceneConverter-v26.6.9-windows-x64.zip`
- NSIS installer: `src-tauri\target\release\bundle\nsis\Cutscene Converter_26.6.9_x64-setup.exe`

## Development

```powershell
npm install
npm run dev
npm run tauri:dev
npm run tauri:build
```

Cutscene Converter v26.6.9

Cutscene Converter is a small workflow tool for preparing AI-generated videos
for game engines such as Godot and Unity.

I originally made it because I needed a fast way to take generated video clips,
clean up the front and back, convert them into game-friendly formats, scale them
down when needed, and combine related clips before dropping them into a project.
It is not trying to be a full video editor. It is just a focused helper for
getting video into video games. No pun intended.

Example:
- Music video clip prepared with Cutscene Converter:
  https://youtu.be/Rji3MnXg2w4

Features:
- Batch convert individual video files or whole folders.
- Export to game-friendly formats: MP4, WebM VP9, and OGV.
- Choose MP4 H.264 for broad compatibility or H.265 for smaller modern output.
- Trim unwanted lead-in or tail frames from generated clips before export.
- Keep the source resolution or scale output to common game-ready sizes like
  1080p, 1444p, or 4K.
- Combine queued videos in alphabetical order into one continuous cutscene file.
- Include subfolders when scanning a source folder.
- Run multiple conversion jobs in parallel for faster batches.
- Control overwrite behavior so existing outputs are either replaced or skipped.
- Track per-file status with clear finished, skipped, failed, and canceled
  states.
- Remove individual queued videos or clear the full queue.
- Open completed output folders directly from the queue.
- Cancel an active batch without leaving the app stuck.
- Automatically find FFmpeg from settings, the portable app folder, the
  app-managed fallback install, D:\Tools, or PATH.
- Download a portable FFmpeg build on Windows when FFmpeg is missing.
- Keep a focused workflow: this is for preparing clips for game projects, not
  for timeline editing, effects, or audio mixing.

FFmpeg:
- On Windows, use the Install button if FFmpeg is missing. The app downloads
  FFmpeg essentials into ffmpeg\bin next to the portable exe when that folder is
  writable. If Windows blocks that location, it falls back to the app data
  folder. Install retries reuse a valid cached ZIP and only fill in missing
  FFmpeg files.
- On Linux, install ffmpeg and ffprobe with your package manager before running.

Windows release outputs:
- Portable executable: dist-portable\CutsceneConverter-v26.6.9-windows-x64\Cutscene Converter.exe
- Portable zip: dist-portable\CutsceneConverter-v26.6.9-windows-x64.zip
- NSIS installer: src-tauri\target\release\bundle\nsis\Cutscene Converter_26.6.9_x64-setup.exe

Development:
- npm install
- npm run dev
- npm run tauri:dev
- npm run tauri:build

Cutscene Converter v26.6.9

Cutscene Converter is now a Tauri desktop app with a React workspace UI.

What it does:
- Exports MP4 runtime copies from queued video files or folders.
- Supports MP4 H.264 and H.265, WebM VP9, and OGV outputs.
- Supports trim start/end, output resolution, overwrite control, recursive folder input, and parallel batch jobs.
- Combines queued videos in alphabetical order into a first_name_combined.ext output.
- Finds FFmpeg from settings, app-managed install, nearby portable folders, D:\Tools, or PATH.
- On Windows, the Install button downloads FFmpeg essentials into the app data folder.
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

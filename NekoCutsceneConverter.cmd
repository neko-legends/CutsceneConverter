@echo off
setlocal
set "PORTABLE_APP=%~dp0dist-portable\CutsceneConverter-v26.6.9-windows-x64\Cutscene Converter.exe"
set "RELEASE_APP=%~dp0src-tauri\target\release\cutscene-converter.exe"

if exist "%PORTABLE_APP%" (
	start "" "%PORTABLE_APP%"
	exit /b 0
)

if exist "%RELEASE_APP%" (
	start "" "%RELEASE_APP%"
	exit /b 0
)

echo Cutscene Converter v26.6.9 has not been built yet.
echo Run npm install, then npm run tauri:build.
pause

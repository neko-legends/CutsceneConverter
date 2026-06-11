use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::VecDeque,
    env,
    fs::{self, File},
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_opener::OpenerExt;
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;
const APP_VERSION: &str = "v26.6.9";
const DEFAULT_OUTPUT_DIR: &str =
    r"D:\NekoLegends-Universe\games\neko-legends-awakening\godot\assets\video\cutscenes";
const DEFAULT_AGENT_API_PORT: u16 = 17337;
const AGENT_APP_ID: &str = "cutscene-converter";
const AGENT_APP_NAME: &str = "Cutscene Converter";
const AGENT_API_BIND_ADDRESS: &str = "127.0.0.1";
const AGENT_API_REGISTRY_FILE: &str = "agent-api-registry.json";
const FFMPEG_DOWNLOAD_URL: &str =
    "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
const VIDEO_EXTENSIONS: &[&str] = &[
    "mp4", "webm", "ogv", "mov", "mkv", "avi", "m4v", "wmv", "flv",
];

#[derive(Clone, Default)]
struct ActiveJobState {
    inner: Arc<Mutex<Option<ActiveJob>>>,
}

struct ActiveJob {
    id: String,
    cancel_requested: bool,
    pids: Vec<u32>,
}

impl ActiveJobState {
    fn is_busy(&self) -> Result<bool, String> {
        self.inner
            .lock()
            .map(|job| job.is_some())
            .map_err(|_| "Unable to lock active job state.".to_string())
    }

    fn start(&self, id: String) -> Result<(), String> {
        let mut active = self
            .inner
            .lock()
            .map_err(|_| "Unable to lock active job state.".to_string())?;
        if active.is_some() {
            return Err("Another job is already running.".to_string());
        }
        *active = Some(ActiveJob {
            id,
            cancel_requested: false,
            pids: Vec::new(),
        });
        Ok(())
    }

    fn add_pid(&self, id: &str, pid: u32) -> Result<(), String> {
        let mut active = self
            .inner
            .lock()
            .map_err(|_| "Unable to lock active job state.".to_string())?;
        let Some(job) = active.as_mut() else {
            return Ok(());
        };
        if job.id == id && !job.pids.contains(&pid) {
            job.pids.push(pid);
        }
        Ok(())
    }

    fn remove_pid(&self, id: &str, pid: u32) -> Result<(), String> {
        let mut active = self
            .inner
            .lock()
            .map_err(|_| "Unable to lock active job state.".to_string())?;
        let Some(job) = active.as_mut() else {
            return Ok(());
        };
        if job.id == id {
            job.pids.retain(|current| *current != pid);
        }
        Ok(())
    }

    fn request_cancel(&self) -> Result<Vec<u32>, String> {
        let mut active = self
            .inner
            .lock()
            .map_err(|_| "Unable to lock active job state.".to_string())?;
        let Some(job) = active.as_mut() else {
            return Err("No active job to cancel.".to_string());
        };
        job.cancel_requested = true;
        Ok(job.pids.clone())
    }

    fn is_canceled(&self, id: &str) -> bool {
        self.inner
            .lock()
            .ok()
            .and_then(|active| {
                active
                    .as_ref()
                    .filter(|job| job.id == id)
                    .map(|job| job.cancel_requested)
            })
            .unwrap_or(true)
    }

    fn finish(&self, id: &str) -> bool {
        let Ok(mut active) = self.inner.lock() else {
            return false;
        };
        let canceled = active
            .as_ref()
            .filter(|job| job.id == id)
            .map(|job| job.cancel_requested)
            .unwrap_or(false);
        if active.as_ref().is_some_and(|job| job.id == id) {
            *active = None;
        }
        canceled
    }

    fn active_job_id(&self) -> Result<Option<String>, String> {
        self.inner
            .lock()
            .map(|job| job.as_ref().map(|job| job.id.clone()))
            .map_err(|_| "Unable to lock active job state.".to_string())
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct AppConfig {
    ffmpeg_path: String,
    output_dir: String,
    source_paths: Vec<String>,
    quality: String,
    output_resolution: String,
    include_subfolders: bool,
    overwrite: bool,
    parallel_jobs: u8,
    trim_start_seconds: f64,
    trim_end_seconds: f64,
    mp4_codec: String,
    show_more_formats: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStatus {
    ffmpeg_found: bool,
    ffmpeg_path: Option<String>,
    ffprobe_path: Option<String>,
    app_data_dir: String,
    config_path: String,
    version: String,
    install_supported: bool,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct VideoItem {
    path: String,
    name: String,
    base_name: String,
    extension: String,
    size_bytes: u64,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ConvertOptions {
    output_dir: String,
    quality: String,
    output_resolution: String,
    include_subfolders: bool,
    overwrite: bool,
    parallel_jobs: u8,
    trim_start_seconds: f64,
    trim_end_seconds: f64,
    mp4_codec: String,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum OutputKind {
    Mp4,
    WebmVp9,
    Ogv,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentConvertRequest {
    paths: Option<Vec<String>>,
    options: Option<serde_json::Value>,
    kind: Option<OutputKind>,
    overwrite: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentServerStatus {
    enabled: bool,
    port: u16,
    url: String,
    openapi_url: String,
    busy: bool,
    active_job_id: Option<String>,
    message: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct AgentApiRegistryEntry {
    app_id: String,
    app_name: String,
    default_port: u16,
    bind_address: String,
    port: u16,
    enabled: bool,
    url: String,
    openapi_url: String,
    busy: bool,
    active_job_id: Option<String>,
    last_seen: Option<String>,
    note: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentApiRegistry {
    updated_at: String,
    apps: Vec<AgentApiRegistryEntry>,
}

#[derive(Clone, Default)]
struct AgentServerState {
    inner: Arc<Mutex<AgentServerControl>>,
}

#[derive(Default)]
struct AgentServerControl {
    enabled: bool,
    port: u16,
    stop: Option<Arc<AtomicBool>>,
}

impl AgentServerControl {
    fn port(&self) -> u16 {
        if self.port == 0 {
            read_registered_agent_api_port().unwrap_or(DEFAULT_AGENT_API_PORT)
        } else {
            self.port
        }
    }
}

fn default_convert_options() -> ConvertOptions {
    ConvertOptions {
        output_dir: DEFAULT_OUTPUT_DIR.to_string(),
        quality: "Balanced".to_string(),
        output_resolution: "(native)".to_string(),
        include_subfolders: false,
        overwrite: true,
        parallel_jobs: 2,
        trim_start_seconds: 0.0,
        trim_end_seconds: 0.0,
        mp4_codec: "H264".to_string(),
    }
}

struct RunningTask {
    child: Child,
    input_path: PathBuf,
    output_path: PathBuf,
    file_name: String,
    index: usize,
    duration_seconds: f64,
    progress_path: PathBuf,
    error_path: PathBuf,
    file_percent: u32,
}

struct SimpleResult {
    exit_code: i32,
    error_text: String,
    canceled: bool,
}

fn default_config() -> AppConfig {
    AppConfig {
        ffmpeg_path: String::new(),
        output_dir: DEFAULT_OUTPUT_DIR.to_string(),
        source_paths: Vec::new(),
        quality: "Balanced".to_string(),
        output_resolution: "(native)".to_string(),
        include_subfolders: false,
        overwrite: true,
        parallel_jobs: 2,
        trim_start_seconds: 0.0,
        trim_end_seconds: 0.0,
        mp4_codec: "H264".to_string(),
        show_more_formats: true,
    }
}

fn hide_command_window(command: &mut Command) {
    #[cfg(target_os = "windows")]
    {
        command.creation_flags(CREATE_NO_WINDOW);
    }
}

fn configure_child_command(command: &mut Command) {
    hide_command_window(command);
    #[cfg(unix)]
    {
        command.process_group(0);
    }
}

fn app_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|error| format!("Unable to resolve app data folder: {error}"))?;
    fs::create_dir_all(&dir)
        .map_err(|error| format!("Unable to create app data folder: {error}"))?;
    Ok(dir)
}

fn config_path(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app_data_dir(app)?.join("config.json"))
}

fn legacy_config_path() -> Option<PathBuf> {
    std::env::current_dir()
        .ok()
        .map(|dir| dir.join("config.json"))
}

fn ps_quote(value: &Path) -> String {
    value.display().to_string().replace('\'', "''")
}

fn normalize_quality(value: &str) -> String {
    match value {
        "High" | "Smaller" => value.to_string(),
        _ => "Balanced".to_string(),
    }
}

fn normalize_mp4_codec(value: &str) -> String {
    let lower = value.to_ascii_lowercase();
    if lower.contains("265") || lower.contains("hevc") || lower.contains("h.265") {
        "H265".to_string()
    } else {
        "H264".to_string()
    }
}

fn normalize_output_resolution(value: &str) -> String {
    let lower = value.trim().to_ascii_lowercase();
    if lower.contains("native") {
        "(native)".to_string()
    } else if lower.contains("1920") || lower.contains("1080") {
        "1920x1080".to_string()
    } else if lower.contains("1444") {
        "1444p".to_string()
    } else if lower.contains("2160") || lower.contains("4k") || lower.contains("uhd") {
        "2160p".to_string()
    } else {
        "(native)".to_string()
    }
}

fn value_string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToOwned::to_owned)
}

fn value_bool(value: &Value, key: &str) -> Option<bool> {
    value.get(key).and_then(Value::as_bool)
}

fn value_u8(value: &Value, key: &str) -> Option<u8> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .map(|number| number.clamp(1, 16) as u8)
}

fn value_f64(value: &Value, key: &str) -> Option<f64> {
    value
        .get(key)
        .and_then(Value::as_f64)
        .map(|number| number.clamp(0.0, 10.0))
}

fn read_config_from_value(value: &Value) -> AppConfig {
    let mut config = default_config();
    if let Some(ffmpeg_path) = value_string(value, "ffmpegPath") {
        config.ffmpeg_path = ffmpeg_path;
    }
    if let Some(output_dir) = value_string(value, "outputDir") {
        config.output_dir = output_dir;
    }
    if let Some(paths) = value.get("sourcePaths").and_then(Value::as_array) {
        config.source_paths = paths
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|path| !path.is_empty())
            .map(ToOwned::to_owned)
            .collect();
    } else if let Some(source_path) = value_string(value, "sourcePath") {
        config.source_paths = vec![source_path];
    }
    if let Some(quality) = value_string(value, "quality") {
        config.quality = normalize_quality(&quality);
    }
    if let Some(output_resolution) = value_string(value, "outputResolution") {
        config.output_resolution = normalize_output_resolution(&output_resolution);
    } else if value_bool(value, "downscale1080").unwrap_or(false) {
        config.output_resolution = "1920x1080".to_string();
    }
    if let Some(include_subfolders) = value_bool(value, "includeSubfolders") {
        config.include_subfolders = include_subfolders;
    }
    if let Some(overwrite) = value_bool(value, "overwrite") {
        config.overwrite = overwrite;
    }
    if let Some(parallel_jobs) = value_u8(value, "parallelJobs") {
        config.parallel_jobs = parallel_jobs;
    }
    if let Some(trim_start_seconds) = value_f64(value, "trimStartSeconds") {
        config.trim_start_seconds = trim_start_seconds;
    }
    if let Some(trim_end_seconds) =
        value_f64(value, "trimEndSeconds").or_else(|| value_f64(value, "trimSeconds"))
    {
        config.trim_end_seconds = trim_end_seconds;
    }
    if let Some(mp4_codec) = value_string(value, "mp4Codec") {
        config.mp4_codec = normalize_mp4_codec(&mp4_codec);
    }
    if let Some(show_more_formats) = value_bool(value, "showMoreFormats") {
        config.show_more_formats = show_more_formats;
    }
    config
}

fn load_config_inner(app: &AppHandle) -> AppConfig {
    let paths = [
        config_path(app).ok(),
        legacy_config_path().filter(|path| {
            config_path(app)
                .ok()
                .is_none_or(|app_path| app_path != *path)
        }),
    ];

    for path in paths.into_iter().flatten() {
        let Ok(text) = fs::read_to_string(path) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        return read_config_from_value(&value);
    }
    default_config()
}

fn write_config(app: &AppHandle, config: &AppConfig) -> Result<PathBuf, String> {
    let path = config_path(app)?;
    let text = serde_json::to_string_pretty(config)
        .map_err(|error| format!("Unable to serialize config: {error}"))?;
    fs::write(&path, text).map_err(|error| format!("Unable to save config: {error}"))?;
    Ok(path)
}

fn command_lookup(name: &str) -> Option<PathBuf> {
    let lookup = if cfg!(target_os = "windows") {
        "where.exe"
    } else {
        "which"
    };
    let mut command = Command::new(lookup);
    command.arg(name);
    hide_command_window(&mut command);
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .find(|path| path.exists())
}

fn ffmpeg_file_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "ffmpeg.exe"
    } else {
        "ffmpeg"
    }
}

fn ffprobe_file_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "ffprobe.exe"
    } else {
        "ffprobe"
    }
}

fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
}

fn portable_ffmpeg_bin_dir() -> Option<PathBuf> {
    Some(exe_dir()?.join("ffmpeg").join("bin"))
}

fn portable_ffmpeg_path() -> Option<PathBuf> {
    Some(portable_ffmpeg_bin_dir()?.join(ffmpeg_file_name()))
}

fn app_data_ffmpeg_bin_dir(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app_data_dir(app)?.join("ffmpeg").join("bin"))
}

fn app_data_ffmpeg_path(app: &AppHandle) -> Option<PathBuf> {
    Some(app_data_ffmpeg_bin_dir(app).ok()?.join(ffmpeg_file_name()))
}

fn ffmpeg_install_ready(bin_dir: &Path) -> bool {
    bin_dir.join(ffmpeg_file_name()).is_file() && bin_dir.join(ffprobe_file_name()).is_file()
}

fn find_named_file(root: &Path, name: &str, max_depth: usize) -> Option<PathBuf> {
    if max_depth == 0 || !root.is_dir() {
        return None;
    }
    let entries = fs::read_dir(root).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file()
            && path
                .file_name()
                .and_then(|file_name| file_name.to_str())
                .is_some_and(|file_name| file_name.eq_ignore_ascii_case(name))
        {
            return Some(path);
        }
        if path.is_dir() {
            if let Some(found) = find_named_file(&path, name, max_depth - 1) {
                return Some(found);
            }
        }
    }
    None
}

fn ffmpeg_candidates(app: &AppHandle, config: &AppConfig) -> Vec<PathBuf> {
    let exe_name = ffmpeg_file_name();
    let current_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let exe_dir = exe_dir().unwrap_or_else(|| current_dir.clone());
    let mut candidates = Vec::new();
    if !config.ffmpeg_path.trim().is_empty() {
        candidates.push(PathBuf::from(config.ffmpeg_path.trim()));
    }
    if let Some(installed) = portable_ffmpeg_path() {
        candidates.push(installed);
    }
    if let Some(installed) = app_data_ffmpeg_path(app) {
        candidates.push(installed);
    }
    candidates.push(current_dir.join("ffmpeg").join("bin").join(exe_name));
    candidates.push(current_dir.join(exe_name));
    candidates.push(exe_dir.join("ffmpeg").join("bin").join(exe_name));
    candidates.push(exe_dir.join(exe_name));
    if cfg!(target_os = "windows") {
        candidates.push(PathBuf::from(r"D:\Tools\ffmpeg\bin\ffmpeg.exe"));
        candidates.push(PathBuf::from(r"D:\Tools\ffmpeg.exe"));
        if let Some(found) = find_named_file(Path::new(r"D:\Tools"), "ffmpeg.exe", 4) {
            candidates.push(found);
        }
    }
    candidates
}

fn find_ffmpeg(app: &AppHandle, config: &AppConfig) -> Option<PathBuf> {
    for candidate in ffmpeg_candidates(app, config) {
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    command_lookup("ffmpeg")
}

fn find_ffprobe(ffmpeg_path: Option<&Path>) -> Option<PathBuf> {
    let exe_name = ffprobe_file_name();
    if let Some(ffmpeg_path) = ffmpeg_path {
        if let Some(parent) = ffmpeg_path.parent() {
            let sibling = parent.join(exe_name);
            if sibling.is_file() {
                return Some(sibling);
            }
        }
    }
    command_lookup("ffprobe")
}

fn is_video_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            VIDEO_EXTENSIONS
                .iter()
                .any(|candidate| candidate.eq_ignore_ascii_case(extension))
        })
        .unwrap_or(false)
}

fn video_item(path: &Path) -> Option<VideoItem> {
    if !path.is_file() || !is_video_file(path) {
        return None;
    }
    let metadata = fs::metadata(path).ok();
    let name = path.file_name()?.to_string_lossy().to_string();
    let base_name = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| name.clone());
    let extension = path
        .extension()
        .map(|extension| extension.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    Some(VideoItem {
        path: path.display().to_string(),
        name,
        base_name,
        extension,
        size_bytes: metadata.map(|metadata| metadata.len()).unwrap_or(0),
    })
}

fn collect_videos(path: &Path, recursive: bool, output: &mut Vec<VideoItem>) {
    if let Some(item) = video_item(path) {
        output.push(item);
        return;
    }
    if !path.is_dir() {
        return;
    }
    let Ok(entries) = fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let entry_path = entry.path();
        if let Some(item) = video_item(&entry_path) {
            output.push(item);
        } else if recursive && entry_path.is_dir() {
            collect_videos(&entry_path, recursive, output);
        }
    }
}

fn sorted_unique_videos(paths: Vec<String>, recursive: bool) -> Vec<VideoItem> {
    let mut videos = Vec::new();
    for path in paths {
        collect_videos(Path::new(&path), recursive, &mut videos);
    }
    videos.sort_by(|left, right| {
        left.base_name
            .to_ascii_lowercase()
            .cmp(&right.base_name.to_ascii_lowercase())
            .then(
                left.name
                    .to_ascii_lowercase()
                    .cmp(&right.name.to_ascii_lowercase()),
            )
            .then(
                left.path
                    .to_ascii_lowercase()
                    .cmp(&right.path.to_ascii_lowercase()),
            )
    });
    videos.dedup_by(|left, right| left.path.eq_ignore_ascii_case(&right.path));
    videos
}

fn emit_event(app: &AppHandle, value: Value) {
    let _ = app.emit("converter-event", value);
}

fn emit_log(app: &AppHandle, message: impl Into<String>) {
    emit_event(
        app,
        serde_json::json!({
            "type": "log",
            "message": message.into()
        }),
    );
}

fn emit_progress(app: &AppHandle, percent: u32, message: impl Into<String>) {
    emit_event(
        app,
        serde_json::json!({
            "type": "progress",
            "percent": percent.min(100),
            "message": message.into()
        }),
    );
}

fn temp_path(prefix: &str, extension: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "{prefix}-{}.{}",
        Uuid::new_v4().simple(),
        extension.trim_start_matches('.')
    ))
}

fn get_video_duration_seconds(ffprobe_path: Option<&Path>, input_path: &Path) -> f64 {
    let Some(ffprobe_path) = ffprobe_path else {
        return 0.0;
    };
    let mut command = Command::new(ffprobe_path);
    command.args([
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
    ]);
    command.arg(input_path);
    hide_command_window(&mut command);
    let Ok(output) = command.output() else {
        return 0.0;
    };
    if !output.status.success() {
        return 0.0;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .and_then(|line| line.trim().parse::<f64>().ok())
        .filter(|duration| duration.is_finite())
        .unwrap_or(0.0)
}

fn get_effective_target_duration_seconds(
    source_duration_seconds: f64,
    trim_start_seconds: f64,
    trim_end_seconds: f64,
) -> f64 {
    if trim_start_seconds > 0.0 || trim_end_seconds > 0.0 {
        if source_duration_seconds > 0.0 {
            (source_duration_seconds - trim_start_seconds - trim_end_seconds).max(0.0)
        } else {
            0.0
        }
    } else {
        source_duration_seconds
    }
}

fn parse_ffmpeg_progress_seconds(progress_path: &Path) -> f64 {
    let Ok(text) = fs::read_to_string(progress_path) else {
        return 0.0;
    };
    for line in text.lines().rev() {
        if let Some(value) = line.strip_prefix("out_time_us=") {
            if let Ok(micros) = value.trim().parse::<f64>() {
                return micros / 1_000_000.0;
            }
        }
        if let Some(value) = line.strip_prefix("out_time=") {
            return parse_timecode_seconds(value.trim());
        }
    }
    0.0
}

fn parse_timecode_seconds(value: &str) -> f64 {
    let parts: Vec<_> = value.split(':').collect();
    if parts.len() != 3 {
        return 0.0;
    }
    let hours = parts[0].parse::<f64>().unwrap_or(0.0);
    let minutes = parts[1].parse::<f64>().unwrap_or(0.0);
    let seconds = parts[2].parse::<f64>().unwrap_or(0.0);
    hours * 3600.0 + minutes * 60.0 + seconds
}

fn scale_filter(output_resolution: &str) -> Option<&'static str> {
    match normalize_output_resolution(output_resolution).as_str() {
        "1920x1080" => Some(
            "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p",
        ),
        "1444p" => Some(
            "scale=2568:1444:force_original_aspect_ratio=decrease,pad=2568:1444:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p",
        ),
        "2160p" => Some(
            "scale=3840:2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p",
        ),
        _ => None,
    }
}

fn output_extension(kind: OutputKind) -> &'static str {
    match kind {
        OutputKind::Mp4 => "mp4",
        OutputKind::WebmVp9 => "webm",
        OutputKind::Ogv => "ogv",
    }
}

fn action_label(kind: OutputKind) -> &'static str {
    match kind {
        OutputKind::Mp4 => "Exporting MP4",
        OutputKind::WebmVp9 => "Converting WebM VP9",
        OutputKind::Ogv => "Converting OGV",
    }
}

fn video_output_path(input: &Path, options: &ConvertOptions, kind: OutputKind) -> PathBuf {
    let output_dir = if options.output_dir.trim().is_empty() {
        input
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."))
    } else {
        PathBuf::from(options.output_dir.trim())
    };
    let base_name = input
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| "cutscene".to_string());
    let mut output_path = output_dir.join(format!("{base_name}.{}", output_extension(kind)));
    if kind == OutputKind::Mp4 {
        if input
            .canonicalize()
            .ok()
            .zip(output_path.canonicalize().ok())
            .is_some_and(|(left, right)| left == right)
        {
            output_path = output_dir.join(format!("{base_name}_export.mp4"));
        }
    }
    output_path
}

fn ffmpeg_args(
    input_path: &Path,
    output_path: &Path,
    options: &ConvertOptions,
    kind: OutputKind,
    progress_path: &Path,
    target_duration_seconds: f64,
) -> Vec<String> {
    let mut args = vec![
        "-hide_banner".to_string(),
        "-nostats".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
        "-progress".to_string(),
        progress_path.display().to_string(),
        if options.overwrite { "-y" } else { "-n" }.to_string(),
        "-i".to_string(),
        input_path.display().to_string(),
    ];

    if options.trim_start_seconds > 0.0 {
        args.extend([
            "-ss".to_string(),
            format!("{:.3}", options.trim_start_seconds),
        ]);
    }
    if target_duration_seconds > 0.0 {
        args.extend(["-t".to_string(), format!("{target_duration_seconds:.3}")]);
    }

    args.extend([
        "-map".to_string(),
        "0:v:0".to_string(),
        "-map".to_string(),
        "0:a?".to_string(),
    ]);

    if let Some(filter) = scale_filter(&options.output_resolution) {
        args.extend(["-vf".to_string(), filter.to_string()]);
    } else if kind == OutputKind::Mp4 {
        args.extend(["-pix_fmt".to_string(), "yuv420p".to_string()]);
    }

    match kind {
        OutputKind::Mp4 => {
            let (crf, audio_bitrate) = match normalize_quality(&options.quality).as_str() {
                "High" => (18, "160k"),
                "Smaller" => (24, "96k"),
                _ => (20, "128k"),
            };
            if normalize_mp4_codec(&options.mp4_codec) == "H265" {
                args.extend([
                    "-c:v".to_string(),
                    "libx265".to_string(),
                    "-preset".to_string(),
                    "fast".to_string(),
                    "-crf".to_string(),
                    (crf + 4).min(30).to_string(),
                    "-tag:v".to_string(),
                    "hvc1".to_string(),
                ]);
            } else {
                args.extend([
                    "-c:v".to_string(),
                    "libx264".to_string(),
                    "-preset".to_string(),
                    "veryfast".to_string(),
                    "-crf".to_string(),
                    crf.to_string(),
                ]);
            }
            args.extend([
                "-c:a".to_string(),
                "aac".to_string(),
                "-b:a".to_string(),
                audio_bitrate.to_string(),
                "-movflags".to_string(),
                "+faststart".to_string(),
                output_path.display().to_string(),
            ]);
        }
        OutputKind::Ogv => {
            let quality = match normalize_quality(&options.quality).as_str() {
                "High" => "7",
                "Smaller" => "5",
                _ => "6",
            };
            args.extend([
                "-c:v".to_string(),
                "libtheora".to_string(),
                "-q:v".to_string(),
                quality.to_string(),
                "-c:a".to_string(),
                "libvorbis".to_string(),
                "-q:a".to_string(),
                quality.to_string(),
                output_path.display().to_string(),
            ]);
        }
        OutputKind::WebmVp9 => {
            let (crf, cpu_used, audio_bitrate) = match normalize_quality(&options.quality).as_str()
            {
                "High" => ("28", "3", "128k"),
                "Smaller" => ("36", "5", "80k"),
                _ => ("32", "4", "96k"),
            };
            args.extend([
                "-c:v".to_string(),
                "libvpx-vp9".to_string(),
                "-b:v".to_string(),
                "0".to_string(),
                "-crf".to_string(),
                crf.to_string(),
                "-deadline".to_string(),
                "good".to_string(),
                "-cpu-used".to_string(),
                cpu_used.to_string(),
                "-row-mt".to_string(),
                "1".to_string(),
                "-tile-columns".to_string(),
                "2".to_string(),
                "-c:a".to_string(),
                "libopus".to_string(),
                "-b:a".to_string(),
                audio_bitrate.to_string(),
                output_path.display().to_string(),
            ]);
        }
    }
    args
}

fn test_completed_output_looks_valid(
    output_path: &Path,
    ffprobe_path: Option<&Path>,
    expected_duration_seconds: f64,
) -> bool {
    let Ok(metadata) = fs::metadata(output_path) else {
        return false;
    };
    if metadata.len() <= 4096 {
        return false;
    }
    let output_duration = get_video_duration_seconds(ffprobe_path, output_path);
    if output_duration <= 0.0 {
        return false;
    }
    if expected_duration_seconds <= 0.0 {
        return true;
    }
    output_duration >= (expected_duration_seconds - 1.0).max(0.25)
}

fn test_combined_output_looks_valid(
    output_path: &Path,
    ffprobe_path: Option<&Path>,
    expected_duration_seconds: f64,
) -> bool {
    if !test_completed_output_looks_valid(output_path, ffprobe_path, 0.0) {
        return false;
    }
    if expected_duration_seconds <= 0.0 {
        return true;
    }
    let output_duration = get_video_duration_seconds(ffprobe_path, output_path);
    output_duration >= (expected_duration_seconds * 0.85).max(0.25)
}

fn read_last_error_lines(path: &Path, max_lines: usize) -> String {
    let Ok(text) = fs::read_to_string(path) else {
        return String::new();
    };
    let lines: Vec<_> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    let start = lines.len().saturating_sub(max_lines);
    lines[start..].join("\n")
}

fn remove_partial_output(app: &AppHandle, output_path: &Path) {
    if output_path.is_file() && fs::remove_file(output_path).is_ok() {
        emit_log(
            app,
            format!("Removed canceled partial output: {}", output_path.display()),
        );
    }
}

fn kill_process_tree(pid: u32) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("taskkill");
        command.args(["/PID", &pid.to_string(), "/T", "/F"]);
        command
    };

    #[cfg(not(target_os = "windows"))]
    let mut command = {
        let mut command = Command::new("kill");
        command.args(["-TERM", &format!("-{pid}")]);
        command
    };

    hide_command_window(&mut command);
    match command.output() {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => {
            #[cfg(not(target_os = "windows"))]
            {
                if Command::new("kill")
                    .args(["-TERM", &pid.to_string()])
                    .output()
                    .is_ok_and(|output| output.status.success())
                {
                    return Ok(());
                }
            }
            Err(format!(
                "Unable to cancel process {pid}: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ))
        }
        Err(error) => Err(format!("Unable to cancel process {pid}: {error}")),
    }
}

fn spawn_ffmpeg(ffmpeg_path: &Path, args: &[String], error_path: &Path) -> Result<Child, String> {
    let err_file = File::create(error_path)
        .map_err(|error| format!("Unable to create FFmpeg error log: {error}"))?;
    let mut command = Command::new(ffmpeg_path);
    configure_child_command(&mut command);
    command
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::from(err_file));
    command
        .spawn()
        .map_err(|error| format!("Unable to start FFmpeg: {error}"))
}

fn run_conversion_job(
    app: AppHandle,
    active_jobs: ActiveJobState,
    job_id: String,
    videos: Vec<VideoItem>,
    options: ConvertOptions,
    kind: OutputKind,
    ffmpeg_path: PathBuf,
    ffprobe_path: Option<PathBuf>,
) {
    let total_files = videos.len().max(1);
    let parallel_limit = usize::from(options.parallel_jobs.clamp(1, 16)).min(total_files);
    let mut pending: VecDeque<_> = videos.into_iter().enumerate().collect();
    let mut running: Vec<RunningTask> = Vec::new();
    let mut success = 0usize;
    let mut failed = 0usize;
    let mut completed = 0usize;
    let action = action_label(kind);

    emit_log(
        &app,
        format!(
            "Using up to {parallel_limit} parallel {} job(s).",
            action.to_ascii_lowercase()
        ),
    );

    while completed < total_files {
        let canceled = active_jobs.is_canceled(&job_id);
        if canceled {
            pending.clear();
            for task in &mut running {
                let pid = task.child.id();
                let _ = kill_process_tree(pid);
                let _ = task.child.kill();
            }
        }

        while !active_jobs.is_canceled(&job_id)
            && running.len() < parallel_limit
            && !pending.is_empty()
        {
            let Some((index, video)) = pending.pop_front() else {
                break;
            };
            let input_path = PathBuf::from(&video.path);
            let output_path = video_output_path(&input_path, &options, kind);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "fileStart",
                    "path": video.path,
                    "outputPath": output_path.display().to_string(),
                    "index": index + 1,
                    "total": total_files,
                    "message": format!("{action}: {}", video.name)
                }),
            );

            if output_path.exists() && !options.overwrite {
                completed += 1;
                success += 1;
                emit_event(
                    &app,
                    serde_json::json!({
                        "type": "fileDone",
                        "path": input_path.display().to_string(),
                        "outputPath": output_path.display().to_string(),
                        "message": "Skipped existing output"
                    }),
                );
                continue;
            }

            if let Some(output_dir) = output_path.parent() {
                if let Err(error) = fs::create_dir_all(output_dir) {
                    completed += 1;
                    failed += 1;
                    emit_event(
                        &app,
                        serde_json::json!({
                            "type": "fileError",
                            "path": input_path.display().to_string(),
                            "message": format!("Unable to create output folder: {error}")
                        }),
                    );
                    continue;
                }
            }

            let source_duration_seconds =
                get_video_duration_seconds(ffprobe_path.as_deref(), &input_path);
            if (options.trim_start_seconds > 0.0 || options.trim_end_seconds > 0.0)
                && source_duration_seconds <= 0.0
            {
                completed += 1;
                failed += 1;
                emit_event(
                    &app,
                    serde_json::json!({
                        "type": "fileError",
                        "path": input_path.display().to_string(),
                        "message": "Could not determine duration, so trim settings could not be applied."
                    }),
                );
                continue;
            }

            let target_duration_seconds = get_effective_target_duration_seconds(
                source_duration_seconds,
                options.trim_start_seconds,
                options.trim_end_seconds,
            );
            if (options.trim_start_seconds > 0.0 || options.trim_end_seconds > 0.0)
                && target_duration_seconds <= 0.0
            {
                completed += 1;
                failed += 1;
                emit_event(
                    &app,
                    serde_json::json!({
                        "type": "fileError",
                        "path": input_path.display().to_string(),
                        "message": "Trim settings are too large for this file."
                    }),
                );
                continue;
            }

            let progress_path = temp_path("cc-progress", "txt");
            let error_path = temp_path("cc-error", "txt");
            let args = ffmpeg_args(
                &input_path,
                &output_path,
                &options,
                kind,
                &progress_path,
                target_duration_seconds,
            );

            match spawn_ffmpeg(&ffmpeg_path, &args, &error_path) {
                Ok(child) => {
                    let pid = child.id();
                    let _ = active_jobs.add_pid(&job_id, pid);
                    emit_log(&app, format!("{action}: {}", input_path.display()));
                    emit_log(&app, format!("Output: {}", output_path.display()));
                    running.push(RunningTask {
                        child,
                        input_path,
                        output_path,
                        file_name: video.name,
                        index: index + 1,
                        duration_seconds: target_duration_seconds,
                        progress_path,
                        error_path,
                        file_percent: 0,
                    });
                }
                Err(error) => {
                    completed += 1;
                    failed += 1;
                    let _ = fs::remove_file(progress_path);
                    let _ = fs::remove_file(error_path);
                    emit_event(
                        &app,
                        serde_json::json!({
                            "type": "fileError",
                            "path": input_path.display().to_string(),
                            "message": error
                        }),
                    );
                }
            }
        }

        let mut still_running = Vec::new();
        for mut task in running {
            let pid = task.child.id();
            if active_jobs.is_canceled(&job_id) {
                let _ = kill_process_tree(pid);
                let _ = task.child.kill();
            }

            match task.child.try_wait() {
                Ok(Some(status)) => {
                    let _ = active_jobs.remove_pid(&job_id, pid);
                    completed += 1;
                    let canceled = active_jobs.is_canceled(&job_id);
                    if canceled {
                        remove_partial_output(&app, &task.output_path);
                        emit_event(
                            &app,
                            serde_json::json!({
                                "type": "fileCanceled",
                                "path": task.input_path.display().to_string(),
                                "outputPath": task.output_path.display().to_string(),
                                "message": "Canceled"
                            }),
                        );
                    } else if !status.success()
                        && !test_completed_output_looks_valid(
                            &task.output_path,
                            ffprobe_path.as_deref(),
                            task.duration_seconds,
                        )
                    {
                        failed += 1;
                        let detail = read_last_error_lines(&task.error_path, 8);
                        emit_event(
                            &app,
                            serde_json::json!({
                                "type": "fileError",
                                "path": task.input_path.display().to_string(),
                                "message": if detail.is_empty() {
                                    format!("FFmpeg failed with exit code {}.", status.code().unwrap_or(-1))
                                } else {
                                    detail
                                }
                            }),
                        );
                    } else {
                        success += 1;
                        emit_event(
                            &app,
                            serde_json::json!({
                                "type": "fileDone",
                                "path": task.input_path.display().to_string(),
                                "outputPath": task.output_path.display().to_string(),
                                "message": "Done"
                            }),
                        );
                    }
                    let _ = fs::remove_file(task.progress_path);
                    let _ = fs::remove_file(task.error_path);
                }
                Ok(None) => {
                    if task.duration_seconds > 0.0 {
                        let elapsed = parse_ffmpeg_progress_seconds(&task.progress_path);
                        task.file_percent = ((elapsed / task.duration_seconds) * 100.0)
                            .floor()
                            .clamp(0.0, 100.0) as u32;
                    }
                    emit_event(
                        &app,
                        serde_json::json!({
                            "type": "fileProgress",
                            "path": task.input_path.display().to_string(),
                            "percent": task.file_percent,
                            "message": format!("{action} {} of {}: {} - {}%", task.index, total_files, task.file_name, task.file_percent)
                        }),
                    );
                    still_running.push(task);
                }
                Err(error) => {
                    let _ = active_jobs.remove_pid(&job_id, pid);
                    completed += 1;
                    failed += 1;
                    emit_event(
                        &app,
                        serde_json::json!({
                            "type": "fileError",
                            "path": task.input_path.display().to_string(),
                            "message": format!("Unable to read FFmpeg status: {error}")
                        }),
                    );
                    let _ = fs::remove_file(task.progress_path);
                    let _ = fs::remove_file(task.error_path);
                }
            }
        }
        running = still_running;

        let running_fraction = running
            .iter()
            .map(|task| f64::from(task.file_percent.min(100)) / 100.0)
            .sum::<f64>();
        let overall_percent = (((completed as f64 + running_fraction) / total_files as f64) * 100.0)
            .floor()
            .clamp(0.0, 100.0) as u32;
        if active_jobs.is_canceled(&job_id) {
            emit_progress(
                &app,
                overall_percent,
                format!("Canceling: {completed} finished, {} active", running.len()),
            );
        } else {
            emit_progress(
                &app,
                overall_percent,
                format!(
                    "Batch {action}: {completed} of {total_files} finished, {} active",
                    running.len()
                ),
            );
        }

        if active_jobs.is_canceled(&job_id) && running.is_empty() {
            break;
        }
        if completed < total_files {
            thread::sleep(Duration::from_millis(250));
        }
    }

    let canceled = active_jobs.finish(&job_id);
    if canceled {
        emit_event(
            &app,
            serde_json::json!({
                "type": "canceled",
                "message": format!("Canceled. Success: {success}. Failed: {failed}.")
            }),
        );
    } else if failed > 0 {
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": format!("Finished with errors. Success: {success}. Failed: {failed}.")
            }),
        );
    } else {
        emit_event(
            &app,
            serde_json::json!({
                "type": "done",
                "message": format!("Finished. Success: {success}. Failed: {failed}.")
            }),
        );
    }
}

fn test_video_has_audio(ffprobe_path: Option<&Path>, input_path: &Path) -> bool {
    let Some(ffprobe_path) = ffprobe_path else {
        return false;
    };
    let mut command = Command::new(ffprobe_path);
    command.args([
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_type",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
    ]);
    command.arg(input_path);
    hide_command_window(&mut command);
    command.output().is_ok_and(|output| {
        output.status.success() && !String::from_utf8_lossy(&output.stdout).trim().is_empty()
    })
}

fn concat_list_text(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|path| {
            let escaped = path
                .display()
                .to_string()
                .replace('\\', "/")
                .replace('\'', "'\\''");
            format!("file '{escaped}'")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn run_ffmpeg_simple(
    app: &AppHandle,
    active_jobs: &ActiveJobState,
    job_id: &str,
    ffmpeg_path: &Path,
    args: &[String],
    progress_message: &str,
) -> SimpleResult {
    let error_path = temp_path("cc-simple-error", "txt");
    let mut child = match spawn_ffmpeg(ffmpeg_path, args, &error_path) {
        Ok(child) => child,
        Err(error) => {
            return SimpleResult {
                exit_code: 1,
                error_text: error,
                canceled: active_jobs.is_canceled(job_id),
            };
        }
    };
    let pid = child.id();
    let _ = active_jobs.add_pid(job_id, pid);
    loop {
        if active_jobs.is_canceled(job_id) {
            let _ = kill_process_tree(pid);
            let _ = child.kill();
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let _ = active_jobs.remove_pid(job_id, pid);
                let error_text = read_last_error_lines(&error_path, 12);
                let _ = fs::remove_file(error_path);
                return SimpleResult {
                    exit_code: status.code().unwrap_or(-1),
                    error_text,
                    canceled: active_jobs.is_canceled(job_id),
                };
            }
            Ok(None) => {
                emit_progress(app, 50, progress_message.to_string());
                thread::sleep(Duration::from_millis(250));
            }
            Err(error) => {
                let _ = active_jobs.remove_pid(job_id, pid);
                let _ = fs::remove_file(error_path);
                return SimpleResult {
                    exit_code: 1,
                    error_text: format!("Unable to read FFmpeg status: {error}"),
                    canceled: active_jobs.is_canceled(job_id),
                };
            }
        }
    }
}

fn combined_output_path(videos: &[VideoItem]) -> PathBuf {
    let first = PathBuf::from(&videos[0].path);
    let parent = first.parent().unwrap_or_else(|| Path::new("."));
    let base_name = first
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| "cutscene".to_string());
    let extension = first
        .extension()
        .map(|extension| extension.to_string_lossy().to_string())
        .unwrap_or_else(|| "mp4".to_string());
    parent.join(format!("{base_name}_combined.{extension}"))
}

fn combine_normalize_args(
    video_path: &Path,
    output_path: &Path,
    target_extension: &str,
    ffprobe_path: Option<&Path>,
) -> Vec<String> {
    let duration = get_video_duration_seconds(ffprobe_path, video_path).max(0.1);
    let has_audio = test_video_has_audio(ffprobe_path, video_path);
    let mut args = vec![
        "-hide_banner".to_string(),
        "-nostats".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
        "-y".to_string(),
        "-i".to_string(),
        video_path.display().to_string(),
    ];
    if !has_audio {
        args.extend([
            "-f".to_string(),
            "lavfi".to_string(),
            "-t".to_string(),
            format!("{duration:.3}"),
            "-i".to_string(),
            "anullsrc=channel_layout=stereo:sample_rate=48000".to_string(),
        ]);
    }
    args.extend([
        "-map".to_string(),
        "0:v:0".to_string(),
        "-map".to_string(),
        if has_audio { "0:a:0" } else { "1:a:0" }.to_string(),
        "-vf".to_string(),
        "fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p".to_string(),
        "-shortest".to_string(),
    ]);
    match target_extension {
        "webm" => args.extend([
            "-c:v".to_string(),
            "libvpx-vp9".to_string(),
            "-b:v".to_string(),
            "0".to_string(),
            "-crf".to_string(),
            "32".to_string(),
            "-deadline".to_string(),
            "good".to_string(),
            "-cpu-used".to_string(),
            "4".to_string(),
            "-row-mt".to_string(),
            "1".to_string(),
            "-tile-columns".to_string(),
            "2".to_string(),
            "-c:a".to_string(),
            "libopus".to_string(),
            "-b:a".to_string(),
            "96k".to_string(),
        ]),
        "ogv" => args.extend([
            "-c:v".to_string(),
            "libtheora".to_string(),
            "-q:v".to_string(),
            "6".to_string(),
            "-c:a".to_string(),
            "libvorbis".to_string(),
            "-q:a".to_string(),
            "6".to_string(),
        ]),
        _ => args.extend([
            "-c:v".to_string(),
            "libx264".to_string(),
            "-preset".to_string(),
            "veryfast".to_string(),
            "-crf".to_string(),
            "20".to_string(),
            "-c:a".to_string(),
            "aac".to_string(),
            "-b:a".to_string(),
            "128k".to_string(),
        ]),
    }
    args.push(output_path.display().to_string());
    args
}

fn move_file_replace(source: &Path, destination: &Path) -> Result<(), String> {
    if destination.exists() {
        fs::remove_file(destination)
            .map_err(|error| format!("Unable to replace existing output: {error}"))?;
    }
    match fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(_) => {
            fs::copy(source, destination)
                .map_err(|error| format!("Unable to copy combined output: {error}"))?;
            fs::remove_file(source)
                .map_err(|error| format!("Unable to remove temporary combined output: {error}"))?;
            Ok(())
        }
    }
}

fn run_combine_job(
    app: AppHandle,
    active_jobs: ActiveJobState,
    job_id: String,
    videos: Vec<VideoItem>,
    overwrite: bool,
    ffmpeg_path: PathBuf,
    ffprobe_path: Option<PathBuf>,
) {
    let output_path = combined_output_path(&videos);
    let expected_duration_seconds = videos
        .iter()
        .map(|video| get_video_duration_seconds(ffprobe_path.as_deref(), Path::new(&video.path)))
        .sum::<f64>();
    emit_log(
        &app,
        format!(
            "Combining {} video file(s) in alphabetical order.",
            videos.len()
        ),
    );
    for video in &videos {
        emit_log(&app, format!("  {}", video.name));
    }
    emit_log(&app, format!("Combined output: {}", output_path.display()));
    emit_progress(&app, 5, "Combining videos...");

    if output_path.exists() && !overwrite {
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": "Combined output already exists. Enable overwrite or rename the existing file."
            }),
        );
        return;
    }

    let list_path = temp_path("cc-concat", "txt");
    let input_paths = videos
        .iter()
        .map(|video| PathBuf::from(&video.path))
        .collect::<Vec<_>>();
    if let Err(error) = fs::write(&list_path, concat_list_text(&input_paths)) {
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": format!("Unable to write concat list: {error}")
            }),
        );
        return;
    }

    let audio_presence = input_paths
        .iter()
        .map(|path| test_video_has_audio(ffprobe_path.as_deref(), path))
        .collect::<Vec<_>>();
    let audio_layout_same = audio_presence
        .first()
        .is_some_and(|first| audio_presence.iter().all(|value| value == first));

    if audio_layout_same {
        let direct_args = vec![
            "-hide_banner".to_string(),
            "-nostats".to_string(),
            "-loglevel".to_string(),
            "error".to_string(),
            if overwrite { "-y" } else { "-n" }.to_string(),
            "-f".to_string(),
            "concat".to_string(),
            "-safe".to_string(),
            "0".to_string(),
            "-i".to_string(),
            list_path.display().to_string(),
            "-c".to_string(),
            "copy".to_string(),
            output_path.display().to_string(),
        ];
        emit_log(&app, "Trying fast combine without re-encoding.");
        let direct_result = run_ffmpeg_simple(
            &app,
            &active_jobs,
            &job_id,
            &ffmpeg_path,
            &direct_args,
            "Combining videos...",
        );
        if direct_result.canceled {
            remove_partial_output(&app, &output_path);
            let _ = fs::remove_file(&list_path);
            active_jobs.finish(&job_id);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "canceled",
                    "message": "Combine canceled."
                }),
            );
            return;
        }
        if direct_result.exit_code == 0
            && test_combined_output_looks_valid(
                &output_path,
                ffprobe_path.as_deref(),
                expected_duration_seconds,
            )
        {
            let _ = fs::remove_file(&list_path);
            active_jobs.finish(&job_id);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "combineDone",
                    "outputPath": output_path.display().to_string(),
                    "message": format!("Combined videos: {} file(s)", videos.len())
                }),
            );
            emit_event(
                &app,
                serde_json::json!({
                    "type": "done",
                    "message": format!("Done: {}", output_path.display())
                }),
            );
            return;
        }
        emit_log(
            &app,
            "Fast combine failed. Retrying with normalized re-encode.",
        );
        if !direct_result.error_text.is_empty() {
            emit_log(&app, direct_result.error_text);
        }
        let _ = fs::remove_file(&output_path);
    } else {
        emit_log(
            &app,
            "Video audio layouts differ; using normalized re-encode.",
        );
    }

    let temp_dir = std::env::temp_dir().join(format!("cc-combine-{}", Uuid::new_v4().simple()));
    if let Err(error) = fs::create_dir_all(&temp_dir) {
        let _ = fs::remove_file(&list_path);
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": format!("Unable to create combine temp folder: {error}")
            }),
        );
        return;
    }

    let target_extension = input_paths[0]
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("mp4")
        .to_ascii_lowercase();
    let segment_extension = if target_extension == "webm" || target_extension == "ogv" {
        target_extension.as_str()
    } else {
        "mkv"
    };
    let mut segment_paths = Vec::new();

    for (index, input_path) in input_paths.iter().enumerate() {
        if active_jobs.is_canceled(&job_id) {
            let _ = fs::remove_file(&list_path);
            let _ = fs::remove_dir_all(&temp_dir);
            active_jobs.finish(&job_id);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "canceled",
                    "message": "Combine canceled."
                }),
            );
            return;
        }
        let segment_path = temp_dir.join(format!("segment_{index:04}.{segment_extension}"));
        let percent = (((index as f64 / videos.len() as f64) * 70.0) + 10.0) as u32;
        emit_progress(
            &app,
            percent,
            format!(
                "Normalizing {} of {}: {}",
                index + 1,
                videos.len(),
                videos[index].name
            ),
        );
        let normalize_args = combine_normalize_args(
            input_path,
            &segment_path,
            &target_extension,
            ffprobe_path.as_deref(),
        );
        let normalize_result = run_ffmpeg_simple(
            &app,
            &active_jobs,
            &job_id,
            &ffmpeg_path,
            &normalize_args,
            &format!("Normalizing {} of {}", index + 1, videos.len()),
        );
        if normalize_result.canceled {
            let _ = fs::remove_file(&list_path);
            let _ = fs::remove_dir_all(&temp_dir);
            active_jobs.finish(&job_id);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "canceled",
                    "message": "Combine canceled."
                }),
            );
            return;
        }
        if normalize_result.exit_code != 0 || !segment_path.exists() {
            let _ = fs::remove_file(&list_path);
            let _ = fs::remove_dir_all(&temp_dir);
            active_jobs.finish(&job_id);
            emit_event(
                &app,
                serde_json::json!({
                    "type": "error",
                    "message": if normalize_result.error_text.is_empty() {
                        format!("Failed to normalize: {}", input_path.display())
                    } else {
                        normalize_result.error_text
                    }
                }),
            );
            return;
        }
        segment_paths.push(segment_path);
    }

    let segment_list_path = temp_dir.join("segments.txt");
    if let Err(error) = fs::write(&segment_list_path, concat_list_text(&segment_paths)) {
        let _ = fs::remove_file(&list_path);
        let _ = fs::remove_dir_all(&temp_dir);
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": format!("Unable to write normalized concat list: {error}")
            }),
        );
        return;
    }

    let temp_final_output = temp_dir.join(format!("combined.{target_extension}"));
    let mut final_args = vec![
        "-hide_banner".to_string(),
        "-nostats".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
        "-y".to_string(),
        "-f".to_string(),
        "concat".to_string(),
        "-safe".to_string(),
        "0".to_string(),
        "-i".to_string(),
        segment_list_path.display().to_string(),
        "-c".to_string(),
        "copy".to_string(),
    ];
    if matches!(target_extension.as_str(), "mp4" | "m4v" | "mov") {
        final_args.extend(["-movflags".to_string(), "+faststart".to_string()]);
    }
    final_args.push(temp_final_output.display().to_string());
    emit_progress(&app, 85, "Writing combined output...");
    let final_result = run_ffmpeg_simple(
        &app,
        &active_jobs,
        &job_id,
        &ffmpeg_path,
        &final_args,
        "Writing combined output...",
    );

    if final_result.canceled {
        remove_partial_output(&app, &output_path);
        let _ = fs::remove_file(&list_path);
        let _ = fs::remove_dir_all(&temp_dir);
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "canceled",
                "message": "Combine canceled."
            }),
        );
        return;
    }
    if final_result.exit_code != 0
        || !test_combined_output_looks_valid(
            &temp_final_output,
            ffprobe_path.as_deref(),
            expected_duration_seconds,
        )
    {
        let _ = fs::remove_file(&list_path);
        let _ = fs::remove_dir_all(&temp_dir);
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": if final_result.error_text.is_empty() {
                    "Failed to write combined output.".to_string()
                } else {
                    final_result.error_text
                }
            }),
        );
        return;
    }

    let move_result = move_file_replace(&temp_final_output, &output_path);
    let _ = fs::remove_file(&list_path);
    let _ = fs::remove_dir_all(&temp_dir);
    if let Err(error) = move_result {
        active_jobs.finish(&job_id);
        emit_event(
            &app,
            serde_json::json!({
                "type": "error",
                "message": error
            }),
        );
        return;
    }

    active_jobs.finish(&job_id);
    emit_event(
        &app,
        serde_json::json!({
            "type": "combineDone",
            "outputPath": output_path.display().to_string(),
            "message": format!("Combined videos: {} file(s)", videos.len())
        }),
    );
    emit_event(
        &app,
        serde_json::json!({
            "type": "done",
            "message": format!("Done: {}", output_path.display())
        }),
    );
}

#[tauri::command]
fn load_config(app: AppHandle) -> AppConfig {
    load_config_inner(&app)
}

#[tauri::command]
fn save_config(app: AppHandle, config: AppConfig) -> Result<String, String> {
    write_config(&app, &config).map(|path| path.display().to_string())
}

#[tauri::command]
fn check_runtime(app: AppHandle) -> Result<RuntimeStatus, String> {
    let config = load_config_inner(&app);
    let ffmpeg = find_ffmpeg(&app, &config);
    let ffprobe = find_ffprobe(ffmpeg.as_deref());
    Ok(RuntimeStatus {
        ffmpeg_found: ffmpeg.is_some(),
        ffmpeg_path: ffmpeg.map(|path| path.display().to_string()),
        ffprobe_path: ffprobe.map(|path| path.display().to_string()),
        app_data_dir: app_data_dir(&app)?.display().to_string(),
        config_path: config_path(&app)?.display().to_string(),
        version: APP_VERSION.to_string(),
        install_supported: cfg!(target_os = "windows"),
    })
}

#[tauri::command]
fn resolve_inputs(paths: Vec<String>, recursive: bool) -> Vec<VideoItem> {
    sorted_unique_videos(paths, recursive)
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    if path.trim().is_empty() {
        return Err("No path was provided.".to_string());
    }
    let requested_path = PathBuf::from(path);
    let target = if requested_path.is_dir() {
        requested_path
    } else {
        requested_path
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| "Unable to resolve containing folder.".to_string())?
    };
    if !target.exists() {
        fs::create_dir_all(&target).map_err(|error| format!("Unable to create folder: {error}"))?;
    }
    app.opener()
        .open_path(target.display().to_string(), None::<&str>)
        .map_err(|error| format!("Unable to open path: {error}"))
}

fn can_install_to_dir(dir: &Path) -> bool {
    if fs::create_dir_all(dir).is_err() {
        return false;
    }
    let test_path = dir.join(format!(".cc-write-test-{}", Uuid::new_v4().simple()));
    let writable = fs::write(&test_path, b"test").is_ok();
    if writable {
        let _ = fs::remove_file(test_path);
    }
    writable
}

fn copy_existing_ffmpeg_install(source_ffmpeg: &Path, target_bin: &Path) -> Result<bool, String> {
    if !source_ffmpeg.is_file() {
        return Ok(false);
    }
    let source_bin = source_ffmpeg
        .parent()
        .ok_or_else(|| "Unable to resolve existing FFmpeg folder.".to_string())?;
    fs::create_dir_all(target_bin)
        .map_err(|error| format!("Unable to create FFmpeg folder: {error}"))?;
    for name in ["ffmpeg.exe", "ffprobe.exe", "ffplay.exe"] {
        let source = source_bin.join(name);
        let target = target_bin.join(name);
        if source.is_file() && !target.is_file() {
            fs::copy(&source, target_bin.join(name))
                .map_err(|error| format!("Unable to copy {name}: {error}"))?;
        }
    }
    Ok(ffmpeg_install_ready(target_bin))
}

#[tauri::command]
fn install_ffmpeg(app: AppHandle) -> Result<String, String> {
    if !cfg!(target_os = "windows") {
        return Err("Automatic FFmpeg install is currently available on Windows only. Install ffmpeg and ffprobe with your system package manager.".to_string());
    }
    if let Some(portable_bin) = portable_ffmpeg_bin_dir().filter(|dir| ffmpeg_install_ready(dir)) {
        return Ok(portable_bin.join(ffmpeg_file_name()).display().to_string());
    }

    let app_data_bin = app_data_ffmpeg_bin_dir(&app)?;
    let app_data_ffmpeg = app_data_bin.join(ffmpeg_file_name());
    let target_bin = portable_ffmpeg_bin_dir()
        .filter(|dir| can_install_to_dir(dir))
        .unwrap_or_else(|| app_data_bin.clone());
    let target_ffmpeg = target_bin.join(ffmpeg_file_name());
    if ffmpeg_install_ready(&target_bin) {
        return Ok(target_ffmpeg.display().to_string());
    }

    if target_bin != app_data_bin
        && copy_existing_ffmpeg_install(&app_data_ffmpeg, &target_bin)?
        && target_ffmpeg.is_file()
    {
        return Ok(target_ffmpeg.display().to_string());
    }

    if target_bin == app_data_bin && ffmpeg_install_ready(&app_data_bin) {
        return Ok(app_data_ffmpeg.display().to_string());
    }

    fs::create_dir_all(&target_bin)
        .map_err(|error| format!("Unable to create FFmpeg folder: {error}"))?;
    let download_dir = app_data_dir(&app)?.join("ffmpeg-download");
    let zip_path = download_dir.join("ffmpeg-release-essentials.zip");
    let partial_zip_path = download_dir.join("ffmpeg-release-essentials.zip.partial");
    let extract_dir = download_dir.join("extract");
    fs::create_dir_all(&download_dir)
        .map_err(|error| format!("Unable to create FFmpeg download folder: {error}"))?;

    let script = format!(
        "$ErrorActionPreference='Stop'; \
         $zip='{zip}'; $partial='{partial}'; $extract='{extract}'; $target='{target}'; \
         function Test-Zip($path) {{ \
           if (-not (Test-Path -LiteralPath $path)) {{ return $false }}; \
           try {{ \
             Add-Type -AssemblyName System.IO.Compression.FileSystem; \
             $archive=[System.IO.Compression.ZipFile]::OpenRead($path); \
             $archive.Dispose(); \
             return $true; \
           }} catch {{ return $false }} \
         }}; \
         New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zip) | Out-Null; \
         New-Item -ItemType Directory -Force -Path $target | Out-Null; \
         if (-not (Test-Zip $zip)) {{ \
           Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue; \
           Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; \
           Invoke-WebRequest -Uri '{url}' -OutFile $partial -UseBasicParsing; \
           Move-Item -LiteralPath $partial -Destination $zip -Force; \
         }}; \
         if (Test-Path -LiteralPath $extract) {{ Remove-Item -LiteralPath $extract -Recurse -Force }}; \
         New-Item -ItemType Directory -Force -Path $extract | Out-Null; \
         Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force; \
         $ffmpeg = Get-ChildItem -Path $extract -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1; \
         if ($null -eq $ffmpeg) {{ throw 'Could not find ffmpeg.exe in the downloaded ZIP.' }}; \
         $bin = Split-Path -Parent $ffmpeg.FullName; \
         foreach ($tool in @('ffmpeg.exe','ffprobe.exe','ffplay.exe')) {{ \
           $source = Join-Path $bin $tool; \
           $destination = Join-Path $target $tool; \
           if ((Test-Path -LiteralPath $source) -and (-not (Test-Path -LiteralPath $destination))) {{ \
             Copy-Item -LiteralPath $source -Destination $target -Force; \
           }} \
         }}; \
         if (-not (Test-Path -LiteralPath (Join-Path $target 'ffmpeg.exe'))) {{ throw 'ffmpeg.exe was not installed.' }}; \
         if (-not (Test-Path -LiteralPath (Join-Path $target 'ffprobe.exe'))) {{ throw 'ffprobe.exe was not installed.' }}; \
         Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue;",
        zip = ps_quote(&zip_path),
        partial = ps_quote(&partial_zip_path),
        extract = ps_quote(&extract_dir),
        target = ps_quote(&target_bin),
        url = FFMPEG_DOWNLOAD_URL
    );

    let mut command = Command::new("powershell.exe");
    command.args([
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        &script,
    ]);
    hide_command_window(&mut command);
    let output = command
        .output()
        .map_err(|error| format!("Unable to start FFmpeg installer: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "FFmpeg install failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    if !ffmpeg_install_ready(&target_bin) {
        return Err("FFmpeg installer completed, but ffmpeg.exe or ffprobe.exe was not found.".to_string());
    }
    Ok(target_ffmpeg.display().to_string())
}

fn start_conversion_job_core(
    app: AppHandle,
    active_jobs: &ActiveJobState,
    paths: Vec<String>,
    options: ConvertOptions,
    kind: OutputKind,
) -> Result<String, String> {
    let videos = sorted_unique_videos(paths, options.include_subfolders);
    if videos.is_empty() {
        return Err("No input videos were provided.".to_string());
    }
    let config = load_config_inner(&app);
    let ffmpeg = find_ffmpeg(&app, &config).ok_or_else(|| {
        "FFmpeg was not found. Install FFmpeg or locate ffmpeg first.".to_string()
    })?;
    let ffprobe = find_ffprobe(Some(&ffmpeg));
    let job_id = Uuid::new_v4().to_string();
    active_jobs.start(job_id.clone())?;
    let app_for_thread = app.clone();
    let active_for_thread = active_jobs.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        run_conversion_job(
            app_for_thread,
            active_for_thread,
            job_id_for_thread,
            videos,
            options,
            kind,
            ffmpeg,
            ffprobe,
        );
    });
    Ok(job_id)
}

#[tauri::command]
fn start_conversion_job(
    app: AppHandle,
    active_jobs: State<'_, ActiveJobState>,
    paths: Vec<String>,
    options: ConvertOptions,
    kind: OutputKind,
) -> Result<String, String> {
    start_conversion_job_core(app, active_jobs.inner(), paths, options, kind)
}

fn start_combine_job_core(
    app: AppHandle,
    active_jobs: &ActiveJobState,
    paths: Vec<String>,
    overwrite: bool,
) -> Result<String, String> {
    let mut videos = paths
        .into_iter()
        .filter_map(|path| video_item(Path::new(&path)))
        .collect::<Vec<_>>();
    videos.sort_by(|left, right| {
        left.base_name
            .to_ascii_lowercase()
            .cmp(&right.base_name.to_ascii_lowercase())
            .then(
                left.name
                    .to_ascii_lowercase()
                    .cmp(&right.name.to_ascii_lowercase()),
            )
            .then(
                left.path
                    .to_ascii_lowercase()
                    .cmp(&right.path.to_ascii_lowercase()),
            )
    });
    videos.dedup_by(|left, right| left.path.eq_ignore_ascii_case(&right.path));
    if videos.len() < 2 {
        return Err("Drop or queue at least two videos to combine.".to_string());
    }
    let config = load_config_inner(&app);
    let ffmpeg = find_ffmpeg(&app, &config).ok_or_else(|| {
        "FFmpeg was not found. Install FFmpeg or locate ffmpeg first.".to_string()
    })?;
    let ffprobe = find_ffprobe(Some(&ffmpeg));
    let job_id = Uuid::new_v4().to_string();
    active_jobs.start(job_id.clone())?;
    let app_for_thread = app.clone();
    let active_for_thread = active_jobs.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        run_combine_job(
            app_for_thread,
            active_for_thread,
            job_id_for_thread,
            videos,
            overwrite,
            ffmpeg,
            ffprobe,
        );
    });
    Ok(job_id)
}

#[tauri::command]
fn start_combine_job(
    app: AppHandle,
    active_jobs: State<'_, ActiveJobState>,
    paths: Vec<String>,
    overwrite: bool,
) -> Result<String, String> {
    start_combine_job_core(app, active_jobs.inner(), paths, overwrite)
}

#[tauri::command]
fn cancel_active_job(active_jobs: State<'_, ActiveJobState>) -> Result<(), String> {
    let pids = active_jobs.request_cancel()?;
    for pid in pids {
        let _ = kill_process_tree(pid);
    }
    Ok(())
}

struct HttpRequest {
    method: String,
    path: String,
    body: Vec<u8>,
}

fn validate_agent_api_port(port: Option<u16>) -> Result<u16, String> {
    let port = port
        .or_else(read_registered_agent_api_port)
        .unwrap_or(DEFAULT_AGENT_API_PORT);
    if port == 0 {
        return Err("Agent API port must be between 1 and 65535.".to_string());
    }
    Ok(port)
}

fn agent_api_url(port: u16) -> String {
    format!("http://{AGENT_API_BIND_ADDRESS}:{port}")
}

fn timestamp_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

fn shared_neko_legends_dir() -> Option<PathBuf> {
    let base = if cfg!(target_os = "windows") {
        env::var_os("APPDATA")
            .map(PathBuf::from)
            .or_else(|| env::var_os("USERPROFILE").map(PathBuf::from))
    } else if cfg!(target_os = "macos") {
        env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join("Library").join("Application Support"))
    } else {
        env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
    }?;
    Some(base.join("NekoLegends"))
}

fn agent_api_registry_path() -> Option<PathBuf> {
    Some(shared_neko_legends_dir()?.join(AGENT_API_REGISTRY_FILE))
}

fn read_agent_api_registry() -> AgentApiRegistry {
    let updated_at = timestamp_string();
    let Some(path) = agent_api_registry_path() else {
        return AgentApiRegistry {
            updated_at,
            apps: Vec::new(),
        };
    };
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(AgentApiRegistry {
            updated_at,
            apps: Vec::new(),
        })
}

fn read_registered_agent_api_port() -> Option<u16> {
    read_agent_api_registry()
        .apps
        .into_iter()
        .find(|entry| entry.app_id == AGENT_APP_ID)
        .map(|entry| entry.port)
        .filter(|port| *port > 0)
}

fn publish_agent_api_status(status: &AgentServerStatus) {
    let Some(path) = agent_api_registry_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let mut registry = read_agent_api_registry();
    let updated_at = timestamp_string();
    let entry = AgentApiRegistryEntry {
        app_id: AGENT_APP_ID.to_string(),
        app_name: AGENT_APP_NAME.to_string(),
        default_port: DEFAULT_AGENT_API_PORT,
        bind_address: AGENT_API_BIND_ADDRESS.to_string(),
        port: status.port,
        enabled: status.enabled,
        url: status.url.clone(),
        openapi_url: status.openapi_url.clone(),
        busy: status.busy,
        active_job_id: status.active_job_id.clone(),
        last_seen: Some(updated_at.clone()),
        note: Some("Local Agent API.".to_string()),
    };
    if let Some(existing) = registry
        .apps
        .iter_mut()
        .find(|entry| entry.app_id == AGENT_APP_ID)
    {
        *existing = entry;
    } else {
        registry.apps.push(entry);
    }
    registry.updated_at = updated_at;
    if let Ok(raw) = serde_json::to_string_pretty(&registry) {
        let _ = fs::write(path, raw);
    }
}

fn agent_status_from(
    agent_state: &AgentServerState,
    active_jobs: &ActiveJobState,
) -> Result<AgentServerStatus, String> {
    let (enabled, port) = {
        let control = agent_state
            .inner
            .lock()
            .map_err(|_| "Unable to lock agent server state.".to_string())?;
        (control.enabled, control.port())
    };
    let busy = active_jobs.is_busy()?;
    let active_job_id = active_jobs.active_job_id()?;
    let status = AgentServerStatus {
        enabled,
        port,
        url: agent_api_url(port),
        openapi_url: format!("{}/openapi.json", agent_api_url(port)),
        busy,
        active_job_id,
        message: if enabled {
            "Agent API is enabled.".to_string()
        } else {
            "Agent API is off.".to_string()
        },
    };
    publish_agent_api_status(&status);
    Ok(status)
}

fn find_header_end(data: &[u8]) -> Option<usize> {
    data.windows(4).position(|window| window == b"\r\n\r\n")
}

fn read_http_request(stream: &mut TcpStream) -> Result<HttpRequest, String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| format!("Unable to set read timeout: {error}"))?;
    let mut data = Vec::new();
    let mut buffer = [0_u8; 4096];
    let mut expected_len: Option<usize> = None;

    loop {
        let bytes_read = stream
            .read(&mut buffer)
            .map_err(|error| format!("Unable to read agent request: {error}"))?;
        if bytes_read == 0 {
            break;
        }
        data.extend_from_slice(&buffer[..bytes_read]);
        if let Some(header_end) = find_header_end(&data) {
            if expected_len.is_none() {
                let headers = String::from_utf8_lossy(&data[..header_end]);
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        if name.eq_ignore_ascii_case("content-length") {
                            value.trim().parse::<usize>().ok()
                        } else {
                            None
                        }
                    })
                    .unwrap_or(0);
                expected_len = Some(header_end + 4 + content_length);
            }
            if expected_len.is_some_and(|len| data.len() >= len) {
                break;
            }
        }
        if data.len() > 2 * 1024 * 1024 {
            return Err("Agent request is too large.".to_string());
        }
    }

    let header_end = find_header_end(&data).ok_or_else(|| "Invalid HTTP request.".to_string())?;
    let headers = String::from_utf8_lossy(&data[..header_end]);
    let mut lines = headers.lines();
    let request_line = lines
        .next()
        .ok_or_else(|| "Invalid HTTP request line.".to_string())?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let raw_path = parts.next().unwrap_or("/").to_string();
    let path = raw_path.split('?').next().unwrap_or("/").to_string();
    let body_start = header_end + 4;
    let body = if body_start <= data.len() {
        data[body_start..].to_vec()
    } else {
        Vec::new()
    };
    Ok(HttpRequest { method, path, body })
}

fn write_json_response(
    stream: &mut TcpStream,
    status: &str,
    payload: serde_json::Value,
) -> Result<(), String> {
    let body = serde_json::to_vec(&payload)
        .map_err(|error| format!("Unable to serialize agent response: {error}"))?;
    let headers = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(headers.as_bytes())
        .and_then(|_| stream.write_all(&body))
        .map_err(|error| format!("Unable to write agent response: {error}"))
}

fn write_empty_response(stream: &mut TcpStream, status: &str) -> Result<(), String> {
    let headers = format!(
        "HTTP/1.1 {status}\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: content-type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(headers.as_bytes())
        .map_err(|error| format!("Unable to write agent response: {error}"))
}

fn agent_openapi(port: u16) -> serde_json::Value {
    serde_json::json!({
        "openapi": "3.1.0",
        "info": {
            "title": "Cutscene Converter Agent API",
            "version": env!("CARGO_PKG_VERSION")
        },
        "servers": [{ "url": agent_api_url(port) }],
        "paths": {
            "/health": { "get": { "summary": "Check API status" } },
            "/status": { "get": { "summary": "Check active job status" } },
            "/runtime": { "get": { "summary": "Check FFmpeg readiness" } },
            "/convert": { "post": { "summary": "Start MP4/WebM/OGV conversion" } },
            "/generate": { "post": { "summary": "Alias for /convert" } },
            "/combine": { "post": { "summary": "Combine queued cutscene videos" } },
            "/cancel": { "post": { "summary": "Cancel the active job" } }
        }
    })
}

fn parse_agent_convert_request(body: &[u8]) -> Result<AgentConvertRequest, String> {
    if body.is_empty() {
        return Ok(AgentConvertRequest {
            paths: None,
            options: None,
            kind: None,
            overwrite: None,
        });
    }
    serde_json::from_slice(body).map_err(|error| format!("Invalid JSON request: {error}"))
}

fn agent_options_from_request(options: Option<serde_json::Value>) -> Result<ConvertOptions, String> {
    let mut merged = serde_json::to_value(default_convert_options())
        .map_err(|error| format!("Unable to build default options: {error}"))?;
    let Some(options) = options else {
        return serde_json::from_value(merged)
            .map_err(|error| format!("Unable to read default options: {error}"));
    };
    if options.is_null() {
        return serde_json::from_value(merged)
            .map_err(|error| format!("Unable to read default options: {error}"));
    }
    let overrides = options
        .as_object()
        .ok_or_else(|| "Agent options must be a JSON object.".to_string())?;
    let base = merged
        .as_object_mut()
        .ok_or_else(|| "Unable to merge default options.".to_string())?;
    for (key, value) in overrides {
        base.insert(key.clone(), value.clone());
    }
    serde_json::from_value(merged).map_err(|error| format!("Invalid agent options: {error}"))
}

fn handle_agent_route(
    request: HttpRequest,
    app: &AppHandle,
    active_jobs: &ActiveJobState,
    agent_state: &AgentServerState,
) -> Result<serde_json::Value, String> {
    match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/health") => Ok(serde_json::json!({
            "ok": true,
            "service": "Cutscene Converter",
            "version": env!("CARGO_PKG_VERSION"),
            "url": agent_status_from(agent_state, active_jobs)?.url
        })),
        ("GET", "/openapi.json") => Ok(agent_openapi(agent_status_from(agent_state, active_jobs)?.port)),
        ("GET", "/status") => {
            serde_json::to_value(agent_status_from(agent_state, active_jobs)?)
                .map_err(|error| error.to_string())
        }
        ("GET", "/runtime") => {
            serde_json::to_value(check_runtime(app.clone())?).map_err(|error| error.to_string())
        }
        ("POST", "/convert") | ("POST", "/generate") => {
            let request = parse_agent_convert_request(&request.body)?;
            let paths = request.paths.unwrap_or_default();
            let options = agent_options_from_request(request.options)?;
            let kind = request.kind.unwrap_or(OutputKind::Mp4);
            let job_id = start_conversion_job_core(app.clone(), active_jobs, paths, options, kind)?;
            Ok(serde_json::json!({ "ok": true, "jobId": job_id }))
        }
        ("POST", "/combine") => {
            let request = parse_agent_convert_request(&request.body)?;
            let job_id = start_combine_job_core(
                app.clone(),
                active_jobs,
                request.paths.unwrap_or_default(),
                request.overwrite.unwrap_or(true),
            )?;
            Ok(serde_json::json!({ "ok": true, "jobId": job_id }))
        }
        ("POST", "/cancel") => {
            let pids = active_jobs.request_cancel()?;
            for pid in pids {
                let _ = kill_process_tree(pid);
            }
            Ok(serde_json::json!({ "ok": true }))
        }
        _ => Err(format!(
            "No agent endpoint for {} {}",
            request.method, request.path
        )),
    }
}

fn handle_agent_stream(
    mut stream: TcpStream,
    app: &AppHandle,
    active_jobs: &ActiveJobState,
    agent_state: &AgentServerState,
) {
    let result = read_http_request(&mut stream).and_then(|request| {
        if request.method == "OPTIONS" {
            return write_empty_response(&mut stream, "204 No Content");
        }
        match handle_agent_route(request, app, active_jobs, agent_state) {
            Ok(payload) => write_json_response(&mut stream, "200 OK", payload),
            Err(error) => write_json_response(
                &mut stream,
                "400 Bad Request",
                serde_json::json!({ "ok": false, "error": error }),
            ),
        }
    });
    if let Err(error) = result {
        let _ = write_json_response(
            &mut stream,
            "400 Bad Request",
            serde_json::json!({ "ok": false, "error": error }),
        );
    }
}

fn run_agent_server(
    listener: TcpListener,
    app: AppHandle,
    active_jobs: ActiveJobState,
    agent_state: AgentServerState,
    stop: Arc<AtomicBool>,
) {
    let _ = listener.set_nonblocking(true);
    while !stop.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => handle_agent_stream(stream, &app, &active_jobs, &agent_state),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(80));
            }
            Err(_) => {
                thread::sleep(Duration::from_millis(150));
            }
        }
    }
}

#[tauri::command]
fn get_agent_server_status(
    agent_state: State<'_, AgentServerState>,
    active_jobs: State<'_, ActiveJobState>,
) -> Result<AgentServerStatus, String> {
    agent_status_from(agent_state.inner(), active_jobs.inner())
}

fn set_agent_server_enabled_inner(
    app: AppHandle,
    agent_state: &AgentServerState,
    active_jobs: &ActiveJobState,
    enabled: bool,
    port: Option<u16>,
) -> Result<AgentServerStatus, String> {
    let port = validate_agent_api_port(port)?;
    {
        let mut control = agent_state
            .inner
            .lock()
            .map_err(|_| "Unable to lock agent server state.".to_string())?;

        if control.enabled && (!enabled || control.port() != port) {
            if let Some(stop) = control.stop.take() {
                stop.store(true, Ordering::SeqCst);
            }
            control.enabled = false;
        }
        control.port = port;

        if enabled && !control.enabled {
            let listener = TcpListener::bind(("127.0.0.1", port))
                .map_err(|error| format!("Unable to start Agent API: {error}"))?;
            let stop = Arc::new(AtomicBool::new(false));
            thread::spawn({
                let app = app.clone();
                let active_jobs = active_jobs.clone();
                let agent_state = agent_state.clone();
                let stop = stop.clone();
                move || run_agent_server(listener, app, active_jobs, agent_state, stop)
            });
            control.enabled = true;
            control.stop = Some(stop);
        }
    }

    agent_status_from(agent_state, active_jobs)
}

#[tauri::command]
fn set_agent_server_enabled(
    app: AppHandle,
    agent_state: State<'_, AgentServerState>,
    active_jobs: State<'_, ActiveJobState>,
    enabled: bool,
    port: Option<u16>,
) -> Result<AgentServerStatus, String> {
    set_agent_server_enabled_inner(
        app,
        agent_state.inner(),
        active_jobs.inner(),
        enabled,
        port,
    )
}

pub fn run() {
    tauri::Builder::default()
        .manage(ActiveJobState::default())
        .manage(AgentServerState::default())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            cancel_active_job,
            check_runtime,
            get_agent_server_status,
            install_ffmpeg,
            load_config,
            open_path,
            resolve_inputs,
            save_config,
            set_agent_server_enabled,
            start_combine_job,
            start_conversion_job
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import { getCurrentWindow, PhysicalSize } from "@tauri-apps/api/window";
import {
  CheckCircle2,
  Download,
  Film,
  FolderOpen,
  Loader2,
  Merge,
  Play,
  RotateCcw,
  Scissors,
  Settings2,
  Square,
  TriangleAlert,
  Video,
  XCircle
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

type Quality = "Balanced" | "High" | "Smaller";
type OutputResolution = "(native)" | "1920x1080" | "1444p" | "2160p";
type Mp4Codec = "H264" | "H265";
type OutputKind = "mp4" | "webmVp9" | "ogv";
type QueueStatus = "pending" | "running" | "done" | "error" | "canceled";

type AppConfig = {
  ffmpegPath: string;
  outputDir: string;
  sourcePaths: string[];
  quality: Quality;
  outputResolution: OutputResolution;
  includeSubfolders: boolean;
  overwrite: boolean;
  parallelJobs: number;
  trimStartSeconds: number;
  trimEndSeconds: number;
  mp4Codec: Mp4Codec;
  showMoreFormats: boolean;
};

type RuntimeStatus = {
  ffmpegFound: boolean;
  ffmpegPath: string | null;
  ffprobePath: string | null;
  appDataDir: string;
  configPath: string;
  version: string;
  installSupported: boolean;
};

type VideoItem = {
  path: string;
  name: string;
  baseName: string;
  extension: string;
  sizeBytes: number;
};

type QueueItem = VideoItem & {
  status: QueueStatus;
  message?: string;
  outputPath?: string;
  percent?: number;
};

type ConvertOptions = {
  outputDir: string;
  quality: Quality;
  outputResolution: OutputResolution;
  includeSubfolders: boolean;
  overwrite: boolean;
  parallelJobs: number;
  trimStartSeconds: number;
  trimEndSeconds: number;
  mp4Codec: Mp4Codec;
};

type ConverterEvent = {
  type:
    | "log"
    | "progress"
    | "fileStart"
    | "fileProgress"
    | "fileDone"
    | "fileError"
    | "fileCanceled"
    | "combineDone"
    | "done"
    | "error"
    | "canceled";
  path?: string;
  outputPath?: string;
  message?: string;
  percent?: number;
};

const APP_VERSION = "v26.6.9";
const VIDEO_EXTENSIONS = ["mp4", "webm", "ogv", "mov", "mkv", "avi", "m4v", "wmv", "flv"];
const QUALITY_OPTIONS: Quality[] = ["Balanced", "High", "Smaller"];
const RESOLUTION_OPTIONS: OutputResolution[] = ["(native)", "1920x1080", "1444p", "2160p"];
const MP4_CODEC_OPTIONS: Mp4Codec[] = ["H264", "H265"];

const defaultConfig: AppConfig = {
  ffmpegPath: "",
  outputDir: "D:\\NekoLegends-Universe\\games\\neko-legends-awakening\\godot\\assets\\video\\cutscenes",
  sourcePaths: [],
  quality: "Balanced",
  outputResolution: "(native)",
  includeSubfolders: false,
  overwrite: true,
  parallelJobs: 2,
  trimStartSeconds: 0,
  trimEndSeconds: 0,
  mp4Codec: "H264",
  showMoreFormats: true
};

const isTauriRuntime = () => "__TAURI_INTERNALS__" in window || "__TAURI__" in window;
const fileName = (path: string) => path.split(/[\\/]/).pop() ?? path;
const trimSecondsOptions = Array.from({ length: 21 }, (_, index) => index / 2);

function formatBytes(bytes: number) {
  if (bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function statusIcon(status: QueueStatus) {
  if (status === "done") return <CheckCircle2 size={18} />;
  if (status === "error") return <XCircle size={18} />;
  if (status === "canceled") return <TriangleAlert size={18} />;
  if (status === "running") return <Loader2 className="spin" size={18} />;
  return <Video size={18} />;
}

function outputLabel(kind: OutputKind) {
  if (kind === "webmVp9") return "WebM VP9";
  if (kind === "ogv") return "OGV";
  return "MP4";
}

function toOptions(config: AppConfig): ConvertOptions {
  return {
    outputDir: config.outputDir,
    quality: config.quality,
    outputResolution: config.outputResolution,
    includeSubfolders: config.includeSubfolders,
    overwrite: config.overwrite,
    parallelJobs: config.parallelJobs,
    trimStartSeconds: config.trimStartSeconds,
    trimEndSeconds: config.trimEndSeconds,
    mp4Codec: config.mp4Codec
  };
}

function eventLogMessage(payload: ConverterEvent) {
  if (payload.type === "progress" || payload.type === "fileProgress" || payload.type === "fileStart") {
    return null;
  }
  if (payload.type === "fileDone" && payload.path) {
    const verb = payload.message?.toLowerCase().includes("skipped") ? "Skipped" : "Finished";
    return `${verb}: ${fileName(payload.path)}`;
  }
  if (payload.type === "fileError" && payload.path) {
    return `Failed: ${fileName(payload.path)}${payload.message ? ` - ${payload.message}` : ""}`;
  }
  if (payload.type === "fileCanceled" && payload.path) {
    return `Canceled: ${fileName(payload.path)}`;
  }
  return payload.message ?? null;
}

export default function App() {
  const [config, setConfig] = useState<AppConfig>(defaultConfig);
  const [runtime, setRuntime] = useState<RuntimeStatus | null>(null);
  const [queue, setQueue] = useState<QueueItem[]>([]);
  const [logs, setLogs] = useState<string[]>([]);
  const [headline, setHeadline] = useState("Ready");
  const [progress, setProgress] = useState({ percent: 0, message: "Idle" });
  const [busy, setBusy] = useState(false);
  const [canceling, setCanceling] = useState(false);
  const [installingFfmpeg, setInstallingFfmpeg] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [lastOutput, setLastOutput] = useState<string | null>(null);
  const [activeKind, setActiveKind] = useState<OutputKind | "combine" | null>(null);
  const queueRef = useRef<QueueItem[]>([]);
  const configRef = useRef<AppConfig>(defaultConfig);
  const loadedConfigRef = useRef(false);
  const logScrollRef = useRef<HTMLDivElement | null>(null);

  const doneCount = useMemo(() => queue.filter((item) => item.status === "done").length, [queue]);
  const errorCount = useMemo(() => queue.filter((item) => item.status === "error").length, [queue]);
  const pendingCount = useMemo(
    () => queue.filter((item) => item.status === "pending" || item.status === "running").length,
    [queue]
  );

  const pushLog = useCallback((message: string) => {
    const stamped = `[${new Date().toLocaleTimeString([], { hour12: false })}] ${message}`;
    setLogs((current) => [...current.slice(-399), stamped]);
  }, []);

  const refreshRuntime = useCallback(async () => {
    if (!isTauriRuntime()) {
      setRuntime({
        ffmpegFound: true,
        ffmpegPath: "Browser preview",
        ffprobePath: "Browser preview",
        appDataDir: "Tauri runtime required",
        configPath: "Tauri runtime required",
        version: APP_VERSION,
        installSupported: false
      });
      return;
    }
    const next = await invoke<RuntimeStatus>("check_runtime");
    setRuntime(next);
  }, []);

  const persistConfig = useCallback(
    async (next: AppConfig) => {
      configRef.current = next;
      setConfig(next);
      if (!loadedConfigRef.current || !isTauriRuntime()) return;
      try {
        await invoke<string>("save_config", { config: next });
      } catch (error) {
        pushLog(`Could not save settings: ${String(error)}`);
      }
    },
    [pushLog]
  );

  const patchConfig = useCallback(
    (patch: Partial<AppConfig>) => {
      const next = { ...config, ...patch };
      void persistConfig(next);
    },
    [config, persistConfig]
  );

  const resolvePaths = useCallback(
    async (paths: string[]) => {
      if (paths.length === 0) return;
      const currentConfig = configRef.current;
      if (!isTauriRuntime()) {
        pushLog("Desktop mode is required for local files.");
        return;
      }
      let resolved: VideoItem[];
      try {
        resolved = await invoke<VideoItem[]>("resolve_inputs", {
          paths,
          recursive: currentConfig.includeSubfolders
        });
      } catch (error) {
        pushLog(`Could not read video paths: ${String(error)}`);
        return;
      }

      const known = new Set(queueRef.current.map((item) => item.path));
      const additions: QueueItem[] = resolved
        .filter((item) => !known.has(item.path))
        .map((item) => ({ ...item, status: "pending" }));
      const nextQueue = [...queueRef.current, ...additions];
      setQueue(nextQueue);
      void persistConfig({ ...currentConfig, sourcePaths: nextQueue.map((item) => item.path) });
      if (additions.length > 0) {
        setHeadline(`${additions.length} video${additions.length === 1 ? "" : "s"} ready`);
        pushLog(`Queued ${additions.length} video${additions.length === 1 ? "" : "s"}.`);
      } else if (resolved.length > 0) {
        pushLog("Dropped videos were already queued.");
      } else {
        pushLog("No supported video files found.");
      }
    },
    [persistConfig, pushLog]
  );

  const chooseVideos = async () => {
    if (!isTauriRuntime()) {
      pushLog("Desktop mode is required for file picking.");
      return;
    }
    const selected = await open({
      multiple: true,
      directory: false,
      filters: [{ name: "Videos", extensions: VIDEO_EXTENSIONS }]
    });
    const paths = Array.isArray(selected) ? selected : selected ? [selected] : [];
    await resolvePaths(paths);
  };

  const chooseFolder = async () => {
    if (!isTauriRuntime()) {
      pushLog("Desktop mode is required for folder picking.");
      return;
    }
    const selected = await open({ multiple: false, directory: true });
    if (typeof selected === "string") {
      await resolvePaths([selected]);
    }
  };

  const chooseOutputFolder = async () => {
    if (!isTauriRuntime()) {
      pushLog("Desktop mode is required for folder picking.");
      return;
    }
    const selected = await open({ multiple: false, directory: true });
    if (typeof selected === "string") {
      patchConfig({ outputDir: selected });
    }
  };

  const locateFfmpeg = async () => {
    if (!isTauriRuntime()) {
      pushLog("Desktop mode is required to locate FFmpeg.");
      return;
    }
    const selected = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "FFmpeg", extensions: ["exe"] }]
    });
    if (typeof selected === "string") {
      await persistConfig({ ...config, ffmpegPath: selected });
      await refreshRuntime();
      pushLog(`FFmpeg set to ${selected}`);
    }
  };

  const installFfmpeg = async () => {
    if (!isTauriRuntime()) return;
    setInstallingFfmpeg(true);
    setHeadline("Installing FFmpeg");
    pushLog("Downloading FFmpeg essentials build.");
    try {
      const ffmpegPath = await invoke<string>("install_ffmpeg");
      await persistConfig({ ...config, ffmpegPath });
      await refreshRuntime();
      pushLog(`Installed FFmpeg: ${ffmpegPath}`);
      setHeadline("FFmpeg ready");
    } catch (error) {
      pushLog(String(error));
      setHeadline("FFmpeg install failed");
    } finally {
      setInstallingFfmpeg(false);
    }
  };

  const clearQueue = () => {
    setQueue([]);
    queueRef.current = [];
    setLastOutput(null);
    setProgress({ percent: 0, message: "Idle" });
    setHeadline("Ready");
    void persistConfig({ ...config, sourcePaths: [] });
  };

  const openFolder = async (path: string) => {
    if (!isTauriRuntime()) return;
    try {
      await invoke("open_path", { path });
    } catch (error) {
      pushLog(String(error));
    }
  };

  const startConversion = async (kind: OutputKind) => {
    if (queue.length === 0 || busy || installingFfmpeg) return;
    if (!runtime?.ffmpegFound) {
      pushLog("FFmpeg was not found.");
      return;
    }
    const paths = queue.map((item) => item.path);
    setBusy(true);
    setActiveKind(kind);
    setProgress({ percent: 0, message: `Starting ${outputLabel(kind)}...` });
    setHeadline(`Starting ${outputLabel(kind)}`);
    setQueue((current) =>
      current.map((item) => ({ ...item, status: "pending", message: undefined, percent: 0 }))
    );
    try {
      await invoke<string>("start_conversion_job", {
        paths,
        options: toOptions(config),
        kind
      });
    } catch (error) {
      setBusy(false);
      setActiveKind(null);
      pushLog(String(error));
      setHeadline("Could not start conversion");
    }
  };

  const startCombine = async () => {
    if (queue.length < 2 || busy || installingFfmpeg) return;
    if (!runtime?.ffmpegFound) {
      pushLog("FFmpeg was not found.");
      return;
    }
    setBusy(true);
    setActiveKind("combine");
    setProgress({ percent: 0, message: "Starting combine..." });
    setHeadline("Combining videos");
    try {
      await invoke<string>("start_combine_job", {
        paths: queue.map((item) => item.path),
        overwrite: config.overwrite
      });
    } catch (error) {
      setBusy(false);
      setActiveKind(null);
      pushLog(String(error));
      setHeadline("Could not start combine");
    }
  };

  const cancelActiveJob = async () => {
    if (!busy || canceling) return;
    setCanceling(true);
    setHeadline("Canceling");
    try {
      await invoke("cancel_active_job");
    } catch (error) {
      pushLog(String(error));
      setCanceling(false);
    }
  };

  useEffect(() => {
    const updateScale = () => {
      const scale = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
      document.documentElement.style.setProperty("--ui-scale", String(scale));
    };
    updateScale();
    window.addEventListener("resize", updateScale);
    return () => window.removeEventListener("resize", updateScale);
  }, []);

  useEffect(() => {
    queueRef.current = queue;
  }, [queue]);

  useEffect(() => {
    configRef.current = config;
  }, [config]);

  useEffect(() => {
    logScrollRef.current?.scrollTo({ top: logScrollRef.current.scrollHeight });
  }, [logs]);

  useEffect(() => {
    if (!isTauriRuntime()) {
      loadedConfigRef.current = true;
      pushLog("Browser preview mode. Launch the desktop app for local file conversion.");
      void refreshRuntime();
      return;
    }

    invoke<AppConfig>("load_config")
      .then(async (loaded) => {
        const merged = { ...defaultConfig, ...loaded };
        loadedConfigRef.current = true;
        configRef.current = merged;
        setConfig(merged);
        if (merged.sourcePaths.length > 0) {
          await resolvePaths(merged.sourcePaths);
        }
      })
      .catch((error) => {
        loadedConfigRef.current = true;
        pushLog(`Could not load settings: ${String(error)}`);
      });

    void refreshRuntime().catch((error) => pushLog(String(error)));

    const eventPromise = listen<ConverterEvent>("converter-event", (event) => {
      const payload = event.payload;
      const logMessage = eventLogMessage(payload);
      if (logMessage) {
        pushLog(logMessage);
      }
      if (payload.message && payload.type !== "progress" && payload.type !== "fileProgress") {
        setHeadline(payload.message);
      }

      if (payload.type === "progress") {
        setProgress({
          percent: Math.max(0, Math.min(100, payload.percent ?? 0)),
          message: payload.message ?? "Working..."
        });
      }

      if (payload.type === "fileStart" && payload.path) {
        setQueue((current) =>
          current.map((item) =>
            item.path === payload.path
              ? {
                  ...item,
                  status: "running",
                  outputPath: payload.outputPath,
                  message: payload.message ?? "Starting",
                  percent: 0
                }
              : item
          )
        );
      }

      if (payload.type === "fileProgress" && payload.path) {
        setQueue((current) =>
          current.map((item) =>
            item.path === payload.path
              ? {
                  ...item,
                  status: "running",
                  message: payload.message ?? "Working",
                  percent: payload.percent ?? item.percent
                }
              : item
          )
        );
      }

      if (payload.type === "fileDone" && payload.path) {
        setLastOutput(payload.outputPath ?? null);
        setQueue((current) =>
          current.map((item) =>
            item.path === payload.path
              ? {
                  ...item,
                  status: "done",
                  outputPath: payload.outputPath ?? item.outputPath,
                  message: payload.message ?? "Done",
                  percent: 100
                }
              : item
          )
        );
      }

      if (payload.type === "fileError" && payload.path) {
        setQueue((current) =>
          current.map((item) =>
            item.path === payload.path
              ? { ...item, status: "error", message: payload.message ?? "Failed" }
              : item
          )
        );
      }

      if (payload.type === "fileCanceled" && payload.path) {
        setQueue((current) =>
          current.map((item) =>
            item.path === payload.path
              ? { ...item, status: "canceled", message: "Canceled" }
              : item
          )
        );
      }

      if (payload.type === "combineDone") {
        setLastOutput(payload.outputPath ?? null);
        setProgress({ percent: 100, message: payload.message ?? "Combined videos" });
      }

      if (payload.type === "done" || payload.type === "error" || payload.type === "canceled") {
        setBusy(false);
        setCanceling(false);
        setActiveKind(null);
        if (payload.type === "canceled") {
          setQueue((current) =>
            current.map((item) =>
              item.status === "pending" || item.status === "running"
                ? { ...item, status: "canceled", message: "Canceled" }
                : item
            )
          );
        }
        void refreshRuntime().catch((error) => pushLog(String(error)));
      }
    });

    const dragPromise = getCurrentWindow().onDragDropEvent((event) => {
      if (event.payload.type === "over") {
        setDragging(true);
      }
      if (event.payload.type === "drop") {
        setDragging(false);
        void resolvePaths(event.payload.paths);
      }
      if (event.payload.type === "leave") {
        setDragging(false);
      }
    });

    let resizeTimer: number | undefined;
    let adjusting = false;
    const enforceAspectRatio = async () => {
      const windowHandle = getCurrentWindow();
      const size = await windowHandle.outerSize();
      let width = Math.max(640, size.width);
      let height = Math.max(360, size.height);
      const heightFromWidth = Math.round((width * 9) / 16);
      const widthFromHeight = Math.round((height * 16) / 9);
      if (Math.abs(heightFromWidth - height) <= Math.abs(widthFromHeight - width)) {
        height = heightFromWidth;
      } else {
        width = widthFromHeight;
      }
      if (Math.abs(width - size.width) > 1 || Math.abs(height - size.height) > 1) {
        adjusting = true;
        try {
          await windowHandle.setSize(new PhysicalSize(width, height));
        } finally {
          window.setTimeout(() => {
            adjusting = false;
          }, 250);
        }
      }
    };
    const resizePromise = getCurrentWindow().onResized(() => {
      if (adjusting) return;
      if (resizeTimer !== undefined) window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        void enforceAspectRatio();
      }, 850);
    });

    return () => {
      if (resizeTimer !== undefined) window.clearTimeout(resizeTimer);
      void eventPromise.then((unlisten) => unlisten());
      void dragPromise.then((unlisten) => unlisten());
      void resizePromise.then((unlisten) => unlisten());
    };
  }, [pushLog, refreshRuntime, resolvePaths]);

  const ffmpegText = runtime?.ffmpegFound
    ? runtime.ffmpegPath ?? "FFmpeg found"
    : "FFmpeg not found";
  const runDisabled = busy || installingFfmpeg || queue.length === 0 || !runtime?.ffmpegFound;

  return (
    <div className="scale-stage">
      <main className="app-shell">
        <aside className="sidebar">
          <div className="brand">
            <div>
              <h1>Cutscene</h1>
              <h2>Converter</h2>
              <p>{APP_VERSION}</p>
            </div>
          </div>

          <section className="runtime">
            <div className="panel-title">
              <Film size={17} />
              Runtime
            </div>
            <div className={runtime?.ffmpegFound ? "ok" : "warn"}>{ffmpegText}</div>
            <small>{runtime?.ffprobePath ? `ffprobe: ${runtime.ffprobePath}` : "ffprobe unavailable"}</small>
            <div className="runtime-actions">
              <button className="secondary" onClick={locateFfmpeg} disabled={busy || installingFfmpeg}>
                <FolderOpen size={16} />
                Locate
              </button>
              <button
                className="secondary"
                onClick={installFfmpeg}
                disabled={busy || installingFfmpeg || !runtime?.installSupported}
              >
                {installingFfmpeg ? <Loader2 className="spin" size={16} /> : <Download size={16} />}
                Install
              </button>
            </div>
          </section>

          <section className="panel">
            <div className="panel-title">
              <FolderOpen size={17} />
              Output
            </div>
            <div className="output-folder-row">
              <input
                value={config.outputDir}
                onChange={(event) => patchConfig({ outputDir: event.target.value })}
              />
              <button className="secondary mini-button" title="Choose output folder" onClick={chooseOutputFolder}>
                <FolderOpen size={15} />
              </button>
              <button className="secondary mini-button" onClick={() => void openFolder(config.outputDir)}>
                Open
              </button>
            </div>
            <label className="toggle">
              <input
                type="checkbox"
                checked={config.overwrite}
                onChange={(event) => patchConfig({ overwrite: event.target.checked })}
              />
              <span>Overwrite existing output</span>
            </label>
            <label className="toggle">
              <input
                type="checkbox"
                checked={config.includeSubfolders}
                onChange={(event) => patchConfig({ includeSubfolders: event.target.checked })}
              />
              <span>Include subfolders</span>
            </label>
          </section>

          <section className="panel">
            <div className="panel-title">
              <Settings2 size={17} />
              Encode
            </div>
            <div className="field">
              <span>Quality</span>
              <select
                value={config.quality}
                onChange={(event) => patchConfig({ quality: event.target.value as Quality })}
              >
                {QUALITY_OPTIONS.map((quality) => (
                  <option value={quality} key={quality}>
                    {quality}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <span>Resolution</span>
              <select
                value={config.outputResolution}
                onChange={(event) =>
                  patchConfig({ outputResolution: event.target.value as OutputResolution })
                }
              >
                {RESOLUTION_OPTIONS.map((resolution) => (
                  <option value={resolution} key={resolution}>
                    {resolution}
                  </option>
                ))}
              </select>
            </div>
            <div className="split-fields">
              <label className="field">
                <span>MP4 codec</span>
                <select
                  value={config.mp4Codec}
                  onChange={(event) => patchConfig({ mp4Codec: event.target.value as Mp4Codec })}
                >
                  {MP4_CODEC_OPTIONS.map((codec) => (
                    <option value={codec} key={codec}>
                      {codec}
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>Batch</span>
                <input
                  type="number"
                  min={1}
                  max={16}
                  value={config.parallelJobs}
                  onChange={(event) =>
                    patchConfig({
                      parallelJobs: Math.max(1, Math.min(16, Number(event.target.value) || 1))
                    })
                  }
                />
              </label>
            </div>
            <div className="split-fields">
              <label className="field">
                <span>Trim start</span>
                <select
                  value={config.trimStartSeconds}
                  onChange={(event) => patchConfig({ trimStartSeconds: Number(event.target.value) })}
                >
                  {trimSecondsOptions.map((seconds) => (
                    <option value={seconds} key={seconds}>
                      {seconds.toFixed(seconds % 1 === 0 ? 0 : 1)}s
                    </option>
                  ))}
                </select>
              </label>
              <label className="field">
                <span>Trim end</span>
                <select
                  value={config.trimEndSeconds}
                  onChange={(event) => patchConfig({ trimEndSeconds: Number(event.target.value) })}
                >
                  {trimSecondsOptions.map((seconds) => (
                    <option value={seconds} key={seconds}>
                      {seconds.toFixed(seconds % 1 === 0 ? 0 : 1)}s
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <label className="toggle">
              <input
                type="checkbox"
                checked={config.showMoreFormats}
                onChange={(event) => patchConfig({ showMoreFormats: event.target.checked })}
              />
              <span>More formats</span>
            </label>
          </section>

          <section className="panel">
            <div className="panel-title">
              <Merge size={17} />
              Combine
            </div>
            <button className="primary folder-button" disabled={busy || queue.length < 2} onClick={startCombine}>
              {activeKind === "combine" ? <Loader2 className="spin" size={16} /> : <Merge size={16} />}
              Combine queued
            </button>
            <small>{queue.length < 2 ? "Queue at least two videos." : `${queue.length} videos queued.`}</small>
          </section>
        </aside>

        <section className="workspace">
          <header className="topbar">
            <div>
              <p className="eyebrow">Local cutscene pipeline</p>
              <h3>{headline}</h3>
            </div>
            <div className="actions">
              <button className="secondary" onClick={chooseVideos} disabled={busy}>
                <Video size={17} />
                Videos
              </button>
              <button className="secondary" onClick={chooseFolder} disabled={busy}>
                <FolderOpen size={17} />
                Folder
              </button>
              <button className="secondary icon" onClick={clearQueue} disabled={busy || queue.length === 0} title="Clear queue">
                <RotateCcw size={17} />
              </button>
              <button className="primary" disabled={runDisabled} onClick={() => void startConversion("mp4")}>
                {activeKind === "mp4" ? <Loader2 className="spin" size={17} /> : <Play size={17} />}
                Export MP4
              </button>
              {config.showMoreFormats ? (
                <>
                  <button className="secondary" disabled={runDisabled} onClick={() => void startConversion("webmVp9")}>
                    {activeKind === "webmVp9" ? <Loader2 className="spin" size={17} /> : <Film size={17} />}
                    WebM VP9
                  </button>
                  <button className="secondary" disabled={runDisabled} onClick={() => void startConversion("ogv")}>
                    {activeKind === "ogv" ? <Loader2 className="spin" size={17} /> : <Film size={17} />}
                    OGV
                  </button>
                </>
              ) : null}
              <button className="secondary" disabled={!busy || canceling} onClick={cancelActiveJob}>
                {canceling ? <Loader2 className="spin" size={17} /> : <Square size={17} />}
                Stop
              </button>
            </div>
          </header>

          <div className="stats">
            <div>
              <span>{queue.length}</span>
              queued
            </div>
            <div>
              <span>{pendingCount}</span>
              active
            </div>
            <div>
              <span>{doneCount}</span>
              done
            </div>
            <div>
              <span>{errorCount}</span>
              failed
            </div>
          </div>

          <section className="progress-card">
            <div>
              <strong>{progress.message}</strong>
              <small>{lastOutput ? fileName(lastOutput) : runtime?.ffmpegFound ? "FFmpeg ready" : "FFmpeg missing"}</small>
            </div>
            <div className="progress-shell">
              <div className="progress-fill" style={{ width: `${progress.percent}%` }} />
            </div>
            <span>{progress.percent}%</span>
            {lastOutput ? (
              <button className="secondary mini-button" onClick={() => void openFolder(lastOutput)}>
                Open
              </button>
            ) : null}
          </section>

          <section className={`drop-zone ${dragging ? "dragging" : ""}`}>
            <Download size={42} />
            <div>
              <h3>Drop videos or folders here</h3>
              <p>MP4, WebM, OGV, MOV, MKV, AVI, M4V, WMV, FLV</p>
            </div>
          </section>

          <section className="queue">
            <div className="queue-header">
              <span>Source</span>
              <span>Status</span>
              <span>Output</span>
            </div>
            {queue.length === 0 ? (
              <div className="empty">
                <Scissors size={18} />
                No videos queued.
              </div>
            ) : (
              queue.map((item) => (
                <div className={`queue-row ${item.status}`} key={item.path}>
                  <div className="queue-input">
                    <strong>{item.name}</strong>
                    <small>{item.path}</small>
                    <small>{formatBytes(item.sizeBytes)}</small>
                  </div>
                  <div className="status">
                    {statusIcon(item.status)}
                    <span>{item.message ?? item.status}</span>
                  </div>
                  <div className="output-history">
                    <div>
                      <strong>{item.outputPath ? fileName(item.outputPath) : "Not written"}</strong>
                      <small>{item.outputPath ?? "Output path appears when the job starts."}</small>
                    </div>
                    {item.outputPath ? (
                      <button className="secondary output-folder" onClick={() => void openFolder(item.outputPath ?? "")}>
                        <FolderOpen size={17} />
                      </button>
                    ) : null}
                  </div>
                </div>
              ))
            )}
          </section>

          <section className="log" ref={logScrollRef}>
            {logs.length === 0 ? <p>Ready.</p> : logs.map((line) => <p key={line}>{line}</p>)}
          </section>
        </section>
      </main>
    </div>
  );
}

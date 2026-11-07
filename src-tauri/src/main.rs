#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // WebKitGTK's DMA-BUF renderer crashes on Wayland with NVIDIA
    // ("Error 71 (Protocol error) dispatching to Wayland display").
    #[cfg(target_os = "linux")]
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }

    // Inside an AppImage: the runtime's Python/Perl/Qt paths only break child
    // processes, and its GTK hook forces GDK_BACKEND=x11, which renders through
    // XWayland (blurry or 2x). Prefer native Wayland.
    #[cfg(target_os = "linux")]
    if std::env::var_os("APPDIR").is_some() {
        for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE", "PERLLIB", "QT_PLUGIN_PATH"] {
            std::env::remove_var(key);
        }
        if std::env::var_os("WAYLAND_DISPLAY").is_some()
            && std::env::var("GDK_BACKEND").as_deref() == Ok("x11")
        {
            std::env::set_var("GDK_BACKEND", "wayland,x11");
        }
    }

    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|arg| arg == "--headless") {
        let port = args.iter().enumerate().find_map(|(index, arg)| {
            if arg == "--agent-api-port" || arg == "--agent-port" {
                args.get(index + 1).cloned()
            } else {
                arg.strip_prefix("--agent-api-port=").map(str::to_string)
            }
        });
        let Some(port) = port.and_then(|value| value.parse::<u16>().ok()).filter(|port| *port > 0) else {
            eprintln!("--headless requires --agent-api-port <1-65535>");
            std::process::exit(1);
        };
        cutscene_converter_lib::run_headless_agent_api(port);
        return;
    }
    cutscene_converter_lib::run()
}

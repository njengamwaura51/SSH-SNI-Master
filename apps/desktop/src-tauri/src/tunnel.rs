// One-click tunnel launcher.
//
// Spawns the user's locally-installed openvpn or v2ray-core binary with a
// snippet generated from a chosen bug-host. Snippets are written to
// $XDG_CONFIG_HOME/sni-hunter/tunnels/<sni>.{ovpn,json} at mode 0600 so the
// embedded UUIDs / keys aren't world-readable.
//
// Concurrency contract: at most one tunnel may run at a time. Launching a
// second is rejected with an error; the UI surfaces a "swap" confirmation
// that calls stop_tunnel() first.
//
// This module is intentionally thin — no per-protocol logic lives here. We
// treat the snippet text as opaque and let openvpn / v2ray do their own
// validation. Status events stream through the `tunnel:event` channel so
// the StatusBar chip can subscribe alongside scan events.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::Mutex;

#[derive(Default)]
pub struct TunnelState {
    pub current: Option<RunningTunnel>,
    /// Monotonically-increasing identity token. Bumped on every successful
    /// launch and stamped onto the spawned watcher task so a *late*
    /// Terminated event from a previously-stopped tunnel can't clear or
    /// mutate the now-current tunnel's state. Same guard applies to
    /// stop_tunnel: it captures the current generation, then refuses to
    /// fall through to take()+kill() if the generation has moved.
    pub generation: u64,
}

pub struct RunningTunnel {
    pub sni: String,
    pub kind: String,
    pub started_unix: i64,
    pub child: CommandChild,
    pub generation: u64,
    #[allow(dead_code)]
    pub stop: Arc<AtomicBool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchTunnelReq {
    pub sni: String,
    /// Either "openvpn" or "v2ray". Drives the binary name and arg style.
    pub kind: String,
    /// Full snippet text (.ovpn config, or v2ray JSON). Treated as opaque.
    pub snippet: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelStatus {
    pub running: bool,
    pub sni: Option<String>,
    pub kind: Option<String>,
    pub started_unix: Option<i64>,
    /// Path the snippet was written to (so the UI can show "config: …").
    pub config_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TunnelEvent {
    Started { sni: String, kind: String, config_path: String },
    Log { stream: String, line: String },
    Stopped { code: i32 },
    Error { message: String },
}

fn config_dir() -> PathBuf {
    dirs::config_dir()
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("sni-hunter")
        .join("tunnels")
}

fn safe_basename(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[tauri::command]
pub async fn launch_tunnel(
    app: AppHandle,
    state: State<'_, Arc<Mutex<TunnelState>>>,
    req: LaunchTunnelReq,
) -> Result<TunnelStatus, String> {
    // Hold the lock across the entire critical section (pre-check → file IO →
    // spawn → state install → generation bump). tokio's Mutex is async-aware
    // so this is safe to await under, and it makes the single-tunnel
    // guarantee atomic against concurrent launch_tunnel calls — the
    // architect's race #1.
    let mut g = state.lock().await;
    if g.current.is_some() {
        return Err(
            "a tunnel is already running; stop it before launching another".into(),
        );
    }

    let dir = config_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir tunnels: {e}"))?;
    let safe = safe_basename(&req.sni);
    let (path, bin, args): (PathBuf, &str, Vec<String>) = match req.kind.as_str() {
        "openvpn" => {
            let p = dir.join(format!("{safe}.ovpn"));
            (
                p.clone(),
                "openvpn",
                vec!["--config".into(), p.to_string_lossy().into()],
            )
        }
        "v2ray" => {
            let p = dir.join(format!("{safe}.json"));
            (
                p.clone(),
                "v2ray",
                vec!["run".into(), "-c".into(), p.to_string_lossy().into()],
            )
        }
        other => return Err(format!("unsupported tunnel kind: {other}")),
    };

    // Create the file with strict mode *before* writing the snippet so the
    // UUIDs/keys are never world-readable, even briefly. (write-then-chmod
    // leaves a window where the file is 0644 on umask=022 systems.)
    write_secret_file(&path, req.snippet.as_bytes())
        .map_err(|e| format!("write snippet: {e}"))?;

    let path_str = path.to_string_lossy().to_string();
    let cmd = app.shell().command(bin).args(args);
    let (mut rx, child) = cmd.spawn().map_err(|e| {
        format!(
            "failed to launch {bin}: {e}\nIs it installed?  Try: sudo apt install {bin}"
        )
    })?;
    let stop = Arc::new(AtomicBool::new(false));
    let started = chrono::Local::now().timestamp();
    g.generation = g.generation.wrapping_add(1);
    let my_gen = g.generation;
    g.current = Some(RunningTunnel {
        sni: req.sni.clone(),
        kind: req.kind.clone(),
        started_unix: started,
        child,
        generation: my_gen,
        stop: stop.clone(),
    });
    drop(g);

    let _ = app.emit(
        "tunnel:event",
        TunnelEvent::Started {
            sni: req.sni.clone(),
            kind: req.kind.clone(),
            config_path: path_str.clone(),
        },
    );

    let app_for_task = app.clone();
    let state_for_task = state.inner().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(b) => {
                    for line in String::from_utf8_lossy(&b).lines() {
                        let _ = app_for_task.emit(
                            "tunnel:event",
                            TunnelEvent::Log {
                                stream: "stdout".into(),
                                line: line.to_string(),
                            },
                        );
                    }
                }
                CommandEvent::Stderr(b) => {
                    for line in String::from_utf8_lossy(&b).lines() {
                        let _ = app_for_task.emit(
                            "tunnel:event",
                            TunnelEvent::Log {
                                stream: "stderr".into(),
                                line: line.to_string(),
                            },
                        );
                    }
                }
                CommandEvent::Terminated(payload) => {
                    // Identity guard (architect race #2): only clear the
                    // global slot if it still belongs to *us*. A late
                    // Terminated from a previously-stopped run must not
                    // wipe out a freshly-launched tunnel.
                    let mut g = state_for_task.lock().await;
                    let still_ours = g
                        .current
                        .as_ref()
                        .map(|rt| rt.generation == my_gen)
                        .unwrap_or(false);
                    if still_ours {
                        g.current = None;
                        let _ = app_for_task.emit(
                            "tunnel:event",
                            TunnelEvent::Stopped {
                                code: payload.code.unwrap_or(-1),
                            },
                        );
                    }
                    break;
                }
                CommandEvent::Error(e) => {
                    let _ = app_for_task
                        .emit("tunnel:event", TunnelEvent::Error { message: e });
                }
                _ => {}
            }
        }
    });

    Ok(TunnelStatus {
        running: true,
        sni: Some(req.sni),
        kind: Some(req.kind),
        started_unix: Some(started),
        config_path: Some(path_str),
    })
}

#[cfg(unix)]
fn write_secret_file(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    // .mode() only applies at creation; if the file already existed (e.g. a
    // re-launch of the same SNI) its prior mode is preserved. Force 0600 on
    // every write so stale snippet files containing UUIDs/keys can never be
    // left world- or group-readable.
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    f.write_all(bytes)
}
#[cfg(not(unix))]
fn write_secret_file(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

#[cfg(unix)]
fn send_term(pid: u32) -> bool {
    unsafe {
        let pid_i = pid as i32;
        if libc::kill(-pid_i, libc::SIGTERM) == 0 {
            return true;
        }
        libc::kill(pid_i, libc::SIGTERM) == 0
    }
}
#[cfg(not(unix))]
fn send_term(_pid: u32) -> bool {
    false
}

#[tauri::command]
pub async fn stop_tunnel(
    state: State<'_, Arc<Mutex<TunnelState>>>,
) -> Result<bool, String> {
    // Capture the identity of the tunnel we're stopping so we don't
    // accidentally kill a *successor* that started after we released the
    // lock (architect race #3).
    let (pid, stop, target_gen) = {
        let g = state.lock().await;
        match &g.current {
            Some(rt) => (rt.child.pid(), rt.stop.clone(), rt.generation),
            None => return Ok(false),
        }
    };
    stop.store(true, Ordering::Relaxed);
    let term_ok = send_term(pid);
    if term_ok {
        // Same SIGTERM-then-SIGKILL pattern as cancel_scan from Task #19.
        for _ in 0..40 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let g = state.lock().await;
            // Either the watcher cleared the slot (graceful exit) or a
            // brand-new tunnel has already taken its place — both mean
            // our target is gone, so we return without further force-kill.
            if g
                .current
                .as_ref()
                .map(|rt| rt.generation != target_gen)
                .unwrap_or(true)
            {
                return Ok(true);
            }
        }
    }
    // SIGKILL fallback: re-check identity under the lock; only force-kill
    // if the slot still holds the same generation we set out to stop.
    let mut g = state.lock().await;
    let same = g
        .current
        .as_ref()
        .map(|rt| rt.generation == target_gen)
        .unwrap_or(false);
    if same {
        if let Some(rt) = g.current.take() {
            let _ = rt.child.kill();
        }
    }
    Ok(true)
}

#[tauri::command]
pub async fn tunnel_status(
    state: State<'_, Arc<Mutex<TunnelState>>>,
) -> Result<TunnelStatus, String> {
    let g = state.lock().await;
    match &g.current {
        Some(rt) => Ok(TunnelStatus {
            running: true,
            sni: Some(rt.sni.clone()),
            kind: Some(rt.kind.clone()),
            started_unix: Some(rt.started_unix),
            config_path: None,
        }),
        None => Ok(TunnelStatus {
            running: false,
            sni: None,
            kind: None,
            started_unix: None,
            config_path: None,
        }),
    }
}

#[tauri::command]
pub async fn tunnel_client_available(name: String) -> Result<bool, String> {
    // PATH probe so the UI can show "Install openvpn…" when the binary is
    // missing instead of failing only on launch.
    let path = std::env::var_os("PATH").unwrap_or_default();
    for dir in std::env::split_paths(&path) {
        if dir.join(&name).exists() {
            return Ok(true);
        }
    }
    Ok(false)
}

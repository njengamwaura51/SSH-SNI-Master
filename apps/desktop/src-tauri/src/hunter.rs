// Process orchestration for the bundled `sni-hunter` sidecar.
//
// IMPORTANT — single source of truth contract with tools/sni-hunter.sh:
//
//   - `hunt` mode writes `<out_dir>/results.csv` (12-col pipe-delimited;
//     see task-6.md) and `<out_dir>/results.json`. It does NOT emit
//     per-host JSON on stdout. To stream live progress we tail the CSV.
//   - `check <sni> --json` emits ONE JSON object on stdout (collected
//     via `output()` in `check_one`).
//   - `tunnel-test` and `self-test` emit free-form text + JSON on stdout
//     (collected via `output()`).
//
// All probe/classifier/protocol logic lives in the bash hunter; this Rust
// module is strictly an orchestrator + line splitter + CSV-to-event
// adapter. No tier classification or protocol framing is reimplemented here.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio::sync::{oneshot, Mutex};

#[derive(Default)]
pub struct HunterState {
    pub running: HashMap<String, RunningChild>,
}

pub struct RunningChild {
    pub child: CommandChild,
    pub stop: Arc<AtomicBool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanOptions {
    pub carrier: String,
    pub corpus_path: Option<String>,
    pub out_dir: Option<String>,
    pub concurrency: u32,
    pub seed_only: bool,
    pub no_throughput: bool,
    pub verify_tunnel: bool,
    pub two_pass: bool,
    pub interactive: bool,
    pub prompt_charge: bool,
    pub auto_renew_promo: bool,
    pub no_auto_ussd: bool,
    pub accessibility_file: Option<String>,
    pub limit: Option<u32>,
    pub uuid_vmess: Option<String>,
    pub uuid_vless: Option<String>,
    pub target_ip: Option<String>,
    pub tunnel_domain: Option<String>,
    pub tunnel_port: Option<u16>,
    // Optional path overrides (forwarded to the hunter as env vars; the
    // hunter reads WS_PATH / VMESS_PATH / VLESS_PATH at startup).
    pub ws_path: Option<String>,
    pub vmess_path: Option<String>,
    pub vless_path: Option<String>,
    pub hunter_script_override: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ScanEvent {
    Started { scan_id: String, out_dir: String },
    Host { line: String },
    Log { stream: String, line: String },
    Done { code: i32 },
    Error { message: String },
}

fn default_out_dir() -> PathBuf {
    let base = dirs::data_local_dir()
        .or_else(dirs::data_dir)
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    base.join("sni-hunter").join("runs").join(stamp)
}

fn build_hunt_args(opts: &ScanOptions, out_dir: &str) -> Vec<String> {
    let mut a: Vec<String> = vec!["hunt".into()];
    if !opts.carrier.is_empty() {
        a.push("--carrier".into());
        a.push(opts.carrier.clone());
    }
    a.push("--out".into());
    a.push(out_dir.to_string());
    a.push("--concurrency".into());
    a.push(opts.concurrency.to_string());
    if opts.seed_only {
        a.push("--seed-only".into());
    }
    if opts.no_throughput {
        a.push("--no-throughput".into());
    }
    if opts.verify_tunnel {
        a.push("--verify-tunnel".into());
    }
    if opts.two_pass {
        a.push("--two-pass".into());
    }
    if opts.interactive {
        a.push("--interactive".into());
    }
    if opts.prompt_charge {
        a.push("--prompt-charge".into());
    }
    if opts.auto_renew_promo {
        a.push("--auto-renew-promo".into());
    }
    if opts.no_auto_ussd {
        a.push("--no-auto-ussd".into());
    }
    if let Some(p) = &opts.accessibility_file {
        if !p.is_empty() {
            a.push("--accessibility".into());
            a.push(p.clone());
        }
    }
    if let Some(n) = opts.limit {
        a.push("--limit".into());
        a.push(n.to_string());
    }
    if let Some(ip) = &opts.target_ip {
        if !ip.is_empty() {
            a.push("--target-ip".into());
            a.push(ip.clone());
        }
    }
    a
}

fn build_check_args(sni: &str, opts: &ScanOptions, json: bool) -> Vec<String> {
    let mut a: Vec<String> = vec!["check".into(), sni.to_string()];
    if !opts.carrier.is_empty() {
        a.push("--carrier".into());
        a.push(opts.carrier.clone());
    }
    if opts.no_throughput {
        a.push("--no-throughput".into());
    }
    if opts.verify_tunnel {
        a.push("--verify-tunnel".into());
    }
    if let Some(ip) = &opts.target_ip {
        if !ip.is_empty() {
            a.push("--target-ip".into());
            a.push(ip.clone());
        }
    }
    if json {
        a.push("--json".into());
    }
    a
}

fn build_tunnel_test_args(sni: Option<&str>, target_ip: Option<&str>) -> Vec<String> {
    let mut a: Vec<String> = vec!["tunnel-test".into()];
    if let Some(s) = sni {
        if !s.is_empty() {
            a.push("--sni".into());
            a.push(s.to_string());
        }
    }
    if let Some(ip) = target_ip {
        if !ip.is_empty() {
            a.push("--target-ip".into());
            a.push(ip.to_string());
        }
    }
    a
}

// Push every relevant config knob to the hunter via env. The hunter reads
// these at startup (DOMAIN/PORT/WS_PATH/VMESS_PATH/VLESS_PATH/UUID_*/CORPUS).
fn apply_env(opts: &ScanOptions) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = vec![];
    let mut push = |k: &str, v: &Option<String>| {
        if let Some(val) = v.as_ref().filter(|s| !s.is_empty()) {
            env.push((k.into(), val.clone()));
        }
    };
    push("UUID_VMESS", &opts.uuid_vmess);
    push("UUID_VLESS", &opts.uuid_vless);
    push("DOMAIN", &opts.tunnel_domain);
    push("WS_PATH", &opts.ws_path);
    push("VMESS_PATH", &opts.vmess_path);
    push("VLESS_PATH", &opts.vless_path);
    push("CORPUS", &opts.corpus_path);
    if let Some(p) = opts.tunnel_port {
        env.push(("PORT".into(), p.to_string()));
    }
    env
}

fn make_command<R: tauri::Runtime>(
    app: &AppHandle<R>,
    opts: &ScanOptions,
    args: Vec<String>,
) -> Result<tauri_plugin_shell::process::Command, String> {
    let shell = app.shell();
    let cmd = if let Some(path) = opts
        .hunter_script_override
        .as_ref()
        .filter(|s| !s.is_empty())
    {
        // Power-user override: run the script directly via bash, no sidecar.
        // Caller is trusted; this path is gated by the Settings dialog only.
        shell.command("bash").args({
            let mut v = vec![path.clone()];
            v.extend(args);
            v
        })
    } else {
        shell
            .sidecar("sni-hunter")
            .map_err(|e| format!("sidecar lookup failed: {e}"))?
            .args(args)
    };
    let env = apply_env(opts);
    let cmd = env.into_iter().fold(cmd, |c, (k, v)| c.env(k, v));
    Ok(cmd)
}

fn ensure_dir(p: &str) -> Result<(), String> {
    if p.is_empty() {
        return Ok(());
    }
    std::fs::create_dir_all(p).map_err(|e| format!("create out_dir: {e}"))
}

// Convert one 12-col pipe-delimited row into a HostRecord-shaped JSON
// string. Returns None for header rows or malformed lines.
fn csv_row_to_host_json(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parts: Vec<&str> = trimmed.split('|').collect();
    if parts.len() < 9 {
        return None;
    }
    // Header guard; the hunter doesn't currently write a header but be defensive.
    if parts[0].eq_ignore_ascii_case("tier") {
        return None;
    }
    let sni = parts[1];
    if sni.is_empty() {
        return None;
    }
    let tier = parts[0];
    let rtt: f64 = parts[2].parse().unwrap_or(0.0);
    let jit: f64 = parts[3].parse().unwrap_or(0.0);
    let mbps: f64 = parts[4].parse().unwrap_or(0.0);
    let bal: i64 = parts[5].parse().unwrap_or(0);
    let iplock = parts[6] == "1" || parts[6].eq_ignore_ascii_case("true");
    let ntype = parts[7];
    let family = parts[8];
    // Col 9 ("101") is the WS handshake marker; non-zero / non-empty means
    // the upgrade succeeded.
    let ws_ok = parts.get(9).map(|s| {
        let v = s.trim();
        !v.is_empty() && v != "0"
    }).unwrap_or(true);
    // Cols 10–11 (zero-indexed) are tunnel_ok / tunnel_bytes from Task #6.
    // Hunter writes "-1" for "not measured"; treat as null.
    let tunnel_ok = parts.get(10).and_then(|s| match s.trim() {
        "" | "-1" => None,
        "1" | "true" | "TRUE" | "PASS" | "pass" => Some(true),
        "0" | "false" | "FALSE" | "FAIL" | "fail" => Some(false),
        _ => None,
    });
    let tunnel_bytes = parts
        .get(11)
        .and_then(|s| s.trim().parse::<i64>().ok())
        .filter(|n| *n >= 0);
    // Cols 13/14 — promo bundle delta + name (Task #14). Hunter writes
    // "-1" for "not measured" and an empty string for "no promo".
    let promo_delta_kb = parts
        .get(12)
        .and_then(|s| s.trim().parse::<i64>().ok())
        .filter(|n| *n >= 0);
    let promo_name = parts
        .get(13)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != "-1");

    let v = json!({
        "schema_version": 2,
        "sni": sni,
        "tier": tier,
        "rtt_ms": rtt,
        "jitter_ms": jit,
        "mbps": mbps,
        "bal_delta_kb": bal,
        "ip_lock": iplock,
        "net_type": ntype,
        "family": family,
        "ws_handshake_ok": ws_ok,
        "tunnel_ok": tunnel_ok,
        "tunnel_bytes": tunnel_bytes,
        "promo_delta_kb": promo_delta_kb,
        "promo_name": promo_name,
        "raw": trimmed,
    });
    Some(v.to_string())
}

// Tails <out_dir>/results.csv until the stop flag flips, then does one
// final drain so trailing rows aren't lost. Polls every 400 ms. When the
// final drain completes we fire `done_tx` so the caller can deterministically
// know the tail has finished and no more Host events will arrive.
async fn tail_results(
    out_dir: PathBuf,
    app: AppHandle,
    stop: Arc<AtomicBool>,
    done_tx: oneshot::Sender<()>,
) {
    let path = out_dir.join("results.csv");
    let mut last_size: u64 = 0;
    let mut buf_carry = String::new();
    loop {
        let stop_now = stop.load(Ordering::Relaxed);
        if let Ok(meta) = tokio::fs::metadata(&path).await {
            let size = meta.len();
            if size < last_size {
                // File was truncated/rotated — start over.
                last_size = 0;
                buf_carry.clear();
            }
            if size > last_size {
                if let Ok(mut f) = tokio::fs::File::open(&path).await {
                    if f.seek(SeekFrom::Start(last_size)).await.is_ok() {
                        let mut s = String::new();
                        if let Ok(n) = f.read_to_string(&mut s).await {
                            last_size = last_size.saturating_add(n as u64);
                            let combined = format!("{}{}", buf_carry, s);
                            // Keep partial trailing line for next poll.
                            let (full, partial) = match combined.rsplit_once('\n') {
                                Some((f, p)) => (f.to_string(), p.to_string()),
                                None => (String::new(), combined.clone()),
                            };
                            buf_carry = partial;
                            for line in full.split('\n') {
                                if let Some(json) = csv_row_to_host_json(line) {
                                    let _ = app.emit(
                                        "scan:event",
                                        ScanEvent::Host { line: json },
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
        if stop_now {
            // Final drain on any remainder line that did get a newline.
            if !buf_carry.is_empty() {
                if let Some(json) = csv_row_to_host_json(&buf_carry) {
                    let _ = app
                        .emit("scan:event", ScanEvent::Host { line: json });
                }
            }
            let _ = done_tx.send(());
            break;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
}

// Splits a possibly-partial chunk into complete \n-terminated lines plus a
// carry-over string for the next chunk.
fn chunked_lines(buf: &mut String, chunk: &str) -> Vec<String> {
    buf.push_str(chunk);
    let mut out = vec![];
    while let Some(idx) = buf.find('\n') {
        let line: String = buf.drain(..=idx).collect();
        let trimmed = line.trim_end_matches(&['\n', '\r'][..]).to_string();
        if !trimmed.is_empty() {
            out.push(trimmed);
        }
    }
    out
}

#[tauri::command]
pub async fn start_scan(
    app: AppHandle,
    state: State<'_, Arc<Mutex<HunterState>>>,
    mut opts: ScanOptions,
) -> Result<String, String> {
    let scan_id = format!("scan-{}", chrono::Local::now().format("%Y%m%d-%H%M%S"));
    let out_dir = match opts.out_dir.as_ref() {
        Some(s) if !s.is_empty() => s.clone(),
        _ => default_out_dir().to_string_lossy().to_string(),
    };
    ensure_dir(&out_dir)?;
    opts.out_dir = Some(out_dir.clone());

    let args = build_hunt_args(&opts, &out_dir);
    tracing::info!(?args, "start_scan");

    let cmd = make_command(&app, &opts, args)?;
    let (mut rx, child) = cmd
        .spawn()
        .map_err(|e| format!("spawn hunter: {e}"))?;

    let stop = Arc::new(AtomicBool::new(false));

    {
        let mut guard = state.lock().await;
        guard.running.insert(
            scan_id.clone(),
            RunningChild {
                child,
                stop: stop.clone(),
            },
        );
    }

    let _ = app.emit(
        "scan:event",
        ScanEvent::Started {
            scan_id: scan_id.clone(),
            out_dir: out_dir.clone(),
        },
    );

    // Tail results.csv (live host events). The oneshot lets the event
    // task await final drain before emitting Done, so no Host event ever
    // arrives after Done.
    let tail_app = app.clone();
    let tail_stop = stop.clone();
    let tail_out = PathBuf::from(&out_dir);
    let (tail_done_tx, tail_done_rx) = oneshot::channel::<()>();
    tauri::async_runtime::spawn(async move {
        tail_results(tail_out, tail_app, tail_stop, tail_done_tx).await;
    });
    let mut tail_done_rx = Some(tail_done_rx);

    // Stream hunter stdout/stderr as log lines (everything from `hunt` mode
    // is human-oriented progress; per-host JSON is read from results.csv).
    let scan_id_for_task = scan_id.clone();
    let app_for_task = app.clone();
    let state_for_task = state.inner().clone();
    let stop_for_task = stop.clone();
    tauri::async_runtime::spawn(async move {
        let mut out_buf = String::new();
        let mut err_buf = String::new();
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => {
                    let chunk = String::from_utf8_lossy(&bytes).to_string();
                    for line in chunked_lines(&mut out_buf, &chunk) {
                        // If the script ever does emit a JSON line on stdout
                        // (e.g. self-test / check), forward it as a host
                        // event when it parses; otherwise treat as log.
                        let stripped = line.trim();
                        if stripped.starts_with('{') && stripped.ends_with('}')
                        {
                            let _ = app_for_task.emit(
                                "scan:event",
                                ScanEvent::Host {
                                    line: stripped.into(),
                                },
                            );
                        } else {
                            let _ = app_for_task.emit(
                                "scan:event",
                                ScanEvent::Log {
                                    stream: "stdout".into(),
                                    line,
                                },
                            );
                        }
                    }
                }
                CommandEvent::Stderr(bytes) => {
                    let chunk = String::from_utf8_lossy(&bytes).to_string();
                    for line in chunked_lines(&mut err_buf, &chunk) {
                        let _ = app_for_task.emit(
                            "scan:event",
                            ScanEvent::Log {
                                stream: "stderr".into(),
                                line,
                            },
                        );
                    }
                }
                CommandEvent::Terminated(payload) => {
                    // Flush any unterminated last line.
                    for buf in [&mut out_buf, &mut err_buf] {
                        let trimmed = buf.trim().to_string();
                        if !trimmed.is_empty() {
                            let _ = app_for_task.emit(
                                "scan:event",
                                ScanEvent::Log {
                                    stream: "stdout".into(),
                                    line: trimmed,
                                },
                            );
                            buf.clear();
                        }
                    }
                    // Tell the tailer to do a final drain and exit, then
                    // wait for it to confirm completion (capped at 5 s in
                    // case the file disappeared and the loop won't trip).
                    stop_for_task.store(true, Ordering::Relaxed);
                    if let Some(rx) = tail_done_rx.take() {
                        let _ = tokio::time::timeout(
                            Duration::from_secs(5),
                            rx,
                        )
                        .await;
                    }

                    let mut guard = state_for_task.lock().await;
                    guard.running.remove(&scan_id_for_task);
                    let _ = app_for_task.emit(
                        "scan:event",
                        ScanEvent::Done {
                            code: payload.code.unwrap_or(-1),
                        },
                    );
                    break;
                }
                CommandEvent::Error(e) => {
                    let _ = app_for_task.emit(
                        "scan:event",
                        ScanEvent::Error { message: e },
                    );
                }
                _ => {}
            }
        }
    });

    Ok(scan_id)
}

#[tauri::command]
pub async fn cancel_scan(
    state: State<'_, Arc<Mutex<HunterState>>>,
    scan_id: String,
) -> Result<bool, String> {
    let mut guard = state.lock().await;
    if let Some(rc) = guard.running.remove(&scan_id) {
        rc.stop.store(true, Ordering::Relaxed);
        // tauri-plugin-shell only exposes hard kill on the CommandChild;
        // the hunter's signal trap still runs because the OS delivers
        // SIGKILL to the bash process group head.
        rc.child.kill().map_err(|e| format!("kill: {e}"))?;
        return Ok(true);
    }
    Ok(false)
}

#[tauri::command]
pub async fn check_one(
    app: AppHandle,
    sni: String,
    opts: ScanOptions,
    json: bool,
) -> Result<String, String> {
    let args = build_check_args(&sni, &opts, json);
    let cmd = make_command(&app, &opts, args)?;
    let output = cmd
        .output()
        .await
        .map_err(|e| format!("check_one spawn: {e}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !output.status.success() && stdout.trim().is_empty() {
        return Err(format!(
            "check failed (exit {:?}): {}",
            output.status.code(),
            stderr
        ));
    }
    Ok(stdout)
}

#[tauri::command]
pub async fn tunnel_test(
    app: AppHandle,
    opts: ScanOptions,
    sni: Option<String>,
    target_ip: Option<String>,
) -> Result<String, String> {
    let args = build_tunnel_test_args(sni.as_deref(), target_ip.as_deref());
    let cmd = make_command(&app, &opts, args)?;
    let output = cmd
        .output()
        .await
        .map_err(|e| format!("tunnel_test spawn: {e}"))?;
    let mut combined = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !stderr.is_empty() {
        combined.push_str("\n--- stderr ---\n");
        combined.push_str(&stderr);
    }
    Ok(combined)
}

#[tauri::command]
pub async fn run_self_test(
    app: AppHandle,
    opts: ScanOptions,
) -> Result<String, String> {
    let cmd = make_command(&app, &opts, vec!["self-test".into()])?;
    let output = cmd
        .output()
        .await
        .map_err(|e| format!("self-test spawn: {e}"))?;
    let mut combined = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if !stderr.is_empty() {
        combined.push_str("\n--- stderr ---\n");
        combined.push_str(&stderr);
    }
    Ok(combined)
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunInfo {
    pub name: String,
    pub path: String,
    pub modified_unix: i64,
    pub size_bytes: u64,
}

#[tauri::command]
pub async fn list_runs() -> Result<Vec<RunInfo>, String> {
    let base = dirs::data_local_dir()
        .or_else(dirs::data_dir)
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("sni-hunter")
        .join("runs");
    if !base.exists() {
        return Ok(vec![]);
    }
    let mut runs = vec![];
    let mut rd = tokio::fs::read_dir(&base)
        .await
        .map_err(|e| format!("read runs dir: {e}"))?;
    while let Ok(Some(entry)) = rd.next_entry().await {
        let meta = match entry.metadata().await {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_dir() {
            continue;
        }
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        runs.push(RunInfo {
            name: entry.file_name().to_string_lossy().to_string(),
            path: entry.path().to_string_lossy().to_string(),
            modified_unix: modified,
            size_bytes: meta.len(),
        });
    }
    runs.sort_by(|a, b| b.modified_unix.cmp(&a.modified_unix));
    Ok(runs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_to_json_handles_full_12_col_row() {
        let s = "UNLIMITED_FREE|cdn.example.com|42|3.1|55.0|0|0|LTE|OTHER|101|1|26214400";
        let j = csv_row_to_host_json(s).unwrap();
        assert!(j.contains("\"sni\":\"cdn.example.com\""));
        assert!(j.contains("\"tier\":\"UNLIMITED_FREE\""));
        assert!(j.contains("\"tunnel_ok\":true"));
        assert!(j.contains("\"tunnel_bytes\":26214400"));
    }
    #[test]
    fn csv_to_json_promo_tier_with_dynamic_suffix() {
        let s =
            "PROMO_BUNDLE_DAILY_SOCIAL|m.example.com|55|4|22.0|0|100|LTE|META|101|-1|-1";
        let j = csv_row_to_host_json(s).unwrap();
        assert!(j.contains("\"tier\":\"PROMO_BUNDLE_DAILY_SOCIAL\""));
        assert!(j.contains("\"tunnel_ok\":null"));
        assert!(j.contains("\"tunnel_bytes\":null"));
    }
    #[test]
    fn csv_to_json_skips_header_and_empty_sni() {
        assert!(csv_row_to_host_json("tier|sni|rtt|jit|mbps|bal|iplock|ntype|family").is_none());
        assert!(csv_row_to_host_json("UNLIMITED_FREE||40|3|45|0|0|LTE|OTHER").is_none());
        assert!(csv_row_to_host_json("").is_none());
    }
    #[test]
    fn chunked_lines_handles_partials() {
        let mut buf = String::new();
        let a = chunked_lines(&mut buf, "hello\nwor");
        assert_eq!(a, vec!["hello".to_string()]);
        let b = chunked_lines(&mut buf, "ld\n");
        assert_eq!(b, vec!["world".to_string()]);
        assert!(buf.is_empty());
    }
}

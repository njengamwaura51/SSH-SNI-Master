// User config persistence at ~/.config/sni-hunter/config.json.
//
// JSON contract: camelCase to match the TS AppConfig type used by the
// frontend. Permissions are clamped to 0600 because UUIDs are credential-
// equivalent for the V2Ray endpoints.
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct AppConfig {
    pub tunnel_domain: String,
    pub tunnel_port: u16,
    pub ws_path: String,
    pub vmess_path: String,
    pub vless_path: String,
    pub uuid_vmess: String,
    pub uuid_vless: String,
    pub default_carrier: String,
    pub default_concurrency: u32,
    pub default_corpus_path: String,
    pub default_out_dir: String,
    pub verify_tunnel: bool,
    pub two_pass: bool,
    pub no_throughput: bool,
    pub prompt_charge: bool,
    pub auto_renew_promo: bool,
    pub accessibility_file: String,
    pub hunter_script_override: String,
    pub theme: String, // "dark" | "light" | "system"
}

impl AppConfig {
    pub fn defaults() -> Self {
        Self {
            tunnel_domain: "shopthelook.page".to_string(),
            tunnel_port: 443,
            ws_path: "/ws-bridge-x9k2".to_string(),
            vmess_path: "/vmess-x9k2".to_string(),
            vless_path: "/vless-x9k2".to_string(),
            uuid_vmess: String::new(),
            uuid_vless: String::new(),
            default_carrier: "auto".to_string(),
            default_concurrency: 30,
            default_corpus_path: String::new(),
            default_out_dir: String::new(),
            verify_tunnel: false,
            two_pass: false,
            no_throughput: false,
            prompt_charge: false,
            auto_renew_promo: false,
            accessibility_file: String::new(),
            hunter_script_override: String::new(),
            theme: "dark".to_string(),
        }
    }
}

fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("sni-hunter")
}
fn config_file() -> PathBuf {
    config_dir().join("config.json")
}

#[tauri::command]
pub async fn config_path() -> Result<String, String> {
    Ok(config_file().to_string_lossy().to_string())
}

#[tauri::command]
pub async fn load_config() -> Result<AppConfig, String> {
    let path = config_file();
    if !path.exists() {
        return Ok(AppConfig::defaults());
    }
    let raw = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| format!("read config: {e}"))?;
    let mut cfg: AppConfig =
        serde_json::from_str(&raw).map_err(|e| format!("parse config: {e}"))?;

    // Backfill blank / zero values so older configs upgrade cleanly.
    let d = AppConfig::defaults();
    if cfg.tunnel_domain.is_empty() {
        cfg.tunnel_domain = d.tunnel_domain;
    }
    if cfg.tunnel_port == 0 {
        cfg.tunnel_port = d.tunnel_port;
    }
    if cfg.ws_path.is_empty() {
        cfg.ws_path = d.ws_path;
    }
    if cfg.vmess_path.is_empty() {
        cfg.vmess_path = d.vmess_path;
    }
    if cfg.vless_path.is_empty() {
        cfg.vless_path = d.vless_path;
    }
    if cfg.default_carrier.is_empty() {
        cfg.default_carrier = d.default_carrier;
    }
    if cfg.default_concurrency == 0 {
        cfg.default_concurrency = d.default_concurrency;
    }
    if cfg.theme.is_empty() {
        cfg.theme = d.theme;
    }
    Ok(cfg)
}

#[cfg(unix)]
fn clamp_perms(path: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}
#[cfg(not(unix))]
fn clamp_perms(_path: &std::path::Path) -> std::io::Result<()> {
    Ok(())
}

#[tauri::command]
pub async fn save_config(cfg: AppConfig) -> Result<(), String> {
    let dir = config_dir();
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("create config dir: {e}"))?;
    let path = config_file();
    let body = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("serialize config: {e}"))?;
    tokio::fs::write(&path, body)
        .await
        .map_err(|e| format!("write config: {e}"))?;
    // Clamp to user-only readable since the file holds VMess/VLESS UUIDs.
    if let Err(e) = clamp_perms(&path) {
        tracing::warn!("could not clamp config perms: {e}");
    }
    Ok(())
}

// Result export helpers: CSV, JSON, and a ready-to-paste OpenVPN-over-WS
// snippet for the operator's chosen top host.
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

// IMPORTANT: keys here are snake_case to mirror the schema-v2 host record
// emitted by tools/sni-hunter.sh and the TypeScript HostRecord type. Do
// NOT add `rename_all = "camelCase"` — the frontend posts these rows
// directly without any mapping.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportRow {
    pub tier: String,
    pub sni: String,
    #[serde(default)]
    pub rtt_ms: f64,
    #[serde(default)]
    pub jitter_ms: f64,
    #[serde(default)]
    pub mbps: f64,
    #[serde(default)]
    pub bal_delta_kb: i64,
    #[serde(default)]
    pub ip_lock: bool,
    #[serde(default)]
    pub net_type: String,
    #[serde(default)]
    pub family: String,
    #[serde(default)]
    pub tunnel_ok: Option<bool>,
    #[serde(default)]
    pub tunnel_bytes: Option<i64>,
    #[serde(default)]
    pub promo_delta_kb: Option<i64>,
    #[serde(default)]
    pub promo_name: Option<String>,
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

#[tauri::command]
pub async fn export_results(
    rows: Vec<ExportRow>,
    format: String, // "csv" | "json"
    path: String,
) -> Result<String, String> {
    if path.is_empty() {
        return Err("path is empty".into());
    }
    let parent = PathBuf::from(&path);
    if let Some(dir) = parent.parent() {
        let _ = tokio::fs::create_dir_all(dir).await;
    }
    let body = match format.as_str() {
        "csv" => {
            let mut out = String::from(
                "tier,sni,rtt_ms,jitter_ms,mbps,bal_delta_kb,ip_lock,net_type,family,tunnel_ok,tunnel_bytes,promo_delta_kb,promo_name\n",
            );
            for r in &rows {
                out.push_str(&format!(
                    "{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
                    csv_escape(&r.tier),
                    csv_escape(&r.sni),
                    r.rtt_ms,
                    r.jitter_ms,
                    r.mbps,
                    r.bal_delta_kb,
                    if r.ip_lock { "true" } else { "false" },
                    csv_escape(&r.net_type),
                    csv_escape(&r.family),
                    r.tunnel_ok
                        .map(|b| if b { "true" } else { "false" })
                        .unwrap_or(""),
                    r.tunnel_bytes
                        .map(|n| n.to_string())
                        .unwrap_or_default(),
                    r.promo_delta_kb
                        .map(|n| n.to_string())
                        .unwrap_or_default(),
                    csv_escape(r.promo_name.as_deref().unwrap_or("")),
                ));
            }
            out
        }
        "json" => serde_json::to_string_pretty(&rows)
            .map_err(|e| format!("serialize json: {e}"))?,
        other => return Err(format!("unknown format: {other}")),
    };
    tokio::fs::write(&path, body)
        .await
        .map_err(|e| format!("write export: {e}"))?;
    Ok(path)
}

#[tauri::command]
pub async fn open_results_folder(app: tauri::AppHandle) -> Result<String, String> {
    use tauri_plugin_opener::OpenerExt;
    let base = dirs::data_local_dir()
        .or_else(dirs::data_dir)
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("sni-hunter")
        .join("runs");
    let _ = tokio::fs::create_dir_all(&base).await;
    let p = base.to_string_lossy().to_string();
    app.opener()
        .open_path(p.clone(), None::<&str>)
        .map_err(|e| format!("open path: {e}"))?;
    Ok(p)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OvpnSnippetReq {
    pub sni: String,
    pub tunnel_domain: String,
    pub tunnel_port: u16,
    pub ws_path: String,
    #[serde(default)]
    pub uuid_vmess: Option<String>,
    #[serde(default)]
    pub uuid_vless: Option<String>,
}

// Minimal copy-paste reference for an OpenVPN-over-WebSocket client that
// rides the picked SNI host. Real config still requires the user's CA/cert
// pair from the tunnel server; this is the route/SNI scaffold.
#[tauri::command]
pub async fn generate_ovpn_snippet(req: OvpnSnippetReq) -> Result<String, String> {
    let s = format!(
        r#"# --- sni-hunter generated snippet ---------------------------------------
# Bug-host  : {sni}
# Tunnel    : {domain}:{port}{ws}
# Generated : {when}
#
# This is the SNI / route scaffold only. Drop your CA, client cert, key,
# and tls-auth blocks below before connecting.
#
# OpenVPN over websocket (via stunnel + ws-ssh-bridge):
client
proto tcp-client
dev tun
remote {sni} {port}
remote-cert-tls server
http-proxy-option SNI {sni}
http-proxy-option CUSTOM-HEADER Host {domain}
http-proxy-option CUSTOM-HEADER Upgrade websocket
http-proxy-option CUSTOM-HEADER Connection Upgrade
http-proxy-option CUSTOM-HEADER Sec-WebSocket-Version 13
auth-nocache
nobind
persist-key
persist-tun
verb 3

# --- v2ray vmess example (jq-friendly):
# {{
#   "outbounds": [{{
#     "protocol": "vmess",
#     "settings": {{ "vnext": [{{ "address": "{sni}", "port": {port},
#       "users": [{{ "id": "{uvmess}", "alterId": 0, "security": "auto" }}] }}] }},
#     "streamSettings": {{ "network": "ws", "security": "tls",
#       "tlsSettings": {{ "serverName": "{sni}" }},
#       "wsSettings": {{ "path": "{ws}", "headers": {{ "Host": "{domain}" }} }} }}
#   }}]
# }}
"#,
        sni = req.sni,
        domain = req.tunnel_domain,
        port = req.tunnel_port,
        ws = req.ws_path,
        when = chrono::Local::now().format("%Y-%m-%d %H:%M:%S"),
        uvmess = req
            .uuid_vmess
            .clone()
            .unwrap_or_else(|| "<paste-vmess-uuid>".into()),
    );
    let _ = req.uuid_vless; // reserved; vless template can be added later
    Ok(s)
}

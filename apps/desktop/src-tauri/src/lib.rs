mod config;
mod exports;
mod hunter;
mod tunnel;

use std::sync::Arc;
use tokio::sync::Mutex;

use hunter::HunterState;
use tunnel::TunnelState;

pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let hunter_state = Arc::new(Mutex::new(HunterState::default()));
    let tunnel_state = Arc::new(Mutex::new(TunnelState::default()));

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_opener::init())
        .manage(hunter_state)
        .manage(tunnel_state)
        .invoke_handler(tauri::generate_handler![
            hunter::start_scan,
            hunter::cancel_scan,
            hunter::check_one,
            hunter::tunnel_test,
            hunter::run_self_test,
            hunter::list_runs,
            config::load_config,
            config::save_config,
            config::config_path,
            exports::export_results,
            exports::open_results_folder,
            exports::generate_ovpn_snippet,
            tunnel::launch_tunnel,
            tunnel::stop_tunnel,
            tunnel::tunnel_status,
            tunnel::tunnel_client_available,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

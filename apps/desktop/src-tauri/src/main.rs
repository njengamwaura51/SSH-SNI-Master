// Prevent the extra Windows console from popping up in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    sni_hunter_desktop_lib::run()
}

// Single source of truth for talking to the Rust side. All Tauri invokes
// go through here so components stay decoupled from the IPC layer.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AppConfig,
  HostRecord,
  RunInfo,
  ScanEvent,
  ScanOptions,
} from "../types";

// Rust serde uses snake_case for the discriminator; convert to camelCase here
// so the rest of the UI works with one tagged union shape.
type RustScanEvent =
  | { type: "started"; scan_id: string; out_dir: string }
  | { type: "host"; line: string }
  | { type: "log"; stream: string; line: string }
  | { type: "done"; code: number }
  | { type: "error"; message: string };

function normalizeEvent(raw: RustScanEvent): ScanEvent {
  if (raw.type === "log") {
    return {
      type: "log",
      stream: raw.stream === "stderr" ? "stderr" : "stdout",
      line: raw.line,
    };
  }
  return raw as ScanEvent;
}

export async function startScan(opts: ScanOptions): Promise<string> {
  return invoke<string>("start_scan", { opts });
}
export async function cancelScan(scanId: string): Promise<boolean> {
  return invoke<boolean>("cancel_scan", { scanId });
}
export async function checkOne(
  sni: string,
  opts: ScanOptions,
  json = true
): Promise<string> {
  return invoke<string>("check_one", { sni, opts, json });
}
export async function tunnelTest(
  opts: ScanOptions,
  sni?: string,
  targetIp?: string
): Promise<string> {
  return invoke<string>("tunnel_test", { opts, sni, targetIp });
}
export async function runSelfTest(opts: ScanOptions): Promise<string> {
  return invoke<string>("run_self_test", { opts });
}
export async function listRuns(): Promise<RunInfo[]> {
  return invoke<RunInfo[]>("list_runs");
}
export async function loadConfig(): Promise<AppConfig> {
  return invoke<AppConfig>("load_config");
}
export async function saveConfig(cfg: AppConfig): Promise<void> {
  return invoke("save_config", { cfg });
}
export async function configPath(): Promise<string> {
  return invoke<string>("config_path");
}
export async function exportResults(
  rows: HostRecord[],
  format: "csv" | "json",
  path: string
): Promise<string> {
  return invoke<string>("export_results", { rows, format, path });
}
export async function openResultsFolder(): Promise<string> {
  return invoke<string>("open_results_folder");
}
export interface OvpnSnippetReq {
  sni: string;
  tunnelDomain: string;
  tunnelPort: number;
  wsPath: string;
  uuidVmess?: string;
  uuidVless?: string;
}
export async function generateOvpnSnippet(
  req: OvpnSnippetReq
): Promise<string> {
  return invoke<string>("generate_ovpn_snippet", { req });
}

export async function subscribeScanEvents(
  cb: (e: ScanEvent) => void
): Promise<UnlistenFn> {
  return listen<RustScanEvent>("scan:event", (msg) => {
    try {
      cb(normalizeEvent(msg.payload));
    } catch (err) {
      console.error("scan event handler threw", err);
    }
  });
}

// Best-effort HostRecord parser. The hunter emits one JSON object per host
// line; older lines may have been CSV. Returns null on parse failure.
export function parseHostLine(line: string): HostRecord | null {
  const t = line.trim();
  if (!t.startsWith("{")) return null;
  try {
    const obj = JSON.parse(t) as Partial<HostRecord> & Record<string, unknown>;
    if (!obj.sni || !obj.tier) return null;
    return { schema_version: 2, raw: t, ...(obj as HostRecord) };
  } catch {
    return null;
  }
}

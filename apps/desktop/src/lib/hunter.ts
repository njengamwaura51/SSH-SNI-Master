// Single source of truth for talking to the Rust side. All Tauri invokes
// go through here so components stay decoupled from the IPC layer.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AppConfig,
  CheckResult,
  HostRecord,
  RunInfo,
  ScanEvent,
  ScanOptions,
  TunnelBreakdown,
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

// Adapter for the one-shot `check --json` schema (sni-hunter.sh:2230-2252).
// That payload uses `cert_subject` and `promo_bundle`, and embeds a nested
// `tunnel` object — different from the streaming results.csv schema. We
// project it onto a flat HostRecord so the drawer keeps a single rendering
// path while also returning the full nested breakdown for the per-endpoint
// table.
export function parseCheckJson(line: string): CheckResult | null {
  const t = line.trim();
  if (!t.startsWith("{")) return null;
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(t);
  } catch {
    return null;
  }
  if (!obj.sni) return null;

  // Failure payload from hunter (sni-hunter.sh:2216): no tier/rtt/etc., just
  // {passed:false, sni, reason, tunnel:null, recommended_action:"RETIRE"}.
  // Surface it as a CheckResult so the drawer can show the reason, but the
  // store will refuse to fold the (mostly empty) record into the hosts map.
  if (obj.passed === false) {
    return {
      record: {
        schema_version: 2,
        sni: String(obj.sni),
        tier: "PASS_NOTHRU",
        rtt_ms: 0,
        jitter_ms: 0,
        mbps: 0,
        bal_delta_kb: 0,
        ip_lock: false,
        net_type: "",
        family: "",
        ws_handshake_ok: false,
        recommended_action: obj.recommended_action as string | undefined,
      },
      tunnel: null,
      passed: false,
      reason: obj.reason as string | undefined,
      recommended_action: obj.recommended_action as string | undefined,
    };
  }

  const tunnel = (obj.tunnel ?? null) as TunnelBreakdown | null;
  const certSubject =
    (obj.cert_subject as string | undefined) ??
    (obj.cert_subj as string | undefined) ??
    undefined;
  const promoName =
    (obj.promo_bundle as string | undefined) ??
    (obj.promo_name as string | undefined) ??
    undefined;

  // Derive the flat tunnel_ok/tunnel_bytes used elsewhere from the nested
  // breakdown so the rest of the UI keeps working. We treat the SSH endpoint
  // as canonical (it's the OpenVPN-over-WS path most operators care about);
  // bytes_in is summed across endpoints that returned a non-zero value so
  // the headline number reflects total tunnel work done, not just SSH.
  let tunnelOk: boolean | null | undefined;
  let tunnelBytes: number | null | undefined;
  if (tunnel === null) {
    tunnelOk = null;
    tunnelBytes = null;
  } else if (typeof tunnel === "object") {
    if ((tunnel as TunnelBreakdown).error) {
      tunnelOk = null;
    } else {
      const ep = ["ssh", "vmess", "vless"] as const;
      let anyPass = false;
      let anyRan = false;
      let bytes = 0;
      for (const k of ep) {
        const r = (tunnel as TunnelBreakdown)[k];
        if (!r) continue;
        anyRan = true;
        if (String(r.status).toUpperCase() === "PASS") anyPass = true;
        if (typeof r.bytes_in === "number") bytes += r.bytes_in;
      }
      const blob = (tunnel as TunnelBreakdown).blob;
      if (blob && typeof blob.bytes_in === "number") bytes += blob.bytes_in;
      tunnelOk = anyRan ? anyPass : null;
      tunnelBytes = anyRan ? bytes : null;
    }
  }

  const record: HostRecord = {
    schema_version: 2,
    sni: String(obj.sni),
    tier: String(obj.tier ?? "PASS_NOTHRU"),
    rtt_ms: Number(obj.rtt_ms ?? 0),
    jitter_ms: Number(obj.jitter_ms ?? 0),
    mbps: Number(obj.mbps ?? 0),
    bal_delta_kb: Number(obj.bal_delta_kb ?? 0),
    ip_lock: Boolean(obj.ip_lock),
    net_type: String(obj.net_type ?? ""),
    family: String(obj.family ?? ""),
    ws_handshake_ok: Boolean(obj.passed ?? true),
    cert_subj: certSubject,
    url_probed: obj.url_probed as string | undefined,
    recommended_action: obj.recommended_action as string | undefined,
    tunnel_ok: tunnelOk,
    tunnel_bytes: tunnelBytes,
    promo_delta_kb:
      typeof obj.promo_delta_kb === "number"
        ? (obj.promo_delta_kb as number)
        : null,
    promo_name: promoName,
    raw: t,
  };
  return {
    record,
    tunnel: tunnel as TunnelBreakdown | null,
    cert_subject: certSubject,
    recommended_action: obj.recommended_action as string | undefined,
    passed: obj.passed === undefined ? true : Boolean(obj.passed),
    reason: obj.reason as string | undefined,
  };
}

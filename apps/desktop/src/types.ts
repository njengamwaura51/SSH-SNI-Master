// JSON schema v2 emitted (or synthesised from results.csv) by the hunter.
// Keep in sync with task-6.md and tools/sni-hunter.sh:902-934.
//
// Tier is intentionally `string`, not a fixed union, because the hunter
// generates dynamic suffixes (`APP_TUNNEL_<FAMILY>`, `PROMO_BUNDLE_<NAME>`)
// and merge-runs adds `NETWORK_TYPE_SPECIFIC`. The full known canonical
// set is exported as KNOWN_TIERS for filter chips, but unknown values must
// render through a fallback path — see theme.ts:tierMeta().
export type Tier = string;

export const KNOWN_TIERS: readonly string[] = [
  "UNLIMITED_FREE",
  "CAPPED_100M",
  "CAPPED_20M",
  "PASS_NOTHRU",
  "BUNDLE_REQUIRED",
  "IP_LOCKED",
  "THROTTLED",
  "NETWORK_TYPE_SPECIFIC",
  // Prefix-matched dynamic tiers; the constants below exist only so the
  // legend can display them when no concrete instance is in results yet.
  "APP_TUNNEL_*",
  "PROMO_BUNDLE_*",
];

export interface HostRecord {
  schema_version: number; // 2
  ts?: string;
  sni: string;
  tier: Tier;
  rtt_ms: number;
  jitter_ms: number;
  mbps: number;
  bal_delta_kb: number;
  ip_lock: boolean;
  net_type: string;
  family: string;
  ws_handshake_ok: boolean;
  cert_subj?: string;
  url_probed?: string;
  recommended_action?: string;
  // Tunnel verify (cols 11-12 in CSV; optional fields in JSON)
  tunnel_ok?: boolean | null;
  tunnel_bytes?: number | null;
  // Promo-bundle delta (Task #14)
  promo_delta_kb?: number | null;
  promo_name?: string;
  // MB left in the promo bundle right after this probe (Task #24). null when
  // no back-end could read it. The toolbar's promo countdown chip subscribes
  // to the *minimum* of these across the live result set.
  promo_mb_remaining?: number | null;
  carrier?: string;
  notes?: string;
  raw?: string;
}

export interface AppConfig {
  tunnelDomain: string;
  tunnelPort: number;
  wsPath: string;
  vmessPath: string;
  vlessPath: string;
  uuidVmess: string;
  uuidVless: string;
  defaultCarrier: string;
  defaultConcurrency: number;
  defaultCorpusPath: string;
  defaultOutDir: string;
  verifyTunnel: boolean;
  twoPass: boolean;
  noThroughput: boolean;
  promptCharge: boolean;
  autoRenewPromo: boolean;
  accessibilityFile: string;
  hunterScriptOverride: string;
  theme: "dark" | "light" | "system";
}

export interface ScanOptions {
  carrier: string;
  corpusPath?: string;
  outDir?: string;
  concurrency: number;
  seedOnly: boolean;
  noThroughput: boolean;
  verifyTunnel: boolean;
  twoPass: boolean;
  interactive: boolean;
  promptCharge: boolean;
  autoRenewPromo: boolean;
  noAutoUssd: boolean;
  accessibilityFile?: string;
  limit?: number;
  uuidVmess?: string;
  uuidVless?: string;
  targetIp?: string;
  tunnelDomain?: string;
  tunnelPort?: number;
  wsPath?: string;
  vmessPath?: string;
  vlessPath?: string;
  hunterScriptOverride?: string;
}

export type ScanEvent =
  | { type: "started"; scan_id: string; out_dir: string }
  | { type: "host"; line: string }
  | { type: "log"; stream: "stdout" | "stderr"; line: string }
  | { type: "done"; code: number }
  | { type: "error"; message: string };

// ---------------------------------------------------------------------------
// `check --json` deep-probe schema (sni-hunter.sh:2230-2252).
// This is *different* from the streaming HostRecord above — it's emitted by a
// one-shot deep probe, and it includes a nested `tunnel` block when
// `--verify-tunnel` is on. Field names from the bash side use `cert_subject`
// and `promo_bundle`, which the adapter in lib/hunter.ts maps onto our
// flat HostRecord conventions (`cert_subj`, `promo_name`).
export interface TunnelEndpointResult {
  status: string; // "PASS" | "FAIL" | "SKIP" | other
  mode?: string;
  bytes_in?: number;
  bytes_out?: number;
  elapsed_ms?: number;
  error?: string;
  reason?: string;
  raw?: string;
}

export interface TunnelBlobResult {
  status: string;
  bytes_in: number;
  mbps: number;
}

export interface TunnelBreakdown {
  ssh?: TunnelEndpointResult;
  vmess?: TunnelEndpointResult;
  vless?: TunnelEndpointResult;
  blob?: TunnelBlobResult;
  // When python3 is missing on the host, hunter emits {error, hint}.
  error?: string;
  hint?: string;
}

// Result of `check <sni> --json [--verify-tunnel]`. The `record` field is a
// flat HostRecord projected onto the same shape used by the streaming path
// so that DetailDrawer/StatusBar/etc. can keep one display contract.
export interface CheckResult {
  record: HostRecord;
  tunnel: TunnelBreakdown | null;
  cert_subject?: string;
  recommended_action?: string;
  // True when the deep probe ran but the host failed entirely (no rec).
  passed?: boolean;
  reason?: string;
}

export interface RunInfo {
  name: string;
  path: string;
  modifiedUnix: number;
  sizeBytes: number;
}

// One-click tunnel launcher (Task #24). Mirrors the Rust tunnel.rs structs.
// Currently supports openvpn (.ovpn snippet) and v2ray (JSON config). The
// snippet text is treated opaquely on the Rust side — keep it generated by
// generate_ovpn_snippet so we don't drift the format.
export type TunnelKind = "openvpn" | "v2ray";

export interface LaunchTunnelReq {
  sni: string;
  kind: TunnelKind;
  snippet: string;
}

export interface TunnelStatus {
  running: boolean;
  sni?: string | null;
  kind?: TunnelKind | null;
  startedUnix?: number | null;
  configPath?: string | null;
}

export type TunnelEvent =
  | { type: "started"; sni: string; kind: TunnelKind; config_path: string }
  | { type: "log"; stream: "stdout" | "stderr"; line: string }
  | { type: "stopped"; code: number }
  | { type: "error"; message: string };

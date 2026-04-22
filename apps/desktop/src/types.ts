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

export interface RunInfo {
  name: string;
  path: string;
  modifiedUnix: number;
  sizeBytes: number;
}

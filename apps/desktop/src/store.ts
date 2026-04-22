import { create } from "zustand";
import type {
  AppConfig,
  CheckResult,
  HostRecord,
  ScanOptions,
  TunnelStatus,
} from "./types";

export interface LogLine {
  ts: number;
  stream: "stdout" | "stderr" | "info";
  line: string;
}

export type ThemeMode = "dark" | "light";

export interface ScanState {
  // Persisted config
  config: AppConfig | null;
  setConfig: (c: AppConfig) => void;

  // Theme — separate from config so the toggle is instant; the chosen
  // value is mirrored back into config on next save.
  theme: ThemeMode;
  setTheme: (t: ThemeMode) => void;

  // Live scan state
  scanId: string | null;
  outDir: string | null;
  isRunning: boolean;
  startedAt: number | null;
  endedAt: number | null;
  exitCode: number | null;

  // Results — keyed by SNI so re-probes update in place
  hosts: Map<string, HostRecord>;
  hostOrder: string[];

  // Cache of `check <sni> --json --verify-tunnel` deep-probe results,
  // keyed by SNI. Populated when the user opens the detail drawer for a
  // row (one probe per row per session, unless explicitly re-run).
  deepChecks: Map<string, CheckResult>;
  deepCheckPending: Set<string>;
  setDeepCheck: (sni: string, res: CheckResult) => void;
  setDeepCheckPending: (sni: string, pending: boolean) => void;

  // Logs (capped to 5000)
  logs: LogLine[];

  // Tunnel launcher (Task #24). Mirrors what the Rust side knows; refreshed
  // from tunnelStatus() on mount and on every tunnel:event.
  tunnel: TunnelStatus;
  setTunnel: (t: TunnelStatus) => void;

  // UI
  selectedSni: string | null;
  filterText: string;
  tierFilter: string | null;
  showLogs: boolean;
  showSettings: boolean;
  showTunnelTest: boolean;
  scanOptions: ScanOptions;

  // Actions
  setSelected: (s: string | null) => void;
  setFilter: (t: string) => void;
  setTierFilter: (t: string | null) => void;
  setShowLogs: (b: boolean) => void;
  setShowSettings: (b: boolean) => void;
  setShowTunnelTest: (b: boolean) => void;
  setScanOptions: (o: Partial<ScanOptions>) => void;

  startedScan: (scanId: string, outDir: string) => void;
  endedScan: (code: number) => void;
  pushHost: (rec: HostRecord) => void;
  pushLog: (l: LogLine) => void;
  clearResults: () => void;
}

export const defaultScanOptions: ScanOptions = {
  carrier: "auto",
  concurrency: 30,
  seedOnly: false,
  noThroughput: false,
  verifyTunnel: false,
  twoPass: false,
  interactive: false,
  promptCharge: false,
  autoRenewPromo: false,
  noAutoUssd: false,
};

export const useStore = create<ScanState>((set) => ({
  config: null,
  setConfig: (c) => set({ config: c }),

  theme: "dark",
  setTheme: (t) => {
    set({ theme: t });
    if (typeof document !== "undefined") {
      document.documentElement.classList.toggle("light", t === "light");
      document.documentElement.classList.toggle("dark", t === "dark");
    }
  },

  scanId: null,
  outDir: null,
  isRunning: false,
  startedAt: null,
  endedAt: null,
  exitCode: null,

  hosts: new Map(),
  hostOrder: [],
  deepChecks: new Map(),
  deepCheckPending: new Set(),
  setDeepCheck: (sni, res) =>
    set((s) => {
      const dc = new Map(s.deepChecks);
      dc.set(sni, res);
      const pend = new Set(s.deepCheckPending);
      pend.delete(sni);
      // Only fold the deep result back into the flat host map when the
      // hunter actually produced a full record. The check --json failure
      // payload (`{passed:false, sni, reason, tunnel:null, ...}`) has no
      // tier/rtt/mbps and would otherwise overwrite a previously valid
      // streaming row with synthetic defaults.
      if (res.passed === false) {
        return { deepChecks: dc, deepCheckPending: pend };
      }
      const hosts = new Map(s.hosts);
      hosts.set(sni, res.record);
      return { deepChecks: dc, deepCheckPending: pend, hosts };
    }),
  setDeepCheckPending: (sni, pending) =>
    set((s) => {
      const pend = new Set(s.deepCheckPending);
      if (pending) pend.add(sni);
      else pend.delete(sni);
      return { deepCheckPending: pend };
    }),

  logs: [],

  tunnel: { running: false },
  setTunnel: (t) => set({ tunnel: t }),

  selectedSni: null,
  filterText: "",
  tierFilter: null,
  showLogs: false,
  showSettings: false,
  showTunnelTest: false,
  scanOptions: defaultScanOptions,

  setSelected: (s) => set({ selectedSni: s }),
  setFilter: (t) => set({ filterText: t }),
  setTierFilter: (t) => set({ tierFilter: t }),
  setShowLogs: (b) => set({ showLogs: b }),
  setShowSettings: (b) => set({ showSettings: b }),
  setShowTunnelTest: (b) => set({ showTunnelTest: b }),
  setScanOptions: (o) =>
    set((s) => ({ scanOptions: { ...s.scanOptions, ...o } })),

  startedScan: (scanId, outDir) =>
    set({
      scanId,
      outDir,
      isRunning: true,
      startedAt: Date.now(),
      endedAt: null,
      exitCode: null,
      hosts: new Map(),
      hostOrder: [],
      deepChecks: new Map(),
      deepCheckPending: new Set(),
      logs: [],
    }),

  endedScan: (code) =>
    set({ isRunning: false, endedAt: Date.now(), exitCode: code }),

  pushHost: (rec) =>
    set((s) => {
      const hosts = new Map(s.hosts);
      const isNew = !hosts.has(rec.sni);
      hosts.set(rec.sni, rec);
      const hostOrder = isNew ? [...s.hostOrder, rec.sni] : s.hostOrder;
      return { hosts, hostOrder };
    }),

  pushLog: (l) =>
    set((s) => {
      const next = s.logs.length >= 5000 ? s.logs.slice(-4500) : s.logs;
      return { logs: [...next, l] };
    }),

  clearResults: () =>
    set({
      hosts: new Map(),
      hostOrder: [],
      deepChecks: new Map(),
      deepCheckPending: new Set(),
      logs: [],
      selectedSni: null,
      exitCode: null,
      endedAt: null,
    }),
}));

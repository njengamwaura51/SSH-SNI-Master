import { create } from "zustand";
import type { AppConfig, HostRecord, ScanOptions } from "./types";

export interface LogLine {
  ts: number;
  stream: "stdout" | "stderr" | "info";
  line: string;
}

export interface ScanState {
  // Persisted config
  config: AppConfig | null;
  setConfig: (c: AppConfig) => void;

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

  // Logs (capped to 5000)
  logs: LogLine[];

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

  scanId: null,
  outDir: null,
  isRunning: false,
  startedAt: null,
  endedAt: null,
  exitCode: null,

  hosts: new Map(),
  hostOrder: [],
  logs: [],

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
      logs: [],
      selectedSni: null,
      exitCode: null,
      endedAt: null,
    }),
}));

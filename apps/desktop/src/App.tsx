import { useEffect, useRef } from "react";
import { Toolbar } from "./components/Toolbar";
import { ScanControls } from "./components/ScanControls";
import { ResultsTable } from "./components/ResultsTable";
import { DetailDrawer } from "./components/DetailDrawer";
import { StatusBar } from "./components/StatusBar";
import { LogViewer } from "./components/LogViewer";
import { SettingsDialog } from "./components/SettingsDialog";
import { AboutDialog } from "./components/AboutDialog";
import { TunnelTestPanel } from "./components/TunnelTestPanel";
import { useStore, defaultScanOptions } from "./store";
import {
  cancelScan,
  loadConfig,
  parseHostLine,
  saveConfig,
  startScan,
  subscribeScanEvents,
  subscribeTunnelEvents,
  tunnelStatus,
} from "./lib/hunter";

export default function App() {
  const {
    setConfig,
    config,
    scanOptions,
    showLogs,
    showSettings,
    showTunnelTest,
    setShowSettings,
    setShowTunnelTest,
    setShowAbout,
    showAbout,
    setShowLogs,
    setScanOptions,
    setTheme,
    isRunning,
    startedScan,
    endedScan,
    pushHost,
    pushLog,
    setTunnel,
  } = useStore();
  const hydratedRef = useRef(false);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let unlistenTunnel: (() => void) | undefined;
    (async () => {
      try {
        const cfg = await loadConfig();
        setConfig(cfg);
        // Apply persisted theme immediately so light-mode users don't see
        // a flash of dark.
        if (cfg.theme === "light" || cfg.theme === "dark") {
          setTheme(cfg.theme);
        }
        // Hydrate scan options from config defaults
        setScanOptions({
          ...defaultScanOptions,
          carrier: cfg.defaultCarrier || "auto",
          concurrency: cfg.defaultConcurrency || 30,
          corpusPath: cfg.defaultCorpusPath || undefined,
          outDir: cfg.defaultOutDir || undefined,
          verifyTunnel: cfg.verifyTunnel,
          twoPass: cfg.twoPass,
          noThroughput: cfg.noThroughput,
          promptCharge: cfg.promptCharge,
          autoRenewPromo: cfg.autoRenewPromo,
          accessibilityFile: cfg.accessibilityFile || undefined,
          uuidVmess: cfg.uuidVmess || undefined,
          uuidVless: cfg.uuidVless || undefined,
          tunnelDomain: cfg.tunnelDomain || undefined,
          tunnelPort: cfg.tunnelPort || undefined,
          // Path overrides: empty string in config means "use the
          // hunter's compiled-in default", so don't propagate it.
          wsPath: cfg.wsPath || undefined,
          vmessPath: cfg.vmessPath || undefined,
          vlessPath: cfg.vlessPath || undefined,
          hunterScriptOverride: cfg.hunterScriptOverride || undefined,
        });
        // From now on, scan-form changes are auto-persisted (debounced).
        hydratedRef.current = true;
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `failed to load config: ${String(e)}`,
        });
      }

      try {
        unlisten = await subscribeScanEvents((e) => {
          switch (e.type) {
            case "started":
              startedScan(e.scan_id, e.out_dir);
              pushLog({
                ts: Date.now(),
                stream: "info",
                line: `scan ${e.scan_id} → ${e.out_dir}`,
              });
              break;
            case "host": {
              const rec = parseHostLine(e.line);
              if (rec) pushHost(rec);
              else
                pushLog({
                  ts: Date.now(),
                  stream: "stdout",
                  line: e.line,
                });
              break;
            }
            case "log":
              pushLog({ ts: Date.now(), stream: e.stream, line: e.line });
              break;
            case "done":
              endedScan(e.code);
              pushLog({
                ts: Date.now(),
                stream: "info",
                line: `scan finished (exit ${e.code})`,
              });
              break;
            case "error":
              pushLog({
                ts: Date.now(),
                stream: "stderr",
                line: `error: ${e.message}`,
              });
              break;
          }
        });
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `event subscribe failed: ${String(e)}`,
        });
      }

      // Tunnel launcher (Task #24): hydrate current state and subscribe.
      try {
        setTunnel(await tunnelStatus());
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `tunnel_status failed: ${String(e)}`,
        });
      }
      try {
        unlistenTunnel = await subscribeTunnelEvents((e) => {
          switch (e.type) {
            case "started":
              setTunnel({
                running: true,
                sni: e.sni,
                kind: e.kind,
                startedUnix: Math.floor(Date.now() / 1000),
                configPath: e.config_path,
              });
              pushLog({
                ts: Date.now(),
                stream: "info",
                line: `tunnel up via ${e.sni} (${e.kind})`,
              });
              break;
            case "stopped":
              setTunnel({ running: false });
              pushLog({
                ts: Date.now(),
                stream: "info",
                line: `tunnel stopped (exit ${e.code})`,
              });
              break;
            case "log":
              pushLog({
                ts: Date.now(),
                stream: e.stream,
                line: `[tunnel] ${e.line}`,
              });
              break;
            case "error":
              pushLog({
                ts: Date.now(),
                stream: "stderr",
                line: `tunnel error: ${e.message}`,
              });
              break;
          }
        });
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `tunnel subscribe failed: ${String(e)}`,
        });
      }
    })();
    return () => {
      if (unlisten) unlisten();
      if (unlistenTunnel) unlistenTunnel();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Auto-persist scan-form state to ~/.config/sni-hunter/config.json so the
  // operator's last carrier/concurrency/toggles are remembered across
  // launches (spec: "Form state persists between launches"). Debounced
  // 600ms; pauses while a scan is running so we don't spam disk.
  useEffect(() => {
    if (!hydratedRef.current || !config || isRunning) return;
    const id = setTimeout(() => {
      const merged = {
        ...config,
        defaultCarrier: scanOptions.carrier,
        defaultConcurrency: scanOptions.concurrency,
        defaultCorpusPath: scanOptions.corpusPath || "",
        defaultOutDir: scanOptions.outDir || "",
        verifyTunnel: scanOptions.verifyTunnel,
        twoPass: scanOptions.twoPass,
        noThroughput: scanOptions.noThroughput,
        promptCharge: scanOptions.promptCharge,
        autoRenewPromo: scanOptions.autoRenewPromo,
        accessibilityFile: scanOptions.accessibilityFile || "",
        uuidVmess: scanOptions.uuidVmess || config.uuidVmess,
        uuidVless: scanOptions.uuidVless || config.uuidVless,
      };
      saveConfig(merged)
        .then(() => setConfig(merged))
        .catch((e) =>
          pushLog({
            ts: Date.now(),
            stream: "stderr",
            line: `auto-save failed: ${String(e)}`,
          })
        );
    }, 600);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scanOptions, isRunning]);

  // Global keyboard shortcuts (Task #24). We attach at the document level
  // so the operator can drive the app without touching the mouse during a
  // long scan. We deliberately ignore key events fired from inside text
  // inputs / textareas (e.g. the corpus filter or settings fields) so
  // typing "?" into a search box doesn't flash the About dialog.
  const { scanId } = useStore.getState();
  useEffect(() => {
    function isTypingTarget(t: EventTarget | null): boolean {
      if (!(t instanceof HTMLElement)) return false;
      const tag = t.tagName;
      return (
        tag === "INPUT" ||
        tag === "TEXTAREA" ||
        tag === "SELECT" ||
        t.isContentEditable
      );
    }
    function onKey(e: KeyboardEvent) {
      // All shortcuts (incl. Esc) are suppressed while focus is in a
      // text-entry control. Each dialog already mounts its own
      // close-on-overlay handler and renders an explicit X button, so
      // dismissing via mouse or focusing-out + Esc still works — we just
      // don't yank a Settings field out from under a typing user.
      if (isTypingTarget(e.target)) return;
      if (e.key === "Escape") {
        const s = useStore.getState();
        if (s.showAbout) {
          s.setShowAbout(false);
          e.preventDefault();
          return;
        }
        if (s.showSettings) {
          s.setShowSettings(false);
          e.preventDefault();
          return;
        }
        if (s.showTunnelTest) {
          s.setShowTunnelTest(false);
          e.preventDefault();
          return;
        }
      }
      const ctrl = e.ctrlKey || e.metaKey;
      if (ctrl && e.key.toLowerCase() === "r") {
        // Ctrl/Cmd-R: start scan, or cancel if one is already running.
        // We swallow the default (browser/Tauri reload) to avoid losing
        // in-flight scan state.
        e.preventDefault();
        const s = useStore.getState();
        if (s.isRunning && s.scanId) {
          cancelScan(s.scanId).catch(() => {});
        } else {
          startScan(s.scanOptions).catch(() => {});
        }
        return;
      }
      if (ctrl && e.key === ",") {
        e.preventDefault();
        useStore.getState().setShowSettings(true);
        return;
      }
      if (ctrl && e.key.toLowerCase() === "l") {
        e.preventDefault();
        const s = useStore.getState();
        s.setShowLogs(!s.showLogs);
        return;
      }
      if (e.key === "?" || (e.shiftKey && e.key === "/")) {
        e.preventDefault();
        useStore.getState().setShowAbout(true);
        return;
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // scanId in deps so we get a fresh closure if React DevTools tries to
    // be clever; the effect itself reads everything via getState().
  }, [scanId]);

  return (
    <div className="flex h-screen flex-col bg-surface text-on-surface">
      <Toolbar />
      <div className="flex flex-1 min-h-0 overflow-hidden">
        <aside className="w-[320px] shrink-0 border-r border-outline-variant bg-surface-2 overflow-y-auto">
          <ScanControls />
        </aside>
        <main className="flex-1 min-w-0 flex flex-col overflow-hidden">
          <ResultsTable />
          {showLogs && <LogViewer />}
        </main>
        <aside className="w-[380px] shrink-0 border-l border-outline-variant bg-surface-2 overflow-y-auto">
          <DetailDrawer />
        </aside>
      </div>
      <StatusBar />
      {showSettings && (
        <SettingsDialog onClose={() => setShowSettings(false)} />
      )}
      {showTunnelTest && (
        <TunnelTestPanel onClose={() => setShowTunnelTest(false)} />
      )}
      {showAbout && <AboutDialog onClose={() => setShowAbout(false)} />}
    </div>
  );
}

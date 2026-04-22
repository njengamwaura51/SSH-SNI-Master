import {
  FolderOpen,
  Moon,
  PlayCircle,
  Settings,
  StopCircle,
  Sun,
  Terminal,
  TestTube,
} from "lucide-react";
import { useStore } from "../store";
import { saveConfig } from "../lib/hunter";
import {
  cancelScan,
  openResultsFolder,
  runSelfTest,
  startScan,
} from "../lib/hunter";

export function Toolbar() {
  const {
    isRunning,
    scanId,
    scanOptions,
    showLogs,
    setShowLogs,
    setShowSettings,
    setShowTunnelTest,
    pushLog,
    theme,
    setTheme,
    config,
    setConfig,
  } = useStore();

  async function onToggleTheme() {
    const next = theme === "dark" ? "light" : "dark";
    setTheme(next);
    if (config) {
      const updated = { ...config, theme: next };
      setConfig(updated);
      try {
        await saveConfig(updated);
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `theme persist failed: ${String(e)}`,
        });
      }
    }
  }

  async function onStart() {
    try {
      await startScan(scanOptions);
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `start_scan failed: ${String(e)}`,
      });
    }
  }
  async function onStop() {
    if (!scanId) return;
    try {
      await cancelScan(scanId);
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `cancel failed: ${String(e)}`,
      });
    }
  }
  async function onSelfTest() {
    pushLog({ ts: Date.now(), stream: "info", line: "running self-test…" });
    try {
      const out = await runSelfTest(scanOptions);
      out
        .split(/\r?\n/)
        .filter(Boolean)
        .forEach((line) =>
          pushLog({ ts: Date.now(), stream: "stdout", line })
        );
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `self-test failed: ${String(e)}`,
      });
    }
    setShowLogs(true);
  }
  async function onOpenFolder() {
    try {
      await openResultsFolder();
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `open folder failed: ${String(e)}`,
      });
    }
  }

  return (
    <header className="flex items-center gap-2 px-3 py-2 border-b border-outline-variant bg-surface-2 shadow-elev1">
      <div className="flex items-center gap-2 mr-2">
        <div
          className="w-7 h-7 rounded-lg bg-primary/15 border border-primary/40 grid place-items-center"
          aria-hidden
        >
          <span className="text-primary font-semibold text-sm">SH</span>
        </div>
        <div className="leading-tight">
          <div className="text-sm font-semibold tracking-tight">
            SNI Hunter
          </div>
          <div className="text-[11px] text-on-surface-variant">
            tunnel bug-host scanner
          </div>
        </div>
      </div>

      <div className="flex-1" />

      {!isRunning ? (
        <button className="btn-primary" onClick={onStart}>
          <PlayCircle size={16} /> Start scan
        </button>
      ) : (
        <button className="btn-danger" onClick={onStop}>
          <StopCircle size={16} /> Stop
        </button>
      )}

      <button
        className="btn"
        onClick={() => setShowTunnelTest(true)}
        title="Run tunnel byte-flow test"
      >
        <TestTube size={16} /> Tunnel test
      </button>

      <button
        className="btn-ghost"
        onClick={() => setShowLogs(!showLogs)}
        aria-pressed={showLogs}
        title="Toggle log viewer"
      >
        <Terminal size={16} /> Logs
      </button>

      <button className="btn-ghost" onClick={onSelfTest} title="Run self-test">
        Self-test
      </button>

      <button
        className="btn-ghost"
        onClick={onOpenFolder}
        title="Open results folder"
      >
        <FolderOpen size={16} /> Runs
      </button>

      <button
        className="btn-ghost"
        onClick={onToggleTheme}
        title={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
        aria-label="Toggle theme"
      >
        {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}
      </button>

      <button
        className="btn-ghost"
        onClick={() => setShowSettings(true)}
        title="Settings"
      >
        <Settings size={16} />
      </button>
    </header>
  );
}

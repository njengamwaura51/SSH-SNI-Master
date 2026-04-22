import { useEffect, useMemo, useState } from "react";
import { useStore } from "../store";
import { tierMeta, tierRank } from "../theme";
import { fmtKb } from "../lib/format";

export function StatusBar() {
  const {
    hosts,
    hostOrder,
    isRunning,
    startedAt,
    endedAt,
    exitCode,
    outDir,
    scanOptions,
  } = useStore();

  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!isRunning) return;
    const id = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(id);
  }, [isRunning]);

  const elapsedMs = startedAt
    ? (isRunning ? now : endedAt || now) - startedAt
    : 0;
  const sec = Math.max(0, Math.floor(elapsedMs / 1000));
  const elapsed = `${Math.floor(sec / 60)}m ${String(sec % 60).padStart(2, "0")}s`;

  // Best tier seen so far + cumulative balance delta + last-known radio.
  const { bestTier, totalBalKb, currentRadio } = useMemo(() => {
    let best: string | null = null;
    let bestRk = 99;
    let total = 0;
    let radio: string | null = null;
    for (const sni of hostOrder) {
      const r = hosts.get(sni);
      if (!r) continue;
      const rk = tierRank(r.tier);
      if (rk < bestRk) {
        bestRk = rk;
        best = r.tier;
      }
      total += r.bal_delta_kb || 0;
      if (r.net_type) radio = r.net_type;
    }
    return { bestTier: best, totalBalKb: total, currentRadio: radio };
  }, [hosts, hostOrder]);

  // Hosts/sec — only meaningful while running or just-finished.
  const elapsedSec = elapsedMs / 1000;
  const rate =
    elapsedSec > 0.5 ? (hosts.size / elapsedSec).toFixed(1) : "—";

  // ETA — known only if the scan was capped via --limit; otherwise we
  // can't estimate the corpus size from inside the GUI.
  let eta: string | null = null;
  if (
    isRunning &&
    scanOptions.limit &&
    scanOptions.limit > hosts.size &&
    Number(rate) > 0
  ) {
    const remaining = scanOptions.limit - hosts.size;
    const sec = Math.round(remaining / Number(rate));
    eta = `${Math.floor(sec / 60)}m${String(sec % 60).padStart(2, "0")}s`;
  }

  return (
    <footer className="flex flex-wrap items-center gap-3 px-3 py-1.5 border-t border-outline-variant bg-surface-2 text-xs text-on-surface-variant">
      <div className="flex items-center gap-1.5">
        <span
          className={`inline-block w-2 h-2 rounded-full ${
            isRunning
              ? "bg-success animate-pulse-soft"
              : exitCode === 0
              ? "bg-success"
              : exitCode == null
              ? "bg-on-surface-variant/40"
              : "bg-error"
          }`}
        />
        <span>
          {isRunning
            ? "Scanning…"
            : exitCode == null
            ? "Idle"
            : exitCode === 0
            ? "Done"
            : `Exited (${exitCode})`}
        </span>
      </div>

      <span>·</span>
      <span title="Hosts probed">{hosts.size} hosts</span>

      {(isRunning || elapsedSec > 0) && (
        <>
          <span>·</span>
          <span title="Hosts probed per second (live)">
            {rate} hosts/s
          </span>
        </>
      )}

      {eta && (
        <>
          <span>·</span>
          <span title="Estimated time remaining (only available when --limit is set)">
            ETA {eta}
          </span>
        </>
      )}

      {currentRadio && (
        <>
          <span>·</span>
          <span title="Last observed radio (LTE/UMTS/WiFi)">
            radio: <span className="text-on-surface">{currentRadio}</span>
          </span>
        </>
      )}

      <>
        <span>·</span>
        <span
          title="Cumulative main-balance delta across all probes"
          className={
            totalBalKb > 0
              ? "text-error"
              : totalBalKb < 0
              ? "text-promo"
              : "text-success"
          }
        >
          Δ {fmtKb(totalBalKb)}
        </span>
      </>

      {bestTier && (() => {
        const m = tierMeta(bestTier);
        return (
          <>
            <span>·</span>
            <span>
              best: <span className={m.fg}>{m.label}</span>
            </span>
          </>
        );
      })()}

      {startedAt && (
        <>
          <span>·</span>
          <span>elapsed {elapsed}</span>
        </>
      )}

      <div className="flex-1" />
      {outDir && (
        <span className="font-mono truncate max-w-[40%]" title={outDir}>
          {outDir}
        </span>
      )}
    </footer>
  );
}

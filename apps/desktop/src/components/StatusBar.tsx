import { useEffect, useState } from "react";
import { useStore } from "../store";
import { tierMeta, tierRank } from "../theme";

export function StatusBar() {
  const {
    hosts,
    hostOrder,
    isRunning,
    startedAt,
    endedAt,
    exitCode,
    outDir,
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

  // Best tier seen so far
  let bestTier: string | null = null;
  let bestRank = 99;
  for (const sni of hostOrder) {
    const r = hosts.get(sni);
    if (!r) continue;
    const rk = tierRank(r.tier);
    if (rk < bestRank) {
      bestRank = rk;
      bestTier = r.tier;
    }
  }

  return (
    <footer className="flex items-center gap-3 px-3 py-1.5 border-t border-outline-variant bg-surface-2 text-xs text-on-surface-variant">
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
      <span>{hosts.size} hosts</span>
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

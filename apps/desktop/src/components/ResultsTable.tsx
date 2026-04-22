import { useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import clsx from "clsx";
import { ArrowDownUp, Download, Filter, X } from "lucide-react";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import { useStore } from "../store";
import { tierMeta, tierRank } from "../theme";
import { fmtMbps, fmtMs, fmtKb, fmtBytes } from "../lib/format";
import { exportResults } from "../lib/hunter";
import type { HostRecord, Tier } from "../types";

type SortKey =
  | "tier"
  | "sni"
  | "rtt"
  | "mbps"
  | "bal"
  | "tunnel"
  | "tunnel_ok"
  | "family"
  | "radio";

export function ResultsTable() {
  const {
    hosts,
    hostOrder,
    selectedSni,
    setSelected,
    filterText,
    setFilter,
    tierFilter,
    setTierFilter,
    pushLog,
  } = useStore();

  const [sortKey, setSortKey] = useState<SortKey>("tier");
  const [sortAsc, setSortAsc] = useState(true);

  const rows = useMemo(() => {
    const all = hostOrder
      .map((s) => hosts.get(s))
      .filter((r): r is HostRecord => !!r);
    const f = filterText.trim().toLowerCase();
    const filtered = all.filter((r) => {
      if (tierFilter && r.tier !== tierFilter) return false;
      if (!f) return true;
      return (
        r.sni.toLowerCase().includes(f) ||
        r.tier.toLowerCase().includes(f) ||
        (r.family || "").toLowerCase().includes(f) ||
        (r.net_type || "").toLowerCase().includes(f) ||
        (r.cert_subj || "").toLowerCase().includes(f)
      );
    });
    const sorted = [...filtered].sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case "tier":
          cmp = tierRank(a.tier) - tierRank(b.tier);
          if (cmp === 0) cmp = (b.mbps || 0) - (a.mbps || 0);
          break;
        case "sni":
          cmp = a.sni.localeCompare(b.sni);
          break;
        case "rtt":
          cmp = (a.rtt_ms || 0) - (b.rtt_ms || 0);
          break;
        case "mbps":
          cmp = (a.mbps || 0) - (b.mbps || 0);
          break;
        case "bal":
          cmp = (a.bal_delta_kb || 0) - (b.bal_delta_kb || 0);
          break;
        case "tunnel":
          cmp = (a.tunnel_bytes || 0) - (b.tunnel_bytes || 0);
          break;
        case "tunnel_ok": {
          // PASS (true) > unknown (null/undefined) > FAIL (false)
          const score = (v: boolean | null | undefined) =>
            v === true ? 2 : v == null ? 1 : 0;
          cmp = score(a.tunnel_ok) - score(b.tunnel_ok);
          if (cmp === 0)
            cmp = (a.tunnel_bytes || 0) - (b.tunnel_bytes || 0);
          break;
        }
        case "family":
          cmp = (a.family || "").localeCompare(b.family || "");
          break;
        case "radio":
          cmp = (a.net_type || "").localeCompare(b.net_type || "");
          break;
      }
      return sortAsc ? cmp : -cmp;
    });
    return sorted;
  }, [hosts, hostOrder, filterText, tierFilter, sortKey, sortAsc]);

  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 38,
    overscan: 12,
  });

  function toggleSort(k: SortKey) {
    if (sortKey === k) setSortAsc(!sortAsc);
    else {
      setSortKey(k);
      setSortAsc(k === "sni" || k === "rtt" || k === "bal");
    }
  }

  async function onExport(format: "csv" | "json") {
    const path = await saveDialog({
      title: `Export results as ${format.toUpperCase()}`,
      defaultPath: `sni-hunter-results.${format}`,
      filters: [{ name: format.toUpperCase(), extensions: [format] }],
    });
    if (!path) return;
    try {
      const wrote = await exportResults(rows, format, path);
      pushLog({ ts: Date.now(), stream: "info", line: `exported → ${wrote}` });
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `export failed: ${String(e)}`,
      });
    }
  }

  const tierCounts = useMemo(() => {
    const m = new Map<Tier, number>();
    for (const sni of hostOrder) {
      const r = hosts.get(sni);
      if (r) m.set(r.tier, (m.get(r.tier) || 0) + 1);
    }
    return m;
  }, [hosts, hostOrder]);

  return (
    <div className="flex-1 flex flex-col min-h-0">
      {/* Filter bar */}
      <div className="flex items-center gap-2 px-3 py-2 border-b border-outline-variant bg-surface-2">
        <div className="relative flex-1 max-w-md">
          <Filter
            size={14}
            className="absolute left-2.5 top-2.5 text-on-surface-variant"
          />
          <input
            className="input pl-8"
            placeholder="Filter by SNI, tier, family…"
            value={filterText}
            onChange={(e) => setFilter(e.target.value)}
          />
        </div>
        <div className="flex flex-wrap gap-1">
          {Array.from(tierCounts.entries())
            .sort((a, b) => tierRank(a[0]) - tierRank(b[0]))
            .map(([t, n]) => {
              const c = tierMeta(t);
              const active = tierFilter === t;
              return (
                <button
                  key={t}
                  onClick={() => setTierFilter(active ? null : t)}
                  className={clsx(
                    "chip",
                    c.bg,
                    c.fg,
                    c.border,
                    active && "ring-2 ring-primary/60"
                  )}
                >
                  {c.label} · {n}
                </button>
              );
            })}
          {tierFilter && (
            <button
              className="chip"
              onClick={() => setTierFilter(null)}
              title="Clear tier filter"
            >
              <X size={12} /> clear
            </button>
          )}
        </div>
        <div className="flex-1" />
        <button className="btn-ghost" onClick={() => onExport("csv")}>
          <Download size={14} /> CSV
        </button>
        <button className="btn-ghost" onClick={() => onExport("json")}>
          <Download size={14} /> JSON
        </button>
      </div>

      {/* Header */}
      <div className="grid grid-cols-[8.5rem_1fr_5rem_5rem_6rem_6rem_5rem] items-center gap-2 px-3 py-2 border-b border-outline-variant bg-surface-3 text-[11px] uppercase tracking-wide text-on-surface-variant">
        <SortHeader
          k="tier"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="Tier"
        />
        <SortHeader
          k="sni"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="SNI"
        />
        <SortHeader
          k="rtt"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="RTT"
        />
        <SortHeader
          k="mbps"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="Mbps"
        />
        <SortHeader
          k="bal"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="Δ Balance"
        />
        <SortHeader
          k="tunnel_ok"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="Tunnel"
        />
        <SortHeader
          k="family"
          cur={sortKey}
          asc={sortAsc}
          onClick={toggleSort}
          label="Family"
        />
      </div>

      {/* Body */}
      <div ref={parentRef} className="flex-1 overflow-auto">
        {rows.length === 0 ? (
          <EmptyState />
        ) : (
          <div
            style={{
              height: virtualizer.getTotalSize(),
              position: "relative",
            }}
          >
            {virtualizer.getVirtualItems().map((vi) => {
              const r = rows[vi.index];
              const c = tierMeta(r.tier);
              const isSel = selectedSni === r.sni;
              return (
                <button
                  key={r.sni}
                  onClick={() => setSelected(r.sni)}
                  style={{
                    position: "absolute",
                    top: 0,
                    left: 0,
                    right: 0,
                    transform: `translateY(${vi.start}px)`,
                    height: vi.size,
                  }}
                  className={clsx(
                    "grid grid-cols-[8.5rem_1fr_5rem_5rem_6rem_6rem_5rem] items-center gap-2 px-3 text-sm border-b border-outline-variant/40 text-left",
                    isSel ? "bg-primary/10" : "hover:bg-surface-3"
                  )}
                >
                  <span
                    className={clsx(
                      "chip justify-self-start",
                      c.bg,
                      c.fg,
                      c.border
                    )}
                  >
                    {c.label}
                  </span>
                  <span className="font-mono text-xs truncate">{r.sni}</span>
                  <span className="tabular-nums text-xs text-on-surface-variant">
                    {fmtMs(r.rtt_ms)}
                  </span>
                  <span className="tabular-nums text-xs">
                    {fmtMbps(r.mbps)}
                  </span>
                  <span
                    className={clsx(
                      "tabular-nums text-xs",
                      r.bal_delta_kb > 0
                        ? "text-error"
                        : r.bal_delta_kb < 0
                        ? "text-promo"
                        : "text-success"
                    )}
                  >
                    {fmtKb(r.bal_delta_kb)}
                  </span>
                  <span className="tabular-nums text-xs">
                    {r.tunnel_ok == null ? (
                      <span className="text-on-surface-variant">—</span>
                    ) : r.tunnel_ok ? (
                      <span className="text-success">
                        {fmtBytes(r.tunnel_bytes)}
                      </span>
                    ) : (
                      <span className="text-error">fail</span>
                    )}
                  </span>
                  <span className="text-xs text-on-surface-variant truncate">
                    {r.family || "—"}
                  </span>
                </button>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

function SortHeader({
  k,
  cur,
  asc,
  onClick,
  label,
}: {
  k: SortKey;
  cur: SortKey;
  asc: boolean;
  onClick: (k: SortKey) => void;
  label: string;
}) {
  const active = cur === k;
  return (
    <button
      className={clsx(
        "flex items-center gap-1 hover:text-on-surface text-left",
        active && "text-primary"
      )}
      onClick={() => onClick(k)}
    >
      {label}
      {active && (
        <ArrowDownUp size={11} className={asc ? "" : "rotate-180"} />
      )}
    </button>
  );
}

function EmptyState() {
  return (
    <div className="h-full grid place-items-center text-center p-12 text-on-surface-variant">
      <div>
        <div className="text-base font-medium text-on-surface mb-1">
          No results yet
        </div>
        <div className="text-sm">
          Configure carrier &amp; corpus on the left, then press
          <span className="mx-1 chip">Start scan</span>
          to begin hunting bug-hosts.
        </div>
      </div>
    </div>
  );
}

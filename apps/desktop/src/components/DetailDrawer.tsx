import { useEffect, useState } from "react";
import { Copy, FileDown, RefreshCw } from "lucide-react";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";
import { useStore } from "../store";
import { tierMeta } from "../theme";
import { fmtBytes, fmtKb, fmtMbps, fmtMs, fmtBool } from "../lib/format";
import { checkOne, generateOvpnSnippet, parseCheckJson } from "../lib/hunter";
import type { TunnelEndpointResult } from "../types";

export function DetailDrawer() {
  const {
    hosts,
    selectedSni,
    config,
    scanOptions,
    deepChecks,
    deepCheckPending,
    setDeepCheck,
    setDeepCheckPending,
    pushLog,
  } = useStore();
  const [snippet, setSnippet] = useState<string>("");

  // Spec: "clicking a row runs sni-hunter.sh check <sni> --json
  // --verify-tunnel". We do that lazily — once per row per session — and
  // cache the deep result in `deepChecks`. Re-check is available via the
  // refresh button.
  useEffect(() => {
    if (!selectedSni) return;
    if (deepChecks.has(selectedSni) || deepCheckPending.has(selectedSni)) return;
    void runDeepCheck(selectedSni);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedSni]);

  async function runDeepCheck(sni: string) {
    setDeepCheckPending(sni, true);
    pushLog({ ts: Date.now(), stream: "info", line: `deep-check ${sni}…` });
    try {
      const merged = { ...scanOptions, verifyTunnel: true };
      const out = await checkOne(sni, merged, true);
      // Hunter writes the JSON object on the last non-empty line; pick that.
      const lines = out.split(/\r?\n/).filter((l) => l.trim().startsWith("{"));
      const last = lines[lines.length - 1] || "";
      const res = parseCheckJson(last);
      if (res) {
        setDeepCheck(sni, res);
      } else {
        setDeepCheckPending(sni, false);
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `deep-check ${sni}: could not parse JSON output`,
        });
      }
    } catch (e) {
      setDeepCheckPending(sni, false);
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `deep-check ${sni} failed: ${String(e)}`,
      });
    }
  }

  if (!selectedSni) return <Empty />;
  const baseRec = hosts.get(selectedSni);
  if (!baseRec) return <Empty />;
  // Prefer the deep-check record (richer fields) once it's back; otherwise
  // fall back to the table row so the panel always shows something.
  const deep = deepChecks.get(selectedSni);
  // When the deep probe failed (passed:false) the synthetic record only
  // carries sni + recommended_action — keep showing the prior streaming row
  // for metrics/tier and surface the failure context separately below.
  const deepFailed = deep?.passed === false;
  const r = deepFailed ? baseRec : deep?.record ?? baseRec;
  const isPending = deepCheckPending.has(selectedSni);
  const c = tierMeta(r.tier);

  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      pushLog({ ts: Date.now(), stream: "info", line: "copied to clipboard" });
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `copy failed: ${String(e)}`,
      });
    }
  }

  async function genSnippet() {
    if (!config) return;
    try {
      const s = await generateOvpnSnippet({
        sni: r!.sni,
        tunnelDomain: config.tunnelDomain,
        tunnelPort: config.tunnelPort,
        wsPath: config.wsPath,
        uuidVmess: config.uuidVmess || undefined,
        uuidVless: config.uuidVless || undefined,
      });
      setSnippet(s);
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `snippet failed: ${String(e)}`,
      });
    }
  }

  async function saveSnippet() {
    if (!snippet) return;
    const path = await saveDialog({
      title: "Save OpenVPN/V2Ray snippet",
      defaultPath: `${r.sni}.ovpn`,
      filters: [{ name: "OpenVPN", extensions: ["ovpn", "txt", "conf"] }],
    });
    if (!path) return;
    try {
      await writeTextFile(path, snippet);
      pushLog({ ts: Date.now(), stream: "info", line: `saved → ${path}` });
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `save failed: ${String(e)}`,
      });
    }
  }

  return (
    <div className="p-4 space-y-4">
      <header className="flex items-start gap-2">
        <span className={`chip ${c.bg} ${c.fg} ${c.border}`}>{c.label}</span>
        <div className="flex-1 min-w-0">
          <div className="font-mono text-sm break-all">{r.sni}</div>
          {r.family && (
            <div className="text-xs text-on-surface-variant">{r.family}</div>
          )}
        </div>
        <button
          className="btn-ghost"
          title="Copy SNI"
          onClick={() => copy(r.sni)}
        >
          <Copy size={14} />
        </button>
        <button
          className="btn-ghost"
          title="Re-run check --json --verify-tunnel"
          onClick={() => runDeepCheck(r.sni)}
          disabled={isPending}
          aria-label="Re-run deep check"
        >
          <RefreshCw size={14} className={isPending ? "animate-spin" : ""} />
        </button>
      </header>

      {isPending && !deep && (
        <div className="text-xs text-on-surface-variant italic">
          Running live check + tunnel verify…
        </div>
      )}

      <section className="grid grid-cols-2 gap-2">
        <Stat label="RTT" value={fmtMs(r.rtt_ms)} />
        <Stat label="Jitter" value={fmtMs(r.jitter_ms)} />
        <Stat label="Throughput" value={fmtMbps(r.mbps)} />
        <Stat label="Δ Balance" value={fmtKb(r.bal_delta_kb)} />
        <Stat
          label="Δ Promo"
          value={
            r.promo_delta_kb != null
              ? `${fmtKb(r.promo_delta_kb)}${r.promo_name ? ` (${r.promo_name})` : ""}`
              : "—"
          }
        />
        <Stat label="IP-locked" value={fmtBool(r.ip_lock)} />
        <Stat label="Net type" value={r.net_type || "—"} />
        <Stat label="WS handshake" value={fmtBool(r.ws_handshake_ok)} />
      </section>

      {deepFailed && (
        <section className="card p-3 border-error/40">
          <div className="label mb-1 text-error">Deep-check failed</div>
          {deep?.reason && (
            <div className="text-xs">{deep.reason}</div>
          )}
          {deep?.recommended_action && (
            <div className="text-[11px] text-on-surface-variant mt-1">
              Recommended action: {deep.recommended_action}
            </div>
          )}
          <div className="text-[11px] text-on-surface-variant mt-1 italic">
            Showing last successful streaming metrics above.
          </div>
        </section>
      )}

      {/* Per-endpoint tunnel breakdown — populated only after the deep
          check returns. Falls back to the flat tunnel_ok/tunnel_bytes
          summary when only the streaming row is available. */}
      {deep?.tunnel ? (
        <TunnelBreakdownCard tunnel={deep.tunnel} />
      ) : r.tunnel_ok != null ? (
        <section className="card p-3">
          <div className="label mb-1">Tunnel byte-flow</div>
          <div className="flex items-baseline gap-2">
            <span
              className={
                r.tunnel_ok
                  ? "text-success font-medium"
                  : "text-error font-medium"
              }
            >
              {r.tunnel_ok ? "PASS" : "FAIL"}
            </span>
            <span className="text-on-surface-variant text-sm">
              {fmtBytes(r.tunnel_bytes)} round-tripped
            </span>
            <span className="text-[11px] text-on-surface-variant ml-auto">
              streaming summary — re-check for endpoint detail
            </span>
          </div>
        </section>
      ) : null}

      {(r.cert_subj || r.url_probed) && (
        <section className="card p-3 space-y-2">
          {r.cert_subj && (
            <Field label="Cert subject" value={r.cert_subj} mono />
          )}
          {r.url_probed && (
            <Field label="URL probed" value={r.url_probed} mono />
          )}
        </section>
      )}

      {r.recommended_action && (
        <section className="card p-3">
          <div className="label mb-1">Recommended action</div>
          <div className="text-sm">{r.recommended_action}</div>
        </section>
      )}

      <section className="space-y-2">
        <div className="flex gap-2">
          <button className="btn flex-1" onClick={genSnippet}>
            <FileDown size={14} /> Generate tunnel snippet
          </button>
          {snippet && (
            <button className="btn-primary" onClick={saveSnippet}>
              Save…
            </button>
          )}
        </div>
        {snippet && (
          <pre className="bg-surface-3 rounded-lg p-2 text-[11px] font-mono overflow-x-auto max-h-64">
            {snippet}
          </pre>
        )}
      </section>

      {r.notes && (
        <section className="text-xs text-on-surface-variant">
          {r.notes}
        </section>
      )}
    </div>
  );
}

function Empty() {
  return (
    <div className="p-6 text-sm text-on-surface-variant">
      Select a host to see its full report, tunnel byte-flow proof, and a
      ready-to-paste OpenVPN/V2Ray snippet.
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="card p-2">
      <div className="label">{label}</div>
      <div className="font-mono text-sm tabular-nums">{value}</div>
    </div>
  );
}

function Field({
  label,
  value,
  mono,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div>
      <div className="label">{label}</div>
      <div
        className={`text-xs break-all ${mono ? "font-mono" : ""}`}
        title={value}
      >
        {value}
      </div>
    </div>
  );
}

function TunnelBreakdownCard({
  tunnel,
}: {
  tunnel: import("../types").TunnelBreakdown;
}) {
  // The hunter emits {error, hint} when python3 is missing on the host —
  // surface that prominently rather than as an empty table.
  if (tunnel.error) {
    return (
      <section className="card p-3 border-error/40">
        <div className="label mb-1 text-error">Tunnel byte-flow unavailable</div>
        <div className="text-xs">{tunnel.error}</div>
        {tunnel.hint && (
          <div className="text-[11px] text-on-surface-variant mt-1">
            {tunnel.hint}
          </div>
        )}
      </section>
    );
  }

  const rows: Array<{
    name: string;
    r: TunnelEndpointResult | undefined;
  }> = [
    { name: "ssh", r: tunnel.ssh },
    { name: "vmess", r: tunnel.vmess },
    { name: "vless", r: tunnel.vless },
  ];
  const blob = tunnel.blob;

  return (
    <section className="card p-3">
      <div className="label mb-2">Per-endpoint tunnel byte-flow</div>
      <div className="grid grid-cols-[3.5rem_4rem_1fr_1fr_1fr] gap-x-3 gap-y-1 text-[11px] text-on-surface-variant uppercase tracking-wide">
        <div>Endpoint</div>
        <div>Status</div>
        <div>Bytes in</div>
        <div>Bytes out</div>
        <div>Elapsed</div>
      </div>
      <div className="grid grid-cols-[3.5rem_4rem_1fr_1fr_1fr] gap-x-3 gap-y-1 text-xs mt-1">
        {rows.map(({ name, r }) =>
          r ? (
            <EndpointRow key={name} name={name} r={r} />
          ) : (
            <Skipped key={name} name={name} />
          )
        )}
        {blob && (
          <>
            <div className="font-mono">blob</div>
            <div className={statusClass(blob.status)}>{blob.status}</div>
            <div className="font-mono tabular-nums">{fmtBytes(blob.bytes_in)}</div>
            <div className="text-on-surface-variant">—</div>
            <div className="font-mono tabular-nums">
              {(blob.mbps ?? 0).toFixed(2)} Mbps
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function EndpointRow({
  name,
  r,
}: {
  name: string;
  r: TunnelEndpointResult;
}) {
  return (
    <>
      <div className="font-mono">{name}</div>
      <div className={statusClass(r.status)}>{r.status}</div>
      <div className="font-mono tabular-nums">
        {r.bytes_in != null ? fmtBytes(r.bytes_in) : "—"}
      </div>
      <div className="font-mono tabular-nums">
        {r.bytes_out != null ? fmtBytes(r.bytes_out) : "—"}
      </div>
      <div className="font-mono tabular-nums">
        {r.elapsed_ms != null
          ? `${r.elapsed_ms} ms`
          : r.error || r.reason || "—"}
      </div>
    </>
  );
}

function Skipped({ name }: { name: string }) {
  return (
    <>
      <div className="font-mono">{name}</div>
      <div className="text-on-surface-variant">—</div>
      <div className="text-on-surface-variant col-span-3 text-[11px] italic">
        not run
      </div>
    </>
  );
}

function statusClass(s: string): string {
  const u = (s || "").toUpperCase();
  if (u === "PASS") return "text-success font-medium";
  if (u === "FAIL") return "text-error font-medium";
  if (u === "SKIP") return "text-on-surface-variant";
  return "text-warning";
}

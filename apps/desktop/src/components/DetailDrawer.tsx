import { useState } from "react";
import { Copy, FileDown } from "lucide-react";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";
import { useStore } from "../store";
import { tierMeta } from "../theme";
import { fmtBytes, fmtKb, fmtMbps, fmtMs, fmtBool } from "../lib/format";
import { generateOvpnSnippet } from "../lib/hunter";

export function DetailDrawer() {
  const { hosts, selectedSni, config, pushLog } = useStore();
  const [snippet, setSnippet] = useState<string>("");

  if (!selectedSni) return <Empty />;
  const r = hosts.get(selectedSni);
  if (!r) return <Empty />;
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
      </header>

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

      {r.tunnel_ok != null && (
        <section className="card p-3">
          <div className="label mb-1">Tunnel byte-flow</div>
          <div className="flex items-baseline gap-2">
            <span
              className={
                r.tunnel_ok ? "text-success font-medium" : "text-error font-medium"
              }
            >
              {r.tunnel_ok ? "PASS" : "FAIL"}
            </span>
            <span className="text-on-surface-variant text-sm">
              {fmtBytes(r.tunnel_bytes)} round-tripped
            </span>
          </div>
        </section>
      )}

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

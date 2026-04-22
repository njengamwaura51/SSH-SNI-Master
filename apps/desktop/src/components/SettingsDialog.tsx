import { useEffect, useState } from "react";
import { X } from "lucide-react";
import { useStore } from "../store";
import { configPath, loadConfig, saveConfig } from "../lib/hunter";
import type { AppConfig } from "../types";

export function SettingsDialog({ onClose }: { onClose: () => void }) {
  const setConfig = useStore((s) => s.setConfig);
  const pushLog = useStore((s) => s.pushLog);
  const [cfg, setCfg] = useState<AppConfig | null>(null);
  const [path, setPath] = useState<string>("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const [c, p] = await Promise.all([loadConfig(), configPath()]);
        setCfg(c);
        setPath(p);
      } catch (e) {
        pushLog({
          ts: Date.now(),
          stream: "stderr",
          line: `load_config: ${String(e)}`,
        });
      }
    })();
  }, [pushLog]);

  async function onSave() {
    if (!cfg) return;
    setSaving(true);
    try {
      await saveConfig(cfg);
      setConfig(cfg);
      pushLog({ ts: Date.now(), stream: "info", line: "settings saved" });
      onClose();
    } catch (e) {
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `save_config: ${String(e)}`,
      });
    } finally {
      setSaving(false);
    }
  }

  if (!cfg) return null;

  return (
    <div
      className="fixed inset-0 z-40 bg-black/60 grid place-items-center p-4"
      onClick={onClose}
    >
      <div
        className="card w-full max-w-2xl max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center px-4 py-3 border-b border-outline-variant">
          <div className="font-semibold">Settings</div>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose}>
            <X size={16} />
          </button>
        </header>
        <div className="p-4 grid grid-cols-2 gap-3">
          <Field
            label="Tunnel domain"
            value={cfg.tunnelDomain}
            onChange={(v) => setCfg({ ...cfg, tunnelDomain: v })}
          />
          <Field
            label="Tunnel port"
            value={String(cfg.tunnelPort)}
            onChange={(v) =>
              setCfg({ ...cfg, tunnelPort: Number(v) || 443 })
            }
          />
          <Field
            label="WS bridge path"
            value={cfg.wsPath}
            onChange={(v) => setCfg({ ...cfg, wsPath: v })}
          />
          <Field
            label="VMess path"
            value={cfg.vmessPath}
            onChange={(v) => setCfg({ ...cfg, vmessPath: v })}
          />
          <Field
            label="VLESS path"
            value={cfg.vlessPath}
            onChange={(v) => setCfg({ ...cfg, vlessPath: v })}
          />
          <Field
            label="Default carrier"
            value={cfg.defaultCarrier}
            onChange={(v) => setCfg({ ...cfg, defaultCarrier: v })}
          />
          <Field
            label="VMess UUID"
            value={cfg.uuidVmess}
            onChange={(v) => setCfg({ ...cfg, uuidVmess: v })}
            secret
          />
          <Field
            label="VLESS UUID"
            value={cfg.uuidVless}
            onChange={(v) => setCfg({ ...cfg, uuidVless: v })}
            secret
          />
          <Field
            label="Default concurrency"
            value={String(cfg.defaultConcurrency)}
            onChange={(v) =>
              setCfg({ ...cfg, defaultConcurrency: Number(v) || 30 })
            }
          />
          <Field
            label="Default corpus path"
            value={cfg.defaultCorpusPath}
            onChange={(v) => setCfg({ ...cfg, defaultCorpusPath: v })}
          />
          <Field
            label="Default output dir"
            value={cfg.defaultOutDir}
            onChange={(v) => setCfg({ ...cfg, defaultOutDir: v })}
          />
          <Field
            label="Hunter script override (path to sni-hunter.sh)"
            value={cfg.hunterScriptOverride}
            onChange={(v) => setCfg({ ...cfg, hunterScriptOverride: v })}
            full
          />
          <div className="col-span-2 grid grid-cols-2 gap-2">
            <Toggle
              label="Verify tunnel by default"
              checked={cfg.verifyTunnel}
              onChange={(b) => setCfg({ ...cfg, verifyTunnel: b })}
            />
            <Toggle
              label="Two-pass by default"
              checked={cfg.twoPass}
              onChange={(b) => setCfg({ ...cfg, twoPass: b })}
            />
            <Toggle
              label="Skip throughput by default"
              checked={cfg.noThroughput}
              onChange={(b) => setCfg({ ...cfg, noThroughput: b })}
            />
            <Toggle
              label="Prompt before charging data"
              checked={cfg.promptCharge}
              onChange={(b) => setCfg({ ...cfg, promptCharge: b })}
            />
            <Toggle
              label="Auto-renew expired promo bundle"
              checked={cfg.autoRenewPromo}
              onChange={(b) => setCfg({ ...cfg, autoRenewPromo: b })}
            />
          </div>
          <div className="col-span-2 text-[11px] text-on-surface-variant">
            Config file: <span className="font-mono">{path}</span>
          </div>
        </div>
        <footer className="flex items-center gap-2 px-4 py-3 border-t border-outline-variant">
          <div className="flex-1" />
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={onSave}
            disabled={saving}
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </footer>
      </div>
    </div>
  );
}

function Field({
  label,
  value,
  onChange,
  full,
  secret,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  full?: boolean;
  secret?: boolean;
}) {
  return (
    <label className={`flex flex-col gap-1 ${full ? "col-span-2" : ""}`}>
      <span className="label">{label}</span>
      <input
        className="input"
        value={value || ""}
        type={secret ? "password" : "text"}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}

function Toggle({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (b: boolean) => void;
}) {
  return (
    <label className="flex items-center gap-2 p-1.5 rounded-md hover:bg-surface-3 cursor-pointer">
      <input
        type="checkbox"
        className="accent-primary"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span className="text-sm">{label}</span>
    </label>
  );
}

import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, X } from "lucide-react";
import { useStore } from "../store";
import { configPath, loadConfig, saveConfig } from "../lib/hunter";
import type { AppConfig } from "../types";

// Permissive UUID v4-ish matcher used for VMess/VLESS IDs. v2ray accepts any
// 8-4-4-4-12 hex grouping so we don't enforce the version nibble — only the
// shape — to avoid rejecting otherwise-valid keys.
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface FieldErrors {
  tunnelPort?: string;
  uuidVmess?: string;
  uuidVless?: string;
  wsPath?: string;
  vmessPath?: string;
  vlessPath?: string;
  defaultConcurrency?: string;
  tunnelDomain?: string;
}

function validate(cfg: AppConfig): FieldErrors {
  const errs: FieldErrors = {};
  if (
    !Number.isInteger(cfg.tunnelPort) ||
    cfg.tunnelPort < 1 ||
    cfg.tunnelPort > 65535
  ) {
    errs.tunnelPort = "Port must be 1–65535";
  }
  if (cfg.uuidVmess && !UUID_RE.test(cfg.uuidVmess.trim())) {
    errs.uuidVmess = "Expected 8-4-4-4-12 hex (UUID)";
  }
  if (cfg.uuidVless && !UUID_RE.test(cfg.uuidVless.trim())) {
    errs.uuidVless = "Expected 8-4-4-4-12 hex (UUID)";
  }
  if (cfg.wsPath !== undefined && cfg.wsPath !== "" && !cfg.wsPath.startsWith("/")) {
    errs.wsPath = "Path must start with /";
  }
  if (
    cfg.vmessPath !== undefined &&
    cfg.vmessPath !== "" &&
    !cfg.vmessPath.startsWith("/")
  ) {
    errs.vmessPath = "Path must start with /";
  }
  if (
    cfg.vlessPath !== undefined &&
    cfg.vlessPath !== "" &&
    !cfg.vlessPath.startsWith("/")
  ) {
    errs.vlessPath = "Path must start with /";
  }
  if (
    !Number.isInteger(cfg.defaultConcurrency) ||
    cfg.defaultConcurrency < 1 ||
    cfg.defaultConcurrency > 256
  ) {
    errs.defaultConcurrency = "Concurrency must be 1–256";
  }
  // Tunnel domain is allowed to be blank (operator hasn't pointed at a server
  // yet), but if provided it must look like a hostname (no scheme, no path).
  if (cfg.tunnelDomain) {
    const d = cfg.tunnelDomain.trim();
    if (/[\s/:]/.test(d) || !/\./.test(d)) {
      errs.tunnelDomain = "Use a bare hostname (e.g. tunnel.example.com)";
    }
  }
  return errs;
}

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

  const errors = useMemo<FieldErrors>(
    () => (cfg ? validate(cfg) : {}),
    [cfg]
  );
  const hasErrors = Object.keys(errors).length > 0;

  async function onSave() {
    if (!cfg || hasErrors) return;
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
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-dialog-title"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center px-4 py-3 border-b border-outline-variant">
          <div id="settings-dialog-title" className="font-semibold">
            Settings
          </div>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </header>

        <div className="p-4 space-y-5">
          <Section
            title="Tunnel server"
            hint="The remote endpoint your snippets and tunnel launches will connect to."
          >
            <Field
              label="Tunnel domain"
              value={cfg.tunnelDomain}
              onChange={(v) => setCfg({ ...cfg, tunnelDomain: v })}
              error={errors.tunnelDomain}
              placeholder="tunnel.example.com"
            />
            <Field
              label="Tunnel port"
              value={String(cfg.tunnelPort)}
              onChange={(v) =>
                setCfg({ ...cfg, tunnelPort: Number(v) || 0 })
              }
              error={errors.tunnelPort}
              placeholder="443"
            />
          </Section>

          <Section
            title="Bridge paths"
            hint="WebSocket paths configured on your nginx/Caddy front. Must start with /."
          >
            <Field
              label="WS bridge path"
              value={cfg.wsPath}
              onChange={(v) => setCfg({ ...cfg, wsPath: v })}
              error={errors.wsPath}
              placeholder="/ws"
            />
            <Field
              label="VMess path"
              value={cfg.vmessPath}
              onChange={(v) => setCfg({ ...cfg, vmessPath: v })}
              error={errors.vmessPath}
              placeholder="/vmess"
            />
            <Field
              label="VLESS path"
              value={cfg.vlessPath}
              onChange={(v) => setCfg({ ...cfg, vlessPath: v })}
              error={errors.vlessPath}
              placeholder="/vless"
            />
          </Section>

          <Section
            title="Identities"
            hint="UUIDs are written into snippet files at mode 0600. Generate with `uuidgen`."
          >
            <Field
              label="VMess UUID"
              value={cfg.uuidVmess}
              onChange={(v) => setCfg({ ...cfg, uuidVmess: v })}
              error={errors.uuidVmess}
              secret
            />
            <Field
              label="VLESS UUID"
              value={cfg.uuidVless}
              onChange={(v) => setCfg({ ...cfg, uuidVless: v })}
              error={errors.uuidVless}
              secret
            />
          </Section>

          <Section title="Scan defaults">
            <Field
              label="Default carrier"
              value={cfg.defaultCarrier}
              onChange={(v) => setCfg({ ...cfg, defaultCarrier: v })}
              placeholder="auto"
            />
            <Field
              label="Default concurrency"
              value={String(cfg.defaultConcurrency)}
              onChange={(v) =>
                setCfg({ ...cfg, defaultConcurrency: Number(v) || 0 })
              }
              error={errors.defaultConcurrency}
              placeholder="30"
            />
            <Field
              label="Default corpus path"
              value={cfg.defaultCorpusPath}
              onChange={(v) => setCfg({ ...cfg, defaultCorpusPath: v })}
              full
            />
            <Field
              label="Default output dir"
              value={cfg.defaultOutDir}
              onChange={(v) => setCfg({ ...cfg, defaultOutDir: v })}
              full
            />
            <Field
              label="Hunter script override (path to sni-hunter.sh)"
              value={cfg.hunterScriptOverride}
              onChange={(v) => setCfg({ ...cfg, hunterScriptOverride: v })}
              full
            />
          </Section>

          <Section title="Behavior toggles">
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
          </Section>

          <div className="text-[11px] text-on-surface-variant">
            Config file: <span className="font-mono">{path}</span>
          </div>
        </div>

        <footer className="flex items-center gap-2 px-4 py-3 border-t border-outline-variant">
          {hasErrors && (
            <span className="inline-flex items-center gap-1 text-xs text-error">
              <AlertTriangle size={12} /> Fix the highlighted fields to save
            </span>
          )}
          <div className="flex-1" />
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn-primary"
            onClick={onSave}
            disabled={saving || hasErrors}
            title={hasErrors ? "Resolve validation errors first" : ""}
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </footer>
      </div>
    </div>
  );
}

function Section({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <div className="flex items-baseline justify-between mb-2">
        <h3 className="text-xs uppercase tracking-wide font-semibold text-on-surface-variant">
          {title}
        </h3>
        {hint && (
          <span className="text-[11px] text-on-surface-variant/70 ml-3 text-right">
            {hint}
          </span>
        )}
      </div>
      <div className="grid grid-cols-2 gap-3">{children}</div>
    </section>
  );
}

function Field({
  label,
  value,
  onChange,
  full,
  secret,
  error,
  placeholder,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  full?: boolean;
  secret?: boolean;
  error?: string;
  placeholder?: string;
}) {
  return (
    <label className={`flex flex-col gap-1 ${full ? "col-span-2" : ""}`}>
      <span className="label">{label}</span>
      <input
        className={`input ${error ? "border-error focus:border-error" : ""}`}
        value={value || ""}
        type={secret ? "password" : "text"}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        aria-invalid={Boolean(error)}
      />
      {error && (
        <span className="text-[11px] text-error inline-flex items-center gap-1">
          <AlertTriangle size={10} /> {error}
        </span>
      )}
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

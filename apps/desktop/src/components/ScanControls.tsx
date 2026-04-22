import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { Search, FileText, FolderOpen } from "lucide-react";
import { useStore } from "../store";
import { checkOne, parseHostLine } from "../lib/hunter";

const CARRIERS = [
  { v: "auto", l: "Auto-detect" },
  { v: "safaricom", l: "Safaricom" },
  { v: "airtel", l: "Airtel" },
  { v: "telkom", l: "Telkom" },
  { v: "unknown", l: "Unknown / WiFi" },
];

export function ScanControls() {
  const { scanOptions, setScanOptions, isRunning, pushHost, pushLog } =
    useStore();

  async function pickCorpus() {
    const sel = await openDialog({
      multiple: false,
      title: "Choose SNI corpus file",
      filters: [{ name: "Text", extensions: ["txt", "list"] }],
    });
    if (typeof sel === "string") setScanOptions({ corpusPath: sel });
  }
  async function pickOutDir() {
    const sel = await openDialog({
      directory: true,
      multiple: false,
      title: "Choose output directory",
    });
    if (typeof sel === "string") setScanOptions({ outDir: sel });
  }
  async function pickAccess() {
    const sel = await openDialog({
      multiple: false,
      title: "Choose accessibility (allowlist) file",
    });
    if (typeof sel === "string")
      setScanOptions({ accessibilityFile: sel });
  }

  async function onCheckOne() {
    const sni = window.prompt("Single-host check — enter SNI");
    if (!sni) return;
    pushLog({ ts: Date.now(), stream: "info", line: `check ${sni}…` });
    try {
      const out = await checkOne(sni.trim(), scanOptions, true);
      const rec = parseHostLine(out);
      if (rec) pushHost(rec);
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
        line: `check failed: ${String(e)}`,
      });
    }
  }

  return (
    <div className="p-4 space-y-5">
      <section>
        <div className="label mb-1">Carrier</div>
        <select
          className="input"
          value={scanOptions.carrier}
          disabled={isRunning}
          onChange={(e) => setScanOptions({ carrier: e.target.value })}
        >
          {CARRIERS.map((c) => (
            <option key={c.v} value={c.v}>
              {c.l}
            </option>
          ))}
        </select>
      </section>

      <section>
        <div className="label mb-1">Concurrency</div>
        <input
          className="input"
          type="number"
          min={1}
          max={200}
          value={scanOptions.concurrency}
          disabled={isRunning}
          onChange={(e) =>
            setScanOptions({ concurrency: Number(e.target.value) || 1 })
          }
        />
      </section>

      <section className="space-y-2">
        <div>
          <div className="label mb-1">Corpus file</div>
          <div className="flex gap-1">
            <input
              className="input"
              placeholder="(default corpus)"
              value={scanOptions.corpusPath || ""}
              disabled={isRunning}
              onChange={(e) =>
                setScanOptions({ corpusPath: e.target.value })
              }
            />
            <button
              className="btn"
              onClick={pickCorpus}
              disabled={isRunning}
              title="Browse"
            >
              <FileText size={16} />
            </button>
          </div>
        </div>

        <div>
          <div className="label mb-1">Output directory</div>
          <div className="flex gap-1">
            <input
              className="input"
              placeholder="(default ~/.local/share/sni-hunter/runs/...)"
              value={scanOptions.outDir || ""}
              disabled={isRunning}
              onChange={(e) => setScanOptions({ outDir: e.target.value })}
            />
            <button
              className="btn"
              onClick={pickOutDir}
              disabled={isRunning}
              title="Browse"
            >
              <FolderOpen size={16} />
            </button>
          </div>
        </div>

        <div>
          <div className="label mb-1">Accessibility allowlist</div>
          <div className="flex gap-1">
            <input
              className="input"
              placeholder="(optional)"
              value={scanOptions.accessibilityFile || ""}
              disabled={isRunning}
              onChange={(e) =>
                setScanOptions({ accessibilityFile: e.target.value })
              }
            />
            <button
              className="btn"
              onClick={pickAccess}
              disabled={isRunning}
              title="Browse"
            >
              <FileText size={16} />
            </button>
          </div>
        </div>
      </section>

      <section className="space-y-1.5">
        <Toggle
          label="Verify tunnel byte-flow"
          checked={scanOptions.verifyTunnel}
          onChange={(b) => setScanOptions({ verifyTunnel: b })}
          disabled={isRunning}
          hint="Push real bytes through SSH-WS / VMess / VLESS"
        />
        <Toggle
          label="Two-pass scan"
          checked={scanOptions.twoPass}
          onChange={(b) => setScanOptions({ twoPass: b })}
          disabled={isRunning}
          hint="Re-probe top hosts to confirm stability"
        />
        <Toggle
          label="Skip throughput probes"
          checked={scanOptions.noThroughput}
          onChange={(b) => setScanOptions({ noThroughput: b })}
          disabled={isRunning}
          hint="Faster; skips the 25 MB blob fetch"
        />
        <Toggle
          label="Seed corpus only"
          checked={scanOptions.seedOnly}
          onChange={(b) => setScanOptions({ seedOnly: b })}
          disabled={isRunning}
          hint="Just the curated seed list, not the full corpus"
        />
        <Toggle
          label="Prompt on data charge"
          checked={scanOptions.promptCharge}
          onChange={(b) => setScanOptions({ promptCharge: b })}
          disabled={isRunning}
        />
        <Toggle
          label="Auto-renew expired promo bundle"
          checked={scanOptions.autoRenewPromo}
          onChange={(b) => setScanOptions({ autoRenewPromo: b })}
          disabled={isRunning}
        />
        <Toggle
          label="Skip USSD auto-detection"
          checked={scanOptions.noAutoUssd}
          onChange={(b) => setScanOptions({ noAutoUssd: b })}
          disabled={isRunning}
        />
        <Toggle
          label="Interactive prompts"
          checked={scanOptions.interactive}
          onChange={(b) => setScanOptions({ interactive: b })}
          disabled={isRunning}
        />
      </section>

      <section className="pt-2 border-t border-outline-variant">
        <button
          className="btn w-full"
          onClick={onCheckOne}
          disabled={isRunning}
        >
          <Search size={16} /> Check single SNI…
        </button>
      </section>
    </div>
  );
}

function Toggle({
  label,
  checked,
  onChange,
  disabled,
  hint,
}: {
  label: string;
  checked: boolean;
  onChange: (b: boolean) => void;
  disabled?: boolean;
  hint?: string;
}) {
  return (
    <label
      className={`flex items-start gap-2 cursor-pointer p-1.5 rounded-md hover:bg-surface-3 ${
        disabled ? "opacity-50 cursor-not-allowed" : ""
      }`}
    >
      <input
        type="checkbox"
        className="mt-0.5 accent-primary"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <div className="leading-tight">
        <div className="text-sm">{label}</div>
        {hint && (
          <div className="text-[11px] text-on-surface-variant">{hint}</div>
        )}
      </div>
    </label>
  );
}

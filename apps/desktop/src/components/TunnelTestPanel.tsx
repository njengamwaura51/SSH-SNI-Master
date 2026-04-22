import { useState } from "react";
import { X, PlayCircle } from "lucide-react";
import { useStore } from "../store";
import { tunnelTest } from "../lib/hunter";

export function TunnelTestPanel({ onClose }: { onClose: () => void }) {
  const { scanOptions, pushLog } = useStore();
  const [sni, setSni] = useState("");
  const [targetIp, setTargetIp] = useState("");
  const [output, setOutput] = useState("");
  const [running, setRunning] = useState(false);

  async function onRun() {
    setRunning(true);
    setOutput("");
    try {
      const out = await tunnelTest(
        scanOptions,
        sni.trim() || undefined,
        targetIp.trim() || undefined
      );
      setOutput(out);
      pushLog({
        ts: Date.now(),
        stream: "info",
        line: `tunnel-test ${sni || "(default sni)"} done`,
      });
    } catch (e) {
      setOutput(String(e));
      pushLog({
        ts: Date.now(),
        stream: "stderr",
        line: `tunnel-test failed: ${String(e)}`,
      });
    } finally {
      setRunning(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-40 bg-black/60 grid place-items-center p-4"
      onClick={onClose}
    >
      <div
        className="card w-full max-w-3xl max-h-[90vh] overflow-hidden flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center px-4 py-3 border-b border-outline-variant">
          <div className="font-semibold">Tunnel byte-flow test</div>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose}>
            <X size={16} />
          </button>
        </header>
        <div className="p-4 grid grid-cols-2 gap-3">
          <label className="flex flex-col gap-1">
            <span className="label">SNI (optional, host header)</span>
            <input
              className="input"
              value={sni}
              onChange={(e) => setSni(e.target.value)}
              placeholder="e.g. cdn.tile.openstreetmap.org"
            />
          </label>
          <label className="flex flex-col gap-1">
            <span className="label">Target IP (optional)</span>
            <input
              className="input"
              value={targetIp}
              onChange={(e) => setTargetIp(e.target.value)}
              placeholder="(uses tunnel default)"
            />
          </label>
        </div>
        <div className="px-4 pb-2">
          <button
            className="btn-primary"
            onClick={onRun}
            disabled={running}
          >
            <PlayCircle size={16} />{" "}
            {running ? "Testing…" : "Run tunnel-test"}
          </button>
        </div>
        <div className="flex-1 min-h-[12rem] mx-4 mb-4 bg-surface-3 rounded-lg p-3 overflow-auto font-mono text-[11px] whitespace-pre-wrap">
          {output || "(output will appear here)"}
        </div>
      </div>
    </div>
  );
}

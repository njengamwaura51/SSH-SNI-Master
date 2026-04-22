import { useEffect, useRef } from "react";
import clsx from "clsx";
import { Eraser, X } from "lucide-react";
import { useStore } from "../store";

export function LogViewer() {
  const logs = useStore((s) => s.logs);
  const setShowLogs = useStore((s) => s.setShowLogs);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!ref.current) return;
    ref.current.scrollTop = ref.current.scrollHeight;
  }, [logs]);

  return (
    <div className="h-64 border-t border-outline-variant bg-surface-2 flex flex-col">
      <div className="flex items-center gap-2 px-3 py-1.5 border-b border-outline-variant">
        <div className="text-xs uppercase tracking-wide text-on-surface-variant">
          Logs
        </div>
        <span className="chip">{logs.length}</span>
        <div className="flex-1" />
        <button
          className="btn-ghost"
          onClick={() =>
            useStore.setState({ logs: [] as ReturnType<typeof useStore.getState>["logs"] })
          }
          title="Clear"
        >
          <Eraser size={14} />
        </button>
        <button
          className="btn-ghost"
          onClick={() => setShowLogs(false)}
          title="Hide"
        >
          <X size={14} />
        </button>
      </div>
      <div
        ref={ref}
        className="flex-1 overflow-auto px-3 py-2 font-mono text-[11px] leading-5 whitespace-pre-wrap"
      >
        {logs.map((l, i) => (
          <div
            key={i}
            className={clsx(
              l.stream === "stderr" && "text-error",
              l.stream === "info" && "text-secondary",
              l.stream === "stdout" && "text-on-surface-variant"
            )}
          >
            <span className="text-on-surface-variant/50 mr-2">
              {new Date(l.ts).toLocaleTimeString()}
            </span>
            {l.line}
          </div>
        ))}
      </div>
    </div>
  );
}

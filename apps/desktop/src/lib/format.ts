export function fmtMs(n: number | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  if (n < 10) return `${n.toFixed(1)} ms`;
  return `${Math.round(n)} ms`;
}
export function fmtMbps(n: number | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  if (n < 1) return `${(n * 1000).toFixed(0)} kbps`;
  if (n < 10) return `${n.toFixed(2)} Mbps`;
  return `${n.toFixed(1)} Mbps`;
}
export function fmtKb(n: number | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  const sign = n > 0 ? "+" : "";
  if (Math.abs(n) >= 1024) return `${sign}${(n / 1024).toFixed(2)} MB`;
  return `${sign}${n} KB`;
}
export function fmtBytes(n: number | undefined): string {
  if (n == null || !Number.isFinite(n)) return "—";
  if (n >= 1_048_576) return `${(n / 1_048_576).toFixed(2)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${n} B`;
}
export function fmtBool(b: boolean | undefined): string {
  if (b == null) return "—";
  return b ? "yes" : "no";
}
export function relTime(unix: number): string {
  const diff = Date.now() / 1000 - unix;
  if (diff < 60) return `${Math.round(diff)}s ago`;
  if (diff < 3600) return `${Math.round(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.round(diff / 3600)}h ago`;
  return `${Math.round(diff / 86400)}d ago`;
}

import type { Tier } from "./types";

export interface TierMeta {
  fg: string;
  bg: string;
  border: string;
  label: string;
  /** Lower = better outcome for the user */
  rank: number;
}

// Canonical (exact-match) entries.
const EXACT: Record<string, TierMeta> = {
  UNLIMITED_FREE: {
    fg: "text-success",
    bg: "bg-success/10",
    border: "border-success/40",
    label: "Free",
    rank: 0,
  },
  CAPPED_100M: {
    fg: "text-success",
    bg: "bg-success/10",
    border: "border-success/40",
    label: "Capped 100M",
    rank: 1,
  },
  CAPPED_20M: {
    fg: "text-secondary",
    bg: "bg-secondary/10",
    border: "border-secondary/40",
    label: "Capped 20M",
    rank: 2,
  },
  NETWORK_TYPE_SPECIFIC: {
    fg: "text-secondary",
    bg: "bg-secondary/10",
    border: "border-secondary/30",
    label: "Net-type specific",
    rank: 5,
  },
  PASS_NOTHRU: {
    fg: "text-on-surface-variant",
    bg: "bg-surface-3",
    border: "border-outline",
    label: "Pass (no throughput)",
    rank: 6,
  },
  THROTTLED: {
    fg: "text-warning",
    bg: "bg-warning/10",
    border: "border-warning/40",
    label: "Throttled",
    rank: 7,
  },
  BUNDLE_REQUIRED: {
    fg: "text-error",
    bg: "bg-error/10",
    border: "border-error/40",
    label: "Bundle required",
    rank: 8,
  },
  IP_LOCKED: {
    fg: "text-error",
    bg: "bg-error/15",
    border: "border-error/50",
    label: "IP-locked",
    rank: 9,
  },
};

const FALLBACK: TierMeta = {
  fg: "text-on-surface-variant",
  bg: "bg-surface-3",
  border: "border-outline",
  label: "Unknown",
  rank: 99,
};

// Resolve any tier string — including dynamic suffixed ones the hunter emits
// such as APP_TUNNEL_META, APP_TUNNEL_WHATSAPP, PROMO_BUNDLE_DAILY_SOCIAL.
export function tierMeta(t: Tier | undefined | null): TierMeta {
  if (!t) return FALLBACK;
  const exact = EXACT[t];
  if (exact) return exact;
  if (t.startsWith("APP_TUNNEL_")) {
    const fam = t.slice("APP_TUNNEL_".length);
    return {
      fg: "text-success",
      bg: "bg-success/10",
      border: "border-success/40",
      label: `App tunnel · ${fam.toLowerCase()}`,
      rank: 3,
    };
  }
  if (t.startsWith("PROMO_BUNDLE_")) {
    const name = t.slice("PROMO_BUNDLE_".length);
    return {
      fg: "text-promo",
      bg: "bg-promo/10",
      border: "border-promo/40",
      label: `Promo · ${name.toLowerCase()}`,
      rank: 4,
    };
  }
  return { ...FALLBACK, label: t };
}

export function tierRank(t: Tier | undefined | null): number {
  return tierMeta(t).rank;
}

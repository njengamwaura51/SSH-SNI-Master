# SNI Hunter — Linux desktop app

A dark-mode Tauri 2 desktop GUI that wraps `tools/sni-hunter.sh`. Packaged as
both an **AppImage** (portable, runs on any glibc Linux) and a **`.deb`**
(installs cleanly on Debian / Ubuntu / Pop!_OS / Mint).

The app is a thin shell over the bash hunter — every classification, probe,
USSD flow, and tunnel-test path lives in `tools/sni-hunter.sh`. The desktop
side only:

- spawns the bundled hunter as a child process;
- streams its line-delimited JSON output back into a virtualized results
  table with live filtering, sorting, and tier chips;
- shows a per-host detail drawer with all schema-v2 fields, including the
  tunnel byte-flow proof (`tunnel_ok` / `tunnel_bytes` from Task #6);
- exports CSV / JSON and a copy-paste-ready OpenVPN/V2Ray snippet for the
  picked host;
- persists settings (tunnel domain, ports, UUIDs, default carrier, etc.) at
  `~/.config/sni-hunter/config.json`.

## Why no build artifacts in this repo

This Replit environment doesn't have the Rust toolchain, `webkit2gtk`, or
the Linux bundler tools needed to produce an AppImage / `.deb`. Everything
is fully scaffolded so you can build on your own Debian box in two
commands.

## Build

### One-time prerequisites (Debian / Ubuntu)

```bash
sudo apt update
sudo apt install -y \
  build-essential curl wget file libssl-dev \
  libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
  librsvg2-dev libgtk-3-dev pkg-config

# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# pnpm + node 20+
curl -fsSL https://get.pnpm.io/install.sh | sh -
```

### Build the packages

```bash
cd apps/desktop
node scripts/make-icons.cjs        # one-shot placeholder icon generation
pnpm install
bash scripts/build-packages.sh
```

Outputs land under
`apps/desktop/src-tauri/target/release/bundle/{appimage,deb}/`.

### Develop

```bash
cd apps/desktop
node scripts/make-icons.cjs   # once
pnpm install
pnpm tauri:dev
```

## How the sidecar wiring works

Tauri's bundler embeds extra binaries from `src-tauri/bin/` named with the
target triple suffix. `scripts/prepare-sidecar.sh` copies
`tools/sni-hunter.sh` into:

```
src-tauri/bin/sni-hunter
src-tauri/bin/sni-hunter-x86_64-unknown-linux-gnu
src-tauri/bin/sni-hunter-x86_64-unknown-linux-musl
src-tauri/bin/sni-hunter-aarch64-unknown-linux-gnu
src-tauri/bin/sni-hunter-aarch64-unknown-linux-musl
```

…right before each `tauri build`. The Rust side spawns the sidecar via
`tauri_plugin_shell` and forwards every stdout line to the frontend. Lines
starting with `{` are parsed as host JSON records (schema v2); everything
else is treated as a log line and shown in the **Logs** drawer.

The hunter remains the single source of truth for protocol framing, tier
classification, and tunnel-test logic — `src-tauri/src/hunter.rs` only
builds command lines and pipes I/O. There is **no** parallel implementation
of any of the probe, classifier, or VMess/VLESS handshake logic in Rust.

## File layout

```
apps/desktop/
├── package.json
├── vite.config.ts
├── tailwind.config.js
├── postcss.config.js
├── tsconfig.json
├── index.html
├── README.md                      ← you are here
├── scripts/
│   ├── prepare-sidecar.sh         ← copy hunter into src-tauri/bin/
│   ├── make-icons.cjs             ← one-shot placeholder icon generator
│   └── build-packages.sh          ← convenience wrapper for AppImage + deb
├── src/
│   ├── main.tsx
│   ├── App.tsx                    ← three-pane layout
│   ├── styles.css                 ← tailwind + Material-3 dark tokens
│   ├── store.ts                   ← zustand global state
│   ├── theme.ts                   ← tier colour table
│   ├── types.ts                   ← shared TS types (HostRecord schema v2)
│   ├── lib/
│   │   ├── hunter.ts              ← every Tauri invoke + event subscribe
│   │   └── format.ts              ← display helpers (ms / Mbps / KB)
│   └── components/
│       ├── Toolbar.tsx
│       ├── ScanControls.tsx       ← left pane
│       ├── ResultsTable.tsx       ← centre pane (virtualized)
│       ├── DetailDrawer.tsx       ← right pane
│       ├── StatusBar.tsx
│       ├── LogViewer.tsx
│       ├── SettingsDialog.tsx
│       └── TunnelTestPanel.tsx
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json            ← bundle = ["deb","appimage"]
    ├── capabilities/main.json
    ├── icons/
    │   ├── icon.svg               ← brand SVG; regenerate PNGs from this
    │   └── …                       ← .png/.ico/.icns produced by make-icons.cjs
    ├── bin/                       ← populated by prepare-sidecar.sh (gitignored)
    └── src/
        ├── main.rs
        ├── lib.rs                 ← Tauri bootstrap + invoke handler list
        ├── hunter.rs              ← spawn / cancel / stream the bash hunter
        ├── config.rs              ← load/save ~/.config/sni-hunter/config.json
        └── exports.rs             ← CSV/JSON export + ovpn snippet
```

## Settings & data locations

| Purpose                  | Path                                            |
| ------------------------ | ----------------------------------------------- |
| User config              | `~/.config/sni-hunter/config.json`              |
| Default scan output      | `~/.local/share/sni-hunter/runs/<timestamp>/`   |
| Bundled hunter sidecar   | `<install>/sni-hunter-<triple>` (extracted by Tauri) |

## Theme

Material-3 dark, OLED-friendly. All colour tokens are CSS variables defined
in `src/styles.css`:

| Token              | Value     | Used for                |
| ------------------ | --------- | ----------------------- |
| `--md-surface`     | `#121212` | window background       |
| `--md-surface-2`   | `#1c1c1f` | side panes / cards      |
| `--md-primary`     | `#bb86fc` | primary actions / focus |
| `--md-secondary`   | `#03dac6` | accents / info logs     |
| `--md-error`       | `#cf6679` | errors / billed tier    |
| `--md-success`     | `#4caf50` | free tier / pass        |
| `--md-warning`     | `#ffb74d` | throttled tier          |
| `--md-promo`       | `#ffb74d` | promo-bundle tier       |

To switch palettes, override the CSS variables; nothing in the components
hard-codes a hex value.

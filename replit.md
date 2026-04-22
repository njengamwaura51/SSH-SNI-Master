# Workspace

## Overview

pnpm workspace monorepo using TypeScript. Each package manages its own dependencies.

## Stack

- **Monorepo tool**: pnpm workspaces
- **Node.js version**: 24
- **Package manager**: pnpm
- **TypeScript version**: 5.9
- **API framework**: Express 5
- **Database**: PostgreSQL + Drizzle ORM
- **Validation**: Zod (`zod/v4`), `drizzle-zod`
- **API codegen**: Orval (from OpenAPI spec)
- **Build**: esbuild (CJS bundle)

## Key Commands

- `pnpm run typecheck` — full typecheck across all packages
- `pnpm run build` — typecheck + build all packages
- `pnpm --filter @workspace/api-spec run codegen` — regenerate API hooks and Zod schemas from OpenAPI spec
- `pnpm --filter @workspace/db run push` — push DB schema changes (dev only)
- `pnpm --filter @workspace/api-server run dev` — run API server locally

See the `pnpm-workspace` skill for workspace structure, TypeScript setup, and package details.

## Out-of-workspace projects

- `tools/sni-hunter.sh` — mature bash hunter (~2200 lines) for SNI/bug-host
  scanning over the tunnel server. Emits one schema-v2 JSON record per host.
- `apps/desktop/` — Tauri 2 + React + Tailwind dark-mode desktop GUI that
  wraps the bash hunter as a sidecar. **Not** part of the pnpm workspace
  (self-contained Cargo + npm). Builds AppImage + .deb on a Debian box via
  `bash apps/desktop/scripts/build-packages.sh`. Replit cannot compile
  Rust/webkit2gtk; this folder is scaffold-only here.
- `apps/android/` (planned, Task #20) — universal Android APK with bundled
  busybox/bash/python3 runtime.

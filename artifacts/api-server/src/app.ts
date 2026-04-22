import express, { type Express } from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import pinoHttp from "pino-http";
import path from "node:path";
import router from "./routes";
import { logger } from "./lib/logger";

const app: Express = express();

app.use(
  pinoHttp({
    logger,
    serializers: {
      req(req) {
        return {
          id: req.id,
          method: req.method,
          url: req.url?.split("?")[0],
        };
      },
      res(res) {
        return {
          statusCode: res.statusCode,
        };
      },
    },
  }),
);
// Security baseline (Task #24): helmet defaults — CSP, X-Frame-Options,
// HSTS, X-Content-Type-Options, etc. The release-download endpoint serves
// large binaries so contentSecurityPolicy is left at its strict default
// (no inline scripts) since the JSON manifest at /api/releases is the only
// thing browsers fetch directly.
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Conservative rate-limit on /api: 120 requests / minute per IP. The
// releases endpoint is also covered; the static /dl/ binaries below are
// rate-limited separately at 30/min so a stuck downloader can't burn the
// API budget.
app.use(
  "/api",
  rateLimit({
    windowMs: 60_000,
    limit: 120,
    standardHeaders: "draft-7",
    legacyHeaders: false,
  }),
  router,
);

// Static download surface for the desktop AppImage / Android APK.
// Path layout matches /api/releases manifest's download_url field.
// RELEASES_DIR can be overridden in production to point at a checked-out
// directory shared with the existing nginx config that serves
// shopthelook.page (the API server then runs alongside it on a private port).
const RELEASES_DIR =
  process.env.RELEASES_DIR ||
  path.resolve(process.cwd(), "releases");
app.use(
  "/dl",
  rateLimit({
    windowMs: 60_000,
    limit: 30,
    standardHeaders: "draft-7",
    legacyHeaders: false,
  }),
  express.static(RELEASES_DIR, {
    fallthrough: false,
    maxAge: "1h",
    index: false,
    dotfiles: "ignore",
  }),
);

export default app;

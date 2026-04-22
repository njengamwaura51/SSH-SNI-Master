import { Github, Globe, Keyboard, Shield, X } from "lucide-react";

const APP_VERSION = "0.4.0";
const REPO_URL = "https://shopthelook.page";

export function AboutDialog({ onClose }: { onClose: () => void }) {
  return (
    <div
      className="fixed inset-0 z-40 bg-black/60 grid place-items-center p-4"
      onClick={onClose}
    >
      <div
        className="card w-full max-w-lg"
        role="dialog"
        aria-modal="true"
        aria-labelledby="about-dialog-title"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-center px-4 py-3 border-b border-outline-variant">
          <div id="about-dialog-title" className="font-semibold">
            About SNI Hunter
          </div>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </header>

        <div className="p-5 space-y-4 text-sm">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-primary/15 border border-primary/40 grid place-items-center">
              <span className="text-primary font-semibold">SH</span>
            </div>
            <div>
              <div className="font-semibold">SNI Hunter Desktop</div>
              <div className="text-on-surface-variant text-xs">
                Version {APP_VERSION} · tunnel bug-host scanner
              </div>
            </div>
          </div>

          <p className="text-on-surface-variant">
            Discovers carrier SNIs that bypass paywalls on Safaricom, Airtel
            and Telkom Kenya, and one-click launches an OpenVPN or V2Ray
            tunnel through the chosen host.
          </p>

          <section>
            <div className="flex items-center gap-1.5 text-xs uppercase tracking-wide text-on-surface-variant mb-1.5">
              <Keyboard size={12} /> Keyboard shortcuts
            </div>
            <ul className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
              <li>
                <kbd className="kbd">Ctrl</kbd>+<kbd className="kbd">R</kbd>
                <span className="ml-2 text-on-surface-variant">
                  Start / stop scan
                </span>
              </li>
              <li>
                <kbd className="kbd">Ctrl</kbd>+<kbd className="kbd">,</kbd>
                <span className="ml-2 text-on-surface-variant">Settings</span>
              </li>
              <li>
                <kbd className="kbd">Ctrl</kbd>+<kbd className="kbd">L</kbd>
                <span className="ml-2 text-on-surface-variant">
                  Toggle logs
                </span>
              </li>
              <li>
                <kbd className="kbd">?</kbd>
                <span className="ml-2 text-on-surface-variant">About</span>
              </li>
              <li>
                <kbd className="kbd">Esc</kbd>
                <span className="ml-2 text-on-surface-variant">
                  Close dialog
                </span>
              </li>
            </ul>
          </section>

          <section className="flex flex-col gap-1.5 text-xs">
            <a
              className="inline-flex items-center gap-1.5 text-primary hover:underline"
              href={REPO_URL}
              target="_blank"
              rel="noreferrer noopener"
            >
              <Globe size={12} /> Project home
            </a>
            <a
              className="inline-flex items-center gap-1.5 text-primary hover:underline"
              href="https://github.com/openvpn/openvpn"
              target="_blank"
              rel="noreferrer noopener"
            >
              <Github size={12} /> OpenVPN client (external dependency)
            </a>
            <a
              className="inline-flex items-center gap-1.5 text-primary hover:underline"
              href="https://github.com/v2fly/v2ray-core"
              target="_blank"
              rel="noreferrer noopener"
            >
              <Github size={12} /> V2Ray client (external dependency)
            </a>
          </section>

          <p className="text-[11px] text-on-surface-variant flex items-start gap-1.5">
            <Shield size={12} className="mt-0.5 flex-shrink-0" />
            For research and circumvention of carrier-side throttling on
            connections you own. Don't use this to defraud third parties.
            Tunnel snippets are written to disk with mode 0600.
          </p>
        </div>

        <footer className="flex items-center gap-2 px-4 py-3 border-t border-outline-variant">
          <div className="flex-1" />
          <button className="btn-primary" onClick={onClose}>
            Close
          </button>
        </footer>
      </div>
    </div>
  );
}

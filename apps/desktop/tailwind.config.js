/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        // Material 3 dark palette tuned for OLED + WCAG-AA contrast
        surface: "var(--md-surface)",
        "surface-2": "var(--md-surface-2)",
        "surface-3": "var(--md-surface-3)",
        "surface-4": "var(--md-surface-4)",
        outline: "var(--md-outline)",
        "outline-variant": "var(--md-outline-variant)",
        "on-surface": "var(--md-on-surface)",
        "on-surface-variant": "var(--md-on-surface-variant)",
        primary: "var(--md-primary)",
        "on-primary": "var(--md-on-primary)",
        secondary: "var(--md-secondary)",
        tertiary: "var(--md-tertiary)",
        success: "var(--md-success)",
        warning: "var(--md-warning)",
        error: "var(--md-error)",
        promo: "var(--md-promo)",
      },
      fontFamily: {
        sans: [
          "Inter",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
        mono: [
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "Consolas",
          "monospace",
        ],
      },
      boxShadow: {
        elev1: "0 1px 2px rgba(0,0,0,0.30), 0 1px 3px 1px rgba(0,0,0,0.15)",
        elev2: "0 1px 2px rgba(0,0,0,0.30), 0 2px 6px 2px rgba(0,0,0,0.15)",
        elev3: "0 4px 8px 3px rgba(0,0,0,0.15), 0 1px 3px rgba(0,0,0,0.30)",
      },
      animation: {
        "pulse-soft": "pulseSoft 2s ease-in-out infinite",
      },
      keyframes: {
        pulseSoft: {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.55" },
        },
      },
    },
  },
  plugins: [],
};

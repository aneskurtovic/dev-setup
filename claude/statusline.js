#!/usr/bin/env node
// Claude Code status line:
//   MODE · Model (effort) · context % · branch
//   5h/7d limits and reset times on a second line
// Reads session JSON on stdin, prints one line. Runs locally, costs no tokens.
// Fields are read defensively — many are null before the first API response,
// and rate_limits is absent entirely on API/Console billing (Pro/Max only).

const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

let input = "";
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  let data = {};
  try {
    data = JSON.parse(input);
  } catch {
    process.stdout.write("Claude\n");
    return;
  }

  // ── ANSI colors ───────────────────────────────────────────────
  const RESET = "\x1b[0m";
  const BOLD = "\x1b[1m";
  const DIM = "\x1b[2m";
  const CYAN = "\x1b[36m";
  const GREEN = "\x1b[32m";
  const YELLOW = "\x1b[33m";
  const RED = "\x1b[31m";
  const SEP = `${DIM} · ${RESET}`;

  // Green under 70%, yellow 70–89%, red 90%+ — used for context and both limits.
  const heat = (p) => (p >= 90 ? RED : p >= 70 ? YELLOW : GREEN);

  // 8500 → "8.5k", 280000 → "280k", 1000000 → "1M".
  const fmtTokens = (n) => {
    if (n >= 1_000_000) {
      const m = n / 1_000_000;
      return (m >= 10 || Number.isInteger(m) ? Math.round(m) : m.toFixed(1)) + "M";
    }
    if (n >= 1000) return Math.round(n / 1000) + "k";
    return String(n);
  };

  // Seconds → "4d6h30m", "2h10m", "45m", or "<1m".
  const fmtCountdown = (secs) => {
    if (secs <= 0) return "now";
    if (secs < 60) return "<1m";
    const d = Math.floor(secs / 86400);
    const h = Math.floor((secs % 86400) / 3600);
    const m = Math.floor((secs % 3600) / 60);
    let out = "";
    if (d > 0) out += `${d}d`;
    if (d > 0 || h > 0) out += `${h}h`;
    return out + `${m}m`;
  };

  const parts = [];

  // ── Permission mode chip (very first) ─────────────────────────
  // The status line payload has no permission_mode, so capture-mode.js (a
  // UserPromptSubmit hook) writes it to a per-session temp file we read here.
  const chip = (label, colorNum) => `\x1b[1;7;${colorNum}m ${label} ${RESET}`;
  const MODE_CHIP = {
    default: chip("CODE", 34), // blue
    plan: chip("PLAN", 32), // green
    acceptEdits: chip("ACCEPT", 33), // yellow
    auto: chip("AUTO", 36), // cyan
    dontAsk: chip("NO-ASK", 35), // magenta
    bypassPermissions: chip("BYPASS", 31), // red
  };
  try {
    const sid = data.session_id;
    if (sid) {
      const mode = fs.readFileSync(path.join(os.tmpdir(), `cc-mode-${sid}`), "utf8").trim();
      if (mode) parts.push(MODE_CHIP[mode] || chip(mode.toUpperCase(), 34));
    }
  } catch {}

  // ── Model (+ effort in parens) ────────────────────────────────
  const model = data.model?.display_name || "Claude";
  const effort = data.effort?.level;
  const effortStr = effort ? ` ${DIM}(${effort})${RESET}` : "";
  parts.push(`${BOLD}${CYAN}${model}${RESET}${effortStr}`);

  // Compact context readout; unknown until the first response.
  const pct = data.context_window?.used_percentage;
  parts.push(pct == null ? `${DIM}ctx --${RESET}` : `${heat(pct)}ctx ${Math.round(pct)}%${RESET}`);
  const limits = [];

  // ── Rate limits (Pro/Max only; absent on API billing) ─────────
  const rl = data.rate_limits;
  const now = Math.floor(Date.now() / 1000);

  const five = rl?.five_hour?.used_percentage;
  if (five != null) {
    const p = Math.round(five);
    const reset = rl.five_hour.resets_at;
    const when = reset ? ` ${DIM}(${fmtCountdown(reset - now)})${RESET}` : "";
    limits.push(`${DIM}5h${RESET} ${heat(p)}${p}%${RESET}${when}`);
  }

  const week = rl?.seven_day?.used_percentage;
  if (week != null) {
    const p = Math.round(week);
    const reset = rl.seven_day.resets_at;
    const when = reset ? ` ${DIM}(${fmtCountdown(reset - now)})${RESET}` : "";
    limits.push(`${DIM}7d${RESET} ${heat(p)}${p}%${RESET}${when}`);
  }

  // ── Git branch (very end) ─────────────────────────────────────
  const dir = data.workspace?.current_dir || data.cwd || process.cwd();
  try {
    const run = (...args) =>
      execFileSync("git", args, { cwd: dir, encoding: "utf8", timeout: 1000, windowsHide: true, stdio: ["pipe", "pipe", "ignore"] }).trim();
    let branch = run("branch", "--show-current");
    if (!branch) {
      const sha = run("rev-parse", "--short", "HEAD"); // detached HEAD
      if (sha) branch = `@${sha}`;
    }
    if (branch) {
      if (branch.length > 28) branch = branch.slice(0, 25) + "...";
      parts.push(`${GREEN}${branch}${RESET}`);
    }
  } catch {}

  process.stdout.write(parts.join(SEP) + "\n" + (limits.length ? limits.join(SEP) + "\n" : ""));
});

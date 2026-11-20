import { get, post, requestBlob, endpoints } from "./api.js";
import { createPlan, shell } from "./plans.js";
import { isAntigravity, isHermes, program } from "./hooks.js";

export const OPEN_DELAY_MS = 200;
export const MOVE_SLOP_PX = 4;
export const VIEW_LIMIT_BYTES = 262144;
export const PROVENANCE_PAGE = 200;
export const PROVENANCE_MAX = 1000;
const RELOAD_WAIT_MS = 5000;
const REVOKE_MS = 10000;
const HIDDEN = /[​-‏‪-‮⁦-⁩﻿\u0000-\u0008\u000B\u000C\u000E-\u001F]/g;

export const TABS = ["overview", "script", "provenance", "edit"];

export const KIND_SENTENCES = {
  first_seen: (file) => `First noticed by ordonnateur in ${file}.`,
  changed: () => "The hook's definition changed.",
  disappeared: (file) => `No longer found in ${file}.`,
  reappeared: (file) => `Found again in ${file}.`,
  enabled: () => "Switched on.",
  disabled: () => "Switched off.",
  edited: () => "Script edited.",
  deleted: () => "Hook deleted.",
};

export const BASIS_WORDS = {
  observed: { text: "Observed by ordonnateur", title: "ordonnateur saw this while reading the hook files." },
  ordonnateur: { text: "Done by ordonnateur", title: "ordonnateur made this change itself." },
  plugin_record: { text: "Plugin install record", title: "Taken from the plugin's own install record." },
  file_mtime: { text: "File modified time", title: "Taken from the file's modified time, which is not an install time." },
};

export const VIA_WORDS = { cli: "terminal", web: "web app", watch: "background watch", tick: "periodic check" };

const HINT_LABELS = { plugin_record: "plugin record", file_mtime: "file modified" };

export function basename(path) {
  const parts = String(path || "")
    .split("/")
    .filter(Boolean);
  return parts.length ? parts[parts.length - 1] : String(path || "");
}

function pad(value) {
  return String(value).padStart(2, "0");
}

export function formatTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value ?? "");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function isoTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value ?? "") : date.toISOString();
}

export function formatBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value)) return "";
  if (value < 1024) return `${value} B`;
  return `${(value / 1024).toFixed(1)} KiB`;
}

export function hiddenCharCount(text) {
  const found = String(text || "").match(HIDDEN);
  return found ? found.length : 0;
}

export function lineCount(text) {
  const value = String(text || "");
  if (!value) return 0;
  const lines = value.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines.length;
}

export function byteLength(text) {
  return new TextEncoder().encode(String(text || "")).length;
}

function clip(text, limit) {
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function stringify(value) {
  if (value === null || value === undefined) return "null";
  if (typeof value === "object") {
    try {
      return clip(JSON.stringify(value), 120);
    } catch (error) {
      return "";
    }
  }
  return clip(String(value), 120);
}

export function provenanceSentence(event) {
  const make = KIND_SENTENCES[event.kind];
  const file = basename(event.source_file) || "the hook file";
  return {
    text: make ? make(file) : String(event.kind || ""),
    sub: event.kind === "first_seen" ? "Not an install time." : "",
  };
}

export function provenanceBasis(event) {
  const basis = BASIS_WORDS[event.basis];
  const via = event.via ? VIA_WORDS[event.via] || event.via : "";
  const base = basis ? basis.text : String(event.basis || "");
  return {
    text: via ? `${base} · ${via}` : base,
    title: basis ? `${basis.title}${via ? ` Recorded by the ${via}.` : ""}` : "",
  };
}

export function provenanceDetail(event) {
  const detail = event.detail && typeof event.detail === "object" ? event.detail : null;
  if (!detail) return { pairs: "", hints: [] };
  const pairs = Object.entries(detail)
    .filter(([key]) => key !== "hints")
    .map(([key, value]) => `${key} ${stringify(value)}`)
    .join(" ");
  const hints = [];
  const raw = detail.hints;
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (item && typeof item === "object") hints.push({ basis: item.basis, at: item.at || item.time || item.value });
    }
  } else if (raw && typeof raw === "object") {
    for (const [basis, at] of Object.entries(raw)) hints.push({ basis, at });
  }
  return {
    pairs,
    hints: hints.map((hint) => `Hint, not an install time: ${HINT_LABELS[hint.basis] || String(hint.basis || "")} ${formatTime(hint.at)}.`),
  };
}

const SUMMARY_PHRASES = {
  first_seen: "noticed",
  changed: "changed",
  disappeared: "disappeared",
  reappeared: "reappeared",
  enabled: "switched on",
  disabled: "switched off",
  edited: "edited",
  deleted: "deleted",
};

export function historySentence(summary) {
  if (typeof summary === "string" && summary) return summary;
  if (!summary || typeof summary !== "object" || !Number(summary.count)) return "No history recorded.";
  const count = Number(summary.count);
  const phrase = (kind) => SUMMARY_PHRASES[kind] || String(kind || "changed").replace(/_/g, " ");
  const parts = [`First ${phrase(summary.first_kind)} ${formatTime(summary.first_at)}`];
  if (count > 1) parts.push(`last ${phrase(summary.last_kind)} ${formatTime(summary.last_at)}`);
  parts.push(plural(count, "event", "events"));
  return `${parts.join("; ")}.`;
}

export function refusalPhrase(text) {
  const value = String(text || "").trim();
  return /^is\s/.test(value) ? `This hook ${value}` : value;
}

export function loadDetail(hook, project, signal) {
  return get(endpoints.hook(hook.id, { project }), { signal });
}

export function loadProvenance(hookId, project, limit, signal) {
  return get(endpoints.provenance({ project, hook: hookId, limit }), { signal });
}

export function planScriptEdit(hookId, project, baseSha, content) {
  return post(endpoints.hookScriptPlan(hookId), { project: project || null, base_sha: baseSha, content });
}

export function deleteRequest(hook, project, base) {
  if (isHermes(hook)) return { scope: "user", project: null, base, changes: [{ op: "delete", hook: hook.id }] };
  if (isAntigravity(hook)) {
    const scope = hook.scope === "workspace" ? "workspace" : "global";
    return { scope, project: scope === "workspace" ? project || null : null, base, changes: [{ op: "delete", hook: hook.id }] };
  }
  return { scope: hook.scope, project: project || null, base, changes: [{ op: "delete", hook: hook.id }] };
}

export function planDelete(hook, project, base) {
  return createPlan(deleteRequest(hook, project, base));
}

export function openOnDesktop(hookId, target) {
  return post(endpoints.hookOpen(hookId), { target });
}

export async function downloadScript(hook) {
  const result = await requestBlob(endpoints.hookScript(hook.id), { fallback: program(hook).base });
  const href = URL.createObjectURL(result.blob);
  const anchor = document.createElement("a");
  anchor.href = href;
  anchor.download = result.filename;
  anchor.hidden = true;
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(href), REVOKE_MS);
  return result;
}

export function awaitLayoutReload() {
  const owner = shell();
  if (!owner || typeof owner.reloadKeepingDraft !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    let timer = 0;
    const done = () => {
      document.removeEventListener("od-layout-reloaded", done);
      window.clearTimeout(timer);
      window.setTimeout(resolve, 0);
    };
    document.addEventListener("od-layout-reloaded", done);
    timer = window.setTimeout(done, RELOAD_WAIT_MS);
    owner.reloadKeepingDraft();
  });
}

export function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many}`;
}

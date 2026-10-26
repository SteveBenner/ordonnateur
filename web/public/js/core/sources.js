import { getPref, setPref } from "./cache.js";

export const HARNESS_ORDER = ["claude-code", "codex", "hermes"];
export const SHAPES = ["square", "diamond", "triangle"];

const TAGS = { "claude-code": "Claude", codex: "Codex", hermes: "Hermes" };
const RANKS = { managed: 0, user: 1, project: 2, local: 3, plugin: 4, disabled: 5 };
const MAX_STORED = 64;

const FIXED = {
  "claude-code:user": 3,
  "claude-code:project": 2,
  "claude-code:local": 7,
  "claude-code:managed": 8,
  "codex:user": 4,
  "codex:managed": 1,
  "codex:project": 5,
  "hermes:user": 6,
};

export function rowKeyOfHook(hook) {
  if (hook.plugin) return `plugin:${hook.plugin}`;
  if (hook.status === "disabled-plugin") return "disabled";
  return hook.scope || "other";
}

export function providerKey(hook) {
  return `${hook.harness}:${rowKeyOfHook(hook)}`;
}

export function rowLabel(key, harness) {
  const codex = harness === "codex";
  if (harness === "hermes" && key === "user") return "Profile config";
  if (key === "managed") return "Managed";
  if (key === "user") return codex ? "User config" : "User settings";
  if (key === "project") return codex ? "Project config" : "Project settings";
  if (key === "local") return "Local settings";
  if (key === "disabled") return "Disabled plugins";
  if (key.startsWith("plugin:")) return key.slice(7);
  return key;
}

function fnv1a32(text) {
  let h = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    h = (h ^ byte) >>> 0;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

export function colorOf(key) {
  if (Object.prototype.hasOwnProperty.call(FIXED, key)) return { index: FIXED[key], shape: "circle" };
  const h = fnv1a32(key);
  return { index: (h % 8) + 1, shape: SHAPES[(h >>> 8) % 3] };
}

function splitKey(key) {
  const at = String(key).indexOf(":");
  if (at < 0) return { harness: String(key), row: "" };
  return { harness: key.slice(0, at), row: key.slice(at + 1) };
}

export function providerMeta(key) {
  const { harness, row } = splitKey(key);
  let kind = "other";
  if (row.startsWith("plugin:")) kind = "plugin";
  else if (Object.prototype.hasOwnProperty.call(RANKS, row)) kind = row;
  const label = rowLabel(row, harness);
  let short = label;
  if (kind === "plugin") {
    const id = row.slice(7);
    const cut = id.indexOf("@");
    short = cut > 0 ? id.slice(0, cut) : id;
  }
  const color = colorOf(key);
  return { key, harness, row, kind, label, short, color: color.index, shape: color.shape };
}

function inSet(hook, harness) {
  return hook.status !== "dispatcher" && (harness === "both" || hook.harness === harness);
}

function harnessIndex(harness) {
  const at = HARNESS_ORDER.indexOf(harness);
  return at < 0 ? HARNESS_ORDER.length : at;
}

function disambiguate(list) {
  const shorts = new Map();
  for (const item of list) shorts.set(item.short, (shorts.get(item.short) || 0) + 1);
  for (const item of list) if (shorts.get(item.short) > 1) item.short = item.label;
  const again = new Map();
  for (const item of list) again.set(item.short, (again.get(item.short) || 0) + 1);
  const labels = new Map();
  for (const item of list) labels.set(item.label, (labels.get(item.label) || 0) + 1);
  for (const item of list) {
    const tag = TAGS[item.harness] || item.harness;
    if (again.get(item.short) > 1) item.short = `${item.short} · ${tag}`;
    if (labels.get(item.label) > 1) item.label = `${item.label} · ${tag}`;
  }
}

export function providersOf(layout, harness, project) {
  const hooks = ((layout && layout.hooks) || []).filter((hook) => inSet(hook, harness));
  const counts = new Map();
  for (const hook of hooks) {
    const key = providerKey(hook);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  if (hooks.some((hook) => hook.harness === "claude-code")) {
    if (!counts.has("claude-code:user")) counts.set("claude-code:user", 0);
    if (project && !counts.has("claude-code:local")) counts.set("claude-code:local", 0);
  }
  const list = [...counts].map(([key, count]) => ({ ...providerMeta(key), count }));
  const rank = (item) => (Object.prototype.hasOwnProperty.call(RANKS, item.kind) ? RANKS[item.kind] : 6);
  list.sort((a, b) => {
    const byHarness = harnessIndex(a.harness) - harnessIndex(b.harness);
    if (byHarness) return byHarness;
    const byRank = rank(a) - rank(b);
    if (byRank) return byRank;
    return a.key.localeCompare(b.key);
  });
  disambiguate(list);
  return list;
}

function sanitize(raw) {
  if (!Array.isArray(raw)) return [];
  if (!raw.every((item) => typeof item === "string")) return [];
  return raw.slice(0, MAX_STORED);
}

function bootOverride() {
  let value = null;
  try {
    value = new URLSearchParams(window.location.search).get("off");
  } catch (error) {
    return null;
  }
  if (value === null) return null;
  if (value.trim() === "*") return { wildcard: true, list: [] };
  const list = value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, MAX_STORED);
  return { wildcard: false, list };
}

export function createSources() {
  let hidden = new Set(sanitize(getPref("sources", [])));
  let wildcard = false;
  const override = bootOverride();
  if (override) {
    if (override.wildcard) {
      wildcard = true;
      hidden = new Set();
    } else {
      hidden = new Set(override.list);
    }
  }
  const persist = () => setPref("sources", Array.from(hidden).sort());
  return {
    get hidden() {
      return hidden;
    },
    get pendingAll() {
      return wildcard;
    },
    resolve(keys) {
      if (!wildcard) return false;
      wildcard = false;
      hidden = new Set(keys);
      return true;
    },
    setHidden(next) {
      wildcard = false;
      hidden = new Set(next);
      persist();
    },
    isHidden(key) {
      return hidden.has(key);
    },
    toggle(key) {
      wildcard = false;
      if (hidden.has(key)) hidden.delete(key);
      else hidden.add(key);
      persist();
      return hidden.has(key);
    },
    only(key, keys) {
      wildcard = false;
      const others = (keys || []).filter((item) => item !== key);
      const alone = !hidden.has(key) && others.every((item) => hidden.has(item));
      if (alone) {
        hidden = new Set();
        persist();
        return "all";
      }
      const next = new Set([...hidden].filter((item) => !(keys || []).includes(item)));
      for (const item of others) next.add(item);
      hidden = next;
      persist();
      return "only";
    },
    showAll() {
      wildcard = false;
      hidden = new Set();
      persist();
    },
  };
}

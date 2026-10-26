import { getPref, setPref } from "./cache.js";
import { program, sourceLabel, statusText } from "./hooks.js";
import { queryParam } from "./query.js";

export const SORT_KEYS = ["order", "hook", "source", "status", "findings", "p95", "timeout"];

const FIRST_DIR = { order: "asc", hook: "asc", source: "asc", status: "asc", findings: "desc", p95: "desc", timeout: "desc" };
const RANK = { error: 3, warn: 2, info: 1 };
const DEFAULT_SORT = { key: "order", dir: "asc" };
const COLLATE = { sensitivity: "base", numeric: true };

let boot;

function bootSort() {
  if (boot !== undefined) return boot;
  const value = queryParam("sort");
  boot = value ? clean(value.split(":")[0], value.split(":")[1], null) : null;
  return boot;
}

function clean(key, dir, fallback) {
  if (!SORT_KEYS.includes(key)) return fallback;
  if (dir !== "asc" && dir !== "desc") return fallback;
  if (key === "order") return { ...DEFAULT_SORT };
  return { key, dir };
}

function sanitize(raw) {
  if (!raw || typeof raw !== "object") return { ...DEFAULT_SORT };
  return clean(raw.key, raw.dir, { ...DEFAULT_SORT });
}

export function readSort() {
  const fromPage = bootSort();
  if (fromPage) return { ...fromPage };
  return sanitize(getPref("sort", null));
}

export function nextSort(current, key) {
  if (key === "order") return { key: "order", dir: "asc" };
  if (current && current.key === key) return { key, dir: current.dir === "asc" ? "desc" : "asc" };
  return { key, dir: FIRST_DIR[key] || "asc" };
}

export function saveSort(sort) {
  setPref("sort", { key: sort.key, dir: sort.dir });
}

function present(value) {
  return value !== null && value !== undefined && value !== "" && !Number.isNaN(value);
}

function valueOf(key, hook, index) {
  if (key === "hook") return program(hook).base;
  if (key === "source") return sourceLabel(hook);
  if (key === "status") return statusText(hook) || null;
  if (key === "p95") return hook.timing && hook.timing.p95 != null ? Number(hook.timing.p95) : null;
  if (key === "timeout") {
    const effective = hook.effective_timeout != null ? hook.effective_timeout : hook.timeout;
    return effective == null ? null : Number(effective);
  }
  const ids = hook.findings || [];
  if (!ids.length) return null;
  let best = 0;
  for (const id of ids) {
    const finding = index && index.get(id);
    const rank = finding ? RANK[finding.severity] || 0 : 0;
    if (rank > best) best = rank;
  }
  return best * 100000 + ids.length;
}

function compare(a, b) {
  if (typeof a === "string" || typeof b === "string") return String(a).localeCompare(String(b), undefined, COLLATE);
  return a - b;
}

export function sortRows(entries, sort, index) {
  const rows = entries.map((entry, position) => ({ entry, position }));
  if (sort.key !== "order") {
    const sign = sort.dir === "desc" ? -1 : 1;
    const keyed = rows.map((row) => ({ ...row, value: valueOf(sort.key, row.entry.hook, index) }));
    keyed.sort((a, b) => {
      const aHas = present(a.value);
      const bHas = present(b.value);
      if (aHas !== bHas) return aHas ? -1 : 1;
      if (aHas) {
        const by = compare(a.value, b.value);
        if (by) return sign * by;
      }
      return a.position - b.position;
    });
    return keyed.map((row) => row.entry);
  }
  return rows.map((row) => row.entry);
}

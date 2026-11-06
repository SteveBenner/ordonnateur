import { get, post, endpoints } from "./api.js";
import { createStore } from "./store.js";
import { toast } from "./announce.js";

export const POLL_MS = 2000;
export const SLOW_POLL_MS = 10000;
export const READ_ONLY_COPY = "This server is read-only.";
export const BUSY_COPY = "Another run is active.";

export const runs = createStore({ active: null, done: { untangle: null, plan: null }, byId: {}, attached: false });

let timer = 0;
let failures = 0;
let attaching = null;
let hooked = false;

function remember(run, meta) {
  const state = runs.get();
  const previous = state.byId[run.run_id] || {};
  const merged = { ...previous, ...run };
  if (meta && meta.project !== undefined) merged.project = meta.project;
  const byId = { ...state.byId, [run.run_id]: merged };
  const done = { ...state.done };
  if ((run.verb === "untangle" || run.verb === "plan") && merged.status !== "running") done[run.verb] = run.run_id;
  let active = state.active;
  if (merged.status === "running") active = merged.run_id;
  else if (active === merged.run_id) active = null;
  runs.set({ byId, done, active });
  return merged;
}

export function runOf(id) {
  return id ? runs.get().byId[id] || null : null;
}

export function activeRun() {
  return runOf(runs.get().active);
}

export function latestRun(verb) {
  const state = runs.get();
  if (verb) return runOf(state.done[verb]);
  const all = [runOf(state.done.untangle), runOf(state.done.plan)].filter(Boolean);
  all.sort((a, b) => Date.parse(b.started_at || 0) - Date.parse(a.started_at || 0));
  return all[0] || null;
}

export function blockReason(readOnly) {
  if (readOnly) return READ_ONLY_COPY;
  if (runs.get().active) return BUSY_COPY;
  return null;
}

function schedule(delay) {
  window.clearTimeout(timer);
  timer = 0;
  if (!runs.get().active || document.visibilityState !== "visible") return;
  timer = window.setTimeout(poll, delay);
}

function finished(run) {
  const label = run.verb === "plan" ? "Plan" : "Untangle";
  if (run.status === "failed") {
    toast(run.error || "The run failed.", { kind: "error", title: `${label} run failed` });
  } else {
    toast(`${label} run finished.`, { kind: "info" });
  }
  document.dispatchEvent(new CustomEvent("od-run-finished", { detail: { run } }));
}

async function poll() {
  timer = 0;
  const id = runs.get().active;
  if (!id) return;
  try {
    const run = await get(endpoints.run(id), { retry: false });
    failures = 0;
    const merged = remember(run);
    if (merged.status !== "running") {
      finished(merged);
      return;
    }
  } catch (error) {
    failures += 1;
    if (error && error.status === 404) {
      const lost = remember({
        run_id: id,
        verb: (runOf(id) || {}).verb || "untangle",
        status: "failed",
        error: "The run is no longer available.",
        finished_at: new Date().toISOString(),
      });
      finished(lost);
      return;
    }
  }
  schedule(failures >= 3 ? SLOW_POLL_MS : POLL_MS);
}

function hook() {
  if (hooked) return;
  hooked = true;
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && runs.get().active) {
      window.clearTimeout(timer);
      timer = window.setTimeout(poll, 0);
    } else {
      window.clearTimeout(timer);
      timer = 0;
    }
  });
}

async function fetchRun(id) {
  try {
    return remember(await get(endpoints.run(id), { retry: false }));
  } catch (error) {
    return null;
  }
}

export function attach() {
  hook();
  if (attaching) return attaching;
  attaching = (async () => {
    try {
      const summary = await get(endpoints.runs);
      const latest = (summary && summary.latest) || {};
      const active = summary && summary.active;
      if (active && active.run_id) remember(active);
      const ids = [latest.untangle, latest.plan].filter((id) => id && !(active && active.run_id === id));
      await Promise.all(ids.map(fetchRun));
      if (runs.get().active) schedule(POLL_MS);
    } catch (error) {
      attaching = null;
    }
    runs.set({ attached: true });
  })();
  return attaching;
}

export async function start(body) {
  hook();
  try {
    const run = await post(endpoints.runs, body);
    failures = 0;
    const merged = remember({ ...run, status: run.status || "running" }, { project: body.project || null });
    schedule(POLL_MS);
    return merged;
  } catch (error) {
    if (error && error.code === "run_active" && error.body && error.body.run_id) {
      await fetchRun(error.body.run_id);
      schedule(POLL_MS);
    }
    throw error;
  }
}

export function elapsedSeconds(run, now = Date.now()) {
  const began = Date.parse(run && run.started_at);
  if (!Number.isFinite(began)) return 0;
  return Math.max(0, Math.floor((now - began) / 1000));
}

export function clock(seconds) {
  const minutes = Math.floor(seconds / 60);
  const rest = String(seconds % 60).padStart(2, "0");
  return `${minutes}:${rest}`;
}

export function clockTime(stamp) {
  const date = new Date(stamp);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

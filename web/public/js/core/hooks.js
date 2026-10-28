import { providerKey } from "./sources.js";

export const HARNESS_LABELS = { "claude-code": "Claude Code", codex: "Codex", hermes: "Hermes", antigravity: "Antigravity" };

const SOURCE_RANK = { managed: 0, user: 1, global: 1, project: 2, workspace: 2, local: 3, plugin: 4 };

let tipSequence = 0;

export function nextId(prefix) {
  tipSequence += 1;
  return `${prefix}-${tipSequence}`;
}

export function program(hook) {
  let text = "";
  if (typeof hook.command === "string" && hook.command.trim()) text = hook.command.trim();
  else if (Array.isArray(hook.args) && hook.args.length) text = String(hook.args[0]);
  const home = "$HOME";
  text = text.split(home).join("~").split("${HOME}").join("~");
  const first = text.match(/^"([^"]*)"|^'([^']*)'|^\S+/);
  if (!first) return { word: "", base: hook.id || "hook", full: hook.command || "" };
  const word = first[1] ?? first[2] ?? first[0];
  const segments = word.split(/[\\/]/).filter(Boolean);
  const base = segments.length ? segments[segments.length - 1] : word;
  return { word, base, full: hook.command || (Array.isArray(hook.args) ? hook.args.join(" ") : "") };
}

export function middle(text, keep) {
  const value = String(text ?? "");
  if (value.length <= keep * 2 + 1) return value;
  return `${value.slice(0, keep)}…${value.slice(-keep)}`;
}

const charWidths = new Map();
let measureCanvas = null;

function charWidth(node) {
  const style = getComputedStyle(node);
  const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  if (!charWidths.has(font)) {
    measureCanvas = measureCanvas || document.createElement("canvas");
    const context = measureCanvas.getContext("2d");
    context.font = font;
    charWidths.set(font, context.measureText("0000000000").width / 10 || 1);
  }
  return charWidths.get(font);
}

function setFitText(node, text) {
  const dot = node.querySelector(":scope > .od-src-dot");
  if (dot) node.replaceChildren(dot, document.createTextNode(text));
  else node.textContent = text;
}

export function fitMiddle(root) {
  if (!root) return;
  const nodes = [...root.querySelectorAll("[data-fit]")];
  for (const node of nodes) if (node.textContent !== node.dataset.fit) setFitText(node, node.dataset.fit);
  const sizes = nodes.map((node) => [node.clientWidth, node.scrollWidth]);
  nodes.forEach((node, index) => {
    const [client, scroll] = sizes[index];
    if (!client || scroll <= client) return;
    const fit = Math.floor(client / charWidth(node));
    setFitText(node, middle(node.dataset.fit, Math.max(1, Math.floor((fit - 1) / 2))));
  });
}

export function isMember(hook) {
  return typeof hook.status === "string" && hook.status.startsWith("member#");
}

export function memberPosition(hook) {
  const parsed = Number.parseInt(String(hook.status).slice(7), 10);
  if (Number.isFinite(parsed)) return parsed;
  return hook.member_position || 0;
}

export function isDispatcher(hook) {
  return hook.status === "dispatcher";
}

export function disabledPlugin(hook) {
  return hook.status === "disabled-plugin";
}

export function sourceRank(hook) {
  if (disabledPlugin(hook)) return 5;
  return SOURCE_RANK[hook.scope] ?? 6;
}

export function isHermes(hook) {
  return Boolean(hook) && hook.harness === "hermes";
}

export function isAntigravity(hook) {
  return Boolean(hook) && hook.harness === "antigravity";
}

export function isPinned(hook) {
  return (isHermes(hook) || isAntigravity(hook)) && Boolean(hook.guard || hook.hard_guard || hook.protected);
}

export const AG_MEMBER_SPEC = "ordonnateur";

export function agWritable(hook) {
  return isAntigravity(hook) && (hook.scope === "global" || hook.scope === "workspace") && Boolean(hook.source_file);
}

export function agEnabled(hook) {
  return isAntigravity(hook) && (hook.status === "active" || hook.status === "member");
}

export function agRuns(hook) {
  return isAntigravity(hook) && (hook.status === "active" || hook.status === "member" || hook.status === "prompt");
}

export function agOrderable(hook) {
  if (!agWritable(hook) || !agEnabled(hook) || isPinned(hook)) return false;
  return hook.member === true || hook.hook_name !== AG_MEMBER_SPEC;
}

export function agFileKey(hook) {
  return `${hook.scope}|${hook.source_file}`;
}

export function agScopeName(hook) {
  if (hook.scope === "global") return "Global hooks";
  if (hook.scope === "workspace") return "Workspace hooks";
  return hook.plugin || "Plugin hooks";
}

export function hermesEvents(layout, event) {
  return ((layout && layout.hooks) || [])
    .filter((hook) => isHermes(hook) && hook.event === event)
    .sort((a, b) => (a.group_index || 0) - (b.group_index || 0));
}

export function sourceLabel(hook) {
  if (isHermes(hook)) return "Profile config";
  if (isAntigravity(hook)) return hook.hook_name ? `${agScopeName(hook)} · ${hook.hook_name}` : agScopeName(hook);
  if (hook.plugin) return hook.plugin;
  const codex = hook.harness === "codex";
  if (hook.scope === "managed") return "Managed";
  if (hook.scope === "user") return codex ? "User config" : "User settings";
  if (hook.scope === "project") return codex ? "Project config" : "Project settings";
  if (hook.scope === "local") return "Local settings";
  return hook.scope || "Unknown";
}

export function compareSources(a, b) {
  const rank = sourceRank(a) - sourceRank(b);
  if (rank) return rank;
  const label = sourceLabel(a).localeCompare(sourceLabel(b));
  if (label) return label;
  const aMember = isMember(a) ? 0 : 1;
  const bMember = isMember(b) ? 0 : 1;
  if (aMember !== bMember) return aMember - bMember;
  if (isMember(a)) return memberPosition(a) - memberPosition(b);
  return 0;
}

function hermesConsent(hook) {
  const trust = hook.trust || {};
  const state = trust.state || hook.status;
  if (state === "allowlisted") {
    return { value: "allowlisted", reason: trust.approved_at ? `Allowlisted, approved ${trust.approved_at}` : "Allowlisted: Hermes runs this hook." };
  }
  if (state === "auto-accepted") {
    return { value: "auto_accepted", reason: `Auto-accepted: an opt-in (${trust.opt_in || "set"}) approves every hook` };
  }
  return { value: "not_allowlisted", reason: "Not allowlisted: Hermes does not run this hook until it is approved in Hermes" };
}

export function pinReason(hook) {
  let text = "A fail-closed hook on a blocking event keeps its place.";
  if (hook.protected && hook.protected_reason) text = hook.protected_reason;
  else if (hook.reason) text = `${program(hook).base} ${hook.reason}`;
  return /[.!?]$/.test(text) ? text : `${text}.`;
}

function agStatus(hook) {
  if (isPinned(hook)) {
    return { value: hook.protected ? "protected" : "guard", reason: `Pinned: ${pinReason(hook)}` };
  }
  if (hook.status === "member" || isMember(hook)) return null;
  if (hook.status === "disabled") return { value: "disabled", reason: "This hook spec is switched off (enabled is false)." };
  if (hook.status === "disabled-plugin") return { value: "disabled_plugin", reason: "The plugin is not enabled." };
  if (hook.status === "file-skipped") return { value: "file_skipped", reason: "Antigravity skips this whole file." };
  if (hook.status === "ignored-event") return { value: "ignored_event", reason: "Antigravity ignores this event name." };
  if (hook.status === "prompt") return { value: "prompt", reason: "A prompt hook calls a model; ordonnateur does not fire it." };
  return { value: "active", reason: "" };
}

export function statusOf(hook) {
  if (isAntigravity(hook)) return agStatus(hook);
  if (isHermes(hook)) {
    const consent = hermesConsent(hook);
    if (isPinned(hook)) {
      return {
        value: hook.protected ? "protected" : "guard",
        reason: `Pinned: ${pinReason(hook)} ${consent.reason}`,
        consent,
      };
    }
    return consent;
  }
  if (hook.harness === "codex") {
    if (hook.status === "disabled") return { value: "disabled", reason: "This hook is disabled in the Codex trust record." };
    if (hook.status === "trust-recorded") return { value: "trusted", reason: "A trust hash is recorded for this hook." };
    if (hook.status === "untrusted") return { value: "untrusted", reason: "Codex has no trust record for this hook." };
    return { value: "native", reason: "" };
  }
  if (isMember(hook)) return null;
  if (disabledPlugin(hook)) return { value: "disabled_plugin", reason: "The plugin is not enabled." };
  if (hook.protected) return { value: "protected", reason: hook.protected_reason || "A policy protects this hook." };
  if (hook.status === "guard") return { value: "guard", reason: hook.reason || "This hook can block, so it stays native." };
  if (hook.status === "not-sequenceable") return { value: "not_sequenceable", reason: hook.reason || "" };
  return { value: "native", reason: hook.reason || "" };
}

export function statusText(hook) {
  if (isMember(hook)) return `member ${memberPosition(hook)}`;
  if (isAntigravity(hook) && hook.status === "member") return "member";
  const status = statusOf(hook);
  if (!status) return "";
  const labels = {
    native: "Native",
    guard: "Guard",
    protected: "Protected",
    not_sequenceable: "Not sequenceable",
    disabled_plugin: "Disabled plugin",
    trusted: "Trusted",
    untrusted: "Untrusted",
    disabled: "Disabled",
    allowlisted: "Allowlisted",
    not_allowlisted: "Not allowlisted",
    auto_accepted: "Auto-accepted",
    active: "Active",
    file_skipped: "File skipped",
    ignored_event: "Ignored event",
    prompt: "Prompt",
  };
  return labels[status.value] || status.value;
}

export function allHooks(layout, harness) {
  const hooks = (layout && layout.hooks) || [];
  return hooks.filter((hook) => !isDispatcher(hook) && (harness === "both" || hook.harness === harness));
}

export function visibleHooks(layout, harness, hidden) {
  const hooks = allHooks(layout, harness);
  if (!hidden || !hidden.size) return hooks;
  return hooks.filter((hook) => !hidden.has(providerKey(hook)));
}

export function harnessesFor(harness) {
  return harness === "both" ? ["claude-code", "codex", "hermes", "antigravity"] : [harness];
}

export function eventSummary(hooks) {
  if (hooks.length && hooks.every(isHermes)) return `${hooks.length} ${hooks.length === 1 ? "hook" : "hooks"} in order`;
  if (hooks.length && hooks.every(isAntigravity)) {
    const specs = new Set(hooks.map((hook) => `${hook.source_file}|${hook.hook_name}`)).size;
    return `${hooks.length} ${hooks.length === 1 ? "hook" : "hooks"} · ${specs} ${specs === 1 ? "spec" : "specs"}`;
  }
  const natives = hooks.filter((hook) => !isMember(hook)).length;
  const frames = new Set(hooks.filter(isMember).map((hook) => `${hook.scope}|${hook.source_file}`)).size;
  const top = natives + frames;
  const parts = [`${top} at once`];
  if (frames) parts.push(`${frames} ${frames === 1 ? "sequence" : "sequences"}`);
  return parts.join(" · ");
}

export function findingIndex(layout) {
  const map = new Map();
  for (const finding of (layout && layout.findings) || []) map.set(finding.id, finding);
  return map;
}

export function worstSeverity(hook, index) {
  const order = ["error", "warn", "info"];
  let best = null;
  for (const id of hook.findings || []) {
    const finding = index.get(id);
    if (!finding) continue;
    if (best === null || order.indexOf(finding.severity) < order.indexOf(best)) best = finding.severity;
  }
  return best;
}

export function draftKeys(project) {
  const suffix = `.${project || "none"}`;
  const found = [];
  try {
    for (let i = 0; i < window.sessionStorage.length; i += 1) {
      const key = window.sessionStorage.key(i);
      if (key && key.startsWith("ordonnateur.web.draft.") && key.endsWith(suffix)) found.push(key);
    }
  } catch (error) {
    return [];
  }
  return found;
}

export function draftScopes(project) {
  const prefix = "ordonnateur.web.draft.";
  const suffix = `.${project || "none"}`;
  return draftKeys(project).map((key) => key.slice(prefix.length, key.length - suffix.length));
}

import { announce, toast } from "../core/announce.js";
import { isHermes, isPinned, program } from "../core/hooks.js";
import {
  HERMES_SCOPE,
  cardStop,
  count,
  originalHermes,
  originalMembers,
  project as projectDraft,
  projectHermes,
  setGuard,
  setHermesOrder,
  setOrder,
} from "../core/draft.js";

const SCOPE_LABELS = { user: "User settings", local: "Local settings" };

const LABELS = {
  up: "Move up",
  down: "Move down",
  first: "Move to first",
  last: "Move to last",
  sequence: "Sequence this hook",
  release: "Release from sequence",
  unguard: "Unguard",
  guard: "Guard",
  select: "Show details",
  copy: "Copy id",
};

const GROUPS = [["up", "down", "first", "last"], ["sequence", "release"], ["unguard", "guard"], ["select", "copy"]];

export function scopeLabel(scope) {
  return SCOPE_LABELS[scope] || scope;
}

export function isEditable(hook, context) {
  if (!context || context.readOnly) return false;
  if (hook.harness !== "claude-code" || hook.plugin) return false;
  if (hook.scope === "user") return true;
  return hook.scope === "local" && Boolean(context.project);
}

export function hermesMoves(hook, context) {
  if (!context || context.readOnly || !isHermes(hook) || isPinned(hook)) return null;
  const order = projectHermes(context.layout, context.project).orders.get(hook.event) || [];
  const ids = order.filter((item) => !isPinned(item)).map((item) => item.id);
  const index = ids.indexOf(hook.id);
  if (ids.length < 2 || index < 0) return null;
  const enabled = [];
  const disabled = {};
  if (index > 0) enabled.push("up", "first");
  else {
    disabled.up = "Already first";
    disabled.first = "Already first";
  }
  if (index < ids.length - 1) enabled.push("down", "last");
  else {
    disabled.down = "Already last";
    disabled.last = "Already last";
  }
  return { ids, index, enabled, disabled };
}

export function allowedActions(hook, context) {
  const allowed = ["select", "copy"];
  if (isHermes(hook)) {
    const moves = hermesMoves(hook, context);
    if (!moves) return allowed;
    const order = ["up", "down", "first", "last"];
    return order.filter((name) => moves.enabled.includes(name)).concat(allowed);
  }
  if (!isEditable(hook, context)) return allowed;
  const state = projectDraft(context.layout, context.project);
  const key = `${hook.scope}|${hook.event}`;
  const members = state.members.get(key) || [];
  const index = members.findIndex((member) => member.id === hook.id);
  const sequenceable = ((context.config && context.config.sequenceable) || []).includes(hook.event);
  const guardEvents = (context.config && context.config.guard_events) || [];
  const guardNow = state.guards.has(hook.id) ? state.guards.get(hook.id) : Boolean(hook.guard);
  const wasMember = String(hook.status).startsWith("member#");
  const blocked = state.touched.has(key) && !state.guards.has(hook.id);
  const items = [];
  if (index >= 0) {
    if (index > 0) items.push("up");
    if (index < members.length - 1) items.push("down");
    if (index > 0) items.push("first");
    if (index < members.length - 1) items.push("last");
    items.push("release");
  } else if ((hook.absorbable || wasMember) && sequenceable && !guardNow && !state.guards.has(hook.id)) {
    items.push("sequence");
  }
  if (!blocked && guardNow && !hook.hard_guard && !wasMember) items.push("unguard");
  if (!blocked && !guardNow && (wasMember || guardEvents.includes(hook.event))) items.push("guard");
  return items.concat(allowed);
}

function plural(total) {
  if (total === 0) return "no changes";
  return `${total} ${total === 1 ? "change" : "changes"}`;
}

function draftSentence(scope, context) {
  return `Draft: ${plural(count(scope, context.project))}.`;
}

function copyId(hook) {
  const write = navigator.clipboard && navigator.clipboard.writeText ? navigator.clipboard.writeText(hook.id) : Promise.reject(new Error("no clipboard"));
  write.then(
    () => toast(hook.id, { title: "Copied id" }),
    () => toast(hook.id, { kind: "error", title: "Could not copy the id" }),
  );
}

export function perform(action, hook, context, trigger) {
  if (action === "select") {
    document.dispatchEvent(new CustomEvent("od-hook-select", { detail: { hook, trigger } }));
    return true;
  }
  if (action === "copy") {
    copyId(hook);
    return true;
  }
  if (!allowedActions(hook, context).includes(action)) return false;
  const layout = context.layout;
  if (isHermes(hook)) {
    const moves = hermesMoves(hook, context);
    const ids = moves.ids.slice();
    ids.splice(moves.index, 1);
    const target = action === "up" ? moves.index - 1 : action === "down" ? moves.index + 1 : action === "first" ? 0 : ids.length;
    ids.splice(target, 0, hook.id);
    return commitHermes(hook, context, ids);
  }
  const scope = hook.scope;
  const base = layout && layout.fingerprint ? layout.fingerprint.config : null;
  const name = program(hook).base;
  if (action === "guard" || action === "unguard") {
    setGuard(scope, context.project, base, hook.id, action === "guard");
    announce(`${action === "guard" ? "Guarded" : "Unguarded"} ${name} on ${hook.event}, ${scopeLabel(scope)}. ${draftSentence(scope, context)}`);
    return true;
  }
  const state = projectDraft(layout, context.project);
  const ids = (state.members.get(`${scope}|${hook.event}`) || []).map((member) => member.id);
  const index = ids.indexOf(hook.id);
  if (action === "sequence") {
    ids.push(hook.id);
    return commit(hook, context, ids, "sequence");
  }
  if (action === "release") {
    ids.splice(index, 1);
    return commit(hook, context, ids, "release");
  }
  ids.splice(index, 1);
  const target = action === "up" ? index - 1 : action === "down" ? index + 1 : action === "first" ? 0 : ids.length;
  ids.splice(target, 0, hook.id);
  return commit(hook, context, ids, "move");
}

export function commit(hook, context, ids, kind) {
  const layout = context.layout;
  const scope = hook.scope;
  const base = layout && layout.fingerprint ? layout.fingerprint.config : null;
  const name = program(hook).base;
  const place = ids.indexOf(hook.id) + 1;
  let sentence = `Moved ${name} to position ${place} of ${ids.length} in ${hook.event}, ${scopeLabel(scope)}.`;
  if (kind === "sequence") sentence = `Sequenced ${name} as position ${place} of ${ids.length} in ${hook.event}, ${scopeLabel(scope)}.`;
  if (kind === "release") sentence = `Released ${name} from the ${hook.event} sequence, ${scopeLabel(scope)}.`;
  setOrder(scope, context.project, base, hook.event, ids, null, originalMembers(layout, scope, hook.event), cardStop(layout, scope, hook.event));
  announce(`${sentence} ${draftSentence(scope, context)}`);
  document.dispatchEvent(new CustomEvent("od-hook-focus", { detail: { id: hook.id } }));
  return true;
}

export function commitHermes(hook, context, ids) {
  const layout = context.layout;
  const base = layout && layout.fingerprint ? layout.fingerprint.config : null;
  setHermesOrder(context.project, base, hook.event, ids, originalHermes(layout, hook.event));
  const full = (projectHermes(layout, context.project).orders.get(hook.event) || []).map((item) => item.id);
  const place = full.indexOf(hook.id) + 1;
  announce(`${program(hook).base} moved to position ${place} of ${full.length} on ${hook.event}. ${draftSentence(HERMES_SCOPE, context)}`);
  document.dispatchEvent(new CustomEvent("od-hook-focus", { detail: { id: hook.id } }));
  return true;
}

export function shortcut(event, hook, context) {
  let action = null;
  if (event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey) {
    if (event.key === "ArrowUp") action = "up";
    else if (event.key === "ArrowDown") action = "down";
    else if (event.key === "Home") action = "first";
    else if (event.key === "End") action = "last";
  } else if (!event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey) {
    if (event.key === "s") action = "sequence";
    else if (event.key === "r") action = "release";
    else if (event.key === "g") {
      const allowed = allowedActions(hook, context);
      action = allowed.includes("unguard") ? "unguard" : allowed.includes("guard") ? "guard" : null;
    }
  }
  if (!action) return false;
  if (!allowedActions(hook, context).includes(action)) return false;
  event.preventDefault();
  perform(action, hook, context, event.currentTarget);
  return true;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

let sequence = 0;

class OdHookMenu extends HTMLElement {
  set context(value) {
    this.ctx = value;
  }

  get context() {
    return this.ctx;
  }

  connectedCallback() {
    sequence += 1;
    this.uid = `od-hook-menu-${sequence}`;
    this.onAction = (event) => {
      const detail = event.detail;
      if (!detail || detail.action !== "menu") return;
      this.open(detail.hook, detail.trigger, this.ctx || detail.context);
    };
    this.onOutside = (event) => {
      if (this.panel && !this.panel.contains(event.target)) this.close(false);
    };
    this.onResize = () => this.close(false);
    this.onSources = () => this.close(false);
    document.addEventListener("od-hook-action", this.onAction);
    document.addEventListener("od-sources-change", this.onSources);
  }

  disconnectedCallback() {
    document.removeEventListener("od-hook-action", this.onAction);
    document.removeEventListener("od-sources-change", this.onSources);
    this.close(false);
  }

  open(hook, trigger, context) {
    if (!hook || !context) return;
    this.close(false);
    this.hook = hook;
    this.trigger = trigger;
    const allowed = allowedActions(hook, context);
    const panel = document.createElement("div");
    panel.className = "od-menu";
    panel.id = `${this.uid}-list`;
    panel.setAttribute("role", "menu");
    panel.setAttribute("aria-label", `Actions for ${program(hook).base}`);
    let first = true;
    const moves = hermesMoves(hook, context);
    for (const group of GROUPS) {
      const present = group.filter((name) => allowed.includes(name) || (moves && name in moves.disabled));
      if (!present.length) continue;
      if (!first) {
        const rule = document.createElement("div");
        rule.className = "od-menu-rule";
        rule.setAttribute("role", "separator");
        panel.append(rule);
      }
      first = false;
      for (const name of present) {
        const item = document.createElement("div");
        item.className = "od-menu-item";
        item.setAttribute("role", "menuitem");
        item.tabIndex = -1;
        item.dataset.action = name;
        item.textContent = LABELS[name];
        if (moves && moves.disabled[name]) {
          item.setAttribute("aria-disabled", "true");
          item.append(el("span", "od-menu-note", ` ${moves.disabled[name]}`));
        }
        item.addEventListener("click", () => this.choose(name, context));
        item.addEventListener("pointermove", () => item.focus({ preventScroll: true }));
        panel.append(item);
      }
    }
    panel.addEventListener("keydown", (event) => this.onKey(event, context));
    this.append(panel);
    this.panel = panel;
    document.dispatchEvent(new CustomEvent("od-overlay-open"));
    this.place();
    document.addEventListener("pointerdown", this.onOutside, true);
    window.addEventListener("resize", this.onResize);
    this.items()[0].focus();
    if (trigger && trigger.setAttribute) trigger.setAttribute("aria-expanded", "true");
  }

  items() {
    return [...this.panel.querySelectorAll("[role=menuitem]")];
  }

  place() {
    const margin = 8;
    const anchor = this.trigger && this.trigger.getBoundingClientRect ? this.trigger.getBoundingClientRect() : { left: margin, right: margin, top: margin, bottom: margin };
    this.panel.style.left = "0px";
    this.panel.style.top = "0px";
    const own = this.panel.getBoundingClientRect();
    let top = anchor.bottom + 4;
    if (top + own.height > window.innerHeight - margin) top = Math.max(margin, anchor.top - own.height - 4);
    const left = Math.max(margin, Math.min(anchor.right - own.width, window.innerWidth - own.width - margin));
    this.panel.style.left = `${Math.round(left)}px`;
    this.panel.style.top = `${Math.round(top)}px`;
  }

  onKey(event, context) {
    const items = this.items();
    const index = items.indexOf(document.activeElement);
    if (event.key === "ArrowDown") {
      event.preventDefault();
      items[(index + 1) % items.length].focus();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      items[(index - 1 + items.length) % items.length].focus();
    } else if (event.key === "Home") {
      event.preventDefault();
      items[0].focus();
    } else if (event.key === "End") {
      event.preventDefault();
      items[items.length - 1].focus();
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      if (index >= 0) this.choose(items[index].dataset.action, context);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.close(true);
    } else if (event.key === "Tab") {
      this.close(false);
    }
  }

  choose(name, context) {
    const current = this.panel && this.panel.querySelector(`[data-action="${name}"]`);
    if (current && current.getAttribute("aria-disabled") === "true") return;
    const hook = this.hook;
    const trigger = this.trigger;
    this.close(true);
    perform(name, hook, context, trigger);
  }

  close(restore) {
    if (!this.panel) return;
    const trigger = this.trigger;
    this.panel.remove();
    this.panel = null;
    document.removeEventListener("pointerdown", this.onOutside, true);
    window.removeEventListener("resize", this.onResize);
    if (trigger && trigger.removeAttribute) trigger.removeAttribute("aria-expanded");
    if (restore && trigger && trigger.isConnected && trigger.focus) trigger.focus();
  }
}

customElements.define("od-hook-menu", OdHookMenu);

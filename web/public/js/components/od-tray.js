import "./od-button.js";
import * as draft from "../core/draft.js";
import { announce } from "../core/announce.js";
import { shell, scopeLabel, changeCount } from "../core/plans.js";

function providerOfScope(scope) {
  if (draft.isHermesScope(scope)) return "hermes:user";
  if (draft.isAntigravityScope(scope)) {
    const parsed = draft.parseAntigravityScope(scope);
    return parsed.kind === "global" ? "antigravity:global" : `antigravity:workspace:${parsed.path}`;
  }
  return `claude-code:${scope}`;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(text, variant, handler) {
  const node = document.createElement("od-button");
  node.setAttribute("variant", variant);
  node.text = text;
  node.addEventListener("click", handler);
  return node;
}

class OdTray extends HTMLElement {
  connectedCallback() {
    if (this.section) return;
    this.section = el("section", "od-tray");
    this.section.setAttribute("aria-label", "Draft");
    this.append(this.section);
    this.refresh = () => this.render();
    for (const name of ["od-draft-change", "od-layout-loaded", "od-layout-reloaded", "od-draft-discarded", "od-sources-change"]) {
      document.addEventListener(name, this.refresh);
    }
    this.render();
  }

  disconnectedCallback() {
    for (const name of ["od-draft-change", "od-layout-loaded", "od-layout-reloaded", "od-draft-discarded", "od-sources-change"]) {
      document.removeEventListener(name, this.refresh);
    }
  }

  context() {
    const owner = shell();
    return owner && typeof owner.context === "function" ? owner.context() : null;
  }

  host() {
    return this.closest(".od-tray-host");
  }

  render() {
    const context = this.context();
    const host = this.host();
    if (!context || !host) return;
    const groups = context.readOnly ? [] : draft.scopesWithChanges(context.project);
    host.hidden = groups.length === 0;
    const hidden = (context.sources && context.sources.hidden) || new Set();
    for (const group of groups) group.hidden = hidden.has(providerOfScope(group.scope));
    const signature = JSON.stringify([context.project, groups.map((group) => [group.scope, group.count, group.hidden])]);
    if (signature === this.signature) return;
    this.signature = signature;
    const focused = this.section.contains(document.activeElement) ? document.activeElement.closest("[data-key]") : null;
    const focusKey = focused ? focused.dataset.key : null;
    this.section.replaceChildren(...groups.map((group) => this.group(group, context)));
    if (focusKey) {
      const target = this.section.querySelector(`[data-key="${focusKey}"]`);
      if (target) target.focus();
    }
  }

  group(group, context) {
    const wrap = el("div", "od-tray-group");
    wrap.setAttribute("role", "group");
    const label = `${scopeLabel(group.scope)}: ${changeCount(group.count)}${group.hidden ? " · hidden" : ""}`;
    wrap.setAttribute("aria-label", label);
    const text = el("span", "od-tray-text", label);
    const actions = el("div", "od-tray-actions");
    const discard = button("Discard", "ghost", () => this.discard(group, context));
    discard.dataset.key = `${group.scope}-discard`;
    const plan = button("Plan", "primary", () => {
      document.dispatchEvent(
        new CustomEvent("od-open-plan", { detail: { scope: group.scope, project: context.project, trigger: plan } }),
      );
    });
    plan.dataset.key = `${group.scope}-plan`;
    actions.append(discard, plan);
    wrap.append(text, actions);
    return wrap;
  }

  discard(group, context) {
    draft.discard(group.scope, context.project);
    announce(`Discarded the draft for ${scopeLabel(group.scope)}.`);
    const owner = shell();
    if (owner && owner.changedOnDisk && typeof owner.reloadKeepingDraft === "function") owner.reloadKeepingDraft();
  }
}

customElements.define("od-tray", OdTray);

export function mountTray() {
  const host = document.querySelector(".od-tray-host");
  if (!host || host.querySelector("od-tray")) return;
  host.append(document.createElement("od-tray"));
}

document.addEventListener("od-layout-loaded", mountTray);
mountTray();

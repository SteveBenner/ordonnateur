import "./od-chip.js";
import "./od-tooltip.js";
import "./od-icon-button.js";
import { providerKey, providerMeta } from "../core/sources.js";
import { isMember, memberPosition, nextId, pinReason, program, sourceLabel, statusOf, statusText, worstSeverity } from "../core/hooks.js";

const NS = "http://www.w3.org/2000/svg";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function glyph(name, className = "od-icon") {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function tipped(node, text) {
  const wrap = el("span", "od-tipped");
  if (!text) {
    wrap.append(node);
    return wrap;
  }
  node.id = node.id || nextId("od-tip-target");
  const tip = document.createElement("od-tooltip");
  tip.setAttribute("for", node.id);
  tip.setAttribute("text", text);
  wrap.append(node, tip);
  return wrap;
}

function statusChip(hook) {
  const status = statusOf(hook);
  if (!status) return null;
  const chip = document.createElement("od-chip");
  chip.setAttribute("kind", "status");
  chip.setAttribute("value", status.value);
  const holder = el("span", "od-chip-host");
  holder.append(chip);
  return tipped(holder, status.reason);
}

function consentChip(hook) {
  const status = statusOf(hook);
  if (!status || !status.consent || status.consent.value === "allowlisted") return null;
  const chip = document.createElement("od-chip");
  chip.setAttribute("kind", "status");
  chip.setAttribute("value", status.consent.value);
  chip.setAttribute("icon-only", "");
  const holder = el("span", "od-chip-host");
  holder.append(chip);
  return tipped(holder, status.consent.reason);
}

function timeoutText(hook) {
  const value = hook.effective_timeout != null ? hook.effective_timeout : hook.timeout;
  return value == null ? "n/a" : `${value} s`;
}

function p95Text(hook) {
  return hook.timing && hook.timing.p95 != null ? `${Math.round(hook.timing.p95)} ms` : "n/a";
}

export function labelFor(hook, position) {
  const names = program(hook);
  const status = isMember(hook) ? `member ${position || memberPosition(hook)}` : statusText(hook);
  return `${names.base} on ${hook.event}, ${sourceLabel(hook)}, ${status}`;
}

class OdHookCard extends HTMLElement {
  set model(value) {
    this.m = value;
    if (this.isConnected) this.render();
  }

  get model() {
    return this.m;
  }

  get hook() {
    return this.m ? this.m.original : null;
  }

  get card() {
    return this.node;
  }

  connectedCallback() {
    if (this.m && !this.node) this.render();
  }

  render() {
    const m = this.m;
    const hook = m.hook;
    const names = program(hook);
    const compact = m.density === "compact";
    const hadFocus = this.node && this.node === document.activeElement;
    const tab = this.node ? this.node.tabIndex : -1;
    const source = providerMeta(providerKey(hook));
    this.dataset.src = String(source.color);
    this.dataset.provider = providerKey(hook);
    this.dataset.shape = source.shape;
    const node = el("div", "od-card");
    node.setAttribute("role", "group");
    node.tabIndex = tab;
    node.dataset.hookId = m.original.id;
    node.dataset.program = names.word;
    node.dataset.density = compact ? "compact" : "detailed";
    if (m.member) node.dataset.member = "true";
    if (m.pinned) node.dataset.pinned = "true";
    if (m.drafted) node.dataset.drafted = "true";
    if (m.selected) node.dataset.selected = "true";
    if (m.dim) node.dataset.dim = "true";
    node.setAttribute("aria-label", labelFor(hook, m.position) + (m.drafted ? ", drafted" : ""));

    const top = el("div", "od-card-row");
    if (m.pinned) {
      const lock = el("span", "od-handle od-handle-empty od-pinned");
      lock.setAttribute("role", "img");
      lock.setAttribute("aria-label", "Pinned");
      lock.tabIndex = -1;
      lock.append(glyph("lock"));
      top.append(tipped(lock, `Pinned: ${pinReason(hook)}`));
    } else if (m.draggable) {
      const handle = el("span", "od-handle");
      handle.setAttribute("aria-hidden", "true");
      handle.append(glyph("grip"));
      top.append(handle);
    } else if (m.ctx && !m.ctx.readOnly) {
      const slot = el("span", "od-handle od-handle-empty");
      slot.setAttribute("aria-hidden", "true");
      top.append(slot);
    }
    if (m.member || m.ordered) {
      const badge = el("span", "od-order-badge", String(m.position));
      badge.setAttribute("aria-label", `Position ${m.position}`);
      top.append(badge);
    }
    const name = el("span", "od-program mono", names.base);
    top.append(tipped(name, names.full || names.base));
    if (m.drafted) top.append(el("span", "od-draft-mark", "Draft"));
    top.append(el("span", "od-spacer"));
    const count = (hook.findings || []).length;
    if (count && !compact) {
      const severity = worstSeverity(hook, m.index) || "info";
      const wrap = el("span", "od-findings");
      wrap.dataset.severity = severity;
      wrap.append(glyph(severity === "error" ? "error" : severity === "warn" ? "warn" : "info"), document.createTextNode(String(count)));
      wrap.setAttribute("aria-label", `${count} ${count === 1 ? "finding" : "findings"}, ${severity}`);
      top.append(wrap);
    }
    if (compact) top.append(el("span", "od-num od-card-p95", p95Text(hook)));
    const more = document.createElement("od-icon-button");
    more.setAttribute("icon", "more");
    more.setAttribute("size", "xs");
    more.setAttribute("label", `More actions for ${names.base}`);
    more.addEventListener("click", (event) => {
      event.stopPropagation();
      more.dispatchEvent(new CustomEvent("od-hook-action", { bubbles: true, detail: { action: "menu", hook: m.original, trigger: more, context: m.ctx } }));
    });
    top.append(more);
    node.append(top);

    if (!compact) {
      const meta = el("div", "od-card-row od-card-meta");
      const chip = statusChip(hook);
      if (chip) meta.append(chip);
      const consent = m.pinned ? consentChip(hook) : null;
      if (consent) meta.append(consent);
      if (hook.matcher && !consent) {
        const matcher = document.createElement("od-chip");
        matcher.setAttribute("label", hook.matcher);
        matcher.className = "od-matcher-chip";
        matcher.title = hook.matcher;
        meta.append(matcher);
      }
      meta.append(el("span", "od-spacer"));
      meta.append(el("span", "od-num od-card-timeout", timeoutText(hook)));
      meta.append(el("span", "od-num od-card-p95", p95Text(hook)));
      node.append(meta);
    }

    if (this.node) this.node.replaceWith(node);
    else this.append(node);
    this.node = node;
    if (hadFocus) node.focus({ preventScroll: true });
  }
}

customElements.define("od-hook-card", OdHookCard);

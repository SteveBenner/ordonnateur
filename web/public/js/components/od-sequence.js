import "./od-toggle.js";
import { announce } from "../core/announce.js";
import { cardStop, count, originalMembers, setOrder } from "../core/draft.js";
import { READ_ONLY_REASON } from "../core/store.js";
import { scopeLabel } from "./od-hook-menu.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function plural(total) {
  if (total === 0) return "no changes";
  return `${total} ${total === 1 ? "change" : "changes"}`;
}

class OdSequence extends HTMLElement {
  set model(value) {
    this.m = value;
    if (this.isConnected) this.render();
  }

  get model() {
    return this.m;
  }

  get list() {
    return this.listEl;
  }

  connectedCallback() {
    if (this.m && !this.frame) this.render();
  }

  render() {
    const m = this.m;
    const frame = el("section", "od-sequence");
    frame.dataset.scope = m.scope;
    frame.dataset.event = m.event;
    frame.setAttribute("aria-label", `Sequence on ${m.event}, ${scopeLabel(m.scope)}`);
    const head = el("div", "od-seq-head");
    head.append(el("span", "od-seq-label", "Sequence"), el("span", "od-seq-count od-num", String(m.cards.length)));
    head.append(el("span", "od-spacer"));
    if (m.editable) {
      const toggle = document.createElement("od-toggle");
      toggle.setAttribute("label", "Stop on block");
      if (m.stop === true) toggle.setAttribute("checked", "");
      if (m.readOnly) {
        toggle.setAttribute("disabled", "");
        toggle.setAttribute("reason", READ_ONLY_REASON);
      }
      toggle.addEventListener("od-change", (event) => this.toggle(event.detail.checked));
      head.append(toggle);
    }
    const list = el("div", "od-seq-list");
    list.append(...m.cards);
    frame.append(head, list);
    if (this.frame) this.frame.replaceWith(frame);
    else this.append(frame);
    this.frame = frame;
    this.listEl = list;
    this.rail();
  }

  toggle(checked) {
    const m = this.m;
    const ctx = m.ctx;
    const base = ctx.layout && ctx.layout.fingerprint ? ctx.layout.fingerprint.config : null;
    setOrder(m.scope, ctx.project, base, m.event, m.ids, checked, originalMembers(ctx.layout, m.scope, m.event), cardStop(ctx.layout, m.scope, m.event));
    announce(`Stop on block ${checked ? "on" : "off"} for ${m.event}, ${scopeLabel(m.scope)}. Draft: ${plural(count(m.scope, ctx.project))}.`);
  }

  rail() {
    const list = this.listEl;
    if (!list) return;
    const badges = list.querySelectorAll(".od-order-badge");
    if (badges.length < 2) {
      list.style.setProperty("--rail-top", "0px");
      list.style.setProperty("--rail-bottom", "100%");
      list.dataset.rail = "none";
      return;
    }
    list.dataset.rail = "on";
    const box = list.getBoundingClientRect();
    const first = badges[0].getBoundingClientRect();
    const last = badges[badges.length - 1].getBoundingClientRect();
    list.style.setProperty("--rail-x", `${Math.round(first.left + first.width / 2 - box.left)}px`);
    list.style.setProperty("--rail-top", `${Math.round(first.top + first.height / 2 - box.top)}px`);
    list.style.setProperty("--rail-bottom", `${Math.round(box.bottom - (last.top + last.height / 2))}px`);
  }
}

customElements.define("od-sequence", OdSequence);

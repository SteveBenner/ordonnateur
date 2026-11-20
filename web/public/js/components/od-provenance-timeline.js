import "./od-chip.js";
import "./od-button.js";
import "./od-icon-button.js";
import "./od-banner.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-command.js";
import { PROVENANCE_PAGE, formatTime, isoTime, provenanceBasis, provenanceDetail, provenanceSentence } from "../core/hook-detail.js";

const NS = "http://www.w3.org/2000/svg";
const HONESTY = "First seen means ordonnateur first noticed this hook. It does not say when the hook was installed.";
const COLUMNS = [
  { key: "time", label: "Time", className: "od-pt-time" },
  { key: "event", label: "Event", className: "od-pt-kind" },
  { key: "what", label: "What happened", className: "od-pt-what" },
  { key: "how", label: "How we know", className: "od-pt-how" },
];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function glyph(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "od-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class OdProvenanceTimeline extends HTMLElement {
  connectedCallback() {
    if (this.ready) return;
    this.ready = true;
    this.model = { events: [], store: "local", degraded: false, note: "", state: "loading", name: "this hook", ...(this.model || {}) };
    this.render();
  }

  set data(next) {
    this.model = { ...this.model, ...next };
    if (this.ready) this.render();
  }

  get data() {
    return this.model;
  }

  render() {
    const model = this.model;
    const state = model.state;
    if (state === "loading") {
      this.replaceChildren(this.loading());
      return;
    }
    if (state === "error") {
      const box = document.createElement("od-state");
      box.setAttribute("kind", "error");
      box.setAttribute("heading", "History could not be loaded");
      box.setAttribute("body", model.errorText || "");
      if (model.errorId) box.setAttribute("error-id", model.errorId);
      this.replaceChildren(box);
      return;
    }
    if (state === "off") {
      const box = document.createElement("od-state");
      box.setAttribute("kind", "disabled");
      box.setAttribute("feature", "Provenance");
      box.setAttribute("body", "ordonnateur is not recording or reading history for hooks. Turn it on in a terminal.");
      const command = document.createElement("od-command");
      command.setAttribute("command", "rplugin settings set ordonnateur provenance.enabled true");
      box.append(command);
      this.replaceChildren(box);
      return;
    }
    const parts = [this.head(), el("p", "od-pt-honesty")];
    parts[1].append(glyph("info"), el("span", "", HONESTY));
    if (model.degraded) {
      const banner = document.createElement("od-banner");
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", `The provenance store is not answering. New events are kept in a local spool and replay when it answers.${model.note ? ` ${model.note}` : ""}`);
      banner.setAttribute("action", "Check again");
      banner.addEventListener("od-action", () => this.dispatchEvent(new CustomEvent("od-prov-refresh", { bubbles: true })));
      parts.splice(1, 0, banner);
    }
    if (state === "empty" || !model.events.length) {
      const box = document.createElement("od-state");
      box.setAttribute("kind", "empty_first_run");
      box.setAttribute("heading", "No history yet");
      box.setAttribute("body", "ordonnateur has not recorded an event for this hook. It records a first sighting each time it reads the hook files, so this fills in on the next refresh.");
      box.setAttribute("action", "Check again");
      box.addEventListener("od-action", (event) => {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent("od-prov-refresh", { bubbles: true }));
      });
      parts.push(box);
    } else {
      parts.push(this.table());
    }
    this.replaceChildren(...parts);
  }

  loading() {
    const wrap = el("div", "od-pt-loading");
    wrap.setAttribute("aria-busy", "true");
    const status = el("p", "visually-hidden", "Loading hook details");
    status.setAttribute("role", "status");
    wrap.append(status);
    for (let i = 0; i < 6; i += 1) wrap.append(document.createElement("od-skeleton"));
    return wrap;
  }

  head() {
    const model = this.model;
    const head = el("div", "od-pt-head");
    const store = document.createElement("od-chip");
    store.setAttribute("label", `Store: ${model.store || "local"}`);
    const actions = el("div", "od-pt-actions");
    if (model.events.length >= PROVENANCE_PAGE && !model.all) {
      const more = document.createElement("od-button");
      more.setAttribute("variant", "ghost");
      more.setAttribute("size", "sm");
      more.text = "Load all";
      more.addEventListener("click", () => this.dispatchEvent(new CustomEvent("od-prov-more", { bubbles: true })));
      actions.append(more);
    }
    const again = document.createElement("od-icon-button");
    again.setAttribute("icon", "reset");
    again.setAttribute("size", "sm");
    again.setAttribute("label", "Check again");
    again.addEventListener("click", () => this.dispatchEvent(new CustomEvent("od-prov-refresh", { bubbles: true })));
    actions.append(again);
    head.append(store, actions);
    return head;
  }

  table() {
    const model = this.model;
    const table = el("table", "od-pt-table");
    table.append(el("caption", "visually-hidden", `History of ${model.name}`));
    const group = el("colgroup");
    for (const column of COLUMNS) group.append(el("col", column.className));
    table.append(group);
    const head = el("tr");
    for (const column of COLUMNS) {
      const th = el("th", column.className, column.label);
      th.scope = "col";
      head.append(th);
    }
    const thead = el("thead");
    thead.append(head);
    table.append(thead);
    const body = el("tbody");
    for (const event of model.events) body.append(this.row(event));
    table.append(body);
    return table;
  }

  row(event) {
    const row = el("tr", "od-pt-row");
    row.dataset.kind = event.kind;
    const time = el("td", "od-pt-time mono");
    const stamp = document.createElement("time");
    stamp.dateTime = isoTime(event.at);
    stamp.title = isoTime(event.at);
    stamp.textContent = formatTime(event.at);
    time.append(stamp);
    const kind = el("td", "od-pt-kind");
    const chip = document.createElement("od-chip");
    chip.setAttribute("kind", "provenance");
    chip.setAttribute("value", event.kind);
    kind.append(chip);
    const sentence = provenanceSentence(event);
    const detail = provenanceDetail(event);
    const basis = provenanceBasis(event);
    const what = el("td", "od-pt-what");
    what.append(el("div", "od-pt-sentence", sentence.text));
    if (sentence.sub) what.append(el("div", "od-pt-sub", sentence.sub));
    if (detail.pairs) what.append(el("div", "od-pt-detail mono", detail.pairs));
    for (const hint of detail.hints) what.append(el("div", "od-pt-hint", hint));
    const sub = el("div", "od-pt-how-sub", basis.text);
    what.append(sub);
    const how = el("td", "od-pt-how", basis.text);
    how.title = basis.title;
    row.append(time, kind, what, how);
    return row;
  }
}

customElements.define("od-provenance-timeline", OdProvenanceTimeline);

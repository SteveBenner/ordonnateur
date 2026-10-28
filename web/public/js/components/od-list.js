import "./od-chip.js";
import "./od-tooltip.js";
import "./od-icon-button.js";
import "./od-state.js";
import "./od-command.js";
import * as draft from "../core/draft.js";
import { announce } from "../core/announce.js";
import { nextSort, readSort, saveSort, sortRows } from "../core/sort.js";
import { providerKey, providerMeta, rowKeyOfHook } from "../core/sources.js";
import {
  HARNESS_LABELS,
  allHooks,
  compareSources,
  eventSummary,
  findingIndex,
  fitMiddle,
  harnessesFor,
  isMember,
  memberPosition,
  middle,
  nextId,
  program,
  sourceLabel,
  statusOf,
  statusText,
  visibleHooks,
  worstSeverity,
} from "../core/hooks.js";

const NS = "http://www.w3.org/2000/svg";

const COLUMNS = [
  { key: "order", label: "#", className: "od-col-order" },
  { key: "hook", label: "Hook", className: "od-col-hook" },
  { key: "source", label: "Source", className: "od-col-source" },
  { key: "status", label: "Status", className: "od-col-status" },
  { key: "findings", label: "Findings", className: "od-col-findings od-num" },
  { key: "p95", label: "p95 ms", className: "od-col-p95 od-num" },
  { key: "timeout", label: "Timeout s", className: "od-col-timeout od-num" },
  { key: "actions", label: "Actions", className: "od-col-actions" },
];

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

function chipFor(hook) {
  const status = statusOf(hook);
  if (!status) return null;
  const chip = document.createElement("od-chip");
  chip.setAttribute("kind", "status");
  chip.setAttribute("value", status.value);
  const holder = el("span", "od-chip-host");
  holder.tabIndex = status.reason ? 0 : -1;
  holder.append(chip);
  const main = tipped(holder, status.reason);
  const consent = status.consent;
  if (!consent || consent.value === "allowlisted") return main;
  const consentChip = document.createElement("od-chip");
  consentChip.setAttribute("kind", "status");
  consentChip.setAttribute("value", consent.value);
  consentChip.setAttribute("icon-only", "");
  const consentHolder = el("span", "od-chip-host");
  consentHolder.tabIndex = 0;
  consentHolder.append(consentChip);
  const pair = el("span", "od-chip-pair");
  pair.append(main, tipped(consentHolder, consent.reason));
  return pair;
}

function badge(position) {
  const node = el("span", "od-order-badge", String(position));
  node.setAttribute("aria-label", `Position ${position}`);
  return node;
}

function numberCell(value, className) {
  const cell = el("td", `od-num ${className}`);
  cell.textContent = value;
  return cell;
}

function hookRow(hook, index, context, drafted, position) {
  const row = el("tr", "od-row");
  if (drafted) row.dataset.drafted = "true";
  row.dataset.hookId = hook.id;
  row.dataset.provider = providerKey(hook);
  const source = providerMeta(providerKey(hook));
  row.dataset.src = String(source.color);
  row.dataset.shape = source.shape;
  const names = program(hook);
  const timing = hook.timing;
  const severity = worstSeverity(hook, index);
  const count = (hook.findings || []).length;
  const p95 = timing ? String(timing.p95) : "n/a";
  const effective = hook.effective_timeout != null ? hook.effective_timeout : hook.timeout;
  const timeout = effective == null ? "n/a" : String(effective);

  const order = el("td", "od-col-order");
  if (isMember(hook)) order.append(badge(memberPosition(hook)));
  else if (position) order.append(badge(position));
  row.append(order);

  const cell = el("td", "od-col-hook");
  const line = el("span", "od-hook-line");
  const name = el("span", "od-program mono", names.base);
  name.dataset.fit = names.base;
  name.tabIndex = 0;
  name.setAttribute("role", "group");
  name.setAttribute("aria-label", `${names.base} on ${hook.event}, ${sourceLabel(hook)}, ${statusText(hook)}${drafted ? ", drafted" : ""}`);
  line.append(tipped(name, names.full || names.base));
  if (drafted) line.append(el("span", "od-draft-mark", "Draft"));
  if (hook.matcher) {
    const matcher = el("span", "od-matcher mono", middle(hook.matcher, 8));
    matcher.title = hook.matcher;
    line.append(matcher);
  }
  cell.append(line);
  const sub = el("span", "od-hook-sub");
  const subChip = chipFor(hook);
  if (subChip) sub.append(subChip);
  const subParts = [];
  if (count) subParts.push(`${count} ${count === 1 ? "finding" : "findings"}`);
  if (effective != null) subParts.push(`${timeout} s`);
  const subText = el("span", "od-hook-sub-text");
  const subSource = el("span", "od-hook-sub-source", sourceLabel(hook));
  subSource.dataset.fit = sourceLabel(hook);
  subSource.title = sourceLabel(hook);
  subText.append(subSource);
  if (subParts.length) subText.append(el("span", "od-hook-sub-rest", ` · ${subParts.join(" · ")}`));
  sub.append(subText);
  cell.append(sub);
  row.append(cell);

  const sourceCell = el("td", "od-col-source");
  const sourceText = el("span", "od-source-text", sourceLabel(hook));
  sourceText.dataset.fit = sourceLabel(hook);
  sourceText.title = sourceLabel(hook);
  const dot = el("span", "od-src-dot");
  dot.setAttribute("aria-hidden", "true");
  dot.dataset.src = String(source.color);
  dot.dataset.shape = source.shape;
  sourceText.prepend(dot);
  sourceCell.append(sourceText);
  row.append(sourceCell);

  const statusCell = el("td", "od-col-status");
  const chip = chipFor(hook);
  if (chip) statusCell.append(chip);
  row.append(statusCell);

  const findings = el("td", "od-num od-col-findings");
  if (count) {
    const wrap = el("span", "od-findings");
    wrap.dataset.severity = severity || "info";
    wrap.append(glyph(severity === "error" ? "error" : severity === "warn" ? "warn" : "info"), document.createTextNode(String(count)));
    wrap.setAttribute("aria-label", `${count} ${count === 1 ? "finding" : "findings"}, ${severity || "info"}`);
    findings.append(wrap);
  }
  row.append(findings);

  row.append(numberCell(p95, "od-col-p95"));
  row.append(numberCell(timeout, "od-col-timeout"));

  const actions = el("td", "od-col-actions");
  const more = document.createElement("od-icon-button");
  more.setAttribute("icon", "more");
  more.setAttribute("size", "xs");
  more.setAttribute("label", `More actions for ${names.base}`);
  more.addEventListener("click", () => {
    more.dispatchEvent(
      new CustomEvent("od-hook-action", { bubbles: true, detail: { action: "menu", hook, trigger: more, context } }),
    );
  });
  actions.append(more);
  row.append(actions);
  const select = () => document.dispatchEvent(new CustomEvent("od-hook-select", { detail: { hook, trigger: name } }));
  name.addEventListener("click", select);
  name.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      select();
    } else if (event.key === "." || (event.key === "F10" && event.shiftKey)) {
      event.preventDefault();
      more.dispatchEvent(new CustomEvent("od-hook-action", { bubbles: true, detail: { action: "menu", hook, trigger: name, context } }));
    }
  });
  return row;
}

function eventHead(event, hooks, context, harness) {
  const body = el("tbody", "od-event");
  const row = el("tr");
  const head = el("th", "od-event-head");
  head.scope = "rowgroup";
  head.colSpan = COLUMNS.length;
  const name = el("span", "od-event-name", event);
  head.append(name);
  const summary = el("span", "od-event-summary", hooks.length ? eventSummary(hooks) : "No hooks");
  head.append(summary);
  const reason = harness === "claude-code" ? context.config.not_sequenceable && context.config.not_sequenceable[event] : null;
  if (reason) {
    const lock = el("span", "od-lock");
    lock.tabIndex = 0;
    lock.setAttribute("role", "img");
    lock.setAttribute("aria-label", `Not sequenceable. ${reason}`);
    lock.append(glyph("lock-slash", "od-icon od-icon-sm"));
    head.append(tipped(lock, reason));
  }
  row.append(head);
  body.append(row);
  return body;
}

const DRAFT_SCOPES = ["user", "local"];

function projected(hooks, event, projection, hidden) {
  const rest = [];
  for (const hook of hooks) {
    const own = hook.harness === "claude-code" && DRAFT_SCOPES.includes(hook.scope) && !hook.plugin;
    if (!own) rest.push(hook);
  }
  const out = rest.slice();
  for (const scope of DRAFT_SCOPES) {
    if (hidden.has(`claude-code:${scope}`)) continue;
    const key = `${scope}|${event}`;
    const members = projection.members.get(key);
    if (!members) continue;
    members.forEach((hook, position) => out.push(adjust({ ...hook, status: `member#${position + 1}` }, projection)));
    for (const hook of projection.natives.get(key) || []) {
      out.push(adjust({ ...hook, status: isMember(hook) ? "native" : hook.status }, projection));
    }
  }
  return out;
}

function adjust(hook, projection) {
  if (!projection.guards.has(hook.id) || isMember(hook)) return hook;
  if (projection.guards.get(hook.id)) return { ...hook, status: "guard" };
  return hook.status === "guard" ? { ...hook, status: "native" } : hook;
}

function antigravityEntries(raw, event, projection) {
  const keys = [];
  for (const hook of raw) {
    const key = rowKeyOfHook(hook);
    if (!keys.includes(key)) keys.push(key);
  }
  const rank = (key) => (key === "global" ? 0 : key.startsWith("workspace:") ? 1 : key.startsWith("plugin:") ? 2 : 3);
  keys.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
  const entries = [];
  for (const key of keys) {
    const own = raw.filter((hook) => rowKeyOfHook(hook) === key);
    const file = own[0].source_file;
    const cell = key === "global" || key.startsWith("workspace:") ? projection.antigravity.cells.get(`${file}|${event}`) : null;
    if (cell) {
      (cell.frame || []).forEach((hook, i) => entries.push({ hook, position: i + 1 }));
      for (const group of cell.groups) {
        group.hooks.forEach((hook, i) => entries.push({ hook: hook.status === "member" ? { ...hook, status: "active" } : hook, position: group.hooks.length >= 2 ? i + 1 : 0 }));
      }
      continue;
    }
    const sizes = new Map();
    for (const hook of own) sizes.set(hook.hook_name, (sizes.get(hook.hook_name) || 0) + 1);
    const seen = new Map();
    for (const hook of own) {
      const at = (seen.get(hook.hook_name) || 0) + 1;
      seen.set(hook.hook_name, at);
      entries.push({ hook, position: sizes.get(hook.hook_name) >= 2 ? at : 0 });
    }
  }
  return entries;
}

function columnName(column) {
  return column.key === "order" ? "execution order" : column.label;
}

function sortButton(column, dir) {
  const name = columnName(column);
  const button = el("button", "od-sort");
  button.type = "button";
  button.dataset.key = column.key;
  const text = dir ? `Sort by ${name}, sorted ${dir === "asc" ? "ascending" : "descending"}` : `Sort by ${name}`;
  button.setAttribute("aria-label", text);
  button.title = text;
  const label = el("span", "od-sort-label", column.label);
  const mark = glyph("chevron-down", "od-icon od-sort-glyph");
  if (column.className.includes("od-num")) button.append(mark, label);
  else button.append(label, mark);
  return button;
}

function table(harness, hooks, context, index, projection, sort, hidden) {
  const wrap = el("section", "od-list-section");
  const element = el("table", "od-list");
  const caption = el("caption", "od-caption", HARNESS_LABELS[harness] || harness);
  element.append(caption);
  if (!hooks.length) {
    wrap.append(element);
    const label = HARNESS_LABELS[harness] || harness;
    const masked = allHooks(context.layout, harness).length > 0;
    wrap.append(el("p", "od-none", masked ? `All ${label} sources hidden.` : `No ${label} hooks found.`));
    return wrap;
  }
  const group = el("colgroup");
  for (const column of COLUMNS) group.append(el("col", column.className.replace(" od-num", "")));
  element.append(group);
  const thead = el("thead");
  const headRow = el("tr");
  for (const column of COLUMNS) {
    const th = el("th", column.className);
    th.scope = "col";
    if (column.key === "actions") {
      const hidden = el("span", "visually-hidden", "Actions");
      th.append(hidden);
    } else {
      const active = sort.key === column.key;
      if (active) th.setAttribute("aria-sort", sort.dir === "asc" ? "ascending" : "descending");
      th.append(sortButton(column, active ? sort.dir : null));
    }
    headRow.append(th);
  }
  thead.append(headRow);
  element.append(thead);
  const events = (context.config.events && context.config.events[harness]) || [];
  const byEvent = new Map();
  for (const hook of hooks) {
    if (!byEvent.has(hook.event)) byEvent.set(hook.event, []);
    byEvent.get(hook.event).push(hook);
  }
  const order = [...events];
  for (const event of byEvent.keys()) if (!order.includes(event)) order.push(event);
  for (const event of order) {
    const raw = byEvent.get(event) || [];
    let list;
    let agEntries = null;
    if (harness === "hermes") list = (projection.hermes.orders.get(event) || raw).slice();
    else if (harness === "antigravity") {
      agEntries = antigravityEntries(raw, event, projection);
      list = agEntries.map((entry) => entry.hook);
    }
    else list = (harness === "claude-code" ? projected(raw, event, projection, hidden) : raw).slice().sort(compareSources);
    if (!list.length && !context.showEmpty) continue;
    const body = eventHead(event, list, context, harness);
    const entries =
      agEntries ||
      list.map((hook, position) => ({
        hook,
        position: harness === "hermes" && list.length >= 2 ? position + 1 : 0,
      }));
    for (const entry of sortRows(entries, sort, index)) {
      const hook = entry.hook;
      const drafted = projection.drafted.has(hook.id) || (harness === "hermes" && projection.hermes.drafted.has(hook.id)) || (harness === "antigravity" && projection.antigravity.drafted.has(hook.id));
      body.append(hookRow(hook, index, context, drafted, entry.position));
    }
    element.append(body);
  }
  wrap.append(element);
  return wrap;
}

class OdListView extends HTMLElement {
  set context(value) {
    this.ctx = value;
    if (this.isConnected) this.render();
  }

  get context() {
    return this.ctx;
  }

  connectedCallback() {
    if (this.region) return;
    if (!this.sort) this.sort = readSort();
    this.region = el("div", "od-region");
    this.region.addEventListener("click", (event) => this.headerClick(event));
    this.region.setAttribute("role", "region");
    this.region.tabIndex = 0;
    this.region.setAttribute("aria-label", "Hook list");
    this.append(this.region);
    if (typeof ResizeObserver === "function") {
      this.resizer = new ResizeObserver(() => fitMiddle(this.region));
      this.resizer.observe(this.region);
    }
    this.onDraft = () => this.render();
    this.onSources = (event) => this.sourcesChanged(event.detail && event.detail.hidden);
    this.onSelect = (event) => {
      this.selected = event.detail && event.detail.hook ? event.detail.hook.id : null;
      this.markSelected();
    };
    document.addEventListener("od-draft-change", this.onDraft);
    document.addEventListener("od-layout-reloaded", this.onDraft);
    document.addEventListener("od-hook-select", this.onSelect);
    document.addEventListener("od-sources-change", this.onSources);
    this.onHover = (event) => this.hotSource(event.detail && event.detail.key);
    document.addEventListener("od-sources-hover", this.onHover);
    const main = this.closest(".od-main");
    if (main && typeof MutationObserver === "function") {
      this.watcher = new MutationObserver(() => {
        if (main.dataset.inspector !== "open" && this.selected) {
          this.selected = null;
          this.markSelected();
        }
      });
      this.watcher.observe(main, { attributes: true, attributeFilter: ["data-inspector"] });
    }
    if (this.ctx) this.render();
  }

  headerClick(event) {
    const button = event.target.closest && event.target.closest("thead .od-sort");
    if (!button || !this.region || !this.region.contains(button)) return;
    const key = button.dataset.key;
    const section = button.closest(".od-list-section");
    const sections = [...this.region.querySelectorAll(".od-list-section")];
    const at = sections.indexOf(section);
    this.sort = nextSort(this.sort, key);
    saveSort(this.sort);
    this.render();
    const fresh = this.region.querySelectorAll(".od-list-section")[at];
    const again = fresh && fresh.querySelector(`thead .od-sort[data-key="${key}"]`);
    if (again) again.focus();
    const column = COLUMNS.find((item) => item.key === key);
    const direction = this.sort.dir === "asc" ? "ascending" : "descending";
    announce(`Sorted by ${columnName(column)}, ${direction}`);
  }

  sourcesChanged(hidden) {
    if (!hidden || !hidden.size || !this.selected) return;
    const hooks = (this.ctx && this.ctx.layout && this.ctx.layout.hooks) || [];
    const hook = hooks.find((item) => item.id === this.selected);
    if (hook && hidden.has(providerKey(hook))) {
      this.selected = null;
      this.markSelected();
    }
  }

  hotSource(key) {
    this.hotKey = key || null;
    if (!this.region) return;
    for (const row of this.region.querySelectorAll(".od-row")) {
      if (this.hotKey && row.dataset.provider === this.hotKey) row.dataset.hot = "true";
      else row.removeAttribute("data-hot");
    }
  }

  markSelected() {
    if (!this.region) return;
    for (const row of this.region.querySelectorAll(".od-row")) {
      if (row.dataset.hookId === this.selected) row.dataset.selected = "true";
      else row.removeAttribute("data-selected");
    }
  }

  disconnectedCallback() {
    document.removeEventListener("od-draft-change", this.onDraft);
    document.removeEventListener("od-layout-reloaded", this.onDraft);
    document.removeEventListener("od-hook-select", this.onSelect);
    document.removeEventListener("od-sources-change", this.onSources);
    document.removeEventListener("od-sources-hover", this.onHover);
    if (this.watcher) this.watcher.disconnect();
    this.watcher = null;
    if (this.resizer) this.resizer.disconnect();
    this.resizer = null;
    this.region = null;
  }

  render() {
    const context = this.ctx;
    if (!context || !context.layout) return;
    const index = findingIndex(context.layout);
    const projection = draft.project(context.layout, context.project);
    projection.hermes = draft.projectHermes(context.layout, context.project);
    projection.antigravity = draft.projectAntigravity(context.layout, context.project);
    const sections = [];
    const sources = context.sources;
    const hidden = (sources && sources.hidden) || new Set();
    for (const harness of harnessesFor(context.harness)) {
      const hooks = visibleHooks(context.layout, harness, hidden);
      sections.push(table(harness, hooks, context, index, projection, this.sort, hidden));
    }
    const everything = allHooks(context.layout, "both");
    if (!everything.length) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "empty_first_run");
      state.setAttribute("heading", "No hooks are configured");
      state.setAttribute("body", "None of Claude Code, Codex, Hermes or Antigravity has a hook in the files ordonnateur reads.");
      const command = document.createElement("od-command");
      command.setAttribute("command", "ordonnateur list");
      state.append(command);
      this.region.replaceChildren(state);
      return;
    }
    if (sources && sources.active && sources.providers.length && sources.providers.every((item) => hidden.has(item.key))) {
      const filtered = document.createElement("od-state");
      filtered.setAttribute("kind", "empty_filtered");
      filtered.setAttribute("heading", "All sources hidden");
      filtered.setAttribute("body", "Every source is switched off in the bar above.");
      filtered.setAttribute("action", "Show all");
      filtered.addEventListener("od-action", () => this.dispatchEvent(new CustomEvent("od-sources-all", { bubbles: true })));
      this.region.replaceChildren(filtered);
      return;
    }
    this.region.replaceChildren(...sections);
    this.markSelected();
    this.hotSource(this.hotKey);
    fitMiddle(this.region);
  }
}

customElements.define("od-list-view", OdListView);

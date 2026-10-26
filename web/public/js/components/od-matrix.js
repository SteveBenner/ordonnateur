import "./od-chip.js";
import "./od-tooltip.js";
import "./od-toggle.js";
import "./od-state.js";
import "./od-command.js";
import "./od-hook-card.js";
import "./od-sequence.js";
import "./od-hook-menu.js";
import {
  HARNESS_LABELS,
  disabledPlugin,
  findingIndex,
  fitMiddle,
  harnessesFor,
  isMember,
  isPinned,
  nextId,
  visibleHooks,
  allHooks,
} from "../core/hooks.js";
import { providerKey, providerMeta, rowKeyOfHook, rowLabel } from "../core/sources.js";
import { cardStop, project as projectDraft, projectHermes } from "../core/draft.js";
import { buildEdges, clearEdges, createSvg, renderEdges, sizeSvg } from "../core/edges.js";
import { commit, commitHermes, shortcut } from "./od-hook-menu.js";

const NS = "http://www.w3.org/2000/svg";
const DRAG_THRESHOLD = 4;
const SCROLL_ZONE = 32;
const SCROLL_STEP = 12;

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

const NONE = new Set();

function rowKeyOf(hook) {
  if (disabledPlugin(hook)) return "disabled";
  return rowKeyOfHook(hook);
}

function hiddenOf(ctx) {
  return (ctx && ctx.sources && ctx.sources.hidden) || NONE;
}

function allOff(ctx) {
  const sources = ctx && ctx.sources;
  return Boolean(sources && sources.active && sources.providers.length && sources.providers.every((item) => sources.hidden.has(item.key)));
}

function rowPath(key, hooks, ctx, harness) {
  const files = ctx.layout.settings_files || {};
  if (harness === "hermes") return files.hermes || "";
  if (harness === "claude-code" && (key === "user" || key === "local") && files[key]) return files[key];
  if (harness === "codex" && key === "user" && files.codex) return files.codex;
  const own = hooks.find((hook) => !isMember(hook) && hook.source_file);
  if (own) return own.source_file;
  const entry = ctx.layout.cards && (key === "user" || key === "local") ? ctx.layout.cards[key] : null;
  if (entry && entry.card && entry.card.settings_file) return entry.card.settings_file;
  if (key === "local" && ctx.project) return `${ctx.project}/.claude/settings.local.json`;
  return "";
}

function rowDefs(harness, hooks, ctx) {
  if (harness === "hermes") {
    return [
      {
        key: "user",
        harness,
        scope: "",
        label: "Profile config",
        path: rowPath("user", hooks, ctx, harness),
        editable: true,
        disabled: false,
        hooks,
      },
    ];
  }
  const groups = new Map();
  for (const hook of hooks) {
    const key = rowKeyOf(hook);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(hook);
  }
  const claude = harness === "claude-code";
  const keys = [];
  const hidden = hiddenOf(ctx);
  for (const key of ["managed", "user", "project", "local"]) {
    const always = (claude && key === "user") || (claude && key === "local" && ctx.project);
    if (groups.has(key) || (always && !hidden.has(`claude-code:${key}`))) keys.push(key);
  }
  const plugins = [...groups.keys()].filter((key) => key.startsWith("plugin:")).sort((a, b) => a.localeCompare(b));
  keys.push(...plugins);
  if (groups.has("disabled")) keys.push("disabled");
  return keys.map((key) => {
    const rowHooks = groups.get(key) || [];
    return {
      key,
      harness,
      scope: key === "user" || key === "local" ? key : "",
      label: rowLabel(key, harness),
      path: key === "disabled" ? "" : rowPath(key, rowHooks, ctx, harness),
      editable: claude && (key === "user" || (key === "local" && Boolean(ctx.project))),
      disabled: key === "disabled",
      hooks: rowHooks,
    };
  });
}

function eventsFor(harness, hooks, ctx) {
  const lifecycle = (ctx.config.events && ctx.config.events[harness]) || [];
  const present = new Set(hooks.map((hook) => hook.event));
  const list = lifecycle.filter((event) => ctx.showEmpty || present.has(event));
  for (const event of present) if (!lifecycle.includes(event)) list.push(event);
  return list;
}

function viewOf(hook, role, position, state) {
  const clone = { ...hook };
  if (role === "member") {
    clone.status = `member#${position}`;
    return clone;
  }
  if (isMember(hook)) clone.status = "native";
  if (state.guards.has(hook.id)) {
    const guarded = state.guards.get(hook.id);
    clone.guard = guarded;
    clone.status = guarded ? "guard" : hook.status === "guard" ? "native" : clone.status;
  }
  return clone;
}

function cellContent(row, event, ctx, state, index, expanded) {
  const result = { frame: null, natives: [] };
  if (row.disabled && !expanded) return result;
  if (row.harness === "hermes") {
    const list = state.hermes.orders.get(event) || [];
    const unpinned = list.filter((hook) => !isPinned(hook)).length;
    result.natives = list.map((hook, i) => ({
      hook: viewOf(hook, "native", 0, state),
      original: hook,
      ctx,
      index,
      density: ctx.density,
      member: false,
      ordered: list.length >= 2,
      pinned: isPinned(hook),
      position: i + 1,
      drafted: state.hermes.drafted.has(hook.id),
      draggable: !ctx.readOnly && !isPinned(hook) && unpinned >= 2,
      selected: false,
      dim: false,
    }));
    return result;
  }
  const make = (hook, role, position) => ({
    hook: viewOf(hook, role, position, state),
    original: hook,
    ctx,
    index,
    density: ctx.density,
    member: role === "member",
    position,
    drafted: state.drafted.has(hook.id),
    draggable: !ctx.readOnly && row.editable,
    selected: false,
    dim: disabledPlugin(hook),
  });
  if (row.editable) {
    const key = `${row.key}|${event}`;
    const members = state.members.get(key) || [];
    const natives = state.natives.get(key) || [];
    if (members.length) {
      result.frame = {
        scope: row.key,
        event,
        ids: members.map((hook) => hook.id),
        cards: members.map((hook, i) => make(hook, "member", i + 1)),
        stop: state.stops.has(key) ? state.stops.get(key) : cardStop(ctx.layout, row.key, event),
      };
    }
    result.natives = natives.map((hook) => make(hook, "native", 0));
    return result;
  }
  result.natives = row.hooks.filter((hook) => hook.event === event).map((hook) => make(hook, "native", 0));
  return result;
}

function summaryText(natives, frames) {
  const parts = [`${natives + frames} at once`];
  if (frames) parts.push(`${frames} ${frames === 1 ? "sequence" : "sequences"}`);
  return parts.join(" · ");
}

class OdMatrix extends HTMLElement {
  set context(value) {
    this.ctx = value;
    if (this.isConnected) this.render();
  }

  get context() {
    return this.ctx;
  }

  connectedCallback() {
    if (this.region) {
      this.bindDocument();
      return;
    }
    this.region = el("div", "od-matrix-wrap");
    this.region.addEventListener("scroll", () => this.edges(), { passive: true });
    this.region.setAttribute("role", "region");
    this.region.tabIndex = 0;
    this.region.setAttribute("aria-label", "Hook layout");
    this.canvas = el("div", "od-matrix-canvas");
    this.svg = createSvg();
    this.canvas.append(this.svg);
    this.tooltip = document.createElement("od-tooltip");
    this.layer = el("div", "od-tip-layer");
    this.append(this.region, this.layer);
    this.showDisabled = false;
    this.selected = null;
    this.current = null;
    this.dragging = null;
    this.tables = [];
    this.bindCanvas();
    this.bindDocument();
    if (typeof ResizeObserver === "function") {
      this.resizer = new ResizeObserver(() => {
        fitMiddle(this.canvas);
        this.rails();
        this.edges();
      });
      this.resizer.observe(this.region);
    }
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

  disconnectedCallback() {
    document.removeEventListener("od-draft-change", this.onDraft);
    document.removeEventListener("od-draft-discarded", this.onDraft);
    document.removeEventListener("od-hook-focus", this.onFocusHook);
    document.removeEventListener("od-hook-select", this.onSelect);
    document.removeEventListener("od-sources-change", this.onSources);
    if (this.resizer) this.resizer.disconnect();
    if (this.watcher) this.watcher.disconnect();
    this.resizer = null;
    this.watcher = null;
  }

  bindDocument() {
    document.removeEventListener("od-draft-change", this.onDraft);
    document.removeEventListener("od-draft-discarded", this.onDraft);
    document.removeEventListener("od-hook-focus", this.onFocusHook);
    document.removeEventListener("od-hook-select", this.onSelect);
    document.removeEventListener("od-sources-change", this.onSources);
    document.removeEventListener("od-sources-hover", this.onHover);
    this.onDraft = () => this.render();
    this.onHover = (event) => this.hotSource(event.detail && event.detail.key);
    this.onSources = (event) => this.sourcesChanged(event.detail && event.detail.hidden);
    this.onFocusHook = (event) => this.focusCard(event.detail && event.detail.id);
    this.onSelect = (event) => {
      this.selected = event.detail && event.detail.hook ? event.detail.hook.id : null;
      this.markSelected();
    };
    document.addEventListener("od-draft-change", this.onDraft);
    document.addEventListener("od-draft-discarded", this.onDraft);
    document.addEventListener("od-hook-focus", this.onFocusHook);
    document.addEventListener("od-hook-select", this.onSelect);
    document.addEventListener("od-sources-change", this.onSources);
    document.addEventListener("od-sources-hover", this.onHover);
  }

  hotSource(key) {
    this.hotKey = key || null;
    if (!this.canvas) return;
    for (const node of this.canvas.querySelectorAll("[data-hot]")) node.removeAttribute("data-hot");
    if (!this.hotKey) return;
    for (const host of this.canvas.querySelectorAll("od-hook-card")) {
      if (host.dataset.provider === this.hotKey && host.node) host.node.setAttribute("data-hot", "true");
    }
    for (const head of this.canvas.querySelectorAll("th.od-rowhead")) {
      if (head.dataset.provider === this.hotKey) head.setAttribute("data-hot", "true");
    }
  }

  sourcesChanged(hidden) {
    if (!hidden || !hidden.size) return;
    const owner = this.dragging ? this.dragging.source.hook : this.pending ? this.pending.host.hook : null;
    if (owner && hidden.has(providerKey(owner))) this.cancelDrag();
    if (this.selected) {
      const hooks = (this.ctx && this.ctx.layout && this.ctx.layout.hooks) || [];
      const hook = hooks.find((item) => item.id === this.selected);
      if (hook && hidden.has(providerKey(hook))) {
        this.selected = null;
        this.markSelected();
      }
    }
  }

  bindCanvas() {
    const canvas = this.canvas;
    canvas.addEventListener("pointerover", (event) => {
      if (this.dragging || this.pending) return;
      const card = event.target.closest && event.target.closest(".od-card");
      if (card) this.highlight(card);
    });
    canvas.addEventListener("pointerout", (event) => {
      if (this.dragging) return;
      const card = event.target.closest && event.target.closest(".od-card");
      if (card && !card.contains(event.relatedTarget)) this.unhighlight();
    });
    canvas.addEventListener("focusin", (event) => {
      const card = event.target.closest && event.target.closest(".od-card");
      if (!card) return;
      this.current = card.dataset.hookId;
      this.roving();
      if (event.target === card) this.highlight(card);
    });
    canvas.addEventListener("focusout", (event) => {
      const card = event.target.closest && event.target.closest(".od-card");
      if (card && !card.contains(event.relatedTarget)) this.unhighlight();
    });
    canvas.addEventListener("click", (event) => {
      if (this.suppressClick) {
        this.suppressClick = false;
        return;
      }
      const card = event.target.closest && event.target.closest(".od-card");
      if (!card || event.target.closest("od-icon-button, od-toggle, .od-handle")) return;
      this.select(card);
    });
    canvas.addEventListener("keydown", (event) => this.onKey(event));
    canvas.addEventListener("pointerdown", (event) => this.onPointerDown(event));
    canvas.addEventListener("pointermove", (event) => this.onPointerMove(event));
    canvas.addEventListener("pointerup", (event) => this.onPointerUp(event));
    canvas.addEventListener("pointercancel", () => this.cancelDrag());
    canvas.addEventListener("lostpointercapture", () => {
      if (this.dragging) this.cancelDrag();
    });
  }

  cardEl(id) {
    for (const card of this.canvas.querySelectorAll(".od-card")) if (card.dataset.hookId === id) return card;
    return null;
  }

  hostOf(card) {
    return card.closest("od-hook-card");
  }

  select(card) {
    const host = this.hostOf(card);
    if (!host) return;
    this.selected = host.hook.id;
    this.markSelected();
    document.dispatchEvent(new CustomEvent("od-hook-select", { detail: { hook: host.hook, trigger: card } }));
  }

  markSelected() {
    for (const card of this.canvas.querySelectorAll(".od-card")) {
      if (card.dataset.hookId === this.selected) card.dataset.selected = "true";
      else card.removeAttribute("data-selected");
    }
  }

  focusCard(id) {
    const card = id ? this.cardEl(id) : null;
    if (!card) return;
    this.current = id;
    this.roving();
    card.focus();
  }

  roving() {
    const cards = [...this.canvas.querySelectorAll(".od-card")];
    let target = cards.find((card) => card.dataset.hookId === this.current) || cards[0];
    for (const card of cards) card.tabIndex = card === target ? 0 : -1;
  }

  highlight(card) {
    this.unhighlight();
    const word = card.dataset.program;
    if (!word) return;
    const matches = [...this.canvas.querySelectorAll(".od-card")].filter((other) => other !== card && other.dataset.program === word);
    if (!matches.length) return;
    for (const other of matches) other.dataset.same = "true";
    this.hot = matches;
    sizeSvg(this.svg, this.canvas);
    renderEdges(this.svg, buildEdges(this.canvas, card, matches));
  }

  unhighlight() {
    if (this.hot) for (const other of this.hot) other.removeAttribute("data-same");
    this.hot = null;
    clearEdges(this.svg);
  }

  edges() {
    const region = this.region;
    if (!region) return;
    const max = region.scrollWidth - region.clientWidth;
    const left = Math.abs(region.scrollLeft);
    this.toggleAttribute("data-more-end", max > 1 && left < max - 1);
    this.toggleAttribute("data-more-start", max > 1 && left > 1);
    this.style.setProperty("--scrollbar-w", `${region.offsetWidth - region.clientWidth}px`);
    this.style.setProperty("--scrollbar-h", `${region.offsetHeight - region.clientHeight}px`);
  }

  rails() {
    if (!this.canvas) return;
    for (const frame of this.canvas.querySelectorAll("od-sequence")) frame.rail();
  }

  render() {
    if (this.dragging) {
      this.deferred = true;
      return;
    }
    const ctx = this.ctx;
    if (!ctx || !ctx.layout || !ctx.config || !this.region) return;
    const active = document.activeElement;
    let refocus = null;
    let regionFocus = false;
    if (active && this.contains(active)) {
      const card = active.closest(".od-card");
      if (card) refocus = card.dataset.hookId;
      else if (active === this.region) regionFocus = true;
    }
    const left = this.region.scrollLeft;
    const top = this.region.scrollTop;
    this.unhighlight();
    const everything = allHooks(ctx.layout, "both");
    if (!everything.length) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "empty_first_run");
      state.setAttribute("heading", "No hooks are configured");
      state.setAttribute("body", "None of Claude Code, Codex or Hermes has a hook in the files ordonnateur reads.");
      const command = document.createElement("od-command");
      command.setAttribute("command", "ordonnateur list");
      state.append(command);
      this.region.replaceChildren(state);
      this.tables = [];
      return;
    }
    if (allOff(ctx)) {
      const filtered = document.createElement("od-state");
      filtered.setAttribute("kind", "empty_filtered");
      filtered.setAttribute("heading", "All sources hidden");
      filtered.setAttribute("body", "Every source is switched off in the bar above.");
      filtered.setAttribute("action", "Show all");
      filtered.addEventListener("od-action", () => this.dispatchEvent(new CustomEvent("od-sources-all", { bubbles: true })));
      this.region.replaceChildren(filtered);
      this.tables = [];
      return;
    }
    const state = projectDraft(ctx.layout, ctx.project);
    state.hermes = projectHermes(ctx.layout, ctx.project);
    const index = findingIndex(ctx.layout);
    for (const table of this.tables) table.remove();
    this.tables = [];
    for (const harness of harnessesFor(ctx.harness)) {
      const table = this.buildTable(harness, ctx, state, index);
      this.tables.push(table);
      this.canvas.insertBefore(table, this.svg);
    }
    if (!this.canvas.contains(this.svg)) this.canvas.append(this.svg);
    if (this.canvas.parentNode !== this.region) this.region.replaceChildren(this.canvas);
    this.layer.replaceChildren(this.tooltip);
    for (const tip of this.canvas.querySelectorAll("od-tooltip")) this.layer.append(tip);
    this.region.scrollLeft = left;
    this.region.scrollTop = top;
    this.markSelected();
    this.roving();
    if (this.settle) {
      const card = this.cardEl(this.settle);
      if (card) card.dataset.settle = "true";
      const id = this.settle;
      this.settle = null;
      setTimeout(() => {
        const node = this.cardEl(id);
        if (node) node.removeAttribute("data-settle");
      }, 400);
    }
    if (refocus) this.focusCard(this.cardEl(refocus) ? refocus : null);
    else if (regionFocus) this.region.focus();
    fitMiddle(this.canvas);
    this.hotSource(this.hotKey);
    this.rails();
    this.edges();
    requestAnimationFrame(() => {
      fitMiddle(this.canvas);
      this.rails();
      this.edges();
    });
  }

  buildTable(harness, ctx, state, index) {
    const hooks = visibleHooks(ctx.layout, harness, hiddenOf(ctx));
    const table = el("table", "od-matrix");
    table.dataset.harness = harness;
    table.dataset.density = ctx.density;
    const caption = el("caption", "od-caption");
    caption.append(el("span", "od-caption-text", HARNESS_LABELS[harness] || harness));
    table.append(caption);
    if (!hooks.length) {
      table.dataset.empty = "true";
      table.append(el("tbody"));
      const wrap = el("div", "od-matrix-none");
      const label = HARNESS_LABELS[harness] || harness;
      const masked = allHooks(ctx.layout, harness).length > 0;
      wrap.append(table, el("p", "od-none", masked ? `All ${label} sources hidden.` : `No ${label} hooks found.`));
      wrap.dataset.harness = harness;
      return wrap;
    }
    const events = eventsFor(harness, hooks, ctx);
    table.style.setProperty("--cols", String(events.length));
    const rows = rowDefs(harness, hooks, ctx);
    const content = new Map();
    const totals = new Map(events.map((event) => [event, { natives: 0, frames: 0 }]));
    for (const row of rows) {
      for (const event of events) {
        const cell = cellContent(row, event, ctx, state, index, this.showDisabled);
        content.set(`${row.key}|${event}`, cell);
        if (!row.disabled) {
          const total = totals.get(event);
          total.natives += cell.natives.length;
          if (cell.frame) total.frames += 1;
        }
      }
    }
    const group = el("colgroup");
    group.append(el("col", "od-col-rowhead"));
    for (let i = 0; i < events.length; i += 1) group.append(el("col", "od-col-event"));
    group.append(el("col", "od-col-fill"));
    table.append(group);
    const thead = el("thead");
    const headRow = el("tr");
    const corner = el("th", "od-corner");
    corner.scope = "col";
    corner.append(el("span", "od-colname", "Source"));
    headRow.append(corner);
    const reasons = (ctx.config.not_sequenceable || {});
    for (const event of events) {
      const th = el("th", "od-colhead");
      th.scope = "col";
      th.dataset.event = event;
      const line = el("span", "od-colline");
      const name = el("span", "od-colname", event);
      name.title = event;
      line.append(name);
      const reason = harness === "claude-code" ? reasons[event] : null;
      if (reason) {
        const lock = el("span", "od-lock");
        lock.tabIndex = 0;
        lock.setAttribute("role", "img");
        lock.setAttribute("aria-label", `Not sequenceable. ${reason}`);
        lock.append(glyph("lock-slash", "od-icon od-icon-sm"));
        line.append(tipped(lock, reason));
      }
      const total = totals.get(event);
      const summary =
        harness === "hermes"
          ? total.natives
            ? `${total.natives} ${total.natives === 1 ? "hook" : "hooks"} in order`
            : "No hooks"
          : summaryText(total.natives, total.frames);
      th.append(line, el("span", "od-colsummary", summary));
      headRow.append(th);
    }
    thead.append(headRow);
    table.append(thead);
    const tbody = el("tbody");
    for (const row of rows) tbody.append(this.buildRow(row, events, content, ctx));
    table.append(tbody);
    return table;
  }

  buildRow(row, events, content, ctx) {
    const tr = el("tr", "od-matrix-row");
    tr.dataset.row = row.key;
    const head = el("th", "od-rowhead");
    head.scope = "row";
    const name = el("span", "od-rowname", row.label);
    name.title = row.label;
    name.setAttribute("aria-label", row.label);
    const top = el("span", "od-rowline");
    if (ctx.sources && ctx.sources.active && !row.disabled) {
      const source = providerMeta(`${row.harness}:${row.key}`);
      head.dataset.src = String(source.color);
      head.dataset.shape = source.shape;
      head.dataset.provider = `${row.harness}:${row.key}`;
      const dot = el("span", "od-src-dot");
      dot.setAttribute("aria-hidden", "true");
      dot.dataset.src = String(source.color);
      dot.dataset.shape = source.shape;
      top.append(dot);
    }
    top.append(name);
    if (row.editable && !ctx.readOnly) {
      const chip = document.createElement("od-chip");
      chip.setAttribute("label", "Editable");
      top.append(chip);
    } else if (!row.disabled) {
      const lock = el("span", "od-readonly");
      lock.append(glyph("lock", "od-icon od-icon-sm"), el("span", "visually-hidden", "Read-only"));
      top.append(lock);
    }
    head.append(top);
    if (row.path) {
      const path = el("span", "od-rowpath mono", row.path);
      path.dataset.fit = row.path;
      path.tabIndex = -1;
      head.append(tipped(path, row.path));
    }
    if (row.disabled) {
      const count = row.hooks.length;
      head.append(el("span", "od-rowpath", `${count} ${count === 1 ? "hook" : "hooks"}`));
      const toggle = document.createElement("od-toggle");
      toggle.setAttribute("label", "Show");
      if (this.showDisabled) toggle.setAttribute("checked", "");
      toggle.addEventListener("od-change", (event) => {
        this.showDisabled = event.detail.checked;
        this.render();
      });
      head.append(toggle);
    }
    tr.append(head);
    for (const event of events) {
      const td = el("td", "od-cell");
      td.dataset.harness = row.harness;
      td.dataset.row = row.key;
      td.dataset.event = event;
      td.dataset.scope = row.scope;
      td.dataset.editable = row.editable ? "true" : "false";
      const inner = el("div", "od-cell-inner");
      const cell = content.get(`${row.key}|${event}`);
      if (cell.frame) {
        const frame = document.createElement("od-sequence");
        frame.model = {
          scope: cell.frame.scope,
          event,
          ids: cell.frame.ids,
          stop: cell.frame.stop,
          editable: row.editable,
          readOnly: ctx.readOnly,
          ctx,
          cards: cell.frame.cards.map((model) => this.makeCard(model)),
        };
        const first = cell.frame.cards[0];
        if (first) {
          const source = providerMeta(providerKey(first.original));
          frame.dataset.src = String(source.color);
          frame.dataset.shape = source.shape;
        }
        inner.append(frame);
      }
      for (const model of cell.natives) inner.append(this.makeCard(model));
      td.append(inner);
      tr.append(td);
    }
    return tr;
  }

  makeCard(model) {
    const card = document.createElement("od-hook-card");
    card.model = model;
    return card;
  }

  onKey(event) {
    const node = event.target;
    if (!node.classList || !node.classList.contains("od-card")) return;
    const host = this.hostOf(node);
    const ctx = this.ctx;
    if (event.key === "Escape") {
      event.preventDefault();
      this.region.focus();
      return;
    }
    if (shortcut(event, host.hook, ctx)) return;
    if (event.key === "Enter" && !event.altKey && !event.ctrlKey && !event.metaKey) {
      event.preventDefault();
      this.select(node);
      return;
    }
    if ((event.key === "." && !event.altKey && !event.ctrlKey && !event.metaKey) || (event.key === "F10" && event.shiftKey) || event.key === "ContextMenu") {
      event.preventDefault();
      node.dispatchEvent(new CustomEvent("od-hook-action", { bubbles: true, detail: { action: "menu", hook: host.hook, trigger: node, context: ctx } }));
      return;
    }
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    const next = this.neighbour(node, event.key);
    if (next) {
      event.preventDefault();
      this.focusCard(next.dataset.hookId);
    } else if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)) {
      event.preventDefault();
    }
  }

  neighbour(card, key) {
    const td = card.closest("td");
    if (!td) return null;
    const tr = td.parentElement;
    const rows = [...tr.parentElement.rows];
    const r = rows.indexOf(tr);
    const c = td.cellIndex;
    const cardsIn = (cell) => (cell ? [...cell.querySelectorAll(".od-card")] : []);
    const here = cardsIn(td);
    const i = here.indexOf(card);
    if (key === "ArrowDown") {
      if (i < here.length - 1) return here[i + 1];
      for (let k = r + 1; k < rows.length; k += 1) {
        const found = cardsIn(rows[k].cells[c]);
        if (found.length) return found[0];
      }
    } else if (key === "ArrowUp") {
      if (i > 0) return here[i - 1];
      for (let k = r - 1; k >= 0; k -= 1) {
        const found = cardsIn(rows[k].cells[c]);
        if (found.length) return found[found.length - 1];
      }
    } else if (key === "ArrowRight") {
      for (let k = c + 1; k < tr.cells.length; k += 1) {
        const found = cardsIn(tr.cells[k]);
        if (found.length) return found[0];
      }
    } else if (key === "ArrowLeft") {
      for (let k = c - 1; k >= 1; k -= 1) {
        const found = cardsIn(tr.cells[k]);
        if (found.length) return found[0];
      }
    }
    return null;
  }

  onPointerDown(event) {
    if (event.button !== 0 || !event.target.closest) return;
    const handle = event.target.closest(".od-handle");
    if (!handle || handle.classList.contains("od-pinned") || !this.ctx || this.ctx.readOnly) return;
    const host = handle.closest("od-hook-card");
    if (!host) return;
    event.preventDefault();
    this.pending = { host, id: event.pointerId, x: event.clientX, y: event.clientY };
    try {
      this.canvas.setPointerCapture(event.pointerId);
    } catch (error) {
      this.pending = null;
    }
  }

  onPointerMove(event) {
    if (this.pending && !this.dragging) {
      const moved = Math.hypot(event.clientX - this.pending.x, event.clientY - this.pending.y);
      if (moved >= DRAG_THRESHOLD) this.startDrag(event);
    }
    if (this.dragging) this.moveDrag(event);
  }

  onPointerUp(event) {
    const pending = this.pending;
    if (this.dragging) {
      this.finishDrag(event);
    } else if (pending) {
      this.pending = null;
    }
    if (pending && this.canvas.hasPointerCapture && this.canvas.hasPointerCapture(pending.id)) this.canvas.releasePointerCapture(pending.id);
  }

  sourceInfo(host) {
    const hook = host.hook;
    const model = host.model;
    const td = host.closest("td");
    return {
      host,
      hook,
      model,
      member: model.member,
      harness: td.dataset.harness,
      pinned: Boolean(model.pinned),
      row: td.dataset.row,
      event: td.dataset.event,
      scope: td.dataset.scope,
      cell: td,
    };
  }

  startDrag(event) {
    const host = this.pending.host;
    const source = this.sourceInfo(host);
    const rect = host.getBoundingClientRect();
    const ghost = document.createElement("od-hook-card");
    ghost.model = { ...host.model, selected: false };
    ghost.className = "od-ghost";
    ghost.style.width = `${Math.round(rect.width)}px`;
    document.body.append(ghost);
    fitMiddle(ghost);
    const placeholder = el("div", "od-placeholder");
    placeholder.style.height = `${Math.round(rect.height)}px`;
    host.parentNode.insertBefore(placeholder, host);
    host.dataset.dragSource = "true";
    this.dragging = {
      source,
      ghost,
      placeholder,
      dx: event.clientX - rect.left,
      dy: event.clientY - rect.top,
      verdict: { ok: true, action: "none" },
      slots: [],
    };
    this.unhighlight();
    document.documentElement.classList.add("od-drag-active");
    this.tooltip.target = ghost;
    this.addSlots(source);
    if (source.harness === "hermes") this.seedHermes(source);
    this.position(event);
    this.suppressClick = true;
  }

  addSlots(source) {
    const ctx = this.ctx;
    if (source.harness === "hermes" || source.member || !source.cell || source.cell.dataset.editable !== "true") return;
    const sequenceable = (ctx.config.sequenceable || []).includes(source.event);
    if (!sequenceable || !source.hook.absorbable || source.hook.guard) return;
    if (source.cell.querySelector("od-sequence")) return;
    const slot = el("div", "od-seq-slot");
    slot.append(el("span", "od-seq-label", "Drop to sequence"));
    source.cell.querySelector(".od-cell-inner").prepend(slot);
    this.dragging.slots.push(slot);
  }

  position(event) {
    const d = this.dragging;
    d.ghost.style.left = `${Math.round(event.clientX - d.dx)}px`;
    d.ghost.style.top = `${Math.round(event.clientY - d.dy)}px`;
  }

  verdictAt(x, y) {
    const d = this.dragging;
    const source = d.source;
    const ctx = this.ctx;
    const stack = document.elementsFromPoint(x, y);
    const td = stack.map((node) => node.closest && node.closest("td.od-cell")).find(Boolean);
    if (!td || !this.canvas.contains(td)) return { ok: false, reason: null };
    const frame = stack.map((node) => node.closest && node.closest("od-sequence")).find((node) => node && td.contains(node));
    const slot = td.querySelector(".od-seq-slot");
    const info = td.dataset;
    if (source.harness === "hermes") {
      if (info.harness !== "hermes" || info.row !== source.row) return { ok: false, reason: "Hermes hooks stay in the Profile config row" };
      if (info.event !== source.event) return { ok: false, reason: "Hooks stay on their own event" };
      const over = stack.map((node) => node.closest && node.closest(".od-card")).find((node) => node && td.contains(node));
      if (over && over.dataset.pinned === "true") return { ok: false, reason: "Pinned hooks keep their place" };
      return { ok: true, action: "hermes", td };
    }
    if (info.harness === "hermes") return { ok: false, reason: "Sequences stay inside one settings file" };
    if (info.harness === "codex") return { ok: false, reason: "Codex is read-only" };
    if (info.row !== source.row) return { ok: false, reason: "Sequences stay inside one settings file" };
    if (info.event !== source.event) return { ok: false, reason: "Hooks stay on their own event" };
    const reasons = ctx.config.not_sequenceable || {};
    if (reasons[source.event]) return { ok: false, reason: reasons[source.event] };
    if (source.member) {
      if (frame) return { ok: true, action: "reorder", list: frame.list };
      return { ok: true, action: "release", td };
    }
    if (source.hook.guard) return { ok: false, reason: "Guards stay native" };
    if (!source.hook.absorbable) return { ok: false, reason: source.hook.reason || "This hook cannot be sequenced" };
    if (frame) return { ok: true, action: "sequence", list: frame.list };
    if (slot) return { ok: true, action: "sequence", list: slot };
    return { ok: true, action: "none" };
  }

  insertionIndex(list, y) {
    const d = this.dragging;
    const cards = [...list.children].filter((node) => node.tagName === "OD-HOOK-CARD" && node !== d.source.host);
    let at = 0;
    for (const card of cards) {
      const box = card.getBoundingClientRect();
      if (y > box.top + box.height / 2) at += 1;
    }
    return { at, cards };
  }

  seedHermes(source) {
    const inner = source.cell.querySelector(".od-cell-inner");
    this.dragging.hermes = { inner, hosts: [...inner.children].filter((node) => node.tagName === "OD-HOOK-CARD") };
  }

  hermesIndex(y) {
    const d = this.dragging;
    let at = 0;
    for (const host of d.hermes.hosts) {
      if (host === d.source.host || host.model.pinned) continue;
      const box = host.getBoundingClientRect();
      if (y > box.top + box.height / 2) at += 1;
    }
    return at;
  }

  arrangeHermes(at) {
    const d = this.dragging;
    const { inner, hosts } = d.hermes;
    const others = hosts.filter((host) => host !== d.source.host && !host.model.pinned);
    const final = others.slice();
    final.splice(Math.min(at, final.length), 0, d.placeholder);
    let k = 0;
    const ordered = hosts.map((host) => {
      if (host === d.source.host) return null;
      if (host.model.pinned) return host;
      const next = final[k];
      k += 1;
      return next;
    });
    if (k < final.length) ordered.push(...final.slice(k));
    inner.append(...ordered.filter(Boolean), d.source.host);
  }

  moveDrag(event) {
    const d = this.dragging;
    this.position(event);
    this.autoScroll(event);
    const verdict = this.verdictAt(event.clientX, event.clientY);
    d.verdict = verdict;
    document.documentElement.classList.toggle("od-drag-illegal", !verdict.ok);
    if (!verdict.ok) {
      this.tooltip.text = verdict.reason || "";
      if (verdict.reason) this.tooltip.show();
      else this.tooltip.hide();
      return;
    }
    this.tooltip.hide();
    const placeholder = d.placeholder;
    if (verdict.action === "hermes") {
      d.at = this.hermesIndex(event.clientY);
      this.arrangeHermes(d.at);
    } else if (verdict.action === "reorder" || verdict.action === "sequence") {
      const { at, cards } = this.insertionIndex(verdict.list, event.clientY);
      d.at = at;
      const before = cards[at] || null;
      if (verdict.list.classList.contains("od-seq-slot")) verdict.list.append(placeholder);
      else if (before) verdict.list.insertBefore(placeholder, before);
      else verdict.list.append(placeholder);
    } else if (verdict.action === "release") {
      verdict.td.querySelector(".od-cell-inner").append(placeholder);
    } else {
      d.source.host.parentNode.insertBefore(placeholder, d.source.host);
    }
  }

  autoScroll(event) {
    const box = this.region.getBoundingClientRect();
    if (event.clientY < box.top + SCROLL_ZONE) this.region.scrollTop -= SCROLL_STEP;
    else if (event.clientY > box.bottom - SCROLL_ZONE) this.region.scrollTop += SCROLL_STEP;
    if (event.clientX < box.left + SCROLL_ZONE) this.region.scrollLeft -= SCROLL_STEP;
    else if (event.clientX > box.right - SCROLL_ZONE) this.region.scrollLeft += SCROLL_STEP;
  }

  cleanup() {
    const d = this.dragging;
    this.dragging = null;
    this.pending = null;
    if (!d) return;
    d.ghost.remove();
    d.placeholder.remove();
    for (const slot of d.slots) slot.remove();
    delete d.source.host.dataset.dragSource;
    document.documentElement.classList.remove("od-drag-active", "od-drag-illegal");
    this.tooltip.hide();
    this.tooltip.target = null;
  }

  cancelDrag() {
    if (!this.dragging && !this.pending) return;
    this.cleanup();
    this.suppressClick = false;
    if (this.deferred) {
      this.deferred = false;
      this.render();
    }
  }

  finishDrag(event) {
    const d = this.dragging;
    const verdict = d.verdict;
    const source = d.source;
    const at = d.at;
    this.cleanup();
    setTimeout(() => {
      this.suppressClick = false;
    }, 0);
    const ctx = this.ctx;
    const hook = source.host.hook;
    const base = projectDraft(ctx.layout, ctx.project);
    const ids = (base.members.get(`${source.scope}|${source.event}`) || []).map((member) => member.id);
    let changed = false;
    if (verdict.ok && verdict.action === "hermes") {
      const state = projectHermes(ctx.layout, ctx.project);
      const ids = (state.orders.get(source.event) || []).filter((item) => !isPinned(item)).map((item) => item.id);
      const next = ids.filter((id) => id !== hook.id);
      next.splice(Math.min(at == null ? next.length : at, next.length), 0, hook.id);
      if (next.join("|") !== ids.join("|")) {
        this.settle = hook.id;
        changed = commitHermes(hook, ctx, next);
      }
    } else if (verdict.ok && verdict.action === "reorder") {
      const next = ids.filter((id) => id !== hook.id);
      next.splice(Math.min(at == null ? next.length : at, next.length), 0, hook.id);
      if (next.join("|") !== ids.join("|")) {
        this.settle = hook.id;
        changed = commit(hook, ctx, next, "move");
      }
    } else if (verdict.ok && verdict.action === "sequence") {
      const next = ids.slice();
      next.splice(Math.min(at == null ? next.length : at, next.length), 0, hook.id);
      this.settle = hook.id;
      changed = commit(hook, ctx, next, "sequence");
    } else if (verdict.ok && verdict.action === "release") {
      this.settle = hook.id;
      changed = commit(hook, ctx, ids.filter((id) => id !== hook.id), "release");
    }
    if (!changed) this.settle = null;
    if (this.deferred) {
      this.deferred = false;
      if (!changed) this.render();
    }
    if (!changed) {
      const card = this.cardEl(hook.id);
      if (card) card.focus({ preventScroll: true });
    }
  }
}

customElements.define("od-matrix", OdMatrix);

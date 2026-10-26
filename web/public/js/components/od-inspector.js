import "./od-button.js";
import "./od-icon-button.js";
import "./od-chip.js";
import "./od-digest.js";
import "./od-command.js";
import "./od-drawer.js";
import "./od-tooltip.js";
import { allowedActions, perform } from "./od-hook-menu.js";
import { shell } from "../core/plans.js";
import { announce } from "../core/announce.js";
import { providerKey, providerMeta } from "../core/sources.js";
import { HARNESS_LABELS, findingIndex, isHermes, isMember, isPinned, memberPosition, pinReason, program, statusOf } from "../core/hooks.js";

const WIDE = "(min-width: 1024px)";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function section(label) {
  const node = el("section", "od-insp-section");
  const title = el("h3", "od-insp-label", label);
  node.append(title);
  return node;
}

function rows(pairs) {
  const list = el("dl", "od-insp-kv");
  for (const [label, value] of pairs) {
    const term = el("dt", "od-insp-key", label);
    const detail = el("dd", "od-insp-val");
    if (value instanceof Node) detail.append(value);
    else detail.textContent = value === null || value === undefined || value === "" ? "Not set" : String(value);
    list.append(term, detail);
  }
  return list;
}

function layoutMembers(hook, layout) {
  return ((layout && layout.hooks) || [])
    .filter((item) => item.harness === "claude-code" && item.scope === hook.scope && item.event === hook.event && isMember(item))
    .sort((a, b) => memberPosition(a) - memberPosition(b))
    .map((item) => item.id);
}

const LABELS = {
  up: "Move up",
  down: "Move down",
  first: "Move to first",
  last: "Move to last",
  sequence: "Sequence this hook",
  release: "Release from sequence",
  unguard: "Unguard",
  guard: "Guard",
  copy: "Copy id",
};

class OdInspector extends HTMLElement {
  connectedCallback() {
    if (this.listening) return;
    this.listening = true;
    this.hookId = null;
    this.trigger = null;
    this.query = window.matchMedia(WIDE);
    this.onSelect = (event) => this.open(event.detail.hook, event.detail.trigger);
    this.onRefresh = () => this.refresh();
    this.onMedia = () => this.reopen();
    this.onSources = (event) => this.sourcesChanged(event.detail);
    this.onKey = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented || !this.hookId || this.drawer) return;
      if (!this.contains(document.activeElement)) return;
      event.preventDefault();
      this.close(true);
    };
    document.addEventListener("od-hook-select", this.onSelect);
    document.addEventListener("od-layout-loaded", this.onRefresh);
    document.addEventListener("od-draft-change", this.onRefresh);
    document.addEventListener("od-sources-change", this.onSources);
    this.query.addEventListener("change", this.onMedia);
    this.addEventListener("keydown", this.onKey);
  }

  disconnectedCallback() {
    this.listening = false;
    document.removeEventListener("od-hook-select", this.onSelect);
    document.removeEventListener("od-layout-loaded", this.onRefresh);
    document.removeEventListener("od-draft-change", this.onRefresh);
    document.removeEventListener("od-sources-change", this.onSources);
    this.query.removeEventListener("change", this.onMedia);
  }

  context() {
    const owner = shell();
    return owner && typeof owner.context === "function" ? owner.context() : null;
  }

  main() {
    return this.closest(".od-main");
  }

  host() {
    return this.closest(".od-inspector-host");
  }

  find() {
    const context = this.context();
    if (!context || !context.layout) return null;
    return context.layout.hooks.find((item) => item.id === this.hookId) || null;
  }

  open(hook, trigger) {
    if (!hook) return;
    this.hookId = hook.id;
    this.trigger = trigger || document.activeElement;
    this.mountSurface();
    this.render(true);
  }

  mountSurface() {
    this.teardown();
    if (this.query.matches) {
      this.panel = el("aside", "od-inspector");
      this.panel.setAttribute("aria-label", "Hook details");
      const header = el("header", "od-insp-header");
      const title = el("h2", "od-insp-title", "Hook details");
      title.tabIndex = -1;
      header.append(title);
      const close = document.createElement("od-icon-button");
      close.setAttribute("icon", "close");
      close.setAttribute("label", "Close hook details");
      close.setAttribute("size", "sm");
      close.addEventListener("click", () => this.close(true));
      header.append(close);
      this.content = el("div", "od-insp-body");
      this.panel.append(header, this.content);
      this.append(this.panel);
      this.host().hidden = false;
      const main = this.main();
      if (main) main.dataset.inspector = "open";
    } else {
      this.drawer = document.createElement("od-drawer");
      this.drawer.setAttribute("heading", "Hook details");
      this.content = el("div", "od-insp-body");
      this.drawer.append(this.content);
      document.body.append(this.drawer);
      const owner = this.main();
      if (owner) owner.dataset.inspector = "open";
      this.drawer.addEventListener("od-close", () => {
        if (!this.drawer) return;
        this.hookId = null;
        this.trigger = null;
        this.teardown();
      });
      this.drawer.show(this.trigger);
    }
  }

  teardown() {
    if (this.panel) this.panel.remove();
    if (this.drawer) {
      const drawer = this.drawer;
      this.drawer = null;
      drawer.remove();
    }
    this.panel = null;
    this.content = null;
    const host = this.host();
    if (host) host.hidden = true;
    const main = this.main();
    if (main) delete main.dataset.inspector;
  }

  reopen() {
    if (!this.hookId) return;
    this.mountSurface();
    this.render(false);
  }

  close(restore) {
    const trigger = this.trigger;
    this.hookId = null;
    this.trigger = null;
    if (this.drawer) {
      const drawer = this.drawer;
      this.drawer = null;
      drawer.close();
      drawer.remove();
    }
    this.teardown();
    if (restore && trigger && trigger.isConnected && typeof trigger.focus === "function") trigger.focus();
  }

  sourcesChanged(detail) {
    if (!this.hookId || !detail || !detail.hidden || !detail.hidden.size) return;
    const hook = this.find();
    if (!hook || !detail.hidden.has(providerKey(hook))) return;
    const name = program(hook).base;
    this.close(false);
    const bar = document.querySelector("od-source-bar");
    if (bar && detail.key && typeof bar.focusKey === "function") bar.focusKey(detail.key);
    announce(`Closed the inspector: ${name} is in a hidden source.`);
  }

  refresh() {
    if (!this.hookId) return;
    if (!this.find()) {
      this.close(false);
      return;
    }
    this.render(false);
  }

  render(focus) {
    const hook = this.find();
    const context = this.context();
    if (!hook || !context || !this.content) return;
    const active = this.content.contains(document.activeElement) ? document.activeElement.closest("[data-action]") : null;
    const activeKey = active ? active.dataset.action : null;
    this.content.replaceChildren(
      this.identity(hook),
      this.command(hook),
      this.settings(hook),
      this.status(hook, context),
      this.findings(hook, context),
      this.timing(hook),
      this.actions(hook, context),
    );
    if (activeKey) {
      const target = this.content.querySelector(`[data-action="${activeKey}"]`);
      if (target) target.focus();
    } else if (focus && this.panel) {
      const first = this.panel.querySelector(".od-insp-title");
      if (first) first.focus();
    }
  }

  identity(hook) {
    const node = section("Identity");
    const digest = document.createElement("od-digest");
    digest.setAttribute("value", hook.id);
    digest.setAttribute("kind", "hook id");
    digest.setAttribute("length", String(hook.id.length));
    const path = el("span", "od-insp-path mono", hook.line ? `${hook.source_file}:${hook.line}` : hook.source_file || "");
    const meta = providerMeta(providerKey(hook));
    const source = el("span", "od-insp-source");
    source.dataset.src = String(meta.color);
    source.dataset.shape = meta.shape;
    const dot = el("span", "od-src-dot");
    dot.setAttribute("aria-hidden", "true");
    dot.dataset.src = String(meta.color);
    dot.dataset.shape = meta.shape;
    source.append(dot, document.createTextNode(" "), path);
    node.append(
      rows([
        ["Id", digest],
        ["Harness", HARNESS_LABELS[hook.harness] || "Claude Code"],
        ["Event", hook.event],
        ["Source", source],
      ]),
    );
    return node;
  }

  command(hook) {
    const node = section("Command");
    const text = typeof hook.command === "string" && hook.command ? hook.command : Array.isArray(hook.args) ? hook.args.join(" ") : "";
    const block = el("pre", "od-insp-command mono", text || "Not set");
    block.tabIndex = 0;
    block.setAttribute("aria-label", "Full command");
    node.append(block);
    return node;
  }

  settings(hook) {
    const node = section("Settings");
    const raw = hook.hook || {};
    if (isHermes(hook)) {
      const unset = hook.timeout === null || hook.timeout === undefined;
      const effective = hook.effective_timeout === undefined || hook.effective_timeout === null ? 60 : hook.effective_timeout;
      const closed = raw.fail_closed !== undefined ? raw.fail_closed : raw.failClosed;
      node.append(
        rows([
          ["Matcher", hook.matcher],
          ["Timeout", `${effective} s${unset ? " (default)" : ""}`],
          ["Fail closed", closed === undefined || closed === null ? null : String(closed)],
        ]),
      );
      return node;
    }
    const timeout =
      hook.effective_timeout === undefined || hook.effective_timeout === null
        ? null
        : `${hook.effective_timeout} s${hook.timeout === null || hook.timeout === undefined ? " (event default)" : ""}`;
    node.append(
      rows([
        ["Matcher", hook.matcher],
        ["Timeout", timeout],
        ["Type", hook.type],
        ["Async", raw.async === undefined ? null : String(raw.async)],
        ["On failure", raw.onFailure],
      ]),
    );
    return node;
  }

  status(hook, context) {
    const node = section("Status");
    const line = el("div", "od-insp-status");
    const status = statusOf(hook);
    if (isMember(hook)) {
      const count = layoutMembers(hook, context.layout).length;
      const chip = document.createElement("od-chip");
      chip.setAttribute("label", `Member ${memberPosition(hook)} of ${count}`);
      line.append(chip);
    } else if (status) {
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "status");
      chip.setAttribute("value", status.value);
      line.append(chip);
      if (status.consent) {
        const consent = document.createElement("od-chip");
        consent.setAttribute("kind", "status");
        consent.setAttribute("value", status.consent.value);
        line.append(consent);
      }
    }
    node.append(line);
    const reasons = [];
    if (isHermes(hook)) {
      const consent = status && status.consent ? status.consent : status;
      const trust = hook.trust || {};
      if (consent) {
        if (consent.value === "allowlisted") reasons.push(`Allowlisted, approved ${trust.approved_at || "on an unknown date"}`);
        else if (consent.value === "auto_accepted") reasons.push(`Auto-accepted: an opt-in (${trust.opt_in || "set"}) approves every hook`);
        else reasons.push("Not allowlisted: Hermes does not run this hook until it is approved in Hermes");
      }
      if (isPinned(hook)) reasons.push(`Pinned: ${pinReason(hook)} It keeps its place in every reorder.`);
      for (const reason of reasons) node.append(el("p", "od-insp-reason", reason));
      return node;
    }
    if (hook.protected && hook.protected_reason) reasons.push(hook.protected_reason);
    if (hook.reason) reasons.push(`${program(hook).base} ${hook.reason}${hook.reason.endsWith(".") ? "" : "."}`);
    if (status && status.reason && status.reason !== hook.reason && !reasons.includes(status.reason)) reasons.push(status.reason);
    if (hook.harness === "codex" && hook.trust) reasons.push(typeof hook.trust === "string" ? hook.trust : JSON.stringify(hook.trust));
    if (!reasons.length) reasons.push("No restriction applies to this hook.");
    for (const reason of reasons) node.append(el("p", "od-insp-reason", reason));
    return node;
  }

  findings(hook, context) {
    const node = section("Findings");
    const index = findingIndex(context.layout);
    const items = (hook.findings || []).map((id) => index.get(id)).filter(Boolean);
    if (!items.length) {
      node.append(el("p", "od-insp-quiet", "No findings for this hook."));
      return node;
    }
    const list = el("ul", "od-insp-findings");
    for (const finding of items) {
      const item = el("li", "od-insp-finding");
      const head = el("div", "od-insp-finding-head");
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "severity");
      chip.setAttribute("value", finding.severity);
      head.append(chip, el("code", "od-insp-code mono", finding.code));
      item.append(head, el("p", "od-insp-message", finding.message));
      if (finding.fix) {
        const fix = document.createElement("od-command");
        fix.setAttribute("command", finding.fix);
        fix.setAttribute("who", "");
        item.append(fix);
      }
      list.append(item);
    }
    node.append(list);
    return node;
  }

  timing(hook) {
    const node = section("Timing");
    const timing = hook.timing;
    if (!timing) {
      node.append(el("p", "od-insp-quiet", "No runs recorded."));
      return node;
    }
    const grid = el("div", "od-insp-tiles");
    const tiles = [
      ["Runs", timing.runs],
      ["p50 ms", timing.p50],
      ["p95 ms", timing.p95],
      ["Max ms", timing.max],
    ];
    for (const [label, value] of tiles) {
      const tile = el("div", "od-insp-tile");
      tile.append(el("span", "od-insp-tile-label", label), el("span", "od-insp-tile-value od-num", value === null || value === undefined ? "n/a" : String(value)));
      grid.append(tile);
    }
    node.append(grid);
    const failures = timing.failures || 0;
    node.append(el("p", "od-insp-quiet", `${failures} ${failures === 1 ? "failure" : "failures"}`));
    return node;
  }

  actions(hook, context) {
    const node = section("Actions");
    const row = el("div", "od-insp-actions");
    for (const key of allowedActions(hook, context)) {
      if (!LABELS[key]) continue;
      const button = document.createElement("od-button");
      button.setAttribute("variant", "secondary");
      button.dataset.action = key;
      button.text = LABELS[key];
      button.addEventListener("click", () => perform(key, hook, context, button));
      row.append(button);
    }
    node.append(row);
    return node;
  }
}

customElements.define("od-inspector", OdInspector);

export function mountInspector() {
  const host = document.querySelector(".od-inspector-host");
  if (!host || host.querySelector("od-inspector")) return;
  host.append(document.createElement("od-inspector"));
}

document.addEventListener("od-layout-loaded", mountInspector);
mountInspector();

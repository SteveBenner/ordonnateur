import "./od-dialog.js";
import "./od-tabs.js";
import "./od-chip.js";
import "./od-digest.js";
import "./od-banner.js";
import "./od-button.js";
import "./od-icon-button.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-code-view.js";
import "./od-provenance-timeline.js";
import "./od-hook-edit.js";
import { app } from "../core/store.js";
import { announce, toast } from "../core/announce.js";
import { shell } from "../core/plans.js";
import { providerKey, providerMeta } from "../core/sources.js";
import { fitMiddle, isMember, memberPosition, program, statusOf } from "../core/hooks.js";
import {
  PROVENANCE_MAX,
  PROVENANCE_PAGE,
  TABS,
  awaitLayoutReload,
  basename,
  downloadScript,
  formatBytes,
  formatTime,
  hiddenCharCount,
  loadDetail,
  loadProvenance,
  historySentence,
  openOnDesktop,
  plural,
} from "../core/hook-detail.js";

const NS = "http://www.w3.org/2000/svg";
const LABELS = { overview: "Overview", script: "Script", provenance: "Provenance", edit: "Edit" };
const OVERVIEW_LIMIT = 1048576;
const NO_DISPLAY = "the server has no display";

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

function button(text, attrs, handler) {
  const node = document.createElement("od-button");
  for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
  node.text = text;
  if (handler) node.addEventListener("click", handler);
  return node;
}

function iconButton(icon, label, handler, size) {
  const node = document.createElement("od-icon-button");
  node.setAttribute("icon", icon);
  node.setAttribute("label", label);
  node.setAttribute("size", size || "xs");
  if (handler) node.addEventListener("click", handler);
  return node;
}

function banner(severity, text, action, handler) {
  const node = document.createElement("od-banner");
  node.setAttribute("severity", severity);
  node.setAttribute("text", text);
  if (action) {
    node.setAttribute("action", action);
    node.addEventListener("od-action", (event) => {
      event.stopPropagation();
      handler(event);
    });
  }
  return node;
}

function skeleton(width) {
  const node = document.createElement("od-skeleton");
  if (width) node.setAttribute("width", width);
  return node;
}

async function copyText(source, text, failure) {
  try {
    await navigator.clipboard.writeText(text);
    source.dispatchEvent(new CustomEvent("od-copied", { bubbles: true, detail: { text, message: "Copied" } }));
  } catch (error) {
    source.dispatchEvent(new CustomEvent("od-copy-failed", { bubbles: true, detail: { text, message: failure || "Select and copy the text." } }));
  }
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

function section(label, className) {
  const node = el("section", `hd-cell${className ? ` ${className}` : ""}`);
  node.append(el("h3", "od-insp-label", label));
  return node;
}

function commandText(hook) {
  if (typeof hook.command === "string" && hook.command) return hook.command;
  if (Array.isArray(hook.args) && hook.args.length) return hook.args.join(" ");
  return "";
}

function context() {
  const owner = shell();
  return owner && typeof owner.context === "function" ? owner.context() : null;
}

function currentFingerprint() {
  const ctx = context();
  return ctx && ctx.layout && ctx.layout.fingerprint ? ctx.layout.fingerprint.config : null;
}

class OdHookDetail extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    this.seq = 0;
    this.deepLinked = false;
    this.dialog = document.createElement("od-dialog");
    this.dialog.setAttribute("size", "lg");
    this.dialog.setAttribute("heading", "Hook");
    this.dialog.setAttribute("initial-focus", ".od-header h2");
    this.notices = el("div", "hd-notices");
    this.notices.dataset.density = "cockpit";
    this.stage = el("div", "hd-stage");
    this.tabs = document.createElement("od-tabs");
    this.tabs.setAttribute("label", "Hook details");
    this.panels = {};
    for (const id of TABS) {
      const panel = el("div", `hd-panel hd-${id}`);
      panel.dataset.tab = id;
      panel.dataset.label = LABELS[id];
      panel.dataset.density = "cockpit";
      this.panels[id] = panel;
      this.tabs.append(panel);
    }
    this.overlay = el("div", "hd-overlay");
    this.overlay.hidden = true;
    this.overlay.dataset.density = "cockpit";
    this.stage.append(this.tabs, this.overlay);
    this.dialog.append(this.notices, this.stage);
    this.append(this.dialog);
    this.dialog.titleEl.tabIndex = -1;
    this.dialog.dialog.querySelector(".od-header").dataset.density = "cockpit";
    this.edit = document.createElement("od-hook-edit");
    this.editLoading = el("div", "hd-loading");
    this.editLoading.setAttribute("aria-busy", "true");
    const editStatus = el("p", "visually-hidden", "Loading hook details");
    editStatus.setAttribute("role", "status");
    this.editLoading.append(editStatus, skeleton(), skeleton("60%"), skeleton(), skeleton("80%"));
    this.panels.edit.append(this.editLoading, this.edit);
    this.timeline = document.createElement("od-provenance-timeline");
    this.panels.provenance.append(this.timeline);
    this.dialog.addEventListener("od-close", () => this.onClosed());
    this.dialog.addEventListener("od-retry", (event) => {
      event.stopPropagation();
      this.load(true);
    });
    this.dialog.closeButton.addEventListener(
      "click",
      (event) => {
        if (this.holdingOrBusy()) {
          event.stopImmediatePropagation();
          return;
        }
        if (this.guardClose()) event.stopImmediatePropagation();
      },
      true,
    );
    this.dialog.dialog.addEventListener("cancel", (event) => {
      if (this.dialog.hasAttribute("busy")) return;
      if (this.closeBanner) {
        event.preventDefault();
        this.clearCloseBanner();
        return;
      }
      if (this.edit.dirty && this.edit.dirty()) {
        event.preventDefault();
        this.showCloseBanner();
      }
    });
    this.tabs.addEventListener("od-tab-change", (event) => {
      this.tab = event.detail.id;
      this.clearCloseBanner();
      window.requestAnimationFrame(() => fitMiddle(this.panels[this.tab]));
    });
    this.edit.addEventListener("od-hook-edit-dirty", () => this.clearCloseBanner());
    this.edit.addEventListener("od-hook-edit-applied", (event) => this.onApplied(event.detail));
    this.edit.addEventListener("od-hook-edit-refetch", (event) => this.onRefetch(event.detail || {}));
    this.timeline.addEventListener("od-prov-refresh", (event) => {
      event.stopPropagation();
      this.refreshProvenance(PROVENANCE_PAGE);
    });
    this.timeline.addEventListener("od-prov-more", (event) => {
      event.stopPropagation();
      this.refreshProvenance(PROVENANCE_MAX, true);
    });
    this.onDetails = (event) => this.open(event.detail && event.detail.hook, event.detail || {});
    this.onLayout = () => this.layoutChanged();
    this.onFirstLayout = () => this.deepLink();
    this.onResize = () => {
      if (this.dialog.open) fitMiddle(this.panels[this.tab || "overview"]);
    };
    document.addEventListener("od-hook-details", this.onDetails);
    document.addEventListener("od-layout-reloaded", this.onLayout);
    document.addEventListener("od-layout-loaded", this.onLayout);
    document.addEventListener("od-layout-loaded", this.onFirstLayout);
    window.addEventListener("resize", this.onResize);
  }

  disconnectedCallback() {
    document.removeEventListener("od-hook-details", this.onDetails);
    document.removeEventListener("od-layout-reloaded", this.onLayout);
    document.removeEventListener("od-layout-loaded", this.onLayout);
    document.removeEventListener("od-layout-loaded", this.onFirstLayout);
    window.removeEventListener("resize", this.onResize);
  }

  holdingOrBusy() {
    return this.dialog.hasAttribute("busy");
  }

  deepLink() {
    if (this.deepLinked) return;
    const ctx = context();
    if (!ctx || !ctx.layout) return;
    this.deepLinked = true;
    document.removeEventListener("od-layout-loaded", this.onFirstLayout);
    const params = new URLSearchParams(window.location.search);
    const id = params.get("hook");
    if (!id) return;
    const tab = TABS.includes(params.get("tab")) ? params.get("tab") : "overview";
    const hook = ctx.layout.hooks.find((item) => item.id === id);
    if (!hook) {
      toast("", { kind: "info", title: "No hook with that id in this layout" });
      return;
    }
    window.requestAnimationFrame(() => this.open(hook, { tab, trigger: null }));
  }

  open(hook, options = {}) {
    if (!hook || this.dialog.open) return;
    const ctx = context();
    this.hook = hook;
    this.project = ctx && ctx.project ? ctx.project : null;
    this.trigger = options.trigger || null;
    this.restore = typeof options.restore === "function" ? options.restore : null;
    this.tab = TABS.includes(options.tab) ? options.tab : "overview";
    this.detail = null;
    this.state = "loading";
    this.deleted = false;
    this.settling = false;
    this.desktopOff = null;
    this.fileRefused = false;
    this.scriptNotice = null;
    this.stale = false;
    this.fetchedFingerprint = null;
    this.provenance = { events: [], store: "local", degraded: false, note: "", state: "loading", name: program(hook).base, all: false };
    this.clearCloseBanner();
    this.editStarted = false;
    this.editedFor = null;
    this.edit.discardAll();
    this.notices.replaceChildren();
    this.overlay.hidden = true;
    this.overlay.replaceChildren();
    this.tabs.hidden = false;
    delete this.panels.provenance.dataset.count;
    this.dialog.setAttribute("heading", program(hook).base);
    this.dialog.titleEl.title = commandText(hook) || program(hook).base;
    this.dialog.removeAttribute("busy");
    this.tabs.setAttribute("selected", this.tab);
    if (this.tabs.list) {
      this.tabs.current = this.tab;
      this.tabs.render();
    }
    this.renderAll();
    this.dialog.show(this.trigger || document.activeElement);
    this.load(true);
  }

  async load(initial) {
    if (this.controller) this.controller.abort();
    this.controller = new AbortController();
    const token = (this.seq += 1);
    if (initial) {
      this.state = "loading";
      this.overlay.hidden = true;
      this.tabs.hidden = false;
      this.renderAll();
    }
    let detail;
    try {
      detail = await loadDetail(this.hook, this.project, this.controller.signal);
    } catch (error) {
      if (token !== this.seq || (error && error.name === "AbortError")) return null;
      if (error.status === 404) this.showGone();
      else this.showError(error);
      return null;
    }
    if (token !== this.seq) return null;
    this.detail = detail;
    this.state = "ready";
    this.fetchedFingerprint = currentFingerprint();
    this.stale = false;
    this.overlay.hidden = true;
    this.tabs.hidden = false;
    this.syncProvenance(detail.provenance, false);
    this.renderAll();
    this.syncNotices();
    return detail;
  }

  showError(error) {
    this.state = "error";
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "Hook details could not be loaded");
    state.setAttribute("body", error.message);
    state.setAttribute("error-id", error.requestId || error.errorId);
    this.overlay.replaceChildren(state);
    this.overlay.hidden = false;
    this.tabs.hidden = true;
  }

  showGone() {
    this.state = "gone";
    const state = document.createElement("od-state");
    state.setAttribute("kind", "disabled");
    state.setAttribute("glyph", "info");
    state.setAttribute("heading", "This hook is no longer there");
    state.setAttribute("body", "It may have been changed or removed on disk since the layout loaded.");
    state.append(button("Close", { variant: "secondary", size: "xs" }, () => this.dialog.close()));
    this.overlay.replaceChildren(state);
    this.overlay.hidden = false;
    this.tabs.hidden = true;
    this.syncNotices();
  }

  layoutChanged() {
    if (!this.dialog.open || this.deleted || this.settling || this.state !== "ready") return;
    const ctx = context();
    if (!ctx || !ctx.layout) return;
    if (!ctx.layout.hooks.some((item) => item.id === this.hook.id)) {
      this.showGone();
      return;
    }
    const now = currentFingerprint();
    if (this.fetchedFingerprint && now && now !== this.fetchedFingerprint) {
      this.stale = true;
      this.syncNotices();
    }
  }

  syncNotices() {
    const nodes = [];
    if (this.stale && this.state === "ready") {
      nodes.push(banner("warn", "The hook files changed after this was loaded.", "Reload", () => this.reload()));
    }
    if (this.closeBanner) nodes.push(this.closeBanner);
    this.notices.replaceChildren(...nodes);
  }

  async reload() {
    const wasEditing = this.edit.mode === "edit";
    const detail = await this.load(false);
    if (!detail) return;
    if (wasEditing) this.edit.rebase(detail);
  }

  async onRefetch(info) {
    const detail = await this.load(false);
    if (!detail) return;
    if (info.rebase) this.edit.rebase(detail);
  }

  async onApplied(info) {
    if (info.kind === "delete") {
      this.deleted = true;
      this.showDeleted(info.result);
      awaitLayoutReload();
      return;
    }
    this.settling = true;
    await awaitLayoutReload();
    await this.load(false);
    this.settling = false;
  }

  showDeleted(result) {
    this.state = "deleted";
    const wrap = el("div", "hd-deleted");
    const state = document.createElement("od-state");
    state.setAttribute("kind", "empty_cleared");
    state.setAttribute("heading", "Hook deleted");
    state.setAttribute("body", "The hook was removed. Running sessions may keep it until they restart.");
    state.append(button("Close", { variant: "secondary", size: "xs" }, () => this.dialog.close()));
    wrap.append(state);
    for (const [label, paths] of [
      ["Written", (result && result.files) || []],
      ["Backups", (result && result.backups) || []],
    ]) {
      const block = el("section", "plan-section");
      block.append(el("h3", "plan-label", label));
      if (!paths.length) block.append(el("p", "plan-quiet", "None."));
      else {
        const list = el("ul", "plan-lines");
        for (const path of paths) list.append(el("li", "plan-line mono", path));
        block.append(list);
      }
      wrap.append(block);
    }
    this.overlay.replaceChildren(wrap);
    this.overlay.hidden = false;
    this.tabs.hidden = true;
    this.dialog.removeAttribute("busy");
    if (this.dialog.closeButton) this.dialog.closeButton.removeAttribute("disabled");
    announce("Hook deleted.");
  }

  guardClose() {
    if (this.edit.dirty && this.edit.dirty()) {
      this.showCloseBanner();
      return true;
    }
    return false;
  }

  showCloseBanner() {
    this.closeBanner = banner("warn", "You have unsaved changes to this script. Close and discard them?", "Discard and close", () => {
      this.clearCloseBanner();
      this.edit.discardAll();
      this.dialog.close();
    });
    this.syncNotices();
  }

  clearCloseBanner() {
    if (!this.closeBanner) return;
    this.closeBanner = null;
    this.syncNotices();
  }

  onClosed() {
    this.seq += 1;
    if (this.controller) this.controller.abort();
    this.controller = null;
    this.edit.discardAll();
    this.clearCloseBanner();
    const trigger = this.trigger;
    const restore = this.restore;
    this.trigger = null;
    this.restore = null;
    if (trigger && trigger.isConnected) return;
    const fallback = (restore && restore()) || document.querySelector(".od-main .od-region");
    if (fallback && typeof fallback.focus === "function") window.setTimeout(() => fallback.focus(), 0);
  }

  syncProvenance(block, all) {
    const config = app.get().config;
    const events = (block && block.events) || [];
    const note = (block && block.note) || "";
    const off = (config && config.provenance && config.provenance.enabled === false) || note === "provenance is off";
    this.provenance = {
      events,
      store: (block && block.store) || (config && config.provenance && config.provenance.store) || "local",
      degraded: Boolean(block && block.degraded),
      note: off ? "" : note,
      state: off ? "off" : events.length ? "ready" : "empty",
      name: program(this.hook).base,
      all,
    };
  }

  async refreshProvenance(limit, all) {
    this.provenance = { ...this.provenance, state: "loading" };
    this.timeline.data = this.provenance;
    let answer;
    try {
      answer = await loadProvenance(this.hook.id, this.project, limit);
    } catch (error) {
      this.provenance = {
        ...this.provenance,
        state: "error",
        errorText: error.message,
        errorId: error.requestId || error.errorId,
      };
      this.timeline.data = this.provenance;
      return;
    }
    this.syncProvenance(answer, Boolean(all));
    this.renderProvenance();
  }

  renderAll() {
    this.renderOverview();
    this.renderScript();
    this.renderProvenance();
    this.renderEdit();
  }

  renderProvenance() {
    this.timeline.data = this.provenance;
    const panel = this.panels.provenance;
    if (this.state === "ready" && this.provenance.state === "ready") panel.dataset.count = String(this.provenance.events.length);
    else delete panel.dataset.count;
    if (this.tabs.list) {
      const focused = this.tabs.list.contains(document.activeElement) ? document.activeElement.dataset.tab : null;
      this.tabs.render();
      if (focused) {
        const tab = this.tabs.list.querySelector(`[data-tab="${focused}"]`);
        if (tab) tab.focus();
      }
    }
  }

  renderEdit() {
    const ready = this.state === "ready" && Boolean(this.detail);
    this.editLoading.hidden = ready;
    this.edit.hidden = !ready;
    if (!ready) return;
    if (this.editedFor !== this.detail) {
      if (!this.editStarted) {
        this.edit.setup({ hook: this.hook, detail: this.detail, project: this.project, dialog: this.dialog });
        this.editStarted = true;
      } else {
        this.edit.update(this.detail);
      }
      this.editedFor = this.detail;
    }
  }

  stateWords(script, caps) {
    if (!script) return "";
    if (script.kind === "refused") return script.refusal || "the path is not served";
    if (script.kind === "missing") return script.path ? "the file does not exist" : "no script file";
    if (script.kind === "unreadable") return "ordonnateur cannot read it";
    if (script.kind === "too_large" && script.size > OVERVIEW_LIMIT) return "it is over 1 MiB";
    return caps && caps.download === false ? "it is not served" : "";
  }

  desktopReason() {
    const config = app.get().config;
    if (this.desktopOff) return this.desktopOff.reason || NO_DISPLAY;
    if (config && config.desktop && config.desktop.open === false) return config.desktop.reason || NO_DISPLAY;
    return null;
  }

  renderOverview() {
    const panel = this.panels.overview;
    const hook = this.hook;
    const detail = this.detail;
    const script = detail ? detail.script : null;
    const caps = detail ? detail.capabilities || {} : {};
    const parts = [];

    const command = section("Command", "hd-span");
    const block = el("div", "hd-command-wrap");
    const text = commandText(hook);
    const pre = el("pre", "hd-command mono", text || "Not set");
    pre.dataset.density = "cockpit";
    block.append(pre);
    if (text) {
      const copy = iconButton("copy", "Copy command", (event) => copyText(event.currentTarget, text, "Select and copy the command."), "xs");
      copy.classList.add("hd-copy");
      block.append(copy);
    }
    command.append(block);
    const words = detail ? detail.command_words || [] : [];
    const commandWord = words.length === 1 && words[0] === text;
    if (words.length && !commandWord) {
      const line = el("div", "hd-words");
      line.append(el("span", "hd-words-label", "Parsed as"));
      for (const word of words) line.append(el("span", "hd-word mono", word));
      command.append(line);
    } else if (!detail && this.state === "loading") {
      command.append(skeleton("40%"));
    }
    parts.push(command);

    const digest = document.createElement("od-digest");
    digest.setAttribute("value", hook.id);
    digest.setAttribute("kind", "hook id");
    digest.setAttribute("length", String(hook.id.length));
    const meta = providerMeta(providerKey(hook));
    const source = el("span", "od-insp-source");
    const dot = el("span", "od-src-dot");
    dot.setAttribute("aria-hidden", "true");
    dot.dataset.src = String(meta.color);
    dot.dataset.shape = meta.shape;
    const path = el("span", "od-insp-path mono", hook.line ? `${hook.source_file}:${hook.line}` : hook.source_file || "");
    source.append(dot, document.createTextNode(" "), path);
    const status = statusOf(hook);
    let statusNode = null;
    if (status) {
      statusNode = document.createElement("od-chip");
      statusNode.setAttribute("kind", "status");
      statusNode.setAttribute("value", status.value);
    } else if (isMember(hook)) {
      statusNode = document.createElement("od-chip");
      statusNode.setAttribute("label", `Member ${memberPosition(hook)}`);
    } else if (hook.harness === "antigravity" && hook.status === "member") {
      statusNode = document.createElement("od-chip");
      statusNode.setAttribute("label", "Member");
    }
    const timeout = hook.effective_timeout != null ? `${hook.effective_timeout} s${hook.timeout == null ? " (default)" : ""}` : hook.timeout != null ? `${hook.timeout} s` : null;
    const left = section("Hook");
    left.append(
      rows([
        ["Id", digest],
        ["Harness", { "claude-code": "Claude Code", codex: "Codex", hermes: "Hermes", antigravity: "Antigravity" }[hook.harness] || "Claude Code"],
        ["Event", hook.event],
        ["Scope", hook.scope],
        ["Source", source],
        ["Matcher", hook.matcher],
        ["Timeout", timeout],
        ["Status", statusNode],
      ]),
    );
    parts.push(left);

    const right = section("Script");
    right.append(this.scriptRows(script));
    parts.push(right);

    const can = section("What this app can do");
    can.append(this.capabilityRows(script, caps));
    parts.push(can);

    const history = section("History");
    history.append(this.historyBlock());
    parts.push(history);
    panel.replaceChildren(...parts);
    window.requestAnimationFrame(() => fitMiddle(panel));
  }

  scriptRows(script) {
    if (!script) {
      return rows([
        ["Path", skeleton()],
        ["Kind", skeleton("40%")],
        ["Size", skeleton("30%")],
        ["Modified", skeleton("50%")],
        ["Lines", skeleton("20%")],
        ["Shebang", skeleton("40%")],
        ["Executable", skeleton("20%")],
        ["SHA-256", skeleton("50%")],
      ]);
    }
    const pathNode = el("span", "hd-path-cell");
    if (script.path) {
      const text = el("span", "hd-path mono", script.path);
      text.dataset.fit = script.path;
      text.title = script.path;
      pathNode.append(text, iconButton("copy", "Copy script path", (event) => copyText(event.currentTarget, script.path, "Select and copy the path."), "xs"));
    } else {
      pathNode.textContent = "Not set";
    }
    const kind = document.createElement("od-chip");
    kind.setAttribute("kind", "script");
    kind.setAttribute("value", script.kind);
    const sha = script.sha256 ? document.createElement("od-digest") : null;
    if (sha) {
      sha.setAttribute("value", script.sha256);
      sha.setAttribute("kind", "script sha256");
      sha.setAttribute("length", "12");
    }
    return rows([
      ["Path", pathNode],
      ["Kind", kind],
      ["Size", script.size != null ? formatBytes(script.size) : null],
      ["Modified", script.mtime ? formatTime(script.mtime) : null],
      ["Lines", script.line_count != null ? String(script.line_count) : null],
      ["Shebang", script.shebang],
      ["Executable", script.executable == null ? null : script.executable ? "Yes" : "No"],
      ["SHA-256", sha],
    ]);
  }

  capabilityRows(script, caps) {
    const list = el("dl", "od-insp-kv hd-can");
    if (!script) {
      for (const label of ["Download", "Open in desktop", "Edit or delete"]) {
        const value = el("dd", "od-insp-val");
        value.append(skeleton("60%"));
        list.append(el("dt", "od-insp-key", label), value);
      }
      return list;
    }
    const reason = this.stateWords(script, caps);
    const download = caps.download ? ["allow", "Available"] : ["deny", `Not available: ${reason || "it is not served"}`];
    const desktop = this.desktopReason();
    let open;
    if (desktop) open = ["deny", `Not available: ${desktop}`];
    else if (caps.open_file) open = ["allow", "Available"];
    else if (caps.open_folder) open = ["allow", "Folder only: only text scripts open as a file"];
    else open = ["deny", `Not available: ${reason || "no script file"}`];
    const editOn = typeof caps.edit_mode === "boolean" ? caps.edit_mode : Boolean(app.get().config && app.get().config.hook_edit);
    const editGate = caps.edit_script || {};
    const deleteGate = caps.delete_hook || {};
    let change;
    if (!editOn) change = ["lock", "Off: web.hook_edit is not on"];
    else if (editGate.allowed === false && deleteGate.allowed === false) change = ["deny", `Refused: ${editGate.refusal || deleteGate.refusal || "not allowed"}`];
    else change = ["lock", "After the gate in the Edit tab"];
    for (const [label, [name, words]] of [
      ["Download", download],
      ["Open in desktop", open],
      ["Edit or delete", change],
    ]) {
      const value = el("dd", "od-insp-val hd-can-val");
      value.append(glyph(name), el("span", "", words));
      list.append(el("dt", "od-insp-key", label), value);
    }
    return list;
  }

  historyBlock() {
    const wrap = el("div", "hd-history");
    if (!this.detail) {
      wrap.append(skeleton(), skeleton("70%"));
      return wrap;
    }
    const block = this.detail.provenance || {};
    wrap.append(el("p", "hd-history-text", historySentence(block.summary)));
    const config = app.get().config;
    const off = (config && config.provenance && config.provenance.enabled === false) || block.note === "provenance is off";
    if (off) wrap.append(banner("info", "Provenance is off, so no history is recorded or read."));
    else if (block.degraded) wrap.append(banner("warn", "The provenance store is not answering. New events are kept in a local spool."));
    wrap.append(button("Open history", { variant: "ghost", size: "xs" }, () => this.select("provenance")));
    return wrap;
  }

  select(id) {
    this.tabs.select(id, true);
  }

  renderScript() {
    const panel = this.panels.script;
    const detail = this.detail;
    if (!detail) {
      const loading = el("div", "hd-loading");
      loading.setAttribute("aria-busy", "true");
      const status = el("p", "visually-hidden", "Loading hook details");
      status.setAttribute("role", "status");
      loading.append(status, skeleton(), skeleton("60%"), skeleton(), skeleton(), skeleton("80%"));
      panel.replaceChildren(loading);
      return;
    }
    const script = detail.script || {};
    const caps = detail.capabilities || {};
    const head = el("div", "hd-script-path");
    const pathText = el("span", "hd-path mono", script.path || "No script file");
    if (script.path) {
      pathText.dataset.fit = script.path;
      pathText.title = script.path;
    }
    const tools = el("span", "hd-script-tools");
    if (script.path) {
      tools.append(iconButton("copy", "Copy script path", (event) => copyText(event.currentTarget, script.path, "Select and copy the path."), "xs"));
      const copyScript = iconButton("file", "Copy script text", (event) => copyText(event.currentTarget, script.content, "Could not copy. Use Download instead."), "xs");
      if (script.kind !== "text" || typeof script.content !== "string") {
        copyScript.setAttribute("disabled", "");
        copyScript.setAttribute("reason", "Only a text script can be copied.");
      }
      tools.append(copyScript);
    }
    head.append(pathText, tools);

    const facts = el("div", "hd-facts");
    const kind = document.createElement("od-chip");
    kind.setAttribute("kind", "script");
    kind.setAttribute("value", script.kind);
    facts.append(kind);
    if (script.size != null) facts.append(el("span", "hd-fact num", formatBytes(script.size)));
    if (script.mtime) facts.append(el("span", "hd-fact num", formatTime(script.mtime)));
    if (script.line_count != null) facts.append(el("span", "hd-fact num", plural(script.line_count, "line", "lines")));
    if (script.shebang) facts.append(el("span", "hd-fact mono", script.shebang));
    if (script.executable != null) facts.append(el("span", "hd-fact", script.executable ? "Executable" : "Not executable"));
    if (script.sha256) {
      const sha = document.createElement("od-digest");
      sha.setAttribute("value", script.sha256);
      sha.setAttribute("kind", "script sha256");
      sha.setAttribute("length", "12");
      facts.append(sha);
    }

    const actionsWrap = el("div", "hd-actions-wrap");
    actionsWrap.append(this.actionBar(script, caps));
    if (actionsWrap.querySelector('[data-action="file"]')) {
      actionsWrap.append(
        el("p", "hd-note", "Download saves the file through your browser. Open in desktop asks the computer that runs ordonnateur web to open it, which may not be the one you are using."),
      );
    }

    const slot = el("div", "hd-code-slot");
    const banners = el("div", "hd-script-banners");
    this.scriptBanners = banners;
    const hidden = script.kind === "text" && typeof script.content === "string" ? hiddenCharCount(script.content) : 0;
    if (hidden) banners.append(banner("warn", `This script contains ${plural(hidden, "invisible or direction-control character", "invisible or direction-control characters")}.`));
    if (this.scriptNotice) banners.append(this.noticeBanner());
    banners.hidden = !banners.childElementCount;
    slot.append(banners, this.codeRegion(script));
    panel.replaceChildren(head, facts, actionsWrap, slot);
    window.requestAnimationFrame(() => fitMiddle(panel));
  }

  noticeBanner() {
    const notice = this.scriptNotice;
    if (notice.retry) return banner("danger", `${notice.text}${notice.id ? ` Error id ${notice.id}.` : ""}`, "Try again", () => this.download());
    return banner("danger", `${notice.text}${notice.id ? ` Error id ${notice.id}.` : ""}`);
  }

  actionBar(script, caps) {
    const items = [];
    const reason = this.stateWords(script, caps);
    const desktop = this.desktopReason();
    const path = Boolean(script.path);
    const kind = script.kind;
    const makeButton = (key, label, icon, enabled, disabledReason, handler) => {
      const node = button(label, { variant: "secondary", size: "sm", icon, block: "" }, handler);
      node.dataset.action = key;
      if (key !== "download") node.setAttribute("write", "");
      if (!enabled) {
        node.setAttribute("disabled", "");
        if (disabledReason) node.setAttribute("reason", disabledReason);
      }
      if (key === "download") node.setAttribute("busy-label", "Downloading");
      return node;
    };
    let wantsDownload = false;
    let wantsFile = false;
    let wantsFolder = false;
    if (kind === "text") wantsDownload = wantsFile = wantsFolder = true;
    else if (kind === "binary") {
      wantsDownload = true;
      wantsFolder = true;
    } else if (kind === "too_large") {
      wantsDownload = script.size <= OVERVIEW_LIMIT;
      wantsFile = wantsFolder = true;
    } else if (kind === "missing" || kind === "unreadable") {
      wantsFolder = path && caps.open_folder !== false;
    }
    if (this.fileRefused) wantsFile = false;
    if (wantsDownload) items.push(makeButton("download", "Download", "download", Boolean(caps.download), reason, () => this.download()));
    if (!desktop) {
      if (wantsFile) items.push(makeButton("file", "Open in desktop", "external", Boolean(caps.open_file), reason || "Only a text script opens as a file.", () => this.openDesktop("file", script)));
      if (wantsFolder) items.push(makeButton("folder", "Open folder", "folder", Boolean(caps.open_folder), reason || "The folder is not available.", () => this.openDesktop("folder", script)));
    } else if (wantsFile || wantsFolder) {
      items.push(el("p", "hd-note hd-desktop-note", `Open in desktop is unavailable: ${desktop}.`));
    }
    const bar = el("div", "hd-actions");
    bar.style.setProperty("--hd-actions", String(Math.max(1, Math.min(3, items.length))));
    bar.dataset.density = "cockpit";
    bar.append(...items);
    if (!items.length) bar.hidden = true;
    return bar;
  }

  async download() {
    const node = this.panels.script.querySelector('[data-action="download"]');
    this.scriptNotice = null;
    if (node) node.setAttribute("busy", "");
    try {
      const result = await downloadScript(this.hook);
      toast(result.filename, { title: "Downloaded" });
      if (node) node.removeAttribute("busy");
    } catch (error) {
      this.scriptNotice = { text: error.message, id: error.requestId || error.errorId, retry: true };
      this.renderScript();
      if (error.status === 404 || (error.status === 422 && error.code === "refused")) this.load(false);
    }
  }

  async openDesktop(target, script) {
    const node = this.panels.script.querySelector(`[data-action="${target}"]`);
    this.scriptNotice = null;
    if (node) node.setAttribute("busy", "");
    try {
      await openOnDesktop(this.hook.id, target);
      const name = target === "file" ? basename(script.path) : basename(String(script.path || "").split("/").slice(0, -1).join("/")) || "folder";
      toast(name, { title: "Asked this computer to open it" });
      if (node) node.removeAttribute("busy");
    } catch (error) {
      if (error.status === 422 && error.code === "no_desktop") this.desktopOff = { reason: error.message };
      else if (error.status === 422 && error.code === "refused" && target === "file") {
        this.fileRefused = true;
        this.scriptNotice = { text: error.message, id: error.requestId || error.errorId };
      } else this.scriptNotice = { text: error.message, id: error.requestId || error.errorId };
      this.renderScript();
      this.renderOverview();
    }
  }

  codeRegion(script) {
    const kind = script.kind;
    const state = (heading, body, glyphName) => {
      const node = document.createElement("od-state");
      node.setAttribute("kind", "disabled");
      node.setAttribute("glyph", glyphName || "info");
      node.setAttribute("heading", heading);
      node.setAttribute("body", body);
      const wrap = el("div", "hd-code-state");
      wrap.append(node);
      return wrap;
    };
    if (kind === "text") {
      const view = document.createElement("od-code-view");
      view.setAttribute("label", `Script ${basename(script.path)}, ${plural(script.line_count != null ? script.line_count : 0, "line", "lines")}`);
      view.text = typeof script.content === "string" ? script.content : "";
      view.dataset.density = "cockpit";
      return view;
    }
    if (kind === "missing" && script.path) return state("Script not found", `${script.path} does not exist. The hook's command may have moved or been removed.`, "deny");
    if (kind === "missing") return state("No script file", "This hook's command does not point at a script file ordonnateur can read. It may be an inline command or a program found on PATH.");
    if (kind === "binary") return state("Binary file", `${formatBytes(script.size)}. Not shown as text. Download it, or open its folder.`);
    if (kind === "too_large") {
      const body =
        script.size > OVERVIEW_LIMIT
          ? `${formatBytes(script.size)}. ordonnateur serves scripts up to 1 MiB. Open the file in your editor.`
          : `${formatBytes(script.size)}. The viewer shows up to 256 KiB. Download it to read it.`;
      return state("Too large to show", body, "warn");
    }
    if (kind === "unreadable") return state("Cannot read the script", `ordonnateur does not have permission to read ${script.path}.`, "deny");
    if (kind === "refused") return state("Not served", script.refusal || "This path is not served.", "lock");
    return state("No script file", "This hook has no script to show.");
  }
}

customElements.define("od-hook-detail", OdHookDetail);

export function mountHookDetail() {
  if (document.querySelector("od-hook-detail") || !document.body) return;
  document.body.append(document.createElement("od-hook-detail"));
}

mountHookDetail();

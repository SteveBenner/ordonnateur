import "./od-button.js";
import "./od-chip.js";
import "./od-toggle.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-drawer.js";
import "./od-confirm.js";
import "./od-run-status.js";
import { diffRows } from "./od-plan-sheet.js";
import { get, endpoints } from "../core/api.js";
import { getPref, setPref } from "../core/cache.js";
import { announce, toast } from "../core/announce.js";
import { runs, start, latestRun, blockReason, attach } from "../core/runs.js";

const DIMENSIONS = ["liveness", "correctness", "duplication", "ordering", "latency", "safety", "integrity", "freshness"];
const STATUS_WORD = { healthy: "healthy", watch: "watch", unhealthy: "unhealthy" };
const SKELETON_ROWS = 6;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function cap(text) {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function appendBreakable(node, text) {
  const parts = String(text).split(/(?<=[:/@])/);
  parts.forEach((part, index) => {
    if (index > 0) node.append(document.createElement("wbr"));
    node.append(document.createTextNode(part));
  });
}

function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many}`;
}

function chip(kind, value, label) {
  const node = document.createElement("od-chip");
  node.setAttribute("kind", kind);
  if (value) node.setAttribute("value", value);
  if (label) node.setAttribute("label", label);
  return node;
}

function button(text, options = {}) {
  const node = document.createElement("od-button");
  if (options.variant) node.setAttribute("variant", options.variant);
  if (options.size) node.setAttribute("size", options.size);
  node.text = text;
  return node;
}

function setDisabled(node, reason) {
  node.toggleAttribute("disabled", Boolean(reason));
  if (reason) node.setAttribute("reason", reason);
  else node.removeAttribute("reason");
}

function harnessParam(value) {
  return !value || value === "both" ? "all" : value;
}

function outcomeChip(outcome) {
  if (outcome === "applied") return chip("status", "trusted", "Applied");
  if (outcome === "skipped") return chip("status", "disabled", "Skipped");
  if (outcome === "rolled_back") return chip("severity", "error", "Rolled back");
  if (outcome === "restore_failed") return chip("severity", "error", "Restore failed");
  return null;
}

export function diffBlock(text) {
  const wrap = el("div", "hv-diff");
  const lines = String(text || "").split("\n");
  const start = lines.findIndex((line) => line.startsWith("--- "));
  const notes = start > 0 ? lines.slice(0, start).filter(Boolean) : [];
  const body = start > 0 ? lines.slice(start).join("\n") : String(text || "");
  for (const note of notes) wrap.append(el("div", "plan-diff-path mono", note));
  const pre = el("pre", "plan-diff mono");
  for (const row of diffRows(body).filter((entry) => entry.kind !== "meta")) {
    const line = el("span", "plan-diff-line");
    line.dataset.kind = row.kind;
    line.append(el("span", "plan-diff-sign", row.sign), el("span", "plan-diff-text", row.text));
    pre.append(line);
  }
  wrap.append(pre);
  return wrap;
}

function healBlock(item, withDiff) {
  const block = el("section", "hv-heal");
  const head = el("div", "hv-heal-head");
  head.append(el("span", "hv-heal-hook mono", item.hook || ""), el("span", "hv-heal-code mono", item.finding || ""));
  head.append(item.safe ? chip("status", "trusted", "Safe") : chip("status", "untrusted", "Not safe"));
  const outcome = outcomeChip(item.outcome);
  if (outcome) head.append(outcome);
  block.append(head);
  if (item.reason) {
    const reason = el("p", "hv-heal-reason", item.reason);
    if (item.outcome === "rolled_back" || item.outcome === "restore_failed") reason.dataset.tone = "danger";
    block.append(reason);
  }
  if (withDiff && item.diff) {
    block.append(diffBlock(item.diff));
  }
  if (item.backups && item.backups.length) {
    const paths = el("ul", "hv-heal-backups");
    for (const path of item.backups) paths.append(el("li", "mono", `Backup ${path}`));
    block.append(paths);
  }
  return block;
}

class OdHealthView extends HTMLElement {
  set context(value) {
    this.ctx = value;
    if (this.header) this.sync();
  }

  get context() {
    return this.ctx;
  }

  connectedCallback() {
    if (this.header) {
      this.watch();
      return;
    }
    this.model = getPref("healModel", true) !== false;
    this.data = null;
    this.error = null;
    this.loading = false;
    this.filter = null;
    this.sequence = 0;
    this.loadedKey = null;
    this.build();
    this.watch();
    this.sync();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    document.removeEventListener("od-run-finished", this.onFinished);
  }

  watch() {
    if (this.unsubscribe) return;
    this.seenRun = runs.get().done.untangle;
    this.unsubscribe = runs.subscribe((state) => {
      this.refreshControls();
      if (state.done.untangle !== this.seenRun) {
        this.seenRun = state.done.untangle;
        if (this.loading) return;
        this.renderAssessment();
        this.renderHeals();
      }
    });
    this.onFinished = (event) => this.finished(event.detail.run);
    document.addEventListener("od-run-finished", this.onFinished);
  }

  build() {
    this.dataset.firstLoad = "true";
    this.header = el("div", "sv-header");
    this.header.dataset.density = "cockpit";
    const status = document.createElement("od-run-status");
    status.setAttribute("verb", "untangle");
    const actions = el("div", "sv-actions");
    this.modelToggle = document.createElement("od-toggle");
    this.modelToggle.setAttribute("label", "Use a model");
    this.modelToggle.toggleAttribute("checked", this.model);
    this.previewButton = button("Preview heals");
    this.runButton = button("Run", { variant: "primary" });
    actions.append(this.modelToggle, this.previewButton, this.runButton);
    this.header.append(status, actions);

    this.autoLine = el("div", "hv-auto");
    this.autoLine.hidden = true;
    this.autoLine.append(document.createTextNode("Auto healing is on, so Run applies safe heals. "));
    this.settingsLink = button("Open Settings", { variant: "ghost", size: "xs" });
    this.autoLine.append(this.settingsLink);

    this.strip = el("div", "hv-strip");
    this.strip.setAttribute("role", "group");
    this.strip.setAttribute("aria-label", "Dimensions");
    this.assessment = el("div", "hv-assessment-host");
    this.heals = el("div", "hv-heals-host");
    this.findings = el("section", "hv-findings");
    this.findings.setAttribute("aria-label", "Findings");
    this.append(this.header, this.autoLine, this.strip, this.assessment, this.heals, this.findings);

    this.modelToggle.addEventListener("od-change", (event) => {
      this.model = event.detail.checked;
      setPref("healModel", this.model);
    });
    this.runButton.addEventListener("click", () => this.run());
    this.previewButton.addEventListener("click", () => this.preview());
    this.settingsLink.addEventListener("click", () => {
      this.dispatchEvent(new CustomEvent("od-goto-section", { bubbles: true, detail: { section: "settings" } }));
    });
    this.addEventListener("od-retry", (event) => {
      event.stopPropagation();
      this.load();
    });
  }

  key() {
    const ctx = this.ctx || {};
    return `${ctx.project || ""}|${harnessParam(ctx.harness)}`;
  }

  sync() {
    const ctx = this.ctx || {};
    if (ctx.active && this.key() !== this.loadedKey) this.load();
    this.refreshControls();
  }

  async load() {
    const ctx = this.ctx || {};
    this.sequence += 1;
    const mine = this.sequence;
    this.loadedKey = this.key();
    this.loading = true;
    this.error = null;
    this.filter = null;
    this.render();
    try {
      const [data] = await Promise.all([get(endpoints.health({ project: ctx.project, harness: harnessParam(ctx.harness) })), attach()]);
      if (mine !== this.sequence) return;
      this.data = data;
    } catch (error) {
      if (mine !== this.sequence) return;
      this.error = error;
      this.data = null;
    }
    this.loading = false;
    this.render();
    this.refreshControls();
    delete this.dataset.firstLoad;
  }

  reload() {
    this.loadedKey = null;
    this.sync();
  }

  findings_() {
    return (this.data && this.data.findings) || [];
  }

  hasHealer() {
    return this.findings_().some((item) => item.healer);
  }

  refreshControls() {
    if (!this.header) return;
    const ctx = this.ctx || {};
    const block = blockReason(ctx.readOnly);
    setDisabled(this.runButton, block);
    const mode = this.data ? this.data.heal_mode : null;
    this.runButton.text = mode === "auto" ? "Run and heal" : "Run";
    let previewReason = block;
    if (!previewReason && mode === "off") {
      previewReason = this.data.heal_locked_by
        ? `${this.data.heal_locked_by} turns healing off.`
        : "Set untangle.heal to plan or auto in Settings";
    }
    if (!previewReason && this.data && !this.hasHealer()) previewReason = "No finding has a heal.";
    if (!previewReason && !this.data) previewReason = "Findings are not loaded yet.";
    setDisabled(this.previewButton, previewReason);
    this.autoLine.hidden = mode !== "auto";
  }

  run() {
    const ctx = this.ctx || {};
    this.begin({ verb: "untangle", project: ctx.project || null, harness: harnessParam(ctx.harness), model: this.model, heal: "none" });
  }

  preview() {
    const ctx = this.ctx || {};
    this.begin({ verb: "untangle", project: ctx.project || null, harness: harnessParam(ctx.harness), model: false, heal: "preview" }).then((run) => {
      if (run) this.previewing = run.run_id;
    });
  }

  async begin(body) {
    try {
      const run = await start(body);
      announce("Run started.");
      return run;
    } catch (error) {
      if (error && error.code === "run_active") toast("Another run is active.", { kind: "error" });
      else toast(error && error.message ? error.message : "The run could not start.", { kind: "error", title: "Could not start the run" });
      return null;
    }
  }

  finished(run) {
    if (run.verb !== "untangle") return;
    if (run.run_id === this.previewing) {
      this.previewing = null;
      this.openDrawer(run);
      this.reload();
      return;
    }
    if (run.run_id === this.applying) {
      this.applying = null;
      this.applied(run);
      return;
    }
    this.reload();
  }

  report() {
    const run = latestRun("untangle");
    if (!run || run.status !== "done" || !run.report) return null;
    const ctx = this.ctx || {};
    if (run.project !== undefined && (run.project || null) !== (ctx.project || null)) return null;
    return run;
  }

  rowIndexFor(ref, report) {
    const source = report.findings && report.findings[ref];
    if (!source) return -1;
    const rows = this.findings_();
    let at = rows.findIndex((item) => item.code === source.code && item.hook === source.hook && item.message === source.message);
    if (at < 0) at = rows.findIndex((item) => item.code === source.code && item.hook === source.hook);
    return at;
  }

  visible() {
    const rows = this.findings_().map((item, index) => ({ item, index }));
    if (!this.filter) return rows;
    const allowed = new Set(this.filter.indexes);
    return rows.filter((row) => allowed.has(row.index));
  }

  render() {
    this.renderStrip();
    this.renderAssessment();
    this.renderHeals();
    this.renderFindings();
  }

  renderStrip() {
    this.strip.textContent = "";
    this.strip.removeAttribute("aria-busy");
    if (this.loading || !this.data) {
      this.strip.hidden = !this.loading;
      if (!this.loading) return;
      this.strip.setAttribute("aria-busy", "true");
      for (let index = 0; index < DIMENSIONS.length; index += 1) {
        const cell = el("div", "hv-dim-skeleton");
        const bar = document.createElement("od-skeleton");
        bar.setAttribute("height", "28px");
        cell.append(bar);
        this.strip.append(cell);
      }
      return;
    }
    this.strip.hidden = false;
    const list = this.data.dimensions || [];
    for (const name of DIMENSIONS) {
      const item = list.find((entry) => entry.dimension === name) || { dimension: name, status: "healthy", count: 0, findings: [] };
      const cell = el("button", "hv-dim od-native");
      cell.type = "button";
      cell.dataset.dimension = name;
      cell.dataset.status = item.status;
      const pressed = Boolean(this.filter && this.filter.type === "dimension" && this.filter.key === name);
      cell.setAttribute("aria-pressed", pressed ? "true" : "false");
      const word = STATUS_WORD[item.status] || item.status;
      cell.setAttribute("aria-label", `${cap(name)}: ${word}, ${plural(item.count, "finding", "findings")}`);
      cell.append(el("span", "hv-dim-name", cap(name)));
      const line = el("span", "hv-dim-line");
      const dot = el("span", "hv-dot");
      dot.setAttribute("aria-hidden", "true");
      line.append(dot, el("span", "hv-dim-word", word), el("span", "hv-dim-count num", String(item.count)));
      cell.append(line);
      cell.addEventListener("click", () => this.toggleDimension(name, item));
      this.strip.append(cell);
    }
  }

  toggleDimension(name, item) {
    if (this.filter && this.filter.type === "dimension" && this.filter.key === name) {
      this.filter = null;
      this.render();
      announce(`Filter cleared. ${plural(this.findings_().length, "finding", "findings")} shown.`);
      this.focusDimension(name);
      return;
    }
    const indexes = Array.isArray(item.findings) ? item.findings : [];
    this.filter = { type: "dimension", key: name, label: cap(name), indexes };
    this.render();
    announce(`Showing ${plural(indexes.length, "finding", "findings")} in ${cap(name)}.`);
    this.focusDimension(name);
  }

  focusDimension(name) {
    const cell = this.strip.querySelector(`[data-dimension="${name}"]`);
    if (cell) cell.focus();
  }

  renderAssessment() {
    this.assessment.textContent = "";
    const run = this.report();
    if (!run) return;
    const report = run.report;
    const status = report.model_status || {};
    const assessment = report.assessment;
    if (status.status !== "ok" || !assessment) {
      const reason = status.status === "skipped" ? "No model was used for the last run." : `No model assessment: ${status.reason || status.status || "none"}.`;
      this.assessment.append(el("p", "hv-quiet", reason));
      return;
    }
    const panel = el("section", "hv-assessment");
    panel.setAttribute("aria-label", "Assessment");
    panel.append(chip("tag", null, "Judged by a model"));
    if (assessment.summary) panel.append(el("p", "hv-summary", assessment.summary));
    const list = el("ol", "hv-causes");
    (assessment.root_causes || []).forEach((cause) => {
      const entry = el("li", "hv-cause");
      entry.append(el("div", "hv-cause-title", cause.title), el("p", "hv-cause-why", cause.why));
      entry.append(el("p", "hv-cause-fix", `Suggestion: ${cause.suggestion}`));
      const refs = el("div", "hv-refs");
      for (const ref of cause.finding_refs || []) {
        const source = report.findings && report.findings[ref];
        if (!source) continue;
        const open = button(source.code, { variant: "ghost", size: "xs" });
        open.classList.add("mono");
        open.addEventListener("click", () => this.showCause(cause, report, ref));
        refs.append(open);
      }
      if (refs.childElementCount) entry.append(refs);
      list.append(entry);
    });
    panel.append(list);
    this.assessment.append(panel);
  }

  showCause(cause, report, ref) {
    const indexes = (cause.finding_refs || []).map((item) => this.rowIndexFor(item, report)).filter((index) => index >= 0);
    this.filter = { type: "cause", key: cause.title, label: cause.title, indexes };
    this.render();
    announce(`Showing ${plural(indexes.length, "finding", "findings")} for ${cause.title}.`);
    const first = this.rowIndexFor(ref, report);
    const row = this.findings.querySelector(`[data-index="${first >= 0 ? first : indexes[0]}"]`);
    if (row) {
      row.scrollIntoView({ block: "nearest" });
      row.focus();
    }
  }

  renderHeals() {
    this.heals.textContent = "";
    const run = this.report();
    if (!run || !run.report.heals || !run.report.heals.length) return;
    const shown = run.report.heals.filter((item) => item.outcome !== "planned");
    if (!shown.length) return;
    const panel = el("section", "hv-heals-note");
    panel.setAttribute("aria-label", "Heals from the last run");
    panel.append(el("div", "hv-note-title", "Heals from the last run"));
    for (const item of shown) panel.append(healBlock(item, false));
    this.heals.append(panel);
  }

  renderFindings() {
    const host = this.findings;
    host.textContent = "";
    host.removeAttribute("aria-busy");
    if (this.loading) {
      host.setAttribute("aria-busy", "true");
      const rows = el("div", "hv-skeleton");
      for (let index = 0; index < SKELETON_ROWS; index += 1) {
        const bar = document.createElement("od-skeleton");
        bar.setAttribute("height", "28px");
        rows.append(bar);
      }
      host.append(rows);
      return;
    }
    if (this.error) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "Health could not be loaded");
      state.setAttribute("body", this.error.message);
      if (this.error.requestId || this.error.errorId) state.setAttribute("error-id", this.error.requestId || this.error.errorId);
      host.append(state);
      return;
    }
    if (!this.data) return;
    const all = this.findings_();
    if (!all.length) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "empty");
      state.setAttribute("heading", "No findings");
      state.setAttribute("body", "Every dimension is healthy");
      state.setAttribute("glyph", "check");
      host.append(state);
      return;
    }
    const rows = this.visible();
    if (this.filter) {
      const bar = el("div", "hv-filter");
      bar.setAttribute("role", "status");
      bar.append(el("span", "hv-filter-text", `Showing ${rows.length} of ${all.length}: ${this.filter.label}`));
      const clear = button("Clear filter", { variant: "ghost", size: "xs" });
      clear.addEventListener("click", () => {
        const prior = this.filter;
        this.filter = null;
        this.render();
        announce(`Filter cleared. ${plural(all.length, "finding", "findings")} shown.`);
        if (prior.type === "dimension") this.focusDimension(prior.key);
      });
      bar.append(clear);
      host.append(bar);
    }
    host.append(this.table(rows));
  }

  table(rows) {
    const wrap = el("div", "hv-table");
    const table = el("table", "hv-grid");
    table.setAttribute("role", "table");
    table.setAttribute("aria-label", "Findings");
    table.setAttribute("aria-rowcount", String(rows.length + 1));
    const thead = el("thead");
    const body = el("tbody");
    const head = el("tr", "hv-row hv-head");
    head.setAttribute("role", "row");
    for (const name of ["Severity", "Code", "Subject", "Finding", "Heal"]) {
      const cell = el("th", "hv-cell", name);
      cell.scope = "col";
      cell.setAttribute("role", "columnheader");
      head.append(cell);
    }
    thead.append(head);
    table.append(thead, body);
    for (const { item, index } of rows) {
      const row = el("tr", "hv-row");
      row.setAttribute("role", "row");
      row.dataset.index = String(index);
      row.dataset.severity = item.severity;
      row.tabIndex = -1;
      const severity = el("td", "hv-cell hv-sev");
      severity.setAttribute("role", "cell");
      severity.append(chip("severity", item.severity));
      const code = el("td", "hv-cell hv-code mono", item.code);
      code.setAttribute("role", "cell");
      const subject = el("td", "hv-cell hv-subject mono");
      appendBreakable(subject, item.hook || "—");
      subject.setAttribute("role", "cell");
      const finding = el("td", "hv-cell hv-msg");
      finding.setAttribute("role", "cell");
      finding.append(el("div", "hv-text", item.message));
      if (item.fix) finding.append(el("div", "hv-fix", `Fix: ${item.fix}`));
      const heal = el("td", "hv-cell hv-heal-cell");
      heal.setAttribute("role", "cell");
      if (item.healer) heal.append(item.healer.safe ? chip("status", "trusted", "Safe heal") : chip("status", "active", "Heal"));
      row.append(severity, code, subject, finding, heal);
      body.append(row);
    }
    wrap.append(table);
    return wrap;
  }

  openDrawer(run) {
    const heals = (run.report && run.report.heals) || [];
    if (run.status !== "done" || !heals.length) {
      toast(run.status === "failed" ? run.error || "The preview failed." : "There are no heals to preview.", { kind: run.status === "failed" ? "error" : "info" });
      return;
    }
    if (this.drawer) this.drawer.remove();
    const drawer = document.createElement("od-drawer");
    drawer.setAttribute("heading", "Heal plan");
    drawer.classList.add("hv-drawer");
    this.drawerBody = el("div", "hv-drawer-body");
    drawer.append(this.drawerBody);
    this.drawer = drawer;
    this.drawerHeals = heals;
    this.drawerState = "preview";
    this.drawerError = null;
    drawer.addEventListener("od-close", () => {
      if (this.drawer === drawer) {
        drawer.remove();
        this.drawer = null;
      }
    });
    this.append(drawer);
    this.renderDrawer();
    drawer.show(this.previewButton);
  }

  renderDrawer() {
    if (!this.drawerBody) return;
    const body = this.drawerBody;
    body.textContent = "";
    const heals = this.drawerHeals;
    for (const item of heals) body.append(healBlock(item, true));
    const footer = el("div", "hv-drawer-footer");
    if (this.drawerError) footer.append(el("p", "hv-heal-reason", this.drawerError));
    if (this.drawerState === "preview") {
      const pending = heals.filter((item) => item.outcome === "planned" && !item.reason);
      if (!pending.length) {
        footer.append(el("p", "hv-quiet", "Nothing here can be applied."));
      } else {
        const label = `Apply ${plural(pending.length, "heal", "heals")}`;
        if (heals.some((item) => item.safe === false)) {
          const intro = el("p", "hv-confirm-intro", "At least one heal is not safe. Type heal to apply them.");
          const confirm = document.createElement("od-confirm");
          confirm.setAttribute("mode", "phrase");
          confirm.setAttribute("expected", "heal");
          confirm.setAttribute("action", label);
          confirm.addEventListener("od-confirm", () => this.applyHeals());
          footer.append(intro, confirm);
        } else {
          const apply = button(label, { variant: "primary" });
          const ctx = this.ctx || {};
          setDisabled(apply, blockReason(ctx.readOnly));
          apply.addEventListener("click", () => this.applyHeals());
          footer.append(apply);
        }
      }
    } else if (this.drawerState === "applying") {
      footer.append(el("p", "hv-quiet", "Applying heals. This can take a moment."));
    }
    body.append(footer);
  }

  async applyHeals() {
    const ctx = this.ctx || {};
    this.drawerState = "applying";
    this.drawerError = null;
    this.drawer.setAttribute("busy", "");
    this.renderDrawer();
    const run = await this.begin({ verb: "untangle", project: ctx.project || null, harness: harnessParam(ctx.harness), model: false, heal: "apply" });
    if (!run) {
      this.drawerState = "preview";
      this.drawer.removeAttribute("busy");
      this.renderDrawer();
      return;
    }
    this.applying = run.run_id;
  }

  applied(run) {
    if (this.drawer) this.drawer.removeAttribute("busy");
    if (run.status === "done" && run.report) {
      this.drawerHeals = run.report.heals || [];
      this.drawerState = "done";
      this.drawerError = null;
      const done = this.drawerHeals.filter((item) => item.outcome === "applied").length;
      const back = this.drawerHeals.filter((item) => item.outcome === "rolled_back" || item.outcome === "restore_failed").length;
      announce(`${plural(done, "heal", "heals")} applied${back ? `, ${back} rolled back` : ""}.`, { assertive: back > 0 });
    } else {
      this.drawerState = "preview";
      this.drawerError = run.error || "The heals could not be applied.";
    }
    this.renderDrawer();
    this.reload();
    document.dispatchEvent(new CustomEvent("od-heals-applied"));
  }
}

customElements.define("od-health-view", OdHealthView);

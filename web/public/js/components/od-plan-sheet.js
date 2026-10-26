import "./od-dialog.js";
import "./od-tabs.js";
import "./od-chip.js";
import "./od-digest.js";
import "./od-banner.js";
import "./od-button.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-text-field.js";
import * as draft from "../core/draft.js";
import { announce } from "../core/announce.js";
import { applyPlan, createPlan, planRequest, scopeLabel, shell } from "../core/plans.js";
import { findingIndex, program } from "../core/hooks.js";

const RELOAD_WAIT_MS = 5000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function section(label, className) {
  const node = el("section", `plan-section${className ? ` ${className}` : ""}`);
  node.append(el("h3", "plan-label", label));
  return node;
}

function basename(path) {
  const parts = String(path).split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : String(path);
}

function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many}`;
}

function cardEvents(card) {
  return (card && card.events) || {};
}

function memberIds(entry) {
  return entry ? entry.members.map((member) => member.id) : [];
}

function sameEntry(left, right) {
  if (!left || !right) return !left && !right;
  const a = memberIds(left);
  const b = memberIds(right);
  return a.length === b.length && a.every((id, index) => id === b[index]) && left.stop_on_block === right.stop_on_block;
}

function touchedEvents(plan, order) {
  const before = cardEvents(plan.card_before);
  const after = cardEvents(plan.card_after);
  const names = [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((name) => !sameEntry(before[name], after[name]));
  const rank = (name) => {
    const index = order.indexOf(name);
    return index === -1 ? order.length : index;
  };
  return names.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
}

function diffRows(text) {
  const lines = String(text || "").split("\n");
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines.map((line, index) => {
    if (index < 2 && (line.startsWith("--- ") || line.startsWith("+++ "))) return { kind: "meta", sign: " ", text: line };
    if (line.startsWith("@@")) return { kind: "hunk", sign: " ", text: line };
    if (line.startsWith("+")) return { kind: "add", sign: "+", text: line.slice(1) };
    if (line.startsWith("-")) return { kind: "del", sign: "-", text: line.slice(1) };
    return { kind: "ctx", sign: " ", text: line.slice(1) };
  });
}

function blockedText(plan, override) {
  const reason = override ? override.code : plan.blocked_reason;
  if (!reason) return "";
  if (reason === "nothing_to_apply") return "Nothing would change.";
  const wanted = reason === "policy_deny" ? "deny" : "warn";
  const row = plan.verdicts.find((item) => item.verdict === wanted);
  const path = row ? row.path : "the settings file";
  const detail = row && row.reason ? row.reason : override && override.message ? override.message : "";
  if (reason === "policy_deny") return `polispec denies writing ${path}: ${detail}. ordonnateur never applies a deny.`;
  return `polispec warns on writing ${path}: ${detail}. ordonnateur never applies a warn.`;
}

class OdPlanSheet extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    this.view = { kind: "loading" };
    this.typed = "";
    this.busy = false;
    this.seq = 0;
    this.dialog = document.createElement("od-dialog");
    this.dialog.setAttribute("size", "lg");
    this.dialog.setAttribute("heading", "Plan");
    this.dialog.setAttribute("initial-focus", ".od-header h2");
    this.append(this.dialog);
    this.dialog.titleEl.tabIndex = -1;
    this.meta = el("div", "plan-meta");
    const header = this.dialog.dialog.querySelector(".od-header");
    header.insertBefore(this.meta, this.dialog.closeButton);
    this.dialog.addEventListener("od-close", () => {
      this.seq += 1;
      window.setTimeout(() => this.restoreFocus(), 0);
    });
    this.dialog.addEventListener("od-retry", (event) => {
      event.stopPropagation();
      this.retry();
    });
    this.onOpen = (event) => this.open(event.detail || {});
    document.addEventListener("od-open-plan", this.onOpen);
  }

  disconnectedCallback() {
    document.removeEventListener("od-open-plan", this.onOpen);
  }

  open({ scope, project, trigger }) {
    if (this.dialog.open || !scope) return;
    if (!draft.count(scope, project)) {
      announce(`No draft changes for ${scopeLabel(scope)}.`);
      return;
    }
    this.scope = scope;
    this.project = project || null;
    this.plan = null;
    this.typed = "";
    this.conflict = null;
    this.override = null;
    this.notice = "";
    this.busy = false;
    this.dialog.setAttribute("heading", `Plan for ${scopeLabel(scope)}`);
    this.view = { kind: "loading" };
    this.render();
    this.dialog.show(trigger || document.activeElement);
    this.makePlan();
  }

  restoreFocus() {
    const active = document.activeElement;
    if (active && active !== document.body) return;
    const target = document.querySelector(`.od-tray [data-key="${this.scope}-plan"]`) || document.querySelector(".od-tray [data-key]");
    if (target) target.focus();
  }

  context() {
    const owner = shell();
    return owner && typeof owner.context === "function" ? owner.context() : null;
  }

  async makePlan() {
    const token = (this.seq += 1);
    this.plan = null;
    this.conflict = null;
    this.override = null;
    this.notice = "";
    this.typed = "";
    this.view = { kind: "loading" };
    this.render();
    let plan;
    try {
      plan = await createPlan(planRequest(this.scope, this.project));
    } catch (error) {
      if (token !== this.seq) return;
      this.failed(error, "plan");
      return;
    }
    if (token !== this.seq) return;
    this.plan = plan;
    this.view = { kind: "plan" };
    this.render();
    this.focusPrimary();
  }

  failed(error, retry) {
    this.setBusy(false);
    const body = error.body || {};
    if (error.status === 409 && (error.code === "base_moved" || error.code === "plan_changed")) {
      this.conflict = { text: "The hook settings changed after this plan was made." };
      this.view = this.plan ? { kind: "plan" } : { kind: "conflict" };
    } else if (error.status === 409 && error.code === "already_applied") {
      this.conflict = { text: "This plan was already applied." };
      this.view = this.plan ? { kind: "plan" } : { kind: "conflict" };
    } else if (error.status === 404 && error.code === "not_found") {
      this.conflict = { text: "This plan expired." };
      this.view = this.plan ? { kind: "plan" } : { kind: "conflict" };
    } else if (error.kind === "rate_limited") {
      this.notice = error.message;
      this.view = this.plan ? { kind: "plan" } : { kind: "error", error, retry };
    } else if (error.status === 422 && error.code === "refused") {
      const lines = Array.isArray(body.refusals) && body.refusals.length ? body.refusals : [error.message];
      this.view = { kind: "refused", lines };
    } else if (error.status === 422 && retry === "apply" && ["policy_warn", "policy_deny", "nothing_to_apply"].includes(error.code)) {
      this.override = { code: error.code, message: error.message };
      this.view = { kind: "plan" };
    } else if (error.status === 422 && error.code === "confirm_required") {
      this.notice = "Type the plan id to apply.";
      this.view = { kind: "plan" };
    } else {
      this.view = { kind: "error", error, retry };
    }
    this.render();
    if (this.view.kind === "plan") this.focusPrimary();
  }

  retry() {
    const view = this.view;
    if (view.kind === "refused") {
      this.makePlan();
      return;
    }
    if (view.kind !== "error") return;
    if (view.retry === "apply" && this.plan) {
      this.view = { kind: "plan" };
      this.render();
      this.apply();
    } else {
      this.makePlan();
    }
  }

  async planAgain() {
    this.seq += 1;
    this.view = { kind: "loading" };
    this.conflict = null;
    this.render();
    const owner = shell();
    if (owner && typeof owner.reloadKeepingDraft === "function") {
      await new Promise((resolve) => {
        let timer = 0;
        const done = () => {
          document.removeEventListener("od-layout-reloaded", done);
          window.clearTimeout(timer);
          window.setTimeout(resolve, 0);
        };
        document.addEventListener("od-layout-reloaded", done);
        timer = window.setTimeout(done, RELOAD_WAIT_MS);
        owner.reloadKeepingDraft();
      });
    }
    if (!this.dialog.open) return;
    if (!draft.count(this.scope, this.project)) {
      this.view = {
        kind: "error",
        error: { message: "Nothing is left in the draft after the settings were reloaded.", requestId: null, errorId: "draft_empty" },
        retry: "plan",
      };
      this.render();
      return;
    }
    this.makePlan();
  }

  canApply() {
    const plan = this.plan;
    if (!plan || this.busy || this.conflict || this.override) return false;
    if (!plan.applicable) return false;
    if (plan.needs_confirm && this.typed !== plan.plan_id) return false;
    return true;
  }

  setBusy(value) {
    this.busy = value;
    if (value) this.dialog.setAttribute("busy", "");
    else this.dialog.removeAttribute("busy");
    if (this.dialog.closeButton) {
      if (value) this.dialog.closeButton.setAttribute("disabled", "");
      else this.dialog.closeButton.removeAttribute("disabled");
    }
    this.syncFooter();
  }

  async apply() {
    if (!this.canApply()) return;
    const plan = this.plan;
    this.notice = "";
    this.setBusy(true);
    let result;
    try {
      result = await applyPlan(plan.plan_id, plan.needs_confirm ? this.typed : undefined);
    } catch (error) {
      this.failed(error, "apply");
      return;
    }
    this.setBusy(false);
    draft.discard(this.scope, this.project);
    const owner = shell();
    if (owner && typeof owner.reloadKeepingDraft === "function") owner.reloadKeepingDraft();
    this.view = { kind: "applied", result };
    this.render();
    announce(`Applied to ${scopeLabel(this.scope)}.`);
    const done = this.dialog.footer.querySelector("od-button");
    if (done) done.focus();
  }

  focusPrimary() {
    if (!this.dialog.open) return;
    if (this.field && !this.field.hasAttribute("disabled")) this.field.focus();
    else if (this.applyButton && this.canApply()) this.applyButton.focus();
    else if (this.cancelButton) this.cancelButton.focus();
  }

  render() {
    this.field = null;
    this.applyButton = null;
    this.cancelButton = null;
    this.meta.replaceChildren();
    const body = this.dialog.body;
    const footer = this.dialog.footer;
    const view = this.view;
    if (view.kind === "loading") {
      body.replaceChildren(this.loading());
      this.footerWith(this.cancel());
      return;
    }
    if (view.kind === "conflict") {
      body.replaceChildren(this.banner());
      this.footerWith(this.cancel());
      return;
    }
    if (view.kind === "refused") {
      body.replaceChildren(this.refused(view.lines));
      footer.hidden = true;
      footer.replaceChildren();
      return;
    }
    if (view.kind === "error") {
      body.replaceChildren(this.errorState(view.error));
      footer.hidden = true;
      footer.replaceChildren();
      return;
    }
    if (view.kind === "applied") {
      body.replaceChildren(this.applied(view.result));
      const done = document.createElement("od-button");
      done.setAttribute("variant", "primary");
      done.text = "Done";
      done.addEventListener("click", () => this.dialog.close());
      this.footerWith(done);
      return;
    }
    this.renderPlan();
  }

  renderPlan() {
    const plan = this.plan;
    const digest = document.createElement("od-digest");
    digest.setAttribute("value", plan.plan_id);
    digest.setAttribute("kind", "plan id");
    digest.setAttribute("length", String(plan.plan_id.length));
    const chip = document.createElement("od-chip");
    chip.setAttribute("kind", "plan");
    chip.setAttribute("value", plan.classification);
    this.meta.append(digest, chip);
    const parts = [];
    if (this.conflict) parts.push(this.banner());
    parts.push(this.result(plan), this.policy(plan), this.lint(plan), this.changes(plan), this.effect(plan));
    this.dialog.body.replaceChildren(...parts);
    this.buildFooter();
  }

  banner() {
    const banner = document.createElement("od-banner");
    banner.setAttribute("severity", "warn");
    banner.setAttribute("text", this.conflict.text);
    banner.setAttribute("action", "Plan again");
    banner.classList.add("plan-banner");
    banner.addEventListener("od-action", () => this.planAgain());
    return banner;
  }

  loading() {
    const wrap = el("div", "plan-loading");
    wrap.setAttribute("aria-busy", "true");
    const status = el("p", "plan-loading-text", "Making the plan. polispec judges every file it would write.");
    status.setAttribute("role", "status");
    wrap.append(status);
    for (const size of [2, 4, 2, 5, 2]) {
      const block = document.createElement("od-skeleton");
      block.dataset.rows = String(size);
      wrap.append(block);
    }
    return wrap;
  }

  refused(lines) {
    const wrap = el("div", "plan-refused");
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The plan was refused");
    state.setAttribute("body", "Nothing was changed. These lines say why.");
    const back = document.createElement("od-button");
    back.setAttribute("variant", "secondary");
    back.text = "Back to draft";
    back.addEventListener("click", () => this.dialog.close());
    state.append(back);
    const list = el("ul", "plan-lines");
    for (const line of lines) list.append(el("li", "plan-line mono", line));
    wrap.append(state, list);
    return wrap;
  }

  errorState(error) {
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", this.view.retry === "apply" ? "The plan could not be applied" : "The plan could not be made");
    state.setAttribute("body", error.message);
    state.setAttribute("error-id", error.requestId || error.errorId);
    const back = document.createElement("od-button");
    back.setAttribute("variant", "secondary");
    back.text = "Back to draft";
    back.addEventListener("click", () => this.dialog.close());
    state.append(back);
    return state;
  }

  applied(result) {
    const wrap = el("div", "plan-applied");
    const state = document.createElement("od-state");
    state.setAttribute("kind", "empty_cleared");
    state.setAttribute("heading", `Applied to ${scopeLabel(this.scope)}`);
    state.setAttribute(
      "body",
      draft.isHermesScope(this.scope)
        ? "The hook order was written. Hermes applies it to new processes; a running gateway keeps its current order until restart."
        : "The hook settings were written. Running Claude Code sessions pick the change up through their settings watcher.",
    );
    wrap.append(state);
    for (const [label, paths] of [
      ["Written", result.files || []],
      ["Backups", result.backups || []],
    ]) {
      const block = section(label);
      if (!paths.length) block.append(el("p", "plan-quiet", "None."));
      else {
        const list = el("ul", "plan-lines");
        for (const path of paths) list.append(el("li", "plan-line mono", path));
        block.append(list);
      }
      wrap.append(block);
    }
    return wrap;
  }

  programName(id, fallback) {
    const context = this.context();
    const hook = context && context.layout ? context.layout.hooks.find((item) => item.id === id) : null;
    if (hook) return program(hook).base;
    if (fallback && fallback.hook) return program({ id, command: fallback.hook.command, args: fallback.hook.args }).base;
    return id;
  }

  result(plan) {
    const node = section("Result");
    if (Array.isArray(plan.orders) && plan.orders.length) {
      for (const change of plan.orders) {
        const block = el("div", "plan-event");
        block.append(el("h4", "plan-event-name", change.event));
        const columns = el("div", "plan-columns");
        const before = { members: change.before.map((id) => ({ id })) };
        const after = { members: change.after.map((id) => ({ id })) };
        columns.append(this.column("Before", before, null, "No hooks"), this.column("After", after, before, "No hooks"));
        block.append(columns);
        node.append(block);
      }
      return node;
    }
    const context = this.context();
    const order = (context && context.config && context.config.events && context.config.events["claude-code"]) || [];
    const before = cardEvents(plan.card_before);
    const after = cardEvents(plan.card_after);
    const events = touchedEvents(plan, order);
    for (const event of events) {
      const block = el("div", "plan-event");
      block.append(el("h4", "plan-event-name", event));
      const columns = el("div", "plan-columns");
      columns.append(this.column("Before", before[event], null, "No sequence"), this.column("After", after[event], before[event], "Released to native hooks"));
      block.append(columns);
      node.append(block);
    }
    const left = (plan.card_before && plan.card_before.unguarded) || [];
    const right = (plan.card_after && plan.card_after.unguarded) || [];
    if (left.length !== right.length || left.some((item, index) => item !== right[index])) {
      node.append(el("p", "plan-quiet", `Unguarded hooks: ${left.length} before, ${right.length} after.`));
    }
    if (!events.length && node.childElementCount === 1) node.append(el("p", "plan-quiet", "No sequence changes."));
    return node;
  }

  column(label, entry, previous, empty) {
    const wrap = el("div", "plan-column");
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-label", label);
    wrap.append(el("div", "plan-column-head", label));
    if (!entry) {
      wrap.append(el("p", "plan-quiet plan-empty", empty));
      return wrap;
    }
    const list = el("ol", "plan-members");
    const old = previous ? memberIds(previous) : [];
    entry.members.forEach((member, index) => {
      const item = el("li", "plan-member");
      item.append(el("span", "od-order-badge", String(index + 1)), el("span", "plan-program mono", this.programName(member.id, member)));
      const was = old.indexOf(member.id);
      if (previous && was !== -1 && was !== index) {
        const up = was > index;
        const mark = el("span", "plan-moved");
        mark.append(el("span", "plan-arrow", up ? "↑" : "↓"), el("span", "plan-was", `was ${was + 1}`));
        item.append(mark);
      } else if (previous && was === -1) {
        item.append(el("span", "plan-moved", "new"));
      }
      list.append(item);
    });
    wrap.append(list);
    if (typeof entry.stop_on_block === "boolean") wrap.append(el("p", "plan-quiet plan-flag", `Stop on block: ${entry.stop_on_block ? "on" : "off"}`));
    return wrap;
  }

  policy(plan) {
    const node = section("Policy");
    if (!plan.verdicts.length) {
      node.append(el("p", "plan-quiet", "No policy verdicts."));
      return node;
    }
    const detailed = plan.verdicts.some((row) => row.rule_id || row.reason);
    const table = el("table", "plan-table");
    table.setAttribute("role", "table");
    table.dataset.detailed = detailed ? "true" : "false";
    const labels = detailed ? ["File", "Verdict", "Rule", "Reason"] : ["File", "Verdict"];
    const group = el("colgroup");
    for (const label of labels) group.append(el("col", `plan-col-${label.toLowerCase()}`));
    table.append(group);
    const head = el("tr");
    head.setAttribute("role", "row");
    for (const label of labels) {
      const th = el("th", "", label);
      th.scope = "col";
      th.setAttribute("role", "columnheader");
      head.append(th);
    }
    const thead = el("thead");
    thead.setAttribute("role", "rowgroup");
    thead.append(head);
    table.append(thead);
    const bodyRows = el("tbody");
    bodyRows.setAttribute("role", "rowgroup");
    const cell = (className, label, text) => {
      const td = el("td", className, text);
      td.dataset.label = label;
      td.setAttribute("role", "cell");
      return td;
    };
    for (const row of plan.verdicts) {
      const tr = el("tr");
      tr.setAttribute("role", "row");
      const file = cell("plan-cell-path mono", "File");
      String(row.path)
        .split("/")
        .forEach((part, index) => {
          if (index) file.append("/", document.createElement("wbr"));
          file.append(part);
        });
      tr.append(file);
      const verdict = cell("plan-cell-verdict", "Verdict");
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "verdict");
      chip.setAttribute("value", row.verdict);
      verdict.append(chip);
      tr.append(verdict);
      if (detailed) tr.append(cell("mono", "Rule", row.rule_id || ""), cell("", "Reason", row.reason || ""));
      bodyRows.append(tr);
    }
    table.append(bodyRows);
    node.append(table);
    return node;
  }

  lint(plan) {
    const node = section("Lint");
    const added = plan.lint.added || [];
    const resolved = plan.lint.resolved || [];
    node.append(el("p", "plan-lint-summary", `+${plural(added.length, "new finding", "new findings")}, ${resolved.length} resolved`));
    const afterIndex = new Map(plan.lint.after.map((item) => [item.id, item]));
    const beforeIndex = new Map(plan.lint.before.map((item) => [item.id, item]));
    const list = el("ul", "plan-findings");
    const push = (sign, finding) => {
      if (!finding) return;
      const item = el("li", "plan-finding");
      item.dataset.kind = sign === "+" ? "add" : "del";
      item.append(el("span", "plan-sign", sign === "+" ? "New" : "Resolved"));
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "severity");
      chip.setAttribute("value", finding.severity);
      item.append(chip, el("code", "plan-code mono", finding.code), el("span", "plan-message", `${this.programName(finding.hook)}: ${finding.message}`));
      list.append(item);
    };
    for (const id of added) push("+", afterIndex.get(id));
    for (const id of resolved) push("-", beforeIndex.get(id));
    if (list.childElementCount) node.append(list);
    return node;
  }

  changes(plan) {
    const node = section("Changes");
    const files = plan.files.filter((file) => file.changes);
    if (!files.length) {
      node.append(el("p", "plan-quiet", "No file changes."));
      return node;
    }
    const tabs = document.createElement("od-tabs");
    tabs.setAttribute("label", "Changed files");
    for (const file of files) {
      const panel = el("div", "plan-panel");
      panel.dataset.tab = file.path;
      panel.dataset.label = basename(file.path);
      panel.append(el("div", "plan-diff-path mono", file.path));
      const pre = el("pre", "plan-diff mono");
      for (const row of diffRows(file.diff).filter((entry) => entry.kind !== "meta")) {
        const line = el("span", "plan-diff-line");
        line.dataset.kind = row.kind;
        line.append(el("span", "plan-diff-sign", row.sign), el("span", "plan-diff-text", row.text));
        pre.append(line);
      }
      panel.append(pre);
      tabs.append(panel);
    }
    node.append(tabs);
    return node;
  }

  humanize(text) {
    return String(text).replace(/\bhm:[A-Za-z0-9_.:-]*[A-Za-z0-9_]/g, (id) => this.programName(id));
  }

  effect(plan) {
    const node = section("Effect");
    node.append(el("p", "plan-effect", plan.effects_text));
    if (typeof plan.notes === "string" && plan.notes.trim()) node.append(el("p", "plan-quiet", this.humanize(plan.notes)));
    else if (Array.isArray(plan.notes)) {
      for (const note of plan.notes) if (String(note) !== plan.effects_text) node.append(el("p", "plan-quiet", this.humanize(note)));
    }
    return node;
  }

  cancel() {
    const button = document.createElement("od-button");
    button.setAttribute("variant", "secondary");
    button.text = "Cancel";
    button.addEventListener("click", () => this.dialog.close());
    this.cancelButton = button;
    return button;
  }

  footerWith(...nodes) {
    const footer = this.dialog.footer;
    footer.hidden = false;
    const wrap = el("div", "plan-footer");
    const actions = el("div", "plan-action");
    actions.append(...nodes);
    wrap.append(el("p", "plan-reason"), actions);
    footer.replaceChildren(wrap);
  }

  buildFooter() {
    const plan = this.plan;
    const footer = this.dialog.footer;
    footer.hidden = false;
    const wrap = el("div", "plan-footer");
    const reason = el("p", "plan-reason");
    reason.setAttribute("role", "status");
    const actions = el("div", "plan-action");
    if (plan.needs_confirm && plan.applicable) {
      const field = document.createElement("od-text-field");
      field.setAttribute("label", "Type the plan id to apply");
      field.setAttribute("placeholder", plan.plan_id);
      field.setAttribute("mono", "");
      field.setAttribute("autocomplete", "off");
      field.setAttribute("value", this.typed);
      field.addEventListener("od-input", (event) => {
        this.typed = event.detail.value;
        this.syncFooter();
      });
      field.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          this.apply();
        }
      });
      this.field = field;
      actions.append(field);
    }
    const apply = document.createElement("od-button");
    apply.setAttribute("variant", "primary");
    apply.setAttribute("busy-label", "Applying");
    apply.text = "Apply";
    apply.addEventListener("click", () => this.apply());
    this.applyButton = apply;
    actions.append(this.cancel(), apply);
    wrap.append(reason, actions);
    const notice = el("p", "plan-notice");
    notice.setAttribute("role", "status");
    wrap.append(notice);
    footer.replaceChildren(wrap);
    this.reasonEl = reason;
    this.noticeEl = notice;
    this.syncFooter();
  }

  syncFooter() {
    if (!this.applyButton || !this.plan || this.view.kind !== "plan") return;
    const plan = this.plan;
    const blocked = blockedText(plan, this.override);
    const can = this.canApply();
    if (this.busy) {
      this.applyButton.setAttribute("busy", "");
    } else {
      this.applyButton.removeAttribute("busy");
    }
    if (!can && !this.busy) this.applyButton.setAttribute("disabled", "");
    else this.applyButton.removeAttribute("disabled");
    if (blocked && !this.busy) this.applyButton.setAttribute("reason", blocked);
    else this.applyButton.removeAttribute("reason");
    if (this.cancelButton) {
      if (this.busy) this.cancelButton.setAttribute("disabled", "");
      else this.cancelButton.removeAttribute("disabled");
    }
    if (this.field) {
      if (this.busy || this.conflict) this.field.setAttribute("disabled", "");
      else this.field.removeAttribute("disabled");
    }
    if (this.reasonEl) this.reasonEl.textContent = blocked || (this.conflict ? "Plan again to continue." : "");
    if (this.noticeEl) this.noticeEl.textContent = this.notice;
  }
}

customElements.define("od-plan-sheet", OdPlanSheet);

export function mountPlanSheet() {
  if (document.querySelector("od-plan-sheet") || !document.body) return;
  document.body.append(document.createElement("od-plan-sheet"));
}

mountPlanSheet();

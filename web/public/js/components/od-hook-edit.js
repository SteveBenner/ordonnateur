import "./od-button.js";
import "./od-banner.js";
import "./od-chip.js";
import "./od-command.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-ai-handoff.js";
import "./od-code-editor.js";
import "./od-hold-button.js";
import "./od-plan-summary.js";
import { blockedText } from "./od-plan-sheet.js";
import { app, readOnly } from "../core/store.js";
import { announce } from "../core/announce.js";
import { shell, startHold, applyHeld } from "../core/plans.js";
import { isAntigravity, isMember, program } from "../core/hooks.js";
import {
  VIEW_LIMIT_BYTES,
  awaitLayoutReload,
  byteLength,
  formatBytes,
  lineCount,
  planDelete,
  planScriptEdit,
  plural,
  refusalPhrase,
} from "../core/hook-detail.js";

const HOLD_WAIT_MS = 3000;
const CRLF_REASON = "This script uses Windows line endings, which the editor cannot keep. Use the commands above.";
const NS = "http://www.w3.org/2000/svg";
let sequence = 0;

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

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function button(text, attrs, handler) {
  const node = document.createElement("od-button");
  for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
  node.text = text;
  if (handler) node.addEventListener("click", handler);
  return node;
}

function banner(severity, text, action, handler) {
  const node = document.createElement("od-banner");
  node.setAttribute("severity", severity);
  node.setAttribute("text", text);
  if (action) {
    node.setAttribute("action", action);
    node.addEventListener("od-action", handler);
  }
  return node;
}

function normalize(plan) {
  return { ...plan, verdicts: plan.verdicts || [], files: plan.files || [] };
}

class OdHookEdit extends HTMLElement {
  connectedCallback() {
    if (this.ready) return;
    this.ready = true;
    sequence += 1;
    this.uid = `od-hook-edit-${sequence}`;
    this.mode = null;
    this.phase = "idle";
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.refusal = null;
    this.applied = null;
    this.rowNote = "";
    this.forcedOff = false;
    this.text = "";
    this.original = "";
    this.seq = 0;
    this.holdToken = 0;
    this.lastReadOnly = readOnly();
    this.unsubscribe = app.subscribe(() => {
      const now = readOnly();
      if (now === this.lastReadOnly) return;
      this.lastReadOnly = now;
      if (this.hook && this.phase !== "holding" && this.phase !== "applying") this.render();
    });
    this.addEventListener("od-hold-start", (event) => this.onHoldStart(event));
    this.addEventListener("od-hold-complete", (event) => this.onHoldComplete(event));
    this.addEventListener("od-hold-cancel", (event) => this.onHoldCancel(event));
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    this.seq += 1;
    this.holdToken += 1;
  }

  setup({ hook, detail, project, dialog }) {
    this.hook = hook;
    this.project = project || null;
    this.dialog = dialog || null;
    this.detail = detail;
    this.mode = null;
    this.phase = "idle";
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.refusal = null;
    this.applied = null;
    this.rowNote = "";
    this.forcedOff = false;
    this.loadText();
    this.render();
  }

  loadText() {
    const script = (this.detail && this.detail.script) || {};
    this.original = typeof script.content === "string" ? script.content : "";
    this.text = this.original;
  }

  update(detail) {
    this.detail = detail;
    if (!this.editOn()) {
      const keep = this.notice && this.notice.kind === "disabled" ? this.notice : null;
      this.discardAll();
      this.applied = null;
      this.notice = keep;
      this.render();
      return;
    }
    if (this.phase === "applied") return;
    if (this.phase === "holding" || this.phase === "applying" || this.phase === "planning") return;
    if (this.mode === "edit" && this.dirty()) return;
    if (this.mode === "delete" && this.plan) return;
    this.loadText();
    this.plan = null;
    this.render();
  }

  rebase(detail) {
    this.detail = detail;
    const script = detail.script || {};
    this.original = typeof script.content === "string" ? script.content : "";
    if (this.mode === "edit") {
      this.plan = null;
      this.override = null;
      this.notice = null;
      this.phase = "editing";
    } else {
      this.text = this.original;
    }
    this.render();
    this.focusTarget("editor");
  }

  caps() {
    return (this.detail && this.detail.capabilities) || {};
  }

  editOn() {
    if (this.forcedOff) return false;
    const caps = this.caps();
    if (typeof caps.edit_mode === "boolean") return caps.edit_mode;
    const config = app.get().config;
    return Boolean(config && config.hook_edit);
  }

  dirty() {
    if (this.phase === "applied") return false;
    if (this.mode === "edit") return this.text !== this.original || Boolean(this.plan);
    if (this.mode === "delete") return Boolean(this.plan);
    return false;
  }

  crlf() {
    const script = (this.detail && this.detail.script) || {};
    return typeof script.content === "string" && script.content.includes("\r");
  }

  gateReason(mode) {
    const caps = this.caps();
    if (mode === "edit") {
      const gate = caps.edit_script || {};
      if (gate.allowed === false) return refusalPhrase(gate.refusal) || "Editing this script is not allowed.";
      if (this.crlf()) return CRLF_REASON;
      const script = (this.detail && this.detail.script) || {};
      if (typeof script.content !== "string") return "The script text is not available to edit.";
      return "";
    }
    const gate = caps.delete_hook || {};
    if (gate.allowed === false) return refusalPhrase(gate.refusal) || "Deleting this hook is not allowed.";
    return "";
  }

  editorError() {
    if (this.text.includes("\u0000")) return "The text contains a NUL character, which a script edit cannot hold.";
    if (byteLength(this.text) > VIEW_LIMIT_BYTES) return "The text is over the 256 KiB limit for an edit.";
    return "";
  }

  base() {
    const owner = shell();
    const context = owner && typeof owner.context === "function" ? owner.context() : null;
    return context && context.layout && context.layout.fingerprint ? context.layout.fingerprint.config : null;
  }

  setBusy(value) {
    if (!this.dialog) return;
    if (value) this.dialog.setAttribute("busy", "");
    else this.dialog.removeAttribute("busy");
    if (this.dialog.closeButton) {
      if (value) this.dialog.closeButton.setAttribute("disabled", "");
      else this.dialog.closeButton.removeAttribute("disabled");
    }
  }

  focusTarget(name) {
    window.requestAnimationFrame(() => {
      const refs = this.refs || {};
      const node = refs[name];
      if (node && node.isConnected && typeof node.focus === "function") node.focus();
    });
  }

  render() {
    if (!this.hook || !this.detail) return;
    this.refs = {};
    const caps = this.caps();
    const editOn = this.editOn();
    const parts = [this.statusStrip(caps, editOn)];
    const editRefused = this.gateReason("edit") && caps.edit_script && caps.edit_script.allowed === false;
    const deleteRefused = caps.delete_hook && caps.delete_hook.allowed === false;
    if (editOn && editRefused && deleteRefused) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "disabled");
      state.setAttribute("glyph", "lock");
      state.setAttribute("heading", "This hook cannot be changed here");
      const editWhy = refusalPhrase(caps.edit_script.refusal) || "Editing is refused.";
      const deleteWhy = refusalPhrase(caps.delete_hook.refusal) || "Deleting is refused.";
      state.setAttribute("body", editWhy === deleteWhy ? editWhy : `${editWhy} ${deleteWhy}`);
      this.replaceChildren(...parts, state);
      return;
    }
    const handoff = document.createElement("od-ai-handoff");
    handoff.id = `${this.uid}-handoff`;
    handoff.data = { ai: this.detail.ai, name: program(this.hook).base, editOn };
    parts.push(handoff);
    if (!editOn) {
      if (this.notice && this.notice.kind === "disabled") parts.push(this.noticeView());
      parts.push(this.offNotice());
      this.replaceChildren(...parts);
      return;
    }
    if (this.applied) {
      parts.length = 1;
      parts.push(this.appliedView());
      this.replaceChildren(...parts);
      return;
    }
    if (readOnly()) {
      parts.push(banner("info", "This server is read-only. Hand edits are off here; the commands above run in a terminal."));
    }
    parts.push(this.gates());
    if (this.notice) parts.push(this.noticeView());
    if (this.refusal) {
      parts.push(this.refusalView());
    } else if (this.mode === "edit") {
      parts.push(this.editorSection());
    } else if (this.mode === "delete") {
      parts.push(this.deleteSection());
    }
    if (this.plan && !this.refusal) {
      const summary = document.createElement("od-plan-summary");
      summary.data = { plan: this.plan, hook: this.hook, kind: this.mode === "delete" ? "delete" : "script_edit", override: this.override };
      this.refs.plan = summary;
      this.refs.heading = null;
      parts.push(summary);
      parts.push(this.actionRow());
      window.requestAnimationFrame(() => {
        if (summary.heading) this.refs.heading = summary.heading;
      });
    }
    this.replaceChildren(...parts);
  }

  statusStrip(caps, editOn) {
    const strip = el("div", "he-status");
    strip.dataset.density = "cockpit";
    const start = el("div", "he-status-col");
    const chip = document.createElement("od-chip");
    chip.setAttribute("kind", "verdict");
    chip.setAttribute("value", editOn ? "allow" : "warn");
    chip.setAttribute("label", editOn ? "Editing on" : "Editing off");
    const editNo = caps.edit_script && caps.edit_script.allowed === false;
    const deleteNo = caps.delete_hook && caps.delete_hook.allowed === false;
    let sentence = "Hand edits and deletes are available after the gates below.";
    if (!editOn) sentence = "Hand edits and deletes are off.";
    else if (editNo && deleteNo) sentence = "This hook cannot be changed here.";
    start.append(chip, el("span", "he-status-text", sentence));
    const end = el("dl", "od-insp-kv he-status-kv");
    const word = (gate) => (!editOn ? "Off" : gate && gate.allowed === false ? `Refused: ${refusalPhrase(gate.refusal) || "not allowed"}` : "Allowed");
    const editWord = word(caps.edit_script);
    const deleteWord = word(caps.delete_hook);
    if (editWord === deleteWord && editWord !== "Allowed" && editWord !== "Off") {
      end.append(el("dt", "od-insp-key", "Edit or delete"), el("dd", "od-insp-val", editWord));
    } else {
      end.append(el("dt", "od-insp-key", "Edit script"), el("dd", "od-insp-val", editWord), el("dt", "od-insp-key", "Delete hook"), el("dd", "od-insp-val", deleteWord));
    }
    strip.append(start, end);
    return strip;
  }

  offNotice() {
    const wrap = el("div", "he-off");
    wrap.append(
      banner("warn", "Editing is off. This app edits scripts and deletes hooks only while web.hook_edit is on, and the browser cannot turn it on."),
    );
    const command = document.createElement("od-command");
    command.setAttribute("command", "rplugin settings set ordonnateur web.hook_edit true");
    command.setAttribute("who", "Run in a terminal. The commands above need it on too.");
    wrap.append(command, el("p", "he-note", "If it still reads off, the ORDONNATEUR_HOOK_EDIT_DISABLED switch may be set."));
    return wrap;
  }

  gates() {
    const row = el("div", "he-gates");
    row.dataset.density = "cockpit";
    const make = (mode, text, controls) => {
      const reason = this.gateReason(mode);
      const cell = el("div", "he-gate");
      const node = button(text, { size: "md", block: "", write: "", controls, expanded: this.mode === mode ? "true" : "false" }, () => this.chooseMode(mode));
      if (reason) {
        node.setAttribute("disabled", "");
        node.setAttribute("reason", reason);
        cell.append(node, el("p", "he-gate-reason", reason));
      } else {
        cell.append(node);
      }
      this.refs[`gate-${mode}`] = node;
      return cell;
    };
    row.append(make("edit", "I will edit it by hand", `${this.uid}-editor`), make("delete", "I will delete it by hand", `${this.uid}-delete`));
    return row;
  }

  noticeView() {
    const notice = this.notice;
    const wrap = el("div", "he-notice");
    if (notice.kind === "discard") {
      wrap.append(banner("warn", "Discard your unsaved edit first.", "Discard", () => this.discardAndSwitch()));
    } else if (notice.kind === "conflict") {
      wrap.append(banner("warn", notice.text, notice.action, () => this.onConflict()));
    } else if (notice.kind === "error") {
      const block = el("div", "he-error");
      block.append(banner("danger", notice.text));
      const meta = el("div", "he-error-meta");
      if (notice.code) {
        const chip = document.createElement("od-chip");
        chip.setAttribute("label", notice.code);
        chip.classList.add("mono");
        meta.append(chip);
      }
      if (notice.id) meta.append(el("span", "he-error-id mono", notice.id));
      if (meta.childElementCount) block.append(meta);
      wrap.append(block);
    } else if (notice.kind === "rate") {
      wrap.append(banner("info", notice.text));
    } else if (notice.kind === "disabled") {
      wrap.append(banner("warn", notice.text));
    }
    return wrap;
  }

  refusalView() {
    const wrap = el("div", "he-refused");
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The plan was refused");
    state.setAttribute("body", "Nothing was changed. These lines say why.");
    const back = button("Back", { variant: "secondary", size: "xs" }, () => {
      this.refusal = null;
      this.render();
    });
    state.append(back);
    const list = el("ul", "plan-lines");
    for (const line of this.refusal) list.append(el("li", "plan-line mono", line));
    wrap.append(state, list);
    return wrap;
  }

  chooseMode(mode) {
    if (this.phase === "holding" || this.phase === "applying" || this.phase === "planning") return;
    if (mode === this.mode) {
      this.focusTarget(mode === "edit" ? "editor" : "deleteHeading");
      return;
    }
    if (this.dirty()) {
      this.notice = { kind: "discard", target: mode };
      this.render();
      return;
    }
    this.enter(mode);
  }

  enter(mode) {
    this.mode = mode;
    this.phase = mode === "edit" ? "editing" : "idle";
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.refusal = null;
    this.text = this.original;
    this.render();
    if (mode === "edit") {
      this.focusTarget("editor");
      announce("Editor shown");
    } else {
      this.focusTarget("deleteHeading");
      announce("Delete plan section shown");
    }
  }

  discardAndSwitch() {
    const target = this.notice && this.notice.target;
    this.notice = null;
    this.plan = null;
    this.text = this.original;
    if (target) this.enter(target);
    else this.render();
  }

  discardAll() {
    this.seq += 1;
    this.mode = null;
    this.phase = "idle";
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.refusal = null;
    this.rowNote = "";
    this.text = this.original;
  }

  editorSection() {
    const wrap = el("section", "he-editor");
    wrap.id = `${this.uid}-editor`;
    wrap.dataset.density = "cockpit";
    const planned = Boolean(this.plan);
    const editor = document.createElement("od-code-editor");
    editor.setAttribute("label", `Script text of ${program(this.hook).base}`);
    editor.value = this.text;
    if (planned || this.phase === "planning") editor.setAttribute("readonly", "");
    const error = this.editorError();
    if (error) editor.setAttribute("error", error);
    this.refs.editor = editor;
    const info = el("div", "he-editor-info");
    const stats = el("span", "he-editor-stats", `${plural(lineCount(this.text), "line", "lines")}, ${formatBytes(byteLength(this.text))} of 256 KiB`);
    const dirty = document.createElement("od-chip");
    const isDirty = this.text !== this.original;
    this.dirtyChip(dirty, isDirty);
    info.append(stats, dirty);
    const bar = el("div", "he-toolbar");
    if (planned) {
      const back = button("Back to editing", { variant: "ghost", size: "sm" }, () => this.backToEditing());
      bar.append(back);
      this.refs.back = back;
    } else {
      const revert = button("Revert changes", { variant: "ghost", size: "sm" }, () => this.revert());
      if (!isDirty) revert.setAttribute("disabled", "");
      bar.append(revert);
      this.refs.revert = revert;
      const save = button("Save", { variant: "secondary", size: "sm", write: "", "busy-label": "Planning" }, () => this.savePlan());
      save.id = `${this.uid}-save`;
      if (this.phase === "planning") save.setAttribute("busy", "");
      else if (!isDirty) {
        save.setAttribute("disabled", "");
        save.setAttribute("reason", "No changes yet");
      } else if (error) {
        save.setAttribute("disabled", "");
        save.setAttribute("reason", error);
      }
      bar.append(save);
      const note = el("span", "visually-hidden", "Builds the plan and shows the diff. Nothing is written yet.");
      note.id = `${this.uid}-save-note`;
      bar.append(note);
      save.setAttribute("aria-describedby", note.id);
      this.refs.save = save;
    }
    editor.addEventListener("od-input", (event) => {
      this.text = event.detail.value;
      this.syncEditor();
    });
    wrap.append(editor, info, bar);
    this.refs.info = { stats, dirty };
    return wrap;
  }

  dirtyChip(chip, isDirty) {
    chip.setAttribute("label", isDirty ? "Unsaved changes" : "No changes");
    if (isDirty) {
      chip.setAttribute("kind", "verdict");
      chip.setAttribute("value", "warn");
    } else {
      chip.removeAttribute("kind");
      chip.removeAttribute("value");
    }
  }

  syncEditor() {
    const refs = this.refs;
    if (!refs || !refs.editor) return;
    const isDirty = this.text !== this.original;
    const error = this.editorError();
    refs.info.stats.textContent = `${plural(lineCount(this.text), "line", "lines")}, ${formatBytes(byteLength(this.text))} of 256 KiB`;
    this.dirtyChip(refs.info.dirty, isDirty);
    if (error) refs.editor.setAttribute("error", error);
    else refs.editor.removeAttribute("error");
    if (refs.revert) {
      if (isDirty) refs.revert.removeAttribute("disabled");
      else refs.revert.setAttribute("disabled", "");
    }
    if (refs.save) {
      if (!isDirty) {
        refs.save.setAttribute("disabled", "");
        refs.save.setAttribute("reason", "No changes yet");
      } else if (error) {
        refs.save.setAttribute("disabled", "");
        refs.save.setAttribute("reason", error);
      } else {
        refs.save.removeAttribute("disabled");
        refs.save.removeAttribute("reason");
      }
    }
    if (this.notice && this.notice.kind === "discard") {
      this.notice = null;
      this.render();
      this.focusTarget("editor");
    }
    this.dispatchEvent(new CustomEvent("od-hook-edit-dirty", { bubbles: true }));
  }

  revert() {
    this.text = this.original;
    this.notice = null;
    this.render();
    this.focusTarget("editor");
  }

  backToEditing() {
    this.seq += 1;
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.phase = "editing";
    this.render();
    this.focusTarget("editor");
  }

  deleteSection() {
    const wrap = el("section", "he-delete");
    wrap.id = `${this.uid}-delete`;
    wrap.dataset.density = "cockpit";
    const heading = el("h3", "he-delete-title");
    heading.tabIndex = -1;
    heading.append(glyph("trash"), el("span", "", "Delete this hook"));
    this.refs.deleteHeading = heading;
    wrap.append(heading);
    wrap.append(el("p", "he-delete-text", `Removes this hook from ${this.hook.source_file || "its file"}. A backup is written first. Running sessions may keep it until they restart.`));
    const member = isAntigravity(this.hook) ? this.hook.member === true : isMember(this.hook);
    if (member) {
      wrap.append(
        banner(
          "warn",
          `This hook is a member of the ${this.hook.event} sequence in its card. Deleting it removes it from the sequence and keeps the order of the others. If it is the last member, the sequence is released and its dispatcher entry goes with it.`,
        ),
      );
    }
    const bar = el("div", "he-toolbar");
    if (this.plan) {
      const back = button("Back", { variant: "ghost", size: "sm" }, () => this.backFromDelete());
      bar.append(back);
      this.refs.back = back;
    } else {
      const plan = button("Plan the deletion", { variant: "secondary", size: "sm", write: "", "busy-label": "Planning" }, () => this.planDeletion());
      if (this.phase === "planning") plan.setAttribute("busy", "");
      bar.append(plan);
      this.refs.planButton = plan;
    }
    wrap.append(bar);
    return wrap;
  }

  backFromDelete() {
    this.seq += 1;
    this.plan = null;
    this.override = null;
    this.notice = null;
    this.phase = "idle";
    this.render();
    this.focusTarget("deleteHeading");
  }

  actionRow() {
    const row = el("div", "he-actions");
    row.dataset.density = "cockpit";
    const text = el("p", "he-actions-text");
    text.setAttribute("role", "status");
    const plan = this.plan;
    const deleting = this.mode === "delete";
    const blockedReason = this.override ? this.override.code : plan.blocked_reason;
    let reason = "";
    if (blockedReason) {
      reason = blockedText(plan, this.override);
    } else if (plan.applicable === false) {
      reason = "This plan cannot be applied.";
    }
    if (reason) text.textContent = reason;
    else if (this.rowNote) text.textContent = this.rowNote;
    else text.textContent = deleting ? "Plan ready. Hold the button for 3 seconds to delete the hook." : "Plan ready. Hold the button for 3 seconds to save the script.";
    const hold = document.createElement("od-hold-button");
    hold.setAttribute("label", deleting ? "Delete this hook" : "Save script");
    hold.setAttribute("busy-label", deleting ? "Deleting" : "Saving");
    hold.setAttribute("variant", deleting ? "danger" : "primary");
    hold.setAttribute("write", "");
    if (reason) {
      hold.setAttribute("disabled", "");
      hold.setAttribute("reason", reason);
    }
    row.append(text, hold);
    this.refs.hold = hold;
    this.refs.actionText = text;
    return row;
  }

  clearNotice() {
    this.notice = null;
  }

  turnedOff() {
    this.holdToken += 1;
    this.seq += 1;
    this.setBusy(false);
    this.forcedOff = true;
    this.discardAll();
    this.applied = null;
    this.rowNote = "";
    this.notice = { kind: "disabled", text: "Editing was turned off while this was open. Nothing was changed." };
    this.render();
    this.revealNotice(this.notice.text);
    this.dispatchEvent(new CustomEvent("od-hook-edit-refetch", { bubbles: true }));
  }

  revealNotice(text) {
    announce(text);
    window.requestAnimationFrame(() => {
      const target = this.querySelector(".he-notice") || this.querySelector(".he-off");
      if (!target) return;
      target.tabIndex = -1;
      target.focus();
      target.scrollIntoView({ block: "nearest" });
    });
  }

  planFailed(error, kind) {
    this.phase = kind === "delete" ? "idle" : "editing";
    this.plan = null;
    const body = error.body || {};
    if (error.status === 403 && error.code === "edit_disabled") {
      this.turnedOff();
      return;
    } else if (error.status === 409 && (error.code === "base_moved" || error.code === "plan_changed")) {
      this.notice = kind === "delete"
        ? { kind: "conflict", text: "The hook settings changed after this plan was made.", action: "Plan again", what: "delete" }
        : { kind: "conflict", text: "The script changed on disk after this plan was made.", action: "Reload script", what: "script" };
    } else if (error.status === 422 && error.code === "refused") {
      this.refusal = Array.isArray(body.refusals) && body.refusals.length ? body.refusals : [error.message];
    } else if (error.kind === "rate_limited") {
      this.notice = { kind: "rate", text: error.message };
    } else {
      this.notice = { kind: "error", text: error.message, code: error.code, id: error.requestId || error.errorId };
    }
    this.render();
    this.focusTarget(kind === "delete" ? "planButton" : "save");
  }

  async savePlan() {
    if (this.phase !== "editing" || this.text === this.original || this.editorError()) return;
    const script = (this.detail && this.detail.script) || {};
    this.notice = null;
    this.rowNote = "";
    this.phase = "planning";
    this.render();
    const token = (this.seq += 1);
    let plan;
    try {
      plan = await planScriptEdit(this.hook.id, this.project, script.sha256, this.text);
    } catch (error) {
      if (token !== this.seq) return;
      this.planFailed(error, "script");
      return;
    }
    if (token !== this.seq) return;
    this.plan = normalize(plan);
    this.override = null;
    this.phase = "planned";
    this.render();
    this.focusTarget("heading");
    announce(this.plan.applicable === false ? "Plan made. It cannot be applied." : "Plan made. Hold the button to save.");
  }

  async planDeletion() {
    if (this.phase !== "idle" || this.mode !== "delete") return;
    this.notice = null;
    this.rowNote = "";
    this.phase = "planning";
    this.render();
    const token = (this.seq += 1);
    let plan;
    try {
      plan = await planDelete(this.hook, this.project, this.base());
    } catch (error) {
      if (token !== this.seq) return;
      this.planFailed(error, "delete");
      return;
    }
    if (token !== this.seq) return;
    this.plan = normalize(plan);
    this.override = null;
    this.phase = "planned";
    this.render();
    this.focusTarget("heading");
    announce(this.plan.applicable === false ? "Plan made. It cannot be applied." : "Plan made. Hold the button to delete.");
  }

  async onConflict() {
    const what = this.notice && this.notice.what;
    if (what === "delete") {
      this.notice = null;
      this.plan = null;
      this.phase = "idle";
      this.render();
      await awaitLayoutReload();
      if (this.mode === "delete" && this.phase === "idle") this.planDeletion();
      return;
    }
    this.dispatchEvent(new CustomEvent("od-hook-edit-refetch", { bubbles: true, detail: { rebase: true } }));
  }

  onHoldStart() {
    if (!this.plan || this.phase !== "planned") return;
    this.phase = "holding";
    this.rowNote = "";
    this.holdToken += 1;
    const token = this.holdToken;
    const planId = this.plan.plan_id;
    this.holdAnswered = 0;
    this.holdPromise = startHold(planId).then((answer) => {
      this.holdAnswered = performance.now();
      return answer;
    });
    this.holdPromise.catch((error) => {
      if (token !== this.holdToken) return;
      this.holdToken += 1;
      this.phase = "planned";
      this.setBusy(false);
      const hold = this.refs && this.refs.hold;
      if (hold) hold.cancel("host");
      this.showError(error);
    });
  }

  onHoldCancel(event) {
    if (event.detail && event.detail.cause === "host") return;
    if (this.phase === "holding") {
      this.phase = "planned";
      this.holdToken += 1;
    }
  }

  async onHoldComplete() {
    if (this.phase !== "holding") return;
    const token = this.holdToken;
    this.phase = "applying";
    this.setBusy(true);
    let answer;
    try {
      answer = await this.holdPromise;
    } catch (error) {
      return;
    }
    if (token !== this.holdToken) return;
    const wait = this.holdAnswered + HOLD_WAIT_MS - performance.now();
    if (wait > 0) await sleep(wait);
    if (token !== this.holdToken) return;
    const planId = this.plan.plan_id;
    let result;
    try {
      result = await applyHeld(planId, answer.hold_id);
    } catch (error) {
      if (token !== this.holdToken) return;
      this.applyFailed(error);
      return;
    }
    if (token !== this.holdToken) return;
    this.setBusy(false);
    const kind = this.mode === "delete" ? "delete" : "script";
    this.phase = "applied";
    this.applied = { kind, result };
    this.plan = null;
    this.render();
    announce(kind === "delete" ? "Hook deleted." : "Script saved. A backup was written.");
    this.dispatchEvent(new CustomEvent("od-hook-edit-applied", { bubbles: true, detail: { kind, result } }));
  }

  applyFailed(error) {
    this.holdToken += 1;
    this.setBusy(false);
    const hold = this.refs && this.refs.hold;
    if (hold) hold.cancel("host");
    this.phase = "planned";
    if (error.status === 403 && error.code === "edit_disabled") {
      this.turnedOff();
      return;
    }
    if (error.status === 422 && ["policy_warn", "policy_deny", "nothing_to_apply"].includes(error.code)) {
      this.override = { code: error.code, message: error.message };
      this.render();
      this.revealRow();
      return;
    }
    if (error.status === 409 && (error.code === "base_moved" || error.code === "plan_changed")) {
      const deleting = this.mode === "delete";
      this.notice = deleting
        ? { kind: "conflict", text: "The hook settings changed after this plan was made.", action: "Plan again", what: "delete" }
        : { kind: "conflict", text: "The script changed on disk after this plan was made.", action: "Reload script", what: "script" };
      this.rowNote = this.notice.text;
      this.render();
      this.revealNotice(this.notice.text);
      return;
    }
    this.showError(error);
  }

  showError(error) {
    if (error.kind === "rate_limited") {
      const seconds = error.retryAfter == null ? 60 : error.retryAfter;
      this.notice = { kind: "rate", text: `Too many changes in a minute. Try again in ${seconds} s.` };
    } else {
      this.notice = { kind: "error", text: error.message, code: error.code, id: error.requestId || error.errorId };
    }
    if (this.phase === "holding" || this.phase === "applying") return;
    if (error.status === 403 && error.code === "edit_disabled") {
      this.turnedOff();
      return;
    }
    this.rowNote = this.notice.text;
    this.render();
    this.revealNotice(this.notice.text);
  }

  revealRow() {
    const text = this.refs && this.refs.actionText ? this.refs.actionText.textContent : "";
    if (text) announce(text);
  }

  appliedView() {
    const { kind, result } = this.applied;
    const wrap = el("div", "he-applied");
    const state = document.createElement("od-state");
    state.setAttribute("kind", "empty_cleared");
    state.setAttribute("heading", kind === "delete" ? "Hook deleted" : "Script saved");
    state.setAttribute("body", kind === "delete" ? "The hook was removed. Running sessions may keep it until they restart." : "A backup was written first.");
    if (kind === "script") {
      state.append(
        button("Edit again", { variant: "secondary", size: "xs" }, () => {
          this.applied = null;
          this.discardAll();
          this.loadText();
          this.render();
          this.focusTarget("gate-edit");
        }),
      );
    }
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
    return wrap;
  }
}

customElements.define("od-hook-edit", OdHookEdit);

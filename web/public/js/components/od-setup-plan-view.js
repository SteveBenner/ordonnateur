import "./od-button.js";
import "./od-chip.js";
import "./od-toggle.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-segmented.js";
import "./od-combobox.js";
import "./od-text-field.js";
import "./od-dialog.js";
import "./od-confirm.js";
import "./od-run-status.js";
import { diffBlock } from "./od-health-view.js";
import { get, post, endpoints } from "../core/api.js";
import { getPref, setPref } from "../core/cache.js";
import { announce, toast } from "../core/announce.js";
import { HARNESS_LABELS } from "../core/hooks.js";
import { runs, start, latestRun, blockReason, attach, READ_ONLY_COPY } from "../core/runs.js";

const NS = "http://www.w3.org/2000/svg";
const SKELETON_BLOCKS = 3;
const GOALS = ["speed", "safety", "fewer prompts", "lower cost", "reliability"];
const HARNESSES = ["claude-code", "codex", "hermes", "antigravity"];
const UNATTENDED = ["often", "sometimes", "never"];
const QUESTION_TEXT = {
  goal: "What do you most want from your agent setup?",
  harnesses: "Which harnesses do you use most?",
  unattended: "Do agents run unattended here?",
  constraint: "Anything that must not change?",
};
let sequence = 0;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function cap(text) {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "od-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
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

function disclosure(label, open) {
  sequence += 1;
  const root = el("div", "pv-disc");
  const toggle = el("button", "pv-disc-toggle od-native");
  toggle.type = "button";
  const region = el("div", "pv-disc-body");
  region.id = `pv-disc-${sequence}`;
  toggle.setAttribute("aria-controls", region.id);
  const text = el("span", "pv-disc-label", label);
  toggle.append(icon("chevron-down"), text);
  const set = (value) => {
    toggle.setAttribute("aria-expanded", value ? "true" : "false");
    region.hidden = !value;
  };
  set(open);
  toggle.addEventListener("click", () => set(region.hidden));
  root.append(toggle, region);
  return { root, region, toggle, set };
}

function listText(items) {
  if (items.length <= 1) return items.join("");
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`;
}

class OdSetupPlanView extends HTMLElement {
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
    this.answers = { goal: null, harnesses: [], unattended: null, constraint: "" };
    this.touched = false;
    this.scope = "user";
    this.model = getPref("planModel", true) !== false;
    this.profile = null;
    this.proposals = [];
    this.applied = {};
    this.questions = null;
    this.loading = false;
    this.error = null;
    this.railOpen = true;
    this.railDecided = false;
    this.open = new Map();
    this.results = new Map();
    this.sequence = 0;
    this.loadedKey = null;
    this.pasteNote = null;
    this.pastedRefused = [];
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
    this.seenPlan = runs.get().done.plan;
    this.unsubscribe = runs.subscribe((state) => {
      this.refreshControls();
      if (state.done.plan !== this.seenPlan) {
        this.seenPlan = state.done.plan;
        this.renderContent();
      }
    });
    this.onFinished = (event) => {
      if (event.detail.run.verb === "plan") this.load(true);
    };
    document.addEventListener("od-run-finished", this.onFinished);
  }

  build() {
    this.dataset.firstLoad = "true";
    this.header = el("div", "sv-header");
    this.header.dataset.density = "cockpit";
    const status = document.createElement("od-run-status");
    status.setAttribute("verb", "plan");
    this.header.append(status);

    this.layout = el("div", "pv-layout");
    this.rail = el("aside", "pv-rail");
    this.rail.setAttribute("aria-label", "Plan questions and options");
    this.rail.dataset.density = "cockpit";
    this.rail.dataset.pending = "true";

    this.summary = el("div", "pv-summary");
    this.summaryText = el("span", "pv-summary-text");
    this.editButton = button("Edit answers", { variant: "ghost", size: "xs" });
    this.summary.append(this.summaryText, this.editButton);

    this.fields = el("div", "pv-fields");
    this.fields.id = "pv-fields";
    this.goal = document.createElement("od-combobox");
    this.goal.setAttribute("label", QUESTION_TEXT.goal);
    this.goal.setAttribute("hide-label", "");
    this.goal.setAttribute("placeholder", "No preference");
    this.goal.options = GOALS.map((value) => ({ value, label: cap(value) }));
    this.harnesses = document.createElement("od-combobox");
    this.harnesses.setAttribute("label", QUESTION_TEXT.harnesses);
    this.harnesses.setAttribute("hide-label", "");
    this.harnesses.setAttribute("placeholder", "Any");
    this.harnesses.setAttribute("multiple", "");
    this.harnesses.options = HARNESSES.map((value) => ({ value, label: HARNESS_LABELS[value] }));
    this.unattended = document.createElement("od-segmented");
    this.unattended.setAttribute("label", QUESTION_TEXT.unattended);
    this.unattended.setAttribute("size", "sm");
    this.unattended.options = UNATTENDED.map((value) => ({ value, label: cap(value) }));
    this.unattended.setAttribute("value", "");
    this.constraint = document.createElement("od-text-field");
    this.constraint.setAttribute("label", QUESTION_TEXT.constraint);
    this.constraint.setAttribute("hide-label", "");
    this.constraint.setAttribute("placeholder", "Nothing in particular");
    this.constraint.setAttribute("maxlength", "500");

    this.clears = {};
    const questions = el("div", "pv-questions");
    questions.setAttribute("role", "group");
    const questionsLabel = el("div", "pv-group-label", "Questions, all optional");
    questionsLabel.id = "pv-questions-label";
    questions.setAttribute("aria-labelledby", questionsLabel.id);
    questions.append(questionsLabel);
    const questionField = (key, name, control) => {
      const field = el("div", "pv-field");
      const head = el("div", "pv-field-head");
      const label = el("div", "pv-label", QUESTION_TEXT[key]);
      label.setAttribute("aria-hidden", "true");
      const clear = el("button", "pv-clear od-native", "Clear");
      clear.type = "button";
      clear.setAttribute("aria-label", `Clear ${name}`);
      clear.dataset.answered = "false";
      this.clears[key] = clear;
      clear.addEventListener("click", () => this.clearAnswer(key));
      head.append(label, clear);
      field.append(head, control);
      questions.append(field);
    };
    questionField("goal", "goal", this.goal);
    questionField("harnesses", "harnesses", this.harnesses);
    questionField("unattended", "unattended", this.unattended);
    questionField("constraint", "constraint", this.constraint);

    const rule = el("hr", "pv-rule");
    const options = el("div", "pv-options");
    options.append(el("div", "pv-group-label", "Run options"));
    this.scopeControl = document.createElement("od-segmented");
    this.scopeControl.setAttribute("label", "Scope");
    this.scopeControl.setAttribute("size", "sm");
    this.scopeControl.setAttribute("value", "user");
    this.scopeReason = el("div", "pv-reason", "Local needs a project.");
    this.scopeReason.id = "pv-scope-reason";
    this.scopeReason.hidden = true;
    this.scopeNoProject = null;
    const scopeField = el("div", "pv-field");
    const scopeRow = el("div", "pv-option-row");
    const scopeLabel = el("div", "pv-label", "Scope");
    scopeLabel.setAttribute("aria-hidden", "true");
    scopeRow.append(scopeLabel, this.scopeControl);
    scopeField.append(scopeRow, this.scopeReason);
    this.modelToggle = document.createElement("od-toggle");
    this.modelToggle.setAttribute("label", "Use a model");
    this.modelToggle.toggleAttribute("checked", this.model);
    const modelRow = el("div", "pv-option-row");
    const modelLabel = el("div", "pv-label", "Use a model");
    modelLabel.setAttribute("aria-hidden", "true");
    modelRow.append(modelLabel, this.modelToggle);
    options.append(scopeField, modelRow);

    this.buttons = el("div", "pv-buttons");
    this.runButton = button("Run plan", { variant: "primary" });
    this.buttons.append(this.runButton);
    this.formError = el("p", "pv-form-error");
    this.formError.setAttribute("role", "alert");
    this.formError.hidden = true;

    this.fields.append(questions, rule, options, this.buttons, this.formError);
    this.rail.append(this.summary, this.fields);

    this.content = el("section", "pv-content");
    this.content.dataset.density = "cockpit";
    this.content.setAttribute("aria-label", "Proposals");
    this.layout.append(this.rail, this.content);
    this.append(this.header, this.layout);

    this.editButton.button.setAttribute("aria-expanded", "true");
    this.editButton.button.setAttribute("aria-controls", this.fields.id);

    this.goal.addEventListener("od-change", (event) => this.answer("goal", event.detail.value));
    this.harnesses.addEventListener("od-change", (event) => this.answer("harnesses", event.detail.value || []));
    this.unattended.addEventListener("od-change", (event) => this.answer("unattended", event.detail.value));
    this.constraint.addEventListener("od-input", (event) => this.answer("constraint", event.detail.value));
    this.scopeControl.addEventListener("od-change", (event) => {
      this.scope = event.detail.value;
    });
    this.modelToggle.addEventListener("od-change", (event) => {
      this.model = event.detail.checked;
      setPref("planModel", this.model);
    });
    this.runButton.addEventListener("click", () => this.run());
    this.editButton.addEventListener("click", () => {
      this.railDecided = true;
      this.railOpen = !this.railOpen;
      this.syncRail();
    });
    this.addEventListener("od-retry", (event) => {
      event.stopPropagation();
      this.load(false);
    });
    this.syncRail();
  }

  answer(key, value) {
    this.touched = true;
    this.answers[key] = value;
    this.formError.hidden = true;
    this.updateSummary();
    this.refreshControls();
    this.syncClears();
  }

  clearAnswer(key) {
    if (key === "goal") {
      this.goal.value = null;
      this.answer("goal", null);
      this.goal.focus();
    } else if (key === "harnesses") {
      this.harnesses.value = [];
      this.answer("harnesses", []);
      this.harnesses.focus();
    } else if (key === "unattended") {
      this.unattended.value = null;
      this.answer("unattended", null);
      this.unattended.focus();
    } else {
      this.constraint.value = "";
      this.answer("constraint", "");
      this.constraint.focus();
    }
  }

  syncClears() {
    const answered = {
      goal: Boolean(this.answers.goal),
      harnesses: this.answers.harnesses.length > 0,
      unattended: Boolean(this.answers.unattended),
      constraint: Boolean((this.answers.constraint || "").trim()),
    };
    for (const key of Object.keys(this.clears)) this.clears[key].dataset.answered = answered[key] ? "true" : "false";
  }

  fill(answers) {
    const data = answers || {};
    this.answers = {
      goal: typeof data.goal === "string" ? data.goal : null,
      harnesses: Array.isArray(data.harnesses) ? data.harnesses : [],
      unattended: typeof data.unattended === "string" ? data.unattended : null,
      constraint: typeof data.constraint === "string" ? data.constraint : "",
    };
    this.goal.value = this.answers.goal;
    this.harnesses.value = this.answers.harnesses;
    this.unattended.value = this.answers.unattended;
    this.constraint.value = this.answers.constraint;
    this.syncClears();
  }

  payloadAnswers() {
    const out = {};
    if (this.answers.goal) out.goal = this.answers.goal;
    if (this.answers.harnesses.length) out.harnesses = [...this.answers.harnesses];
    if (this.answers.unattended) out.unattended = this.answers.unattended;
    const text = (this.answers.constraint || "").trim();
    if (text) out.constraint = text;
    return out;
  }

  updateSummary() {
    const answers = this.touched ? this.payloadAnswers() : this.profile ? this.profile.answers || {} : this.payloadAnswers();
    const parts = [];
    if (answers.goal) parts.push(`Goal: ${cap(answers.goal)}`);
    if (answers.harnesses && answers.harnesses.length) parts.push(`Harnesses: ${listText(answers.harnesses.map((item) => HARNESS_LABELS[item] || item))}`);
    if (answers.unattended) parts.push(`Unattended: ${answers.unattended}`);
    if (answers.constraint) parts.push(`Must not change: ${answers.constraint}`);
    this.summaryText.textContent = parts.length ? parts.join(" · ") : "No answers saved.";
  }

  syncRail() {
    this.rail.dataset.collapsed = this.railOpen ? "false" : "true";
    this.editButton.text = this.railOpen ? "Hide answers" : "Edit answers";
    if (this.editButton.button) this.editButton.button.setAttribute("aria-expanded", this.railOpen ? "true" : "false");
  }

  key() {
    const ctx = this.ctx || {};
    return ctx.project || "";
  }

  sync() {
    const ctx = this.ctx || {};
    if (!ctx.project && this.scope === "local") {
      this.scope = "user";
      this.scopeControl.setAttribute("value", "user");
    }
    if (ctx.active && this.key() !== this.loadedKey) this.load(false);
    this.refreshControls();
  }

  async load(quiet) {
    const ctx = this.ctx || {};
    this.sequence += 1;
    const mine = this.sequence;
    this.loadedKey = this.key();
    if (!quiet) {
      this.loading = true;
      this.error = null;
      this.renderContent();
    }
    try {
      const [data] = await Promise.all([get(endpoints.proposals({ project: ctx.project })), attach()]);
      if (mine !== this.sequence) return;
      this.proposals = data.proposals || [];
      this.applied = data.applied || {};
      this.profile = data.profile || null;
      this.questions = data.questions || null;
      this.error = null;
      if (this.profile && !this.touched) this.fill(this.profile.answers);
      if (this.profile && !this.railDecided) {
        this.railOpen = false;
        this.syncRail();
      }
      this.updateSummary();
    } catch (error) {
      if (mine !== this.sequence) return;
      this.error = error;
    }
    this.loading = false;
    this.rail.removeAttribute("data-pending");
    this.refreshControls();
    this.renderContent();
    delete this.dataset.firstLoad;
  }

  hasAnswers() {
    return Object.keys(this.payloadAnswers()).length > 0;
  }

  refreshControls() {
    if (!this.header) return;
    const ctx = this.ctx || {};
    const block = blockReason(ctx.readOnly);
    setDisabled(this.runButton, block);
    const noProject = !ctx.project;
    if (noProject !== this.scopeNoProject) {
      this.scopeNoProject = noProject;
      this.scopeControl.options = [
        { value: "user", label: "User" },
        { value: "local", label: "Local", disabled: noProject, reason: "Local needs a project", describedby: this.scopeReason.id },
      ];
    }
    this.scopeReason.hidden = !noProject;
    this.updateSummary();
  }

  async run() {
    const ctx = this.ctx || {};
    const body = { verb: "plan", project: ctx.project || null, model: this.model, scope: ctx.project ? this.scope : "user" };
    if (this.hasAnswers()) body.answers = this.payloadAnswers();
    else if (this.profile && !this.touched) body.interview = "saved";
    else body.interview = "skip";
    this.formError.hidden = true;
    try {
      await start(body);
      announce("Run started.");
      this.results.clear();
      this.pastedRefused = [];
    } catch (error) {
      if (error && error.code === "answers_needed") {
        this.formError.textContent = error.message || "The server asked for an answer.";
        this.formError.hidden = false;
      } else if (error && error.code === "run_active") {
        toast("Another run is active.", { kind: "error" });
      } else {
        toast(error && error.message ? error.message : "The run could not start.", { kind: "error", title: "Could not start the run" });
      }
    }
  }

  report() {
    const run = latestRun("plan");
    if (!run || run.status !== "done" || !run.report) return null;
    const ctx = this.ctx || {};
    if (run.project !== undefined && (run.project || null) !== (ctx.project || null)) return null;
    return run.report;
  }

  renderContent() {
    if (!this.content) return;
    const host = this.content;
    host.textContent = "";
    host.removeAttribute("aria-busy");
    if (this.loading) {
      host.setAttribute("aria-busy", "true");
      for (let index = 0; index < SKELETON_BLOCKS; index += 1) {
        const bar = document.createElement("od-skeleton");
        bar.setAttribute("height", "96px");
        host.append(bar);
      }
      return;
    }
    if (this.error) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "Proposals could not be loaded");
      state.setAttribute("body", this.error.message);
      if (this.error.requestId || this.error.errorId) state.setAttribute("error-id", this.error.requestId || this.error.errorId);
      host.append(state);
      return;
    }
    const report = this.report();
    if (report && report.assessment) {
      const line = el("div", "pv-assessment");
      line.append(chip("tag", null, "Judged by a model"), el("p", "pv-assessment-text", report.assessment));
      host.append(line);
    } else if (report && report.model_status && report.model_status.status !== "ok" && report.model_status.status !== "skipped") {
      host.append(el("p", "pv-quiet", `No model assessment: ${report.model_status.reason || report.model_status.status}.`));
    }
    if (!this.proposals.length) {
      if (report && report.prompt) {
        host.append(el("p", "pv-quiet", "This run used no model. Copy the prompt to your agent, then paste what it writes."));
      } else {
        const state = document.createElement("od-state");
        state.setAttribute("kind", "empty");
        state.setAttribute("heading", "No proposals yet");
        state.setAttribute("body", "Answer what you like and run plan");
        host.append(state);
      }
    } else {
      this.proposals.forEach((proposal, index) => host.append(this.proposalBlock(proposal, index)));
    }
    const refused = [...((report && report.refused) || []), ...this.pastedRefused];
    if (refused.length) host.append(this.refusedBlock(refused));
    if (report && report.prompt) host.append(this.factsBlock(report));
  }

  proposalBlock(proposal, index) {
    const block = el("article", "pv-proposal");
    block.dataset.id = proposal.id;
    if (proposal.widening) block.dataset.widening = "true";
    const head = el("div", "pv-proposal-head");
    head.append(chip("tag", null, proposal.kind === "apply" ? "Apply" : "Suggest"));
    head.append(chip("tag", null, HARNESS_LABELS[proposal.harness] || proposal.harness));
    head.append(chip("tag", null, proposal.scope === "local" ? "Local" : "User"));
    if (proposal.widening) head.append(chip("status", "untrusted", "Widens access"));
    const appliedAt = this.applied[proposal.id];
    if (appliedAt) head.append(chip("status", "trusted", "Applied"));
    head.append(el("span", "pv-proposal-id mono", proposal.id));
    block.append(head);
    block.append(el("h3", "pv-proposal-title", proposal.title));
    if (proposal.why) block.append(el("p", "pv-proposal-why", proposal.why));
    if (proposal.serves) block.append(el("p", "pv-proposal-serves", `Serves: ${proposal.serves}`));
    const isApply = proposal.kind === "apply";
    const shown = this.open.has(proposal.id) ? this.open.get(proposal.id) : index === 0;
    const disc = disclosure(isApply ? "Diff" : "Instructions", shown);
    disc.toggle.addEventListener("click", () => this.open.set(proposal.id, !disc.region.hidden));
    if (isApply) {
      if (proposal.diff) disc.region.append(diffBlock(proposal.diff));
      else disc.region.append(el("p", "pv-quiet", "No diff is stored for this proposal."));
      if (proposal.no_change) disc.region.append(el("p", "pv-quiet", "Settings already match this proposal."));
    } else {
      disc.region.append(el("p", "pv-instructions", proposal.instructions || ""));
    }
    block.append(disc.root);
    const result = el("p", "pv-result");
    result.setAttribute("role", "status");
    block.append(result);
    this.showResult(result, this.results.get(proposal.id));
    if (isApply && !appliedAt) {
      const actions = el("div", "pv-proposal-actions");
      const apply = button(proposal.widening ? "Apply…" : "Apply", { size: "xs" });
      setDisabled(apply, this.ctx && this.ctx.readOnly ? READ_ONLY_COPY : null);
      apply.addEventListener("click", () => {
        if (proposal.widening) this.confirmWidening(proposal, apply);
        else this.apply(proposal, false);
      });
      actions.append(apply);
      block.append(actions);
    }
    return block;
  }

  showResult(node, result) {
    node.textContent = "";
    node.removeAttribute("data-tone");
    if (!result) return;
    node.textContent = result.text;
    if (result.tone) node.dataset.tone = result.tone;
  }

  refusedBlock(refused) {
    const wrap = el("div", "pv-refused");
    const disc = disclosure(`Refused proposals (${refused.length})`, false);
    const list = el("ul", "pv-refused-list");
    for (const item of refused) {
      const entry = el("li", "pv-refused-item");
      entry.append(el("strong", "pv-refused-title", item.title || `Proposal ${item.index || ""}`.trim()));
      entry.append(el("span", "pv-refused-reasons", (item.reasons || []).join("; ")));
      list.append(entry);
    }
    disc.region.append(list);
    wrap.append(disc.root);
    return wrap;
  }

  factsBlock(report) {
    const wrap = el("div", "pv-facts");
    const prompt = disclosure("Prompt for your agent", false);
    const text = [report.system, report.prompt].filter(Boolean).join("\n\n");
    const pre = el("pre", "pv-prompt mono", text);
    const copy = button("Copy", { size: "xs" });
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(text);
        toast("Prompt copied.", { kind: "info" });
      } catch (error) {
        toast("The browser did not allow copying.", { kind: "error" });
      }
    });
    prompt.region.append(copy, pre);
    wrap.append(prompt.root);

    const paste = disclosure("Paste proposals", Boolean(this.pasteNote));
    const field = document.createElement("od-text-field");
    field.setAttribute("multiline", "");
    field.setAttribute("mono", "");
    field.setAttribute("label", "Proposals from your agent");
    field.setAttribute("placeholder", "Paste the JSON your agent wrote");
    const store = button("Store proposals", { size: "xs" });
    setDisabled(store, this.ctx && this.ctx.readOnly ? READ_ONLY_COPY : null);
    const note = el("p", "pv-result");
    note.setAttribute("role", "status");
    if (this.pasteNote) {
      note.textContent = this.pasteNote.text;
      if (this.pasteNote.tone) note.dataset.tone = this.pasteNote.tone;
    }
    store.addEventListener("click", () => this.storePasted(field, note));
    paste.region.append(field, store, note);
    wrap.append(paste.root);
    return wrap;
  }

  async storePasted(field, note) {
    const ctx = this.ctx || {};
    let parsed;
    try {
      parsed = JSON.parse(field.value);
    } catch (error) {
      field.setAttribute("error", "That is not valid JSON.");
      return;
    }
    field.removeAttribute("error");
    const list = Array.isArray(parsed) ? parsed : parsed && Array.isArray(parsed.proposals) ? parsed.proposals : null;
    if (!list) {
      field.setAttribute("error", "Paste a list of proposals, or an object with a proposals list.");
      return;
    }
    try {
      const out = await post(endpoints.proposals({}), { proposals: list, project: ctx.project || null, scope: ctx.project ? this.scope : "user" });
      const count = (value) => (Array.isArray(value) ? value.length : Number(value) || 0);
      const stored = count(out && out.stored);
      const refused = count(out && out.refused);
      this.pastedRefused = Array.isArray(out && out.refused) ? out.refused : [];
      this.pasteNote = { text: `Stored ${stored}, refused ${refused}.`, tone: refused ? "warn" : null };
      note.textContent = this.pasteNote.text;
      if (this.pasteNote.tone) note.dataset.tone = this.pasteNote.tone;
      else note.removeAttribute("data-tone");
      announce(this.pasteNote.text);
      await this.load(true);
    } catch (error) {
      field.setAttribute("error", error && error.message ? error.message : "The proposals could not be stored.");
    }
  }

  confirmWidening(proposal, opener) {
    const dialog = document.createElement("od-dialog");
    dialog.setAttribute("heading", "Apply a change that widens access");
    dialog.setAttribute("size", "sm");
    const words = el("p", "pv-dialog-text", `${proposal.title} widens what an agent may do. Review the diff, then type its id to apply it.`);
    const confirm = document.createElement("od-confirm");
    confirm.setAttribute("mode", "phrase");
    confirm.setAttribute("expected", proposal.id);
    confirm.setAttribute("action", "Apply");
    dialog.addEventListener("od-close", () => dialog.remove());
    confirm.addEventListener("od-confirm", async () => {
      confirm.setAttribute("busy", "");
      await this.apply(proposal, true);
      dialog.close();
    });
    this.append(dialog);
    dialog.body.append(words, confirm);
    dialog.show(opener);
  }

  async apply(proposal, widening) {
    const ctx = this.ctx || {};
    const body = { ids: [proposal.id], project: ctx.project || null };
    if (widening) {
      body.allow_widening = true;
      body.confirm = proposal.id;
    }
    let result;
    try {
      const out = await post(endpoints.proposalsApply, body);
      result = ((out && out.applied) || [])[0] || null;
    } catch (error) {
      const again = error && (error.status === 409 || error.code === "changed");
      this.results.set(proposal.id, {
        text: again ? "Settings changed since this proposal was stored. Run plan again." : error && error.message ? error.message : "The proposal could not be applied.",
        tone: "danger",
      });
      this.renderContent();
      return;
    }
    if (!result) {
      this.results.set(proposal.id, { text: "The server returned no result. Run plan again.", tone: "danger" });
    } else if (result.status === "applied") {
      this.results.set(proposal.id, { text: "Applied.", tone: "ok" });
      toast(`Applied: ${proposal.title}`, { kind: "info" });
    } else if (result.status === "unchanged") {
      this.results.set(proposal.id, { text: "Settings already match.", tone: null });
    } else if (result.status === "changed") {
      this.results.set(proposal.id, { text: "Settings changed since this proposal was stored. Run plan again.", tone: "danger" });
    } else {
      this.results.set(proposal.id, { text: result.reason || "The proposal was refused.", tone: "danger" });
    }
    await this.load(true);
  }
}

customElements.define("od-setup-plan-view", OdSetupPlanView);

import "./od-button.js";
import "./od-chip.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-segmented.js";
import "./od-text-field.js";
import "./od-dialog.js";
import "./od-confirm.js";
import "./od-run-status.js";
import { get, put, del, endpoints } from "../core/api.js";
import { announce, toast } from "../core/announce.js";
import { READ_ONLY_COPY } from "../core/runs.js";

const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const SKELETON_ROWS = 4;
const GROUPS = [
  { label: "Healing", keys: ["untangle.heal"] },
  { label: "Model", keys: ["advisor.backend", "advisor.harness", "advisor.model"] },
];
const CHOICES = {
  "untangle.heal": [
    { value: "off", label: "Off" },
    { value: "plan", label: "Plan" },
    { value: "auto", label: "Auto" },
  ],
  "advisor.backend": [
    { value: "harness", label: "Harness CLI" },
    { value: "extension", label: "Extension" },
  ],
  "advisor.harness": [
    { value: "claude", label: "Claude" },
    { value: "codex", label: "Codex" },
  ],
};
const DESCRIPTIONS = {
  "untangle.heal": {
    off: "Untangle reports and never heals.",
    plan: "Untangle previews heals, and you apply them.",
    auto: "Untangle also applies safe heals on every run.",
  },
  "advisor.backend": {
    harness: "A harness CLI runs the model, with no tools.",
    extension: "The author port's extension runs the model.",
  },
};
const FIXED_DESCRIPTIONS = {
  "advisor.harness": "The CLI the Harness CLI backend runs.",
  "advisor.model": "The model name passed to that CLI.",
};
const EXTENSION_REASON = "Not used with the Extension backend";
const AUTO_WORDS = "Each untangle run, including Run on the Health page, will apply safe heals without asking. Heals never touch guard, plugin, project, or managed hooks.";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function chip(kind, value, label) {
  const node = document.createElement("od-chip");
  node.setAttribute("kind", kind);
  if (value) node.setAttribute("value", value);
  if (label) node.setAttribute("label", label);
  return node;
}

class OdSettingsView extends HTMLElement {
  set context(value) {
    this.ctx = value;
    if (this.header) this.sync();
  }

  get context() {
    return this.ctx;
  }

  connectedCallback() {
    if (this.header) return;
    this.settings = [];
    this.extensionAvailable = true;
    this.loading = false;
    this.error = null;
    this.loaded = false;
    this.busy = new Set();
    this.drafts = new Map();
    this.messages = new Map();
    this.sequence = 0;
    this.build();
    this.sync();
  }

  build() {
    this.header = el("div", "sv-header");
    this.header.dataset.density = "cockpit";
    const status = document.createElement("od-run-status");
    this.header.append(status);
    this.body = el("div", "st-body");
    this.body.dataset.density = "cockpit";
    this.append(this.header, this.body);
    this.addEventListener("od-retry", (event) => {
      event.stopPropagation();
      this.load();
    });
  }

  sync() {
    const ctx = this.ctx || {};
    if (ctx.active && !this.loaded && !this.loading) this.load();
    else if (this.loaded && Boolean(ctx.readOnly) !== this.lastReadOnly) this.renderRows();
  }

  async load(quiet) {
    this.sequence += 1;
    const mine = this.sequence;
    if (!quiet) {
      this.loading = true;
      this.error = null;
      this.render();
    }
    try {
      const data = await get(endpoints.settings);
      if (mine !== this.sequence) return;
      this.settings = data.settings || [];
      this.extensionAvailable = data.extension_available !== false;
      this.error = null;
      this.loaded = true;
    } catch (error) {
      if (mine !== this.sequence) return;
      this.error = error;
    }
    this.loading = false;
    this.render();
  }

  render() {
    const host = this.body;
    host.textContent = "";
    host.removeAttribute("aria-busy");
    if (this.loading) {
      host.setAttribute("aria-busy", "true");
      for (let index = 0; index < SKELETON_ROWS; index += 1) {
        const bar = document.createElement("od-skeleton");
        bar.setAttribute("height", "44px");
        host.append(bar);
      }
      return;
    }
    if (this.error) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "Settings could not be loaded");
      state.setAttribute("body", this.error.message);
      if (this.error.requestId || this.error.errorId) state.setAttribute("error-id", this.error.requestId || this.error.errorId);
      host.append(state);
      return;
    }
    this.renderRows();
  }

  find(key) {
    return this.settings.find((item) => item.key === key) || null;
  }

  renderRows() {
    this.lastReadOnly = Boolean((this.ctx || {}).readOnly);
    const host = this.body;
    host.textContent = "";
    host.removeAttribute("aria-busy");
    let any = false;
    for (const group of GROUPS) {
      const rows = group.keys.map((key) => this.find(key)).filter(Boolean);
      if (!rows.length) continue;
      any = true;
      const section = el("section", "st-group");
      const heading = el("h2", "st-group-label", group.label);
      section.setAttribute("aria-label", group.label);
      section.append(heading);
      for (const setting of rows) section.append(this.row(setting));
      host.append(section);
    }
    if (!any) {
      const state = document.createElement("od-state");
      state.setAttribute("kind", "empty");
      state.setAttribute("heading", "No settings");
      state.setAttribute("body", "The server listed no settings to change");
      host.append(state);
    }
  }

  reasonFor(setting) {
    const ctx = this.ctx || {};
    if (ctx.readOnly) return READ_ONLY_COPY;
    if (setting.locked_by) return `Locked by ${setting.locked_by}.`;
    if (setting.key === "advisor.harness" || setting.key === "advisor.model") {
      const backend = this.find("advisor.backend");
      if (backend && backend.value === "extension") return EXTENSION_REASON;
    }
    return null;
  }

  row(setting) {
    const key = setting.key;
    const wrap = el("div", "st-row");
    wrap.dataset.key = key;
    wrap.setAttribute("role", "group");
    const nameId = `st-name-${key.replace(/\./g, "-")}`;
    wrap.setAttribute("aria-labelledby", nameId);
    const reason = this.reasonFor(setting);
    const saving = this.busy.has(key);

    const text = el("div", "st-text");
    const name = el("div", "st-name mono", key);
    name.id = nameId;
    const described = (DESCRIPTIONS[key] && DESCRIPTIONS[key][String(setting.value)]) || FIXED_DESCRIPTIONS[key] || setting.description || "";
    text.append(name, el("div", "st-desc", described));
    if (reason) text.append(el("div", "st-hint", reason));
    wrap.append(text);

    const control = el("div", "st-control");
    if (CHOICES[key]) {
      const segmented = document.createElement("od-segmented");
      segmented.setAttribute("label", key);
      segmented.setAttribute("size", "sm");
      segmented.options = CHOICES[key];
      segmented.setAttribute("value", String(setting.value));
      if (reason || saving) segmented.setAttribute("disabled", "");
      segmented.addEventListener("od-change", (event) => this.choose(setting, event.detail.value));
      control.append(segmented);
    } else {
      control.append(this.modelField(setting, reason, saving));
    }
    wrap.append(control);

    const source = el("div", "st-source");
    if (setting.locked_by) source.append(chip("status", "guard", "Locked"));
    else if (setting.layer === "default") source.append(chip("tag", null, "Default"));
    else source.append(chip("tag", null, "Your setting"));
    wrap.append(source);

    const reset = document.createElement("od-button");
    reset.text = "Reset";
    reset.setAttribute("size", "xs");
    reset.setAttribute("aria-label", `Reset ${key}`);
    const resetReason = reason && !reason.startsWith("Not used") ? reason : setting.layer === "default" ? "Already at the default" : null;
    reset.toggleAttribute("disabled", Boolean(resetReason) || saving);
    if (resetReason) reset.setAttribute("reason", resetReason);
    reset.addEventListener("click", () => this.reset(setting));
    const resetCell = el("div", "st-reset");
    resetCell.append(reset);
    wrap.append(resetCell);

    const message = this.messages.get(key);
    if (message) {
      const note = el("div", "st-message", message.text);
      note.setAttribute("role", "status");
      if (message.tone) note.dataset.tone = message.tone;
      wrap.append(note);
    }
    if (key === "advisor.backend" && setting.value === "extension" && !this.extensionAvailable) {
      wrap.append(el("div", "st-warning", "No extension backs the author port here, so untangle and plan will run with no model."));
    }
    return wrap;
  }

  modelField(setting, reason, saving) {
    const key = setting.key;
    const cell = el("div", "st-model");
    const field = document.createElement("od-text-field");
    field.setAttribute("label", key);
    field.setAttribute("hide-label", "");
    field.setAttribute("mono", "");
    field.setAttribute("maxlength", "128");
    field.setAttribute("value", this.drafts.has(key) ? this.drafts.get(key) : String(setting.value ?? ""));
    if (reason || saving) field.setAttribute("disabled", "");
    field.validator = (value) => {
      if (!value.trim()) return "Enter a model name, or use Reset for the default.";
      return MODEL_PATTERN.test(value.trim()) ? "" : "Start with a letter or digit, then use letters, digits, and . _ : / - up to 128 characters.";
    };
    const save = document.createElement("od-button");
    save.text = "Save";
    save.setAttribute("size", "xs");
    save.setAttribute("variant", "primary");
    const changed = () => field.value.trim() !== String(setting.value ?? "");
    save.hidden = !(this.drafts.has(key) && this.drafts.get(key) !== String(setting.value ?? ""));
    field.addEventListener("od-input", () => {
      this.drafts.set(key, field.value);
      save.hidden = !changed();
      field.removeAttribute("error");
    });
    const submit = () => {
      if (!changed()) return;
      this.saveModel(setting, field);
    };
    save.addEventListener("click", submit);
    field.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && event.target === field.input) {
        event.preventDefault();
        submit();
      }
    });
    cell.append(field, save);
    return cell;
  }

  async saveModel(setting, field) {
    const value = field.value.trim();
    const problem = field.validator(value);
    if (problem) {
      field.setAttribute("error", problem);
      field.focus();
      return;
    }
    const outcome = await this.write(setting, value, null);
    if (outcome && outcome.error) {
      field.setAttribute("error", outcome.error);
      field.focus();
    } else if (outcome) {
      this.drafts.delete(setting.key);
    }
  }

  choose(setting, value) {
    if (setting.key === "untangle.heal" && value === "auto") {
      this.confirmAuto(setting);
      return;
    }
    this.write(setting, value, null);
  }

  confirmAuto(setting) {
    const dialog = document.createElement("od-dialog");
    dialog.setAttribute("heading", "Turn on auto healing");
    dialog.setAttribute("size", "sm");
    const words = el("p", "st-dialog-text", AUTO_WORDS);
    const confirm = document.createElement("od-confirm");
    confirm.setAttribute("mode", "phrase");
    confirm.setAttribute("expected", "auto");
    confirm.setAttribute("action", "Turn on auto");
    let confirmed = false;
    dialog.addEventListener("od-close", () => {
      dialog.remove();
      if (!confirmed) this.renderRows();
    });
    confirm.addEventListener("od-confirm", async () => {
      confirmed = true;
      confirm.setAttribute("busy", "");
      await this.write(setting, "auto", "auto");
      dialog.close();
    });
    this.append(dialog);
    dialog.body.append(words, confirm);
    dialog.show(document.activeElement);
  }

  async write(setting, value, confirm) {
    const key = setting.key;
    this.busy.add(key);
    this.messages.delete(key);
    this.renderRows();
    try {
      const body = confirm ? { value, confirm } : { value };
      await put(endpoints.setting(key), body);
      this.busy.delete(key);
      announce(`${key} set to ${value}.`);
      await this.load(true);
      this.refocus(key);
      return { ok: true };
    } catch (error) {
      this.busy.delete(key);
      const text = error && error.message ? error.message : "The setting could not be saved.";
      const inline = key === "advisor.model" && error && error.code === "invalid";
      if (!inline) {
        this.messages.set(key, { text, tone: "danger" });
        toast(text, { kind: "error", title: `Could not change ${key}` });
      }
      this.renderRows();
      this.refocus(key);
      return { error: text };
    }
  }

  refocus(key) {
    const row = this.body.querySelector(`[data-key="${key}"]`);
    if (!row) return;
    const target = row.querySelector("[role=radio][aria-checked=true]") || row.querySelector("input.od-native:not(:disabled)") || row.querySelector("[role=radio]");
    if (target) target.focus();
  }

  async reset(setting) {
    const key = setting.key;
    this.busy.add(key);
    this.messages.delete(key);
    this.renderRows();
    try {
      await del(endpoints.setting(key));
      this.busy.delete(key);
      this.drafts.delete(key);
      announce(`${key} reset to its default.`);
      await this.load(true);
      this.refocus(key);
    } catch (error) {
      this.busy.delete(key);
      const text = error && error.message ? error.message : "The setting could not be reset.";
      this.messages.set(key, { text, tone: "danger" });
      toast(text, { kind: "error", title: `Could not reset ${key}` });
      this.renderRows();
    }
  }
}

customElements.define("od-settings-view", OdSettingsView);

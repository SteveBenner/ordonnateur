import "./od-dialog.js";
import "./od-button.js";
import "./od-skeleton.js";
import "./od-state.js";
import { get, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";

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

function baseName(path) {
  return path === "/" ? "/" : path.split("/").filter(Boolean).pop() || path;
}

class OdFolderPicker extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    sequence += 1;
    this.uid = `od-folder-picker-${sequence}`;
    this.requests = 0;
    this.location = null;
    this.entries = [];
    this.activeIndex = -1;
    this.bar = el("div", "od-fp-bar");
    this.up = document.createElement("od-button");
    this.up.setAttribute("variant", "ghost");
    this.up.setAttribute("size", "sm");
    this.up.textContent = "Up";
    this.path = el("span", "od-fp-path mono");
    this.bar.append(this.up, this.path);
    this.list = el("div", "od-fp-list");
    this.list.id = `${this.uid}-list`;
    this.list.setAttribute("role", "listbox");
    this.list.tabIndex = 0;
    this.note = el("p", "od-fp-note");
    this.note.hidden = true;
    this.cancel = document.createElement("od-button");
    this.cancel.setAttribute("data-dialog-footer", "");
    this.cancel.setAttribute("size", "md");
    this.cancel.textContent = this.getAttribute("cancel-label") || "Cancel";
    this.confirm = document.createElement("od-button");
    this.confirm.setAttribute("data-dialog-footer", "");
    this.confirm.setAttribute("variant", "primary");
    this.confirm.setAttribute("size", "md");
    this.confirm.setAttribute("write", "");
    this.confirm.textContent = this.getAttribute("confirm-label") || "Select";
    this.dialog = document.createElement("od-dialog");
    this.dialog.setAttribute("heading", this.getAttribute("label") || "Select a Folder");
    this.dialog.setAttribute("size", "md");
    this.dialog.setAttribute("dismissible", "");
    this.dialog.setAttribute("initial-focus", ".od-fp-list");
    this.dialog.append(this.bar, this.list, this.note, this.cancel, this.confirm);
    this.append(this.dialog);
    this.up.addEventListener("click", () => this.goUp());
    this.cancel.addEventListener("click", () => this.dialog.close());
    this.confirm.addEventListener("click", () => this.choose());
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[data-index]");
      if (row) this.setActive(Number(row.dataset.index));
    });
    this.list.addEventListener("dblclick", (event) => {
      const row = event.target.closest("[data-index]");
      if (row) this.enter(Number(row.dataset.index));
    });
    this.list.addEventListener("keydown", (event) => this.onKey(event));
  }

  async open(start, opener) {
    this.dialog.show(opener);
    await this.load(start || "");
  }

  async load(path) {
    this.requests += 1;
    const ticket = this.requests;
    this.renderLoading();
    try {
      const result = await get(endpoints.folders({ path }), { retry: false });
      if (ticket !== this.requests) return;
      this.location = result;
      this.entries = result.entries || [];
      this.activeIndex = this.entries.length ? 0 : -1;
      this.render(result);
      announce(`${baseName(result.path)}, ${this.entries.length} ${this.entries.length === 1 ? "folder" : "folders"}.`);
    } catch (error) {
      if (ticket !== this.requests) return;
      this.renderError(error, path);
    }
  }

  renderLoading() {
    this.list.setAttribute("aria-busy", "true");
    const rows = [];
    for (let index = 0; index < 4; index += 1) {
      const row = el("div", "od-fp-skeleton");
      row.append(document.createElement("od-skeleton"));
      rows.push(row);
    }
    this.list.replaceChildren(...rows);
    this.note.hidden = true;
  }

  render(result) {
    this.list.removeAttribute("aria-busy");
    this.path.textContent = result.path;
    this.path.title = result.path;
    this.up.toggleAttribute("disabled", !result.parent);
    this.list.setAttribute("aria-label", `Folders in ${baseName(result.path)}`);
    this.confirm.text = `Select ${baseName(result.path)}`;
    if (!this.entries.length) {
      this.list.replaceChildren(el("div", "od-fp-empty", "No subfolders"));
    } else {
      this.list.replaceChildren(
        ...this.entries.map((entry, index) => {
          const row = el("div", "od-fp-row");
          row.id = `${this.uid}-row-${index}`;
          row.setAttribute("role", "option");
          row.dataset.index = String(index);
          row.title = entry.name;
          row.append(glyph("folder"), el("span", "od-fp-name", entry.name));
          return row;
        }),
      );
    }
    this.note.hidden = !result.truncated;
    if (result.truncated) this.note.textContent = `Showing the first ${this.entries.length} of ${result.total} folders.`;
    this.syncActive();
  }

  renderError(error, path) {
    this.list.removeAttribute("aria-busy");
    this.entries = [];
    this.activeIndex = -1;
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "Could not list this folder");
    state.setAttribute("body", error && error.message ? error.message : "The server did not answer.");
    const retry = document.createElement("od-button");
    retry.setAttribute("size", "sm");
    retry.textContent = "Retry";
    retry.addEventListener("click", () => this.load(path));
    state.append(retry);
    this.list.replaceChildren(state);
    this.note.hidden = true;
  }

  setActive(index) {
    this.activeIndex = index;
    this.syncActive();
  }

  syncActive() {
    const rows = this.list.querySelectorAll("[role=option]");
    rows.forEach((row, index) => row.setAttribute("aria-selected", index === this.activeIndex ? "true" : "false"));
    const row = rows[this.activeIndex];
    if (row) {
      this.list.setAttribute("aria-activedescendant", row.id);
      row.scrollIntoView({ block: "nearest" });
    } else {
      this.list.removeAttribute("aria-activedescendant");
    }
  }

  enter(index) {
    const entry = this.entries[index];
    if (entry) this.load(entry.path);
  }

  goUp() {
    if (this.location && this.location.parent) this.load(this.location.parent);
  }

  choose() {
    if (!this.location) return;
    this.dispatchEvent(new CustomEvent("od-folder-pick", { bubbles: true, detail: { path: this.location.path } }));
    this.dialog.close();
  }

  onKey(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    const count = this.entries.length;
    const key = event.key;
    if (key === "ArrowDown" && count) this.setActive(Math.min(count - 1, this.activeIndex + 1));
    else if (key === "ArrowUp" && count) this.setActive(Math.max(0, this.activeIndex - 1));
    else if (key === "Home" && count) this.setActive(0);
    else if (key === "End" && count) this.setActive(count - 1);
    else if ((key === "Enter" || key === "ArrowRight") && count) this.enter(this.activeIndex);
    else if (key === "Backspace" || key === "ArrowLeft") this.goUp();
    else return;
    event.preventDefault();
  }
}

customElements.define("od-folder-picker", OdFolderPicker);

import "./od-dialog.js";
import "./od-kbd.js";
import * as keys from "../core/keys.js";

const MATRIX = [
  { keys: "Tab", description: "Enter the matrix at the last focused card" },
  { keys: "ArrowDown ArrowUp", description: "Move through the cards of a cell and on to the next row" },
  { keys: "ArrowRight ArrowLeft", description: "Move to the nearest cell in the same row" },
  { keys: "Enter", description: "Open the inspector" },
  { keys: ". Shift+F10", description: "Open the actions menu" },
  { keys: "Escape", description: "Return focus to the matrix" },
  { keys: "Alt+ArrowUp Alt+ArrowDown", description: "Move a member up or down" },
  { keys: "Alt+Home Alt+End", description: "Move a member to first or last" },
  { keys: "s", description: "Sequence a native hook" },
  { keys: "r", description: "Release a member" },
  { keys: "g", description: "Guard or unguard" },
];

const SOURCES = [
  { keys: "ArrowLeft ArrowRight Home End", description: "Move between source buttons" },
  { keys: "Space", description: "Show or hide a source" },
  { keys: "o", description: "Show only this source" },
];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function row(shortcut) {
  const line = el("div", "od-shortcut-row");
  line.append(el("span", "od-shortcut-text", shortcut.description));
  const group = el("span", "od-shortcut-keys");
  const alternatives = shortcut.keys.split(" ").filter(Boolean);
  alternatives.forEach((combo) => {
    const kbd = document.createElement("od-kbd");
    kbd.textContent = combo;
    group.append(kbd);
  });
  line.append(group);
  return line;
}

function section(title, rows) {
  const wrap = el("section", "od-shortcut-section");
  wrap.append(el("h3", "od-shortcut-title", title));
  for (const item of rows) wrap.append(row(item));
  return wrap;
}

class OdShortcuts extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    this.dialog = document.createElement("od-dialog");
    this.dialog.setAttribute("heading", "Keyboard shortcuts");
    this.dialog.setAttribute("dismissible", "");
    this.body = el("div", "od-shortcuts");
    this.dialog.append(this.body);
    this.append(this.dialog);
  }

  show(opener) {
    const groups = new Map();
    for (const entry of keys.list()) {
      if (!groups.has(entry.group)) groups.set(entry.group, []);
      groups.get(entry.group).push(entry);
    }
    const sections = [];
    for (const [name, rows] of groups) sections.push(section(name, rows));
    sections.push(section("Matrix", MATRIX));
    sections.push(section("Sources", SOURCES));
    sections.push(section("Layers", [{ keys: "Escape", description: "Close the top layer" }]));
    this.body.replaceChildren(...sections);
    this.dialog.show(opener);
  }
}

customElements.define("od-shortcuts", OdShortcuts);

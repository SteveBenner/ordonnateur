import { diffRows } from "./od-plan-sheet.js";
import { basename } from "../core/hook-detail.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

class OdDiffView extends HTMLElement {
  static observedAttributes = ["path"];

  connectedCallback() {
    if (this.rendered) return;
    this.rendered = true;
    this.render();
  }

  attributeChangedCallback() {
    if (this.rendered) this.render();
  }

  get diff() {
    return this.value === undefined ? "" : this.value;
  }

  set diff(next) {
    this.value = String(next ?? "");
    if (this.rendered) this.render();
  }

  render() {
    const path = this.getAttribute("path") || "";
    const rows = diffRows(this.diff).filter((row) => row.kind !== "meta");
    const children = [];
    if (path) children.push(el("div", "od-diff-path mono", path));
    if (!rows.length) {
      children.push(el("p", "plan-quiet", "No changes."));
      this.replaceChildren(...children);
      return;
    }
    const region = el("div", "od-diff");
    region.setAttribute("role", "region");
    region.tabIndex = 0;
    region.setAttribute("aria-label", `Changes to ${basename(path) || "the script"}`);
    for (const row of rows) {
      const line = el("span", "od-diff-line");
      line.dataset.kind = row.kind;
      line.append(el("span", "od-diff-sign", row.sign), el("span", "od-diff-text", row.text));
      region.append(line);
    }
    children.push(region);
    this.replaceChildren(...children);
  }
}

customElements.define("od-diff-view", OdDiffView);

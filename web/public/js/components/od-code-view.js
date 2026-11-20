import { lineCount } from "../core/hook-detail.js";

class OdCodeView extends HTMLElement {
  static observedAttributes = ["label"];

  connectedCallback() {
    if (this.scroller) return;
    this.scroller = document.createElement("div");
    this.scroller.className = "od-cv-scroll";
    this.scroller.setAttribute("role", "region");
    this.scroller.tabIndex = 0;
    this.gutter = document.createElement("pre");
    this.gutter.className = "od-cv-gutter";
    this.gutter.setAttribute("aria-hidden", "true");
    this.pre = document.createElement("pre");
    this.pre.className = "od-cv-code";
    this.code = document.createElement("code");
    this.pre.append(this.code);
    this.empty = document.createElement("p");
    this.empty.className = "od-cv-empty";
    this.empty.textContent = "This file is empty.";
    this.scroller.append(this.gutter, this.pre, this.empty);
    this.append(this.scroller);
    this.render();
  }

  attributeChangedCallback() {
    if (this.scroller) this.render();
  }

  get text() {
    return this.value === undefined ? "" : this.value;
  }

  set text(next) {
    this.value = String(next ?? "");
    if (this.scroller) this.render();
  }

  render() {
    const text = this.text;
    const count = lineCount(text);
    this.scroller.setAttribute("aria-label", this.getAttribute("label") || "Script text");
    this.empty.hidden = count > 0;
    this.gutter.hidden = count === 0;
    this.pre.hidden = count === 0;
    this.scroller.dataset.empty = count === 0 ? "true" : "false";
    this.style.setProperty("--digits", String(Math.max(2, String(count).length)));
    const numbers = [];
    for (let i = 1; i <= count; i += 1) numbers.push(i);
    this.gutter.textContent = numbers.join("\n");
    this.code.textContent = count ? (text.endsWith("\n") ? text.slice(0, -1) : text) : "";
  }
}

customElements.define("od-code-view", OdCodeView);

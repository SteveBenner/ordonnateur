import { lineCount } from "../core/hook-detail.js";

const NS = "http://www.w3.org/2000/svg";
let sequence = 0;

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "od-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class OdCodeEditor extends HTMLElement {
  static observedAttributes = ["label", "readonly", "disabled", "reason", "error"];

  connectedCallback() {
    if (this.input) return;
    sequence += 1;
    this.uid = `od-code-editor-${sequence}`;
    this.box = document.createElement("div");
    this.box.className = "od-box";
    this.gutter = document.createElement("pre");
    this.gutter.className = "od-ce-gutter";
    this.gutter.setAttribute("aria-hidden", "true");
    this.input = document.createElement("textarea");
    this.input.className = "od-native";
    this.input.id = `${this.uid}-input`;
    this.input.setAttribute("wrap", "off");
    this.input.setAttribute("spellcheck", "false");
    this.input.setAttribute("autocomplete", "off");
    this.input.setAttribute("autocapitalize", "off");
    this.input.setAttribute("autocorrect", "off");
    this.input.rows = 1;
    this.input.value = this.pending === undefined ? "" : this.pending;
    this.input.setSelectionRange(0, 0);
    this.box.append(this.gutter, this.input);
    this.message = document.createElement("div");
    this.message.className = "od-message";
    this.message.id = `${this.uid}-message`;
    this.append(this.box, this.message);
    this.input.addEventListener("input", () => {
      this.grow();
      this.dispatchEvent(new CustomEvent("od-input", { bubbles: true, detail: { value: this.value } }));
    });
    this.input.addEventListener("change", () => {
      this.dispatchEvent(new CustomEvent("od-change", { bubbles: true, detail: { value: this.value } }));
    });
    this.resizeObserver = new ResizeObserver(() => this.grow());
    this.resizeObserver.observe(this.input);
    this.update();
    this.grow();
  }

  disconnectedCallback() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
    this.resizeObserver = null;
  }

  attributeChangedCallback() {
    if (this.input) this.update();
  }

  get value() {
    return this.input ? this.input.value : this.pending === undefined ? "" : this.pending;
  }

  set value(next) {
    const text = String(next ?? "");
    this.pending = text;
    if (!this.input) return;
    this.input.value = text;
    this.grow();
  }

  focus(options) {
    this.input?.focus(options);
  }

  grow() {
    if (!this.input || !this.isConnected) return;
    const count = Math.max(1, lineCount(this.input.value));
    if (this.counted !== count) {
      this.counted = count;
      const numbers = [];
      for (let i = 1; i <= count; i += 1) numbers.push(i);
      this.gutter.textContent = numbers.join("\n");
      this.style.setProperty("--digits", String(Math.max(2, String(count).length)));
    }
    this.input.style.height = "auto";
    const bar = this.input.offsetHeight - this.input.clientHeight;
    this.input.style.height = `${this.input.scrollHeight + Math.max(0, bar)}px`;
  }

  update() {
    const input = this.input;
    input.setAttribute("aria-label", this.getAttribute("label") || "Script text");
    input.readOnly = this.hasAttribute("readonly");
    input.disabled = this.hasAttribute("disabled");
    const error = this.getAttribute("error") || "";
    const reason = this.hasAttribute("disabled") ? this.getAttribute("reason") || "" : "";
    this.message.textContent = "";
    if (error) {
      this.message.append(icon("deny"));
      const span = document.createElement("span");
      span.textContent = error;
      this.message.append(span);
      this.message.setAttribute("data-kind", "error");
      input.setAttribute("aria-invalid", "true");
      input.setAttribute("aria-describedby", this.message.id);
    } else {
      this.message.textContent = reason;
      this.message.removeAttribute("data-kind");
      input.removeAttribute("aria-invalid");
      if (reason) input.setAttribute("aria-describedby", this.message.id);
      else input.removeAttribute("aria-describedby");
    }
    this.message.hidden = !error && !reason;
  }
}

customElements.define("od-code-editor", OdCodeEditor);

import "./od-icon-button.js";
import "./od-button.js";

const COPIED_MS = 1500;
let sequence = 0;

class OdCopyBlock extends HTMLElement {
  static observedAttributes = ["label", "text", "mode", "clamp"];

  connectedCallback() {
    if (this.frame) return;
    sequence += 1;
    this.uid = `od-copy-block-${sequence}`;
    this.labelEl = document.createElement("div");
    this.labelEl.className = "od-cb-label";
    this.frame = document.createElement("div");
    this.frame.className = "od-cb-frame";
    this.body = document.createElement("div");
    this.body.className = "od-cb-text";
    this.body.id = `${this.uid}-text`;
    this.copyButton = document.createElement("od-icon-button");
    this.copyButton.setAttribute("icon", "copy");
    this.copyButton.setAttribute("size", "sm");
    this.copyButton.addEventListener("click", () => this.copy());
    this.frame.append(this.body, this.copyButton);
    this.more = document.createElement("od-button");
    this.more.setAttribute("variant", "ghost");
    this.more.setAttribute("size", "xs");
    this.more.setAttribute("controls", this.body.id);
    this.more.addEventListener("click", () => {
      this.expanded = !this.expanded;
      this.update();
    });
    this.live = document.createElement("span");
    this.live.className = "visually-hidden";
    this.live.setAttribute("role", "status");
    this.expanded = false;
    this.append(this.labelEl, this.frame, this.more, this.live);
    this.update();
  }

  disconnectedCallback() {
    clearTimeout(this.resetTimer);
  }

  attributeChangedCallback() {
    if (this.frame) this.update();
  }

  update() {
    const label = this.getAttribute("label") || "";
    const clamp = Number(this.getAttribute("clamp")) || 0;
    this.labelEl.textContent = label;
    this.labelEl.hidden = !label;
    this.body.textContent = this.getAttribute("text") || "";
    this.setAttribute("data-mode", this.getAttribute("mode") === "prose" ? "prose" : "mono");
    this.body.classList.toggle("mono", this.getAttribute("mode") !== "prose");
    this.body.dataset.clamped = clamp && !this.expanded ? "true" : "false";
    if (clamp && !this.expanded) this.body.title = this.getAttribute("text") || "";
    else this.body.removeAttribute("title");
    if (clamp) this.body.style.setProperty("--clamp", String(clamp));
    else this.body.style.removeProperty("--clamp");
    this.more.hidden = !clamp;
    this.more.text = this.expanded ? "Show less" : "Show all";
    this.more.setAttribute("expanded", this.expanded ? "true" : "false");
    this.copyButton.setAttribute("label", `Copy ${label.toLowerCase() || "text"}`);
  }

  async copy() {
    const text = this.getAttribute("text") || "";
    const label = this.getAttribute("label") || "Text";
    clearTimeout(this.resetTimer);
    try {
      await navigator.clipboard.writeText(text);
      this.copyButton.setAttribute("icon", "check");
      this.live.textContent = "";
      requestAnimationFrame(() => {
        this.live.textContent = `${label} copied`;
      });
      this.dispatchEvent(new CustomEvent("od-copied", { bubbles: true, detail: { text, message: "Copied" } }));
      this.resetTimer = setTimeout(() => this.copyButton.setAttribute("icon", "copy"), COPIED_MS);
    } catch (error) {
      const range = document.createRange();
      range.selectNodeContents(this.body);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      this.live.textContent = "Select and copy the text.";
      this.dispatchEvent(new CustomEvent("od-copy-failed", { bubbles: true, detail: { text, message: "Select and copy the text." } }));
    }
  }
}

customElements.define("od-copy-block", OdCopyBlock);

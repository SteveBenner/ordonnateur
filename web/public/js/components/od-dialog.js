let sequence = 0;

class OdDialog extends HTMLElement {
  static observedAttributes = ["heading", "busy"];

  connectedCallback() {
    if (this.dialog) return;
    sequence += 1;
    this.uid = `od-dialog-${sequence}`;
    const content = [...this.childNodes];
    this.dialog = document.createElement("dialog");
    this.dialog.className = "od-native";
    this.dialog.setAttribute("aria-labelledby", `${this.uid}-title`);
    const panel = document.createElement("div");
    panel.className = "od-panel";
    const header = document.createElement("header");
    header.className = "od-header";
    this.titleEl = document.createElement("h2");
    this.titleEl.id = `${this.uid}-title`;
    this.closeButton = document.createElement("od-icon-button");
    this.closeButton.setAttribute("icon", "close");
    this.closeButton.setAttribute("label", "Close");
    this.closeButton.setAttribute("size", "sm");
    header.append(this.titleEl, this.closeButton);
    this.body = document.createElement("div");
    this.body.className = "od-body";
    this.footer = document.createElement("footer");
    this.footer.className = "od-footer";
    for (const node of content) {
      if (node.nodeType === 1 && node.hasAttribute("data-dialog-footer")) this.footer.append(node);
      else this.body.append(node);
    }
    this.footer.hidden = !this.footer.childElementCount;
    panel.append(header, this.body, this.footer);
    this.dialog.append(panel);
    this.append(this.dialog);
    this.closeButton.addEventListener("click", () => this.close());
    this.dialog.addEventListener("cancel", (event) => {
      if (this.hasAttribute("busy")) event.preventDefault();
    });
    this.dialog.addEventListener("close", () => {
      this.dispatchEvent(new CustomEvent("od-close", { bubbles: true }));
      const opener = this.opener;
      this.opener = null;
      if (opener && opener.isConnected) opener.focus();
    });
    this.dialog.addEventListener("pointerdown", (event) => {
      this.pressedBackdrop = event.target === this.dialog;
    });
    this.dialog.addEventListener("click", (event) => {
      if (event.target === this.dialog && this.pressedBackdrop && !this.hasAttribute("busy") && this.hasAttribute("dismissible")) this.close();
    });
    this.update();
  }

  attributeChangedCallback() {
    if (this.dialog) this.update();
  }

  update() {
    this.titleEl.textContent = this.getAttribute("heading") || "";
    if (this.hasAttribute("busy")) this.dialog.setAttribute("aria-busy", "true");
    else this.dialog.removeAttribute("aria-busy");
  }

  get open() {
    return this.dialog ? this.dialog.open : false;
  }

  show(opener) {
    if (this.dialog.open) return;
    this.opener = opener || document.activeElement;
    document.dispatchEvent(new CustomEvent("od-overlay-open"));
    this.dialog.showModal();
    const selector = this.getAttribute("initial-focus");
    const target = selector ? this.dialog.querySelector(selector) : null;
    if (target) target.focus();
    else {
      const first = this.body.querySelector("input, textarea, button, [tabindex]:not([tabindex='-1']), a[href]");
      if (first) first.focus();
      else {
        this.titleEl.tabIndex = -1;
        this.titleEl.focus();
      }
    }
  }

  close() {
    if (this.dialog.open) this.dialog.close();
  }
}

customElements.define("od-dialog", OdDialog);

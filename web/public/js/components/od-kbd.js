const MAC = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

class OdKbd extends HTMLElement {
  connectedCallback() {
    if (this.prepared) return;
    this.prepared = true;
    this.setAttribute("translate", "no");
    const text = this.textContent.trim();
    if (/\bMod\b/.test(text)) this.textContent = text.replace(/\bMod\b/g, MAC ? "⌘" : "Ctrl");
  }
}

customElements.define("od-kbd", OdKbd);

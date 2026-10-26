const NS = "http://www.w3.org/2000/svg";

const KINDS = {
  verdict: {
    allow: { label: "Allow", icon: "allow", tone: "ok" },
    warn: { label: "Warn", icon: "warn", tone: "warn" },
    deny: { label: "Deny", icon: "deny", tone: "danger" },
  },
  status: {
    native: { label: "Native", icon: null, tone: "neutral" },
    guard: { label: "Guard", icon: "lock", tone: "neutral" },
    protected: { label: "Protected", icon: "shield", tone: "accent" },
    not_sequenceable: { label: "Not sequenceable", icon: "slash-circle", tone: "dim" },
    disabled_plugin: { label: "Disabled plugin", icon: "eye-off", tone: "faint" },
    trusted: { label: "Trusted", icon: "check", tone: "ok" },
    untrusted: { label: "Untrusted", icon: "warn", tone: "warn" },
    disabled: { label: "Disabled", icon: "slash-circle", tone: "dim" },
    stale_trust: { label: "Stale trust", icon: "warn", tone: "warn" },
    allowlisted: { label: "Allowlisted", icon: "check", tone: "ok" },
    not_allowlisted: { label: "Not allowlisted", icon: "warn", tone: "warn" },
    auto_accepted: { label: "Auto-accepted", icon: null, tone: "neutral" },
  },
  plan: {
    reorder: { label: "Reorder", icon: null, tone: "neutral" },
    change: { label: "Change", icon: null, tone: "warn" },
  },
  severity: {
    error: { label: "Error", icon: "error", tone: "danger" },
    warn: { label: "Warning", icon: "warn", tone: "warn" },
    info: { label: "Info", icon: "info", tone: "neutral" },
  },
};

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "od-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class OdChip extends HTMLElement {
  static observedAttributes = ["kind", "value", "label", "size", "icon-only"];

  connectedCallback() {
    if (this.rendered) return;
    this.rendered = true;
    this.fallbackText = this.textContent.trim();
    this.render();
  }

  attributeChangedCallback() {
    if (this.rendered) this.render();
  }

  render() {
    const kind = this.getAttribute("kind") || "tag";
    const value = this.getAttribute("value");
    const entry = KINDS[kind] && KINDS[kind][value];
    const text = this.getAttribute("label") || (entry ? entry.label : this.fallbackText);
    this.textContent = "";
    this.hidden = kind === "tag" && !text;
    this.setAttribute("data-tone", entry ? entry.tone : "neutral");
    const wrap = entry && entry.command ? document.createElement("button") : document.createElement("span");
    wrap.className = "od-chip-body";
    const iconOnly = this.hasAttribute("icon-only") && Boolean(entry);
    const glyph = entry && (entry.icon || (iconOnly ? "info" : null));
    if (glyph) wrap.append(icon(glyph));
    const label = document.createElement("span");
    label.className = "od-chip-label";
    label.textContent = text;
    wrap.append(label);
    if (iconOnly) {
      label.hidden = true;
      this.setAttribute("role", "img");
      this.setAttribute("aria-label", text);
    } else {
      this.removeAttribute("role");
      this.removeAttribute("aria-label");
    }
    if (entry && entry.command) {
      wrap.type = "button";
      wrap.classList.add("od-native");
      wrap.setAttribute("aria-label", `${text}, copy ${entry.command}`);
      wrap.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(entry.command);
          this.dispatchEvent(new CustomEvent("od-copied", { bubbles: true, detail: { text: entry.command } }));
        } catch (error) {
          this.dispatchEvent(new CustomEvent("od-copy-failed", { bubbles: true, detail: { text: entry.command } }));
        }
      });
    }
    this.append(wrap);
    if (kind === "filter") {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "od-native od-remove";
      remove.setAttribute("aria-label", `Remove filter ${text}`);
      remove.append(icon("close"));
      remove.addEventListener("click", () => {
        this.dispatchEvent(new CustomEvent("od-remove", { bubbles: true, detail: { label: text } }));
      });
      this.append(remove);
    }
  }
}

customElements.define("od-chip", OdChip);

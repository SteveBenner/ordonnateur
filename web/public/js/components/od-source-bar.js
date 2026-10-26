const SLOT = 144;
const GAP = 4;
const NARROW = "(max-width: 599px)";
const LIST_ID = "od-sources-list";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function plural(count) {
  return `${count} ${count === 1 ? "hook" : "hooks"}`;
}

class OdSourceBar extends HTMLElement {
  set providers(value) {
    this.items = Array.isArray(value) ? value : [];
    if (this.list) this.render();
  }

  get providers() {
    return this.items || [];
  }

  set off(value) {
    this.offSet = value instanceof Set ? value : new Set(value || []);
    if (this.list) this.render();
  }

  get off() {
    return this.offSet || new Set();
  }

  connectedCallback() {
    this.setAttribute("data-density", "cockpit");
    if (this.list) {
      this.watch();
      return;
    }
    this.items = this.items || [];
    this.offSet = this.offSet || new Set();
    this.expanded = false;
    this.rover = null;
    this.width = -1;
    this.group = el("div", "od-sourcebar");
    this.group.setAttribute("role", "group");
    this.group.setAttribute("aria-label", "Sources");
    this.list = el("div", "od-sourcebar-list");
    this.list.id = LIST_ID;
    this.group.append(this.list);
    this.append(this.group);
    this.addEventListener("click", (event) => this.onClick(event));
    this.addEventListener("keydown", (event) => this.onKey(event));
    this.addEventListener("focusin", (event) => this.onFocus(event));
    this.addEventListener("focusout", () => this.hot(null));
    this.addEventListener("pointerover", (event) => this.onHover(event));
    this.addEventListener("pointerleave", () => this.hot(null));
    this.watch();
    this.render();
  }

  disconnectedCallback() {
    if (this.resizer) this.resizer.disconnect();
    this.resizer = null;
  }

  watch() {
    if (this.resizer || typeof ResizeObserver !== "function") return;
    this.resizer = new ResizeObserver(() => {
      const width = Math.round(this.group.getBoundingClientRect().width);
      if (width === this.width) return;
      this.render();
    });
    this.resizer.observe(this.group);
  }

  buttons() {
    return [...this.list.querySelectorAll(".od-src-btn")].filter((node) => !node.hidden);
  }

  capacity() {
    const narrow = window.matchMedia(NARROW).matches;
    const width = Math.round(this.group.getBoundingClientRect().width);
    this.width = width;
    if (narrow) return { cap: 2, rows: 3 };
    if (!width) return { cap: 1000, rows: 2 };
    return { cap: Math.max(1, Math.floor((width + GAP) / (SLOT + GAP))), rows: 2 };
  }

  render() {
    if (!this.list) return;
    if (typeof ResizeObserver === "function") {
      const measured = Math.round(this.group.getBoundingClientRect().width);
      if (!measured) {
        this.width = 0;
        return;
      }
    }
    const active = document.activeElement;
    let refocus = null;
    if (active && this.contains(active)) {
      if (active.classList.contains("od-src-btn")) refocus = { key: active.dataset.key };
      else if (active.classList.contains("od-src-all")) refocus = { cls: "od-src-all" };
      else if (active.classList.contains("od-src-none")) refocus = { cls: "od-src-none" };
      else if (active.classList.contains("od-src-more")) refocus = { cls: "od-src-more" };
    }
    const providers = this.items;
    const off = this.offSet;
    const anyOff = providers.some((item) => off.has(item.key));
    const { cap, rows } = this.capacity();
    const slots = cap * rows;
    const anyOn = providers.some((item) => !off.has(item.key));
    const extra = (anyOff ? 1 : 0) + (anyOn ? 1 : 0);
    const fits = providers.length + extra <= slots;
    const shown = fits || this.expanded ? providers.length : Math.max(1, slots - 1 - extra);
    const nodes = [];
    providers.forEach((item, index) => {
      const button = this.button(item, !off.has(item.key));
      if (index >= shown) button.hidden = true;
      nodes.push(button);
    });
    if (anyOff) {
      const all = el("button", "od-src-all", "Show all");
      all.type = "button";
      nodes.push(all);
    }
    if (anyOn) {
      const none = el("button", "od-src-none", "Hide all");
      none.type = "button";
      nodes.push(none);
    }
    if (!fits) {
      const more = el("button", "od-src-more");
      more.type = "button";
      more.setAttribute("aria-expanded", this.expanded ? "true" : "false");
      more.setAttribute("aria-controls", LIST_ID);
      if (this.expanded) {
        more.textContent = "Show fewer";
      } else {
        const rest = providers.slice(shown);
        const hiddenOff = rest.filter((item) => off.has(item.key)).length;
        more.textContent = `+${rest.length} more${hiddenOff ? `, ${hiddenOff} off` : ""}`;
      }
      nodes.push(more);
    }
    this.list.replaceChildren(...nodes);
    if (this.hotKey && !this.buttons().some((node) => node.dataset.key === this.hotKey)) this.hot(null);
    this.rove();
    if (refocus) {
      const target = refocus.key
        ? this.buttons().find((node) => node.dataset.key === refocus.key)
        : this.list.querySelector(`.${refocus.cls}`);
      if (target) target.focus({ preventScroll: true });
    }
  }

  button(item, on) {
    const button = el("button", "od-src-btn");
    button.type = "button";
    button.setAttribute("aria-pressed", on ? "true" : "false");
    button.dataset.key = item.key;
    button.dataset.src = String(item.color);
    button.dataset.shape = item.shape;
    button.tabIndex = -1;
    button.setAttribute("aria-label", `${item.label}, ${plural(item.count)}`);
    button.title = item.kind === "plugin" ? item.row.slice(7) : `${item.label}. Alt-click shows only this source.`;
    const dot = el("span", "od-src-dot");
    dot.setAttribute("aria-hidden", "true");
    dot.dataset.src = String(item.color);
    dot.dataset.shape = item.shape;
    if (!on) dot.dataset.off = "";
    button.append(dot, el("span", "od-src-label", item.short), el("span", "od-src-count", String(item.count)));
    return button;
  }

  rove() {
    const buttons = this.buttons();
    const target = buttons.find((node) => node.dataset.key === this.rover) || buttons[0];
    for (const node of this.list.querySelectorAll(".od-src-btn")) node.tabIndex = node === target ? 0 : -1;
  }

  focusKey(key) {
    const target = this.buttons().find((node) => node.dataset.key === key);
    if (target) target.focus({ preventScroll: true });
    return Boolean(target);
  }

  hot(key) {
    const next = key || null;
    if (next === (this.hotKey || null)) return;
    this.hotKey = next;
    this.emit("od-sources-hover", { key: next });
  }

  onHover(event) {
    const button = event.target.closest ? event.target.closest(".od-src-btn") : null;
    this.hot(button && this.list.contains(button) ? button.dataset.key : null);
  }

  emit(name, detail) {
    this.dispatchEvent(new CustomEvent(name, { bubbles: true, detail }));
  }

  onClick(event) {
    const target = event.target.closest ? event.target.closest("button") : null;
    if (!target || !this.list.contains(target)) return;
    if (target.classList.contains("od-src-btn")) {
      this.rover = target.dataset.key;
      this.emit(event.altKey ? "od-sources-only" : "od-sources-toggle", { key: target.dataset.key });
    } else if (target.classList.contains("od-src-all")) {
      this.emit("od-sources-all");
    } else if (target.classList.contains("od-src-none")) {
      this.emit("od-sources-none");
    } else if (target.classList.contains("od-src-more")) {
      this.expanded = !this.expanded;
      this.render();
    }
  }

  onFocus(event) {
    const target = event.target;
    if (!target.classList || !target.classList.contains("od-src-btn")) return;
    this.rover = target.dataset.key;
    this.rove();
    this.hot(target.dataset.key);
  }

  onKey(event) {
    const target = event.target;
    if (!target.classList || !target.classList.contains("od-src-btn")) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === "o" && !event.shiftKey) {
      event.preventDefault();
      this.emit("od-sources-only", { key: target.dataset.key });
      return;
    }
    const buttons = this.buttons();
    const index = buttons.indexOf(target);
    if (index < 0) return;
    let next = -1;
    if (event.key === "ArrowRight") next = (index + 1) % buttons.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + buttons.length) % buttons.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = buttons.length - 1;
    if (next < 0) return;
    event.preventDefault();
    buttons[next].focus();
  }
}

customElements.define("od-source-bar", OdSourceBar);

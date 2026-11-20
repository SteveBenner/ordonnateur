import "./od-tooltip.js";
import { app, readOnly, READ_ONLY_REASON } from "../core/store.js";

const HOLD_MS = 3000;
const ASSISTIVE_GAP_MS = 50;
const CANCELLED_HINT_MS = 3000;
const NS = "http://www.w3.org/2000/svg";
const RADIUS = 8;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;
const IDLE_HINT = "Press and hold for 3 seconds";

let sequence = 0;

function svg(tag, attrs) {
  const node = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
  return node;
}

function reduced() {
  try {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch (error) {
    return false;
  }
}

class OdHoldButton extends HTMLElement {
  static observedAttributes = ["label", "busy-label", "variant", "disabled", "reason", "write", "busy"];

  connectedCallback() {
    if (this.button) {
      this.watch();
      this.update();
      return;
    }
    sequence += 1;
    this.uid = `od-hold-${sequence}`;
    this.state = "idle";
    this.method = null;
    this.startKey = null;
    this.startedAt = 0;
    this.lastStart = -Infinity;
    this.timeoutId = 0;
    this.frameId = 0;
    this.hintTimer = 0;
    this.cancelledHint = false;
    this.button = document.createElement("button");
    this.button.type = "button";
    this.button.className = "od-native";
    this.button.id = `${this.uid}-button`;
    this.ring = svg("svg", { class: "od-hb-ring", viewBox: "0 0 20 20", "aria-hidden": "true" });
    this.track = svg("circle", { class: "od-hb-track", cx: "10", cy: "10", r: String(RADIUS), fill: "none" });
    this.arc = svg("circle", { class: "od-hb-arc", cx: "10", cy: "10", r: String(RADIUS), fill: "none", transform: "rotate(-90 10 10)" });
    this.arc.style.strokeDasharray = String(CIRCUMFERENCE);
    this.arc.style.strokeDashoffset = String(CIRCUMFERENCE);
    this.ring.append(this.track, this.arc);
    this.textNode = document.createElement("span");
    this.textNode.className = "od-text";
    this.count = document.createElement("span");
    this.count.className = "od-count";
    this.button.append(this.ring, this.textNode, this.count);
    this.hint = document.createElement("div");
    this.hint.className = "od-hb-hint";
    this.hint.id = `${this.uid}-hint`;
    this.live = document.createElement("span");
    this.live.className = "visually-hidden";
    this.live.setAttribute("role", "status");
    this.tooltip = document.createElement("od-tooltip");
    this.tooltip.setAttribute("for", this.button.id);
    this.button.setAttribute("aria-describedby", this.hint.id);
    this.append(this.button, this.hint, this.live, this.tooltip);
    this.bind();
    this.watch();
    this.update();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    if (this.state === "holding" || this.state === "committing") this.cancel("disconnect");
    clearTimeout(this.hintTimer);
  }

  attributeChangedCallback() {
    if (this.button) this.update();
  }

  watch() {
    if (this.unsubscribe) return;
    this.unsubscribe = app.subscribe(() => {
      if (this.hasAttribute("write")) this.update();
    });
  }

  get holding() {
    return this.state === "holding";
  }

  blocked() {
    return this.hasAttribute("disabled") || this.hasAttribute("busy") || (this.hasAttribute("write") && readOnly());
  }

  focus(options) {
    this.button?.focus(options);
  }

  bind() {
    const button = this.button;
    button.addEventListener("pointerdown", (event) => {
      if (!event.isPrimary || event.button !== 0) return;
      if (this.blocked() || this.state !== "idle") return;
      const method = event.pointerType === "touch" ? "touch" : event.pointerType === "pen" ? "pen" : "pointer";
      this.begin(method);
    });
    button.addEventListener("pointermove", (event) => {
      if (this.state !== "holding" || !event.isPrimary) return;
      const rect = button.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) this.cancel("leave");
    });
    button.addEventListener("pointerleave", (event) => {
      if (this.state === "holding" && event.pointerType === "mouse") this.cancel("leave");
    });
    button.addEventListener("pointercancel", () => this.cancel("pointercancel"));
    button.addEventListener("lostpointercapture", () => this.cancel("pointercancel"));
    button.addEventListener("contextmenu", (event) => event.preventDefault());
    button.addEventListener("keydown", (event) => {
      if (event.key !== " " && event.key !== "Enter") return;
      event.preventDefault();
      if (event.repeat) return;
      if (this.blocked() || this.state !== "idle") return;
      this.startKey = event.key;
      this.begin("keyboard");
    });
    button.addEventListener("keyup", (event) => {
      if (event.key !== " " && event.key !== "Enter") return;
      event.preventDefault();
      if (this.state === "holding" && this.method === "keyboard" && event.key === this.startKey) this.cancel("release");
    });
    button.addEventListener("blur", () => {
      if (this.state === "holding") this.cancel("blur");
    });
    button.addEventListener(
      "click",
      (event) => {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (event.detail !== 0) return;
        if (performance.now() - this.lastStart < ASSISTIVE_GAP_MS) return;
        if (this.blocked()) return;
        if (this.state === "holding" && this.method === "assistive") {
          this.cancel("toggle");
          return;
        }
        if (this.state === "idle") this.begin("assistive");
      },
      true,
    );
    this.onWindowPointerUp = () => {
      if (this.state === "holding" && this.method !== "keyboard" && this.method !== "assistive") this.cancel("release");
    };
    this.onWindowKey = (event) => {
      if (event.key !== "Escape" || (this.state !== "holding" && this.state !== "committing")) return;
      if (this.state === "committing") return;
      event.preventDefault();
      event.stopPropagation();
      this.cancel("escape");
    };
    this.onWindowBlur = () => {
      if (this.state === "holding") this.cancel("blur");
    };
    this.onVisibility = () => {
      if (document.visibilityState === "hidden" && this.state === "holding") this.cancel("visibility");
    };
  }

  listen(on) {
    const act = on ? "addEventListener" : "removeEventListener";
    window[act]("pointerup", this.onWindowPointerUp, true);
    window[act]("keydown", this.onWindowKey, true);
    window[act]("blur", this.onWindowBlur);
    document[act]("visibilitychange", this.onVisibility);
  }

  begin(method) {
    clearTimeout(this.hintTimer);
    this.cancelledHint = false;
    this.state = "holding";
    this.method = method;
    this.lastStart = performance.now();
    this.startedAt = this.lastStart;
    this.stepped = reduced();
    this.lastShown = -1;
    this.listen(true);
    this.update();
    this.announceLive("Holding. Keep holding for 3 seconds.");
    this.dispatchEvent(new CustomEvent("od-hold-start", { bubbles: true, detail: { method } }));
    this.timeoutId = window.setTimeout(() => this.complete(), HOLD_MS);
    this.draw();
  }

  draw() {
    cancelAnimationFrame(this.frameId);
    if (this.state !== "holding") return;
    const elapsed = Math.min(HOLD_MS, performance.now() - this.startedAt);
    let fraction = elapsed / HOLD_MS;
    let seconds = (HOLD_MS - elapsed) / 1000;
    if (this.stepped) {
      fraction = Math.floor(elapsed / 1000) / 3;
      seconds = Math.ceil((HOLD_MS - elapsed) / 1000);
    }
    this.arc.style.strokeDashoffset = String(CIRCUMFERENCE * (1 - fraction));
    const shown = this.stepped ? `${seconds} s` : `${seconds.toFixed(1)} s`;
    if (shown !== this.lastShown) {
      this.lastShown = shown;
      this.count.textContent = shown;
    }
    this.frameId = requestAnimationFrame(() => this.draw());
  }

  stop() {
    clearTimeout(this.timeoutId);
    cancelAnimationFrame(this.frameId);
    this.timeoutId = 0;
    this.frameId = 0;
    this.listen(false);
  }

  complete() {
    if (this.state !== "holding") return;
    this.stop();
    this.state = "committing";
    this.arc.style.strokeDashoffset = "0";
    this.count.textContent = "";
    this.update();
    this.announceLive("Held for 3 seconds. Saving.");
    this.dispatchEvent(
      new CustomEvent("od-hold-complete", { bubbles: true, detail: { method: this.method, startedAt: this.startedAt, completedAt: performance.now() } }),
    );
  }

  cancel(cause) {
    if (this.state === "idle") return;
    if (this.state === "committing" && cause !== "host" && cause !== "disconnect") return;
    const elapsed = this.state === "holding" ? performance.now() - this.startedAt : HOLD_MS;
    const wasHolding = this.state === "holding";
    this.stop();
    this.state = "idle";
    this.method = null;
    this.startKey = null;
    this.arc.style.strokeDashoffset = String(CIRCUMFERENCE);
    this.count.textContent = "";
    if (wasHolding && cause !== "host" && cause !== "disconnect") {
      this.cancelledHint = true;
      clearTimeout(this.hintTimer);
      this.hintTimer = window.setTimeout(() => {
        this.cancelledHint = false;
        this.update();
      }, CANCELLED_HINT_MS);
      this.announceLive("Released early. Nothing was changed.");
    }
    this.update();
    this.dispatchEvent(new CustomEvent("od-hold-cancel", { bubbles: true, detail: { cause, elapsed } }));
  }

  finish() {
    if (this.state !== "committing") return;
    this.state = "idle";
    this.method = null;
    this.startKey = null;
    this.arc.style.strokeDashoffset = String(CIRCUMFERENCE);
    this.update();
  }

  announceLive(text) {
    this.live.textContent = "";
    requestAnimationFrame(() => {
      this.live.textContent = text;
    });
  }

  update() {
    const label = this.getAttribute("label") || "Hold";
    const locked = this.hasAttribute("write") && readOnly();
    const disabled = this.hasAttribute("disabled") || locked;
    const busy = this.hasAttribute("busy");
    const committing = this.state === "committing" || busy;
    this.textNode.textContent = committing ? this.getAttribute("busy-label") || label : label;
    this.button.setAttribute("aria-label", label);
    this.dataset.state = committing ? "committing" : this.state;
    if (disabled || busy) this.button.setAttribute("aria-disabled", "true");
    else this.button.removeAttribute("aria-disabled");
    if (committing) this.button.setAttribute("aria-busy", "true");
    else this.button.removeAttribute("aria-busy");
    const reason = locked ? READ_ONLY_REASON : this.getAttribute("reason") || "";
    let hint = IDLE_HINT;
    if (disabled) hint = reason || "Not available";
    else if (this.state === "holding") hint = "Keep holding";
    else if (committing) hint = "";
    else if (this.cancelledHint) hint = "Released early. Nothing was changed.";
    this.hint.textContent = hint;
    if (disabled && reason) this.tooltip.setAttribute("text", reason);
    else this.tooltip.removeAttribute("text");
    if (this.state === "idle" && !busy) this.arc.style.strokeDashoffset = String(CIRCUMFERENCE);
    if (committing) this.arc.style.strokeDashoffset = "0";
  }
}

customElements.define("od-hold-button", OdHoldButton);

import { runs, activeRun, latestRun, elapsedSeconds, clock, clockTime, attach } from "../core/runs.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

class OdRunStatus extends HTMLElement {
  static observedAttributes = ["verb"];

  connectedCallback() {
    if (this.line) {
      this.watch();
      this.render();
      return;
    }
    this.setAttribute("role", "status");
    this.setAttribute("aria-atomic", "true");
    this.line = el("span", "od-run-line");
    this.append(this.line);
    this.watch();
    attach();
    this.render();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    window.clearInterval(this.tick);
    this.tick = 0;
  }

  attributeChangedCallback() {
    if (this.line) this.render();
  }

  watch() {
    if (this.unsubscribe) return;
    this.unsubscribe = runs.subscribe(() => this.render());
  }

  render() {
    const active = activeRun();
    this.line.textContent = "";
    this.removeAttribute("data-state");
    window.clearInterval(this.tick);
    this.tick = 0;
    if (active) {
      this.dataset.state = "running";
      this.line.append(document.createTextNode(`Running ${active.verb}, `));
      const elapsed = el("span", "od-run-elapsed num", clock(elapsedSeconds(active)));
      elapsed.setAttribute("aria-hidden", "true");
      this.line.append(elapsed, document.createTextNode(". A model call can take a few minutes."));
      this.tick = window.setInterval(() => {
        elapsed.textContent = clock(elapsedSeconds(activeRun() || active));
      }, 1000);
      return;
    }
    const verb = this.getAttribute("verb");
    const last = latestRun(verb || undefined);
    if (!last) {
      this.line.textContent = "No run yet.";
      return;
    }
    if (last.status === "failed") {
      this.dataset.state = "failed";
      this.line.textContent = `The ${last.verb} run failed: ${last.error || "no reason was given"}`;
      return;
    }
    const when = clockTime(last.finished_at || last.started_at);
    this.line.textContent = when ? `Last run at ${when}.` : "Last run finished.";
  }
}

customElements.define("od-run-status", OdRunStatus);

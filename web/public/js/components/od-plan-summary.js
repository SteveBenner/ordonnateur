import "./od-chip.js";
import "./od-digest.js";
import "./od-banner.js";
import "./od-diff-view.js";
import { blockedText, diffRows } from "./od-plan-sheet.js";
import { program } from "../core/hooks.js";
import { basename, plural } from "../core/hook-detail.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function section(label) {
  const node = el("section", "plan-section");
  node.append(el("h3", "plan-label", label));
  return node;
}

class OdPlanSummary extends HTMLElement {
  connectedCallback() {
    if (this.ready) return;
    this.ready = true;
    this.model = { ...{ plan: null, hook: null, kind: "script_edit", override: null }, ...(this.model || {}) };
    this.render();
  }

  set data(next) {
    this.model = { ...this.model, ...next };
    if (this.ready) this.render();
  }

  get data() {
    return this.model;
  }

  changedLines(plan) {
    let total = 0;
    for (const file of plan.files || []) {
      total += diffRows(file.diff).filter((row) => row.kind === "add" || row.kind === "del").length;
    }
    return total;
  }

  result(plan, hook, kind) {
    const node = section("Result");
    const file = basename((plan.files && plan.files[0] && plan.files[0].path) || hook.source_file || "");
    if (kind === "delete") {
      node.append(el("p", "plan-effect", `Removes ${program(hook).base} from ${basename(hook.source_file || file)}.`));
      const orders = Array.isArray(plan.orders) ? plan.orders : [];
      const notes = Array.isArray(plan.notes) ? plan.notes.join(" ") : String(plan.notes || "");
      const released = orders.some((order) => order.event === hook.event && Array.isArray(order.after) && order.after.length === 0) || /released/i.test(notes);
      if (released) node.append(el("p", "plan-quiet", `The sequence for ${hook.event} is released.`));
      return node;
    }
    node.append(el("p", "plan-effect", `Changes ${plural(this.changedLines(plan), "line", "lines")} in ${file}.`));
    return node;
  }

  policy(plan) {
    const node = section("Policy");
    const verdicts = plan.verdicts || [];
    if (!verdicts.length) {
      node.append(el("p", "plan-quiet", "No policy verdicts."));
      return node;
    }
    const detailed = verdicts.some((row) => row.rule_id || row.reason);
    const table = el("table", "plan-table");
    table.dataset.detailed = detailed ? "true" : "false";
    const labels = detailed ? ["File", "Verdict", "Rule", "Reason"] : ["File", "Verdict"];
    const group = el("colgroup");
    for (const label of labels) group.append(el("col", `plan-col-${label.toLowerCase()}`));
    table.append(group);
    const head = el("tr");
    for (const label of labels) {
      const th = el("th", "", label);
      th.scope = "col";
      head.append(th);
    }
    const thead = el("thead");
    thead.append(head);
    table.append(thead);
    const body = el("tbody");
    for (const row of verdicts) {
      const tr = el("tr");
      const file = el("td", "plan-cell-path mono");
      String(row.path || "")
        .split("/")
        .forEach((part, index) => {
          if (index) file.append("/", document.createElement("wbr"));
          file.append(part);
        });
      const verdict = el("td", "plan-cell-verdict");
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "verdict");
      chip.setAttribute("value", row.verdict);
      verdict.append(chip);
      tr.append(file, verdict);
      if (detailed) tr.append(el("td", "mono", row.rule_id || ""), el("td", "", row.reason || ""));
      body.append(tr);
    }
    table.append(body);
    node.append(table);
    return node;
  }

  lint(plan) {
    const lint = plan.lint || {};
    const added = lint.added || [];
    const resolved = lint.resolved || [];
    if (!added.length && !resolved.length) return null;
    const node = section("Lint");
    node.append(el("p", "plan-lint-summary", `${plural(added.length, "new finding", "new findings")}, ${resolved.length} resolved`));
    const after = new Map((lint.after || []).map((item) => [item.id, item]));
    const before = new Map((lint.before || []).map((item) => [item.id, item]));
    const list = el("ul", "plan-findings");
    const push = (sign, finding) => {
      if (!finding) return;
      const item = el("li", "plan-finding");
      item.dataset.kind = sign === "+" ? "add" : "del";
      item.append(el("span", "plan-sign", sign === "+" ? "New" : "Resolved"));
      const chip = document.createElement("od-chip");
      chip.setAttribute("kind", "severity");
      chip.setAttribute("value", finding.severity);
      item.append(chip, el("code", "plan-code mono", finding.code), el("span", "plan-message", finding.message));
      list.append(item);
    };
    for (const id of added) push("+", after.get(id));
    for (const id of resolved) push("-", before.get(id));
    if (list.childElementCount) node.append(list);
    return node;
  }

  changes(plan) {
    const files = (plan.files || []).filter((file) => file.changes);
    if (!files.length) return null;
    const node = section("Changes");
    for (const file of files) {
      const view = document.createElement("od-diff-view");
      view.setAttribute("path", file.path);
      view.diff = file.diff;
      node.append(view);
    }
    return node;
  }

  effect(plan) {
    const notes = Array.isArray(plan.notes) ? plan.notes : plan.notes ? [plan.notes] : [];
    if (!plan.effects_text && !notes.length) return null;
    const node = section("Effect");
    if (plan.effects_text) node.append(el("p", "plan-effect", plan.effects_text));
    for (const note of notes) if (String(note) !== plan.effects_text) node.append(el("p", "plan-quiet", String(note)));
    return node;
  }

  blocked(plan, override) {
    const reason = override ? override.code : plan.blocked_reason;
    if (!reason) return null;
    const banner = document.createElement("od-banner");
    banner.setAttribute("severity", reason === "policy_deny" ? "danger" : reason === "policy_warn" ? "warn" : "info");
    banner.classList.add("od-ps-blocked");
    const text = blockedText({ ...plan, verdicts: plan.verdicts || [] }, override);
    banner.setAttribute("text", reason === "policy_warn" ? `${text} Use the commands above in a terminal.` : text);
    return banner;
  }

  render() {
    const { plan, hook, kind, override } = this.model;
    if (!plan || !hook) {
      this.replaceChildren();
      return;
    }
    const head = el("div", "od-ps-head");
    const digest = document.createElement("od-digest");
    digest.setAttribute("value", plan.plan_id);
    digest.setAttribute("kind", "plan id");
    digest.setAttribute("length", String(String(plan.plan_id).length));
    const chip = document.createElement("od-chip");
    chip.setAttribute("kind", "plan");
    chip.setAttribute("value", kind);
    head.append(digest, chip);
    const heading = el("h3", "od-ps-title", kind === "delete" ? "Deletion plan" : "Plan for the script");
    heading.tabIndex = -1;
    this.heading = heading;
    const parts = [heading, head];
    const banner = this.blocked(plan, override);
    if (banner) parts.push(banner);
    parts.push(this.result(plan, hook, kind), this.policy(plan));
    for (const extra of [this.lint(plan), this.changes(plan), this.effect(plan)]) if (extra) parts.push(extra);
    this.replaceChildren(...parts);
  }
}

customElements.define("od-plan-summary", OdPlanSummary);

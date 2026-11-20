import "./od-command.js";
import "./od-copy-block.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

class OdAiHandoff extends HTMLElement {
  connectedCallback() {
    if (this.ready) return;
    this.ready = true;
    this.model = { ...{ ai: null, name: "", editOn: true }, ...(this.model || {}) };
    this.render();
  }

  set data(next) {
    this.model = { ...this.model, ...next };
    if (this.ready) this.render();
  }

  get data() {
    return this.model;
  }

  command(text, who) {
    const node = document.createElement("od-command");
    node.setAttribute("command", text || "");
    node.setAttribute("who", who);
    return node;
  }

  render() {
    const { ai, editOn } = this.model;
    const cli = (ai && ai.cli) || {};
    const heading = el("h3", "od-insp-label", "Let a model do this");
    heading.id = `${this.id || "od-ai"}-heading`;
    const intro = el(
      "p",
      "od-ah-intro",
      "A model reads the whole script and every other hook that runs it, checks the lint findings, and shows you the same diff and policy verdict before anything is written. A hand edit sees only what is on your screen.",
    );
    const terminal = el("div", "od-ah-col");
    terminal.append(el("div", "od-ah-label", "In a terminal"));
    if (!editOn) terminal.append(el("p", "od-ah-note", "The edit and delete commands need web.hook_edit on too."));
    terminal.append(
      this.command(cli.show, "See the hook and script."),
      this.command(cli.edit, "Edit the script. Prints the plan; writes only with --apply and your plan id."),
      this.command(cli.delete, "Delete the hook. Same rules."),
    );
    const agent = el("div", "od-ah-col");
    agent.append(el("div", "od-ah-label", "With your agent"));
    const skill = document.createElement("od-copy-block");
    skill.setAttribute("label", "Skill");
    skill.setAttribute("text", (ai && ai.skill) || "");
    skill.setAttribute("mode", "mono");
    const prompt = document.createElement("od-copy-block");
    prompt.setAttribute("label", "Prompt");
    prompt.setAttribute("text", (ai && ai.prompt) || "");
    prompt.setAttribute("mode", "prose");
    prompt.setAttribute("clamp", "6");
    agent.append(skill, prompt);
    const cols = el("div", "od-ah-cols");
    cols.append(terminal, agent);
    this.setAttribute("aria-labelledby", heading.id);
    this.setAttribute("role", "group");
    this.replaceChildren(heading, intro, cols);
  }
}

customElements.define("od-ai-handoff", OdAiHandoff);

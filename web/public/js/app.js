import "./components/od-app-shell.js";
import "./components/od-session-gate.js";
import "./components/od-inspector.js";
import "./components/od-tray.js";
import "./components/od-plan-sheet.js";
import "./core/theme.js";
import { app } from "./core/store.js";
import { bootSession, watchLinks } from "./core/session.js";
import * as keys from "./core/keys.js";
import * as layoutView from "./views/layout.js";

const GATE_STATES = ["exchanging", "link_used_or_expired", "no_session", "session_ended", "server_unreachable"];

let shell = null;
let gateHost = null;

function openShell() {
  if (shell) return;
  shell = document.createElement("od-app-shell");
  shell.registerView(layoutView);
  document.body.insertBefore(shell, document.getElementById("live-polite"));
}

function closeShell() {
  if (!shell) return;
  shell.remove();
  shell = null;
}

function showGate(state) {
  hideGate();
  gateHost = document.createElement("div");
  gateHost.id = "gate";
  const gate = document.createElement("od-session-gate");
  gate.setAttribute("state", state);
  gateHost.append(gate);
  closeShell();
  document.body.insertBefore(gateHost, document.getElementById("live-polite"));
  const heading = gateHost.querySelector("h1");
  if (heading) heading.focus();
}

function hideGate() {
  if (gateHost) gateHost.remove();
  gateHost = null;
}

function onState(state) {
  document.documentElement.toggleAttribute("data-offline", state.offline);
  if (state.session === "active") {
    hideGate();
    openShell();
    return;
  }
  if (GATE_STATES.includes(state.session)) showGate(state.session);
}

keys.start();
app.subscribe(onState);
watchLinks();
bootSession();

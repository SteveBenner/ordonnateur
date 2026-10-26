import { get, post, endpoints } from "./api.js";
import * as draft from "./draft.js";

export function planRequest(scope, project) {
  const hermes = draft.isHermesScope(scope);
  return {
    scope: hermes ? "user" : scope,
    project: hermes ? null : project || null,
    base: draft.baseOf(scope, project),
    changes: draft.changes(scope, project),
  };
}

export function createPlan(request, options) {
  return post(endpoints.plans, request, options);
}

export function fetchPlan(id, options) {
  return get(endpoints.plan(id), options);
}

export function applyPlan(id, confirm, options) {
  return post(endpoints.apply(id), confirm ? { confirm } : {}, options);
}

export function shell() {
  return document.querySelector("od-app-shell");
}

export function scopeLabel(scope) {
  if (draft.isHermesScope(scope)) return "Hermes config";
  if (scope === "local") return "Local settings";
  if (scope === "user") return "User settings";
  return scope;
}

export function changeCount(count) {
  return `${count} ${count === 1 ? "change" : "changes"}`;
}

import { announce } from "./announce.js";
import { agOrderable, agWritable, draftScopes, hermesEvents, isDispatcher, isHermes, isMember, isPinned, memberPosition } from "./hooks.js";

const PREFIX = "ordonnateur.web.draft.";
const SCOPES = ["user", "local"];
export const HERMES_SCOPE = "hermes.user";
const ALL_SCOPES = [...SCOPES, HERMES_SCOPE];
const AG_PREFIX = "antigravity.";

export function isHermesScope(scope) {
  return scope === HERMES_SCOPE;
}

export function isAntigravityScope(scope) {
  return typeof scope === "string" && scope.startsWith(AG_PREFIX);
}

export function antigravityScope(kind, path) {
  return `${AG_PREFIX}${kind}.${path}`;
}

export function parseAntigravityScope(scope) {
  const rest = String(scope).slice(AG_PREFIX.length);
  const at = rest.indexOf(".");
  return { kind: rest.slice(0, at), path: rest.slice(at + 1) };
}

export function antigravityScopes(project) {
  return draftScopes(project).filter(isAntigravityScope);
}

export function draftKey(scope, project) {
  return `${PREFIX}${scope}.${project || "none"}`;
}

function area() {
  try {
    return window.sessionStorage;
  } catch (error) {
    return null;
  }
}

function blank(base) {
  return { base: base || null, events: {}, guards: {} };
}

function size(draft) {
  return Object.keys(draft.events).length + Object.keys(draft.guards).length;
}

function sameList(a, b) {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

export function load(scope, project) {
  const storage = area();
  if (!storage) return null;
  try {
    const raw = storage.getItem(draftKey(scope, project));
    if (raw === null) return null;
    const data = JSON.parse(raw);
    if (!data || typeof data !== "object") return null;
    return { base: data.base || null, events: data.events || {}, guards: data.guards || {} };
  } catch (error) {
    return null;
  }
}

export function count(scope, project) {
  const draft = load(scope, project);
  return draft ? size(draft) : 0;
}

export function baseOf(scope, project) {
  const draft = load(scope, project);
  return draft ? draft.base : null;
}

function notify(scope, project) {
  document.dispatchEvent(new CustomEvent("od-draft-change", { detail: { scope, project: project || null, count: count(scope, project) } }));
}

function store(scope, project, draft) {
  const storage = area();
  if (!storage) return;
  try {
    if (size(draft) === 0) storage.removeItem(draftKey(scope, project));
    else storage.setItem(draftKey(scope, project), JSON.stringify(draft));
  } catch (error) {
    return;
  }
  notify(scope, project);
}

export function setHermesOrder(project, base, event, ids, original) {
  const draft = load(HERMES_SCOPE, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  const previous = draft.events[event];
  const first = previous && Array.isArray(previous.original) ? previous.original : original || [];
  if (sameList(ids, first)) delete draft.events[event];
  else draft.events[event] = { op: "order", hooks: ids.slice(), original: first.slice() };
  store(HERMES_SCOPE, project, draft);
}

export function setAgOrder(scope, project, base, event, ids, original, mode, spec) {
  const draft = load(scope, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  if (sameList(ids, original || [])) delete draft.events[event];
  else draft.events[event] = { op: "order", mode, spec: spec || null, hooks: ids.slice(), original: (original || []).slice() };
  store(scope, project, draft);
}

export function setAgRelease(scope, project, base, event, original) {
  const draft = load(scope, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  if (!(original || []).length) delete draft.events[event];
  else draft.events[event] = { op: "release", mode: "members", spec: null, original: original.slice() };
  store(scope, project, draft);
}

export function setOrder(scope, project, base, event, ids, stopOnBlock = null, original, originalStop) {
  const draft = load(scope, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  const previous = draft.events[event];
  const first = previous && Array.isArray(previous.original) ? previous.original : original || [];
  const originalFlag = previous && "original_stop_on_block" in previous ? previous.original_stop_on_block : originalStop === undefined ? null : originalStop;
  let stop = stopOnBlock;
  if (stop === null && previous && previous.op === "order" && previous.stop_on_block !== undefined) stop = previous.stop_on_block;
  const list = ids.slice();
  if (list.length === 0) {
    if (first.length === 0) delete draft.events[event];
    else draft.events[event] = { op: "release", original: first.slice() };
  } else if (sameList(list, first) && (stop === null || stop === originalFlag)) {
    delete draft.events[event];
  } else {
    draft.events[event] = { op: "order", hooks: list, stop_on_block: stop, original: first.slice(), original_stop_on_block: originalFlag };
  }
  store(scope, project, draft);
}

export function release(scope, project, base, event, original) {
  const draft = load(scope, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  const previous = draft.events[event];
  const first = previous && Array.isArray(previous.original) ? previous.original : original || [];
  if (first.length === 0) delete draft.events[event];
  else draft.events[event] = { op: "release", original: first.slice() };
  store(scope, project, draft);
}

export function setGuard(scope, project, base, hookId, wantGuard) {
  const draft = load(scope, project) || blank(base);
  if (!draft.base) draft.base = base || null;
  const next = wantGuard ? "guard" : "unguard";
  const previous = draft.guards[hookId];
  if (previous && previous !== next) delete draft.guards[hookId];
  else draft.guards[hookId] = next;
  store(scope, project, draft);
}

export function discard(scope, project) {
  const storage = area();
  if (storage) {
    try {
      storage.removeItem(draftKey(scope, project));
    } catch (error) {
      return;
    }
  }
  notify(scope, project);
}

export function changes(scope, project) {
  const draft = load(scope, project);
  if (!draft) return [];
  const list = [];
  if (isHermesScope(scope)) {
    for (const [event, entry] of Object.entries(draft.events)) list.push({ op: "order", event, hooks: entry.hooks.slice() });
    return list;
  }
  if (isAntigravityScope(scope)) {
    for (const [event, entry] of Object.entries(draft.events)) {
      if (entry.op === "release") list.push({ op: "release", event });
      else list.push({ op: "order", event, hooks: entry.hooks.slice() });
    }
    return list;
  }
  for (const [event, entry] of Object.entries(draft.events)) {
    if (entry.op === "release") list.push({ op: "release", event });
    else {
      const change = { op: "order", event, hooks: entry.hooks.slice() };
      if (entry.stop_on_block === true || entry.stop_on_block === false) change.stop_on_block = entry.stop_on_block;
      list.push(change);
    }
  }
  for (const [hook, kind] of Object.entries(draft.guards)) list.push({ op: kind, hook });
  return list;
}

export function scopesWithChanges(project) {
  const found = [];
  for (const scope of [...ALL_SCOPES, ...antigravityScopes(project)]) {
    const total = count(scope, project);
    if (total > 0) found.push({ scope, project: project || null, count: total });
  }
  return found;
}

function agDraftValid(entry, known) {
  if (entry.op !== "order") return true;
  entry.hooks = entry.hooks.filter((id) => known.has(id));
  entry.original = (entry.original || []).filter((id) => known.has(id));
  return entry.hooks.length > 0 && !sameList(entry.hooks, entry.original);
}

function rebaseAntigravity(project, layout, fingerprint) {
  const hooks = (layout && layout.hooks) || [];
  const known = new Set(hooks.filter(agOrderable).map((hook) => hook.id));
  const dropped = [];
  for (const scope of antigravityScopes(project)) {
    const draft = load(scope, project);
    if (!draft) continue;
    const { path } = parseAntigravityScope(scope);
    for (const [event, entry] of Object.entries(draft.events)) {
      if (entry.op === "order") for (const id of entry.hooks) if (!known.has(id)) dropped.push(id);
      const members = hooks.filter((hook) => agWritable(hook) && hook.source_file === path && hook.event === event && hook.member === true);
      const keep = entry.op === "release" ? members.length > 0 : agDraftValid(entry, known);
      if (!keep) delete draft.events[event];
    }
    draft.base = fingerprint;
    store(scope, project, draft);
  }
  if (dropped.length) {
    announce(`${dropped.length === 1 ? "A drafted hook is" : `${dropped.length} drafted hooks are`} no longer in the layout and ${dropped.length === 1 ? "was" : "were"} dropped from the draft.`);
  }
}

export function rebase(project, layout) {
  const fingerprint = layout && layout.fingerprint ? layout.fingerprint.config : null;
  const known = new Set(((layout && layout.hooks) || []).map((hook) => hook.id));
  rebaseAntigravity(project, layout, fingerprint);
  for (const scope of ALL_SCOPES) {
    const draft = load(scope, project);
    if (!draft) continue;
    const dropped = [];
    if (isHermesScope(scope)) {
      const unpinned = new Map();
      for (const hook of (layout && layout.hooks) || []) {
        if (isHermes(hook) && !isPinned(hook)) {
          if (!unpinned.has(hook.event)) unpinned.set(hook.event, []);
          unpinned.get(hook.event).push(hook.id);
        }
      }
      for (const [event, entry] of Object.entries(draft.events)) {
        const live = new Set(unpinned.get(event) || []);
        for (const id of entry.hooks) if (!live.has(id)) dropped.push(id);
        entry.hooks = entry.hooks.filter((id) => live.has(id));
        entry.original = (entry.original || []).filter((id) => live.has(id));
        if (entry.hooks.length < 2 || entry.hooks.length !== live.size || sameList(entry.hooks, entry.original)) delete draft.events[event];
      }
      draft.base = fingerprint;
      store(scope, project, draft);
      if (dropped.length) {
        announce(`${dropped.length === 1 ? "A drafted hook is" : `${dropped.length} drafted hooks are`} no longer in the layout and ${dropped.length === 1 ? "was" : "were"} dropped from the draft.`);
      }
      continue;
    }
    for (const [event, entry] of Object.entries(draft.events)) {
      if (entry.op === "order") {
        const kept = entry.hooks.filter((id) => known.has(id));
        for (const id of entry.hooks) if (!known.has(id)) dropped.push(id);
        entry.hooks = kept;
      }
      const original = (entry.original || []).filter((id) => known.has(id));
      entry.original = original;
      if (entry.op === "order" && entry.hooks.length === 0) {
        if (original.length === 0) delete draft.events[event];
        else draft.events[event] = { op: "release", original };
      } else if (entry.op === "order" && sameList(entry.hooks, original) && (entry.stop_on_block === null || entry.stop_on_block === entry.original_stop_on_block)) {
        delete draft.events[event];
      }
    }
    for (const id of Object.keys(draft.guards)) {
      if (!known.has(id)) {
        dropped.push(id);
        delete draft.guards[id];
      }
    }
    draft.base = fingerprint;
    store(scope, project, draft);
    if (dropped.length) {
      announce(`${dropped.length === 1 ? "A drafted hook is" : `${dropped.length} drafted hooks are`} no longer in the layout and ${dropped.length === 1 ? "was" : "were"} dropped from the draft.`);
    }
  }
}

function membersOf(layout, scope, event) {
  return ((layout && layout.hooks) || [])
    .filter((hook) => hook.harness === "claude-code" && hook.scope === scope && hook.event === event && isMember(hook))
    .sort((a, b) => memberPosition(a) - memberPosition(b));
}

export function originalHermes(layout, event) {
  return hermesEvents(layout, event).filter((hook) => !isPinned(hook)).map((hook) => hook.id);
}

export function projectHermes(layout, projectRoot) {
  const result = { orders: new Map(), drafted: new Set() };
  const draft = load(HERMES_SCOPE, projectRoot);
  const events = new Set(((layout && layout.hooks) || []).filter(isHermes).map((hook) => hook.event));
  for (const event of events) {
    const base = hermesEvents(layout, event);
    const list = base.slice();
    const entry = draft ? draft.events[event] : null;
    if (entry && entry.op === "order") {
      const byId = new Map(base.map((hook) => [hook.id, hook]));
      const chosen = entry.hooks.map((id) => byId.get(id)).filter(Boolean);
      const slots = base.map((hook, index) => (isPinned(hook) ? -1 : index)).filter((index) => index >= 0);
      if (chosen.length === slots.length) {
        slots.forEach((slot, i) => {
          list[slot] = chosen[i];
        });
        chosen.forEach((hook, i) => {
          if (base[slots[i]].id !== hook.id) result.drafted.add(hook.id);
        });
      }
    }
    result.orders.set(event, list);
  }
  return result;
}

export function originalMembers(layout, scope, event) {
  return membersOf(layout, scope, event).map((hook) => hook.id);
}

export function cardStop(layout, scope, event) {
  const entry = layout && layout.cards && layout.cards[scope];
  const card = entry && entry.card;
  const events = card && card.events;
  const value = events && events[event] ? events[event].stop_on_block : null;
  return value === true || value === false ? value : null;
}

export function project(layout, projectRoot) {
  const result = {
    members: new Map(),
    natives: new Map(),
    drafted: new Set(),
    guards: new Map(),
    stops: new Map(),
    touched: new Set(),
  };
  const hooks = ((layout && layout.hooks) || []).filter((hook) => !isDispatcher(hook));
  const byId = new Map(hooks.map((hook) => [hook.id, hook]));
  const drafts = new Map();
  for (const scope of SCOPES) {
    const draft = load(scope, projectRoot);
    if (draft) drafts.set(scope, draft);
  }
  for (const [scope, draft] of drafts) {
    for (const [id, kind] of Object.entries(draft.guards)) {
      result.guards.set(id, kind === "guard");
      result.drafted.add(id);
    }
    for (const event of Object.keys(draft.events)) result.touched.add(`${scope}|${event}`);
  }
  const keys = new Set();
  for (const hook of hooks) {
    if (hook.harness === "claude-code" && SCOPES.includes(hook.scope)) keys.add(`${hook.scope}|${hook.event}`);
  }
  for (const [scope, draft] of drafts) for (const event of Object.keys(draft.events)) keys.add(`${scope}|${event}`);
  for (const key of keys) {
    const [scope, event] = key.split("|");
    const base = membersOf(layout, scope, event);
    const draft = drafts.get(scope);
    const entry = draft ? draft.events[event] : null;
    let members = base.slice();
    if (entry && entry.op === "order") {
      members = entry.hooks.map((id) => byId.get(id)).filter(Boolean);
      const baseIds = base.map((hook) => hook.id);
      entry.hooks.forEach((id, index) => {
        if (baseIds.indexOf(id) !== index) result.drafted.add(id);
      });
      for (const hook of base) if (!entry.hooks.includes(hook.id)) result.drafted.add(hook.id);
      if (entry.stop_on_block === true || entry.stop_on_block === false) result.stops.set(key, entry.stop_on_block);
    } else if (entry && entry.op === "release") {
      members = [];
      for (const hook of base) result.drafted.add(hook.id);
    }
    members = members.filter((hook) => result.guards.get(hook.id) !== true);
    for (const hook of base) if (result.guards.get(hook.id) === true) result.drafted.add(hook.id);
    result.members.set(key, members);
  }
  for (const key of keys) {
    const [scope, event] = key.split("|");
    const inside = new Set(result.members.get(key).map((hook) => hook.id));
    const natives = hooks.filter(
      (hook) => hook.harness === "claude-code" && hook.scope === scope && hook.event === event && !isMember(hook) && !inside.has(hook.id) && !hook.plugin,
    );
    const returned = hooks.filter((hook) => hook.harness === "claude-code" && hook.scope === scope && hook.event === event && isMember(hook) && !inside.has(hook.id));
    returned.sort((a, b) => memberPosition(a) - memberPosition(b));
    result.natives.set(key, natives.concat(returned));
  }
  return result;
}

function agBase(layout, file, event) {
  const hooks = ((layout && layout.hooks) || []).filter((hook) => agWritable(hook) && hook.source_file === file && hook.event === event);
  const members = hooks.filter((hook) => hook.member === true);
  const groups = [];
  for (const hook of hooks) {
    if (hook.member === true) continue;
    let group = groups.find((item) => item.name === hook.hook_name);
    if (!group) {
      group = { name: hook.hook_name, hooks: [] };
      groups.push(group);
    }
    group.hooks.push(hook);
  }
  return { hooks, members, groups };
}

function agCell(base, entry, byId) {
  const out = {
    frame: base.members.length ? base.members.slice() : null,
    groups: base.groups.map((group) => ({ name: group.name, hooks: group.hooks.slice() })),
    drafted: new Set(),
  };
  if (!entry) return out;
  if (entry.op === "release") {
    out.frame = null;
    if (base.members.length) out.groups.push({ name: null, hooks: base.members.slice() });
    for (const hook of base.members) out.drafted.add(hook.id);
    return out;
  }
  const named = entry.hooks.map((id) => byId.get(id)).filter(Boolean);
  if (entry.mode === "inplace") {
    const group = out.groups.find((item) => item.name === entry.spec);
    if (!group) return out;
    const slots = [];
    group.hooks.forEach((hook, index) => {
      if (entry.hooks.includes(hook.id)) slots.push(index);
    });
    if (slots.length !== named.length) return out;
    const next = group.hooks.slice();
    slots.forEach((slot, i) => {
      next[slot] = named[i];
      if (group.hooks[slot].id !== named[i].id) out.drafted.add(named[i].id);
    });
    group.hooks = next;
    return out;
  }
  const inside = new Set(entry.hooks);
  out.frame = named.length ? named : null;
  out.groups = out.groups.map((group) => ({ name: group.name, hooks: group.hooks.filter((hook) => !inside.has(hook.id)) })).filter((group) => group.hooks.length);
  const released = base.members.filter((hook) => !inside.has(hook.id));
  if (released.length) {
    out.groups.push({ name: null, hooks: released });
    for (const hook of released) out.drafted.add(hook.id);
  }
  named.forEach((hook, index) => {
    if (!base.members[index] || base.members[index].id !== hook.id) out.drafted.add(hook.id);
  });
  return out;
}

export function projectAntigravity(layout, projectRoot) {
  const result = { cells: new Map(), drafted: new Set() };
  const hooks = (layout && layout.hooks) || [];
  const byId = new Map(hooks.map((hook) => [hook.id, hook]));
  const drafts = new Map();
  for (const scope of antigravityScopes(projectRoot)) {
    const draft = load(scope, projectRoot);
    if (draft) drafts.set(parseAntigravityScope(scope).path, { scope, draft });
  }
  const keys = new Set();
  for (const hook of hooks) if (agWritable(hook)) keys.add(`${hook.source_file}|${hook.event}`);
  for (const [file, item] of drafts) for (const event of Object.keys(item.draft.events)) keys.add(`${file}|${event}`);
  for (const key of keys) {
    const at = key.lastIndexOf("|");
    const file = key.slice(0, at);
    const event = key.slice(at + 1);
    const base = agBase(layout, file, event);
    const item = drafts.get(file);
    const entry = item ? item.draft.events[event] || null : null;
    const cell = agCell(base, entry, byId);
    cell.base = base;
    cell.entry = entry;
    for (const id of cell.drafted) result.drafted.add(id);
    result.cells.set(key, cell);
  }
  return result;
}

export const AG_CONFLICT = "This event already has a different change in the draft";
export const AG_SEQUENCE_FIRST = "This event has a sequence; reorder inside it or release it first";
export const AG_TWO_SPECS = "A sequence needs hooks from two different specs";

function entryAllows(entry, mode, spec) {
  if (!entry) return true;
  if (entry.op === "release") return mode === "members";
  return entry.mode === mode && (mode !== "inplace" || entry.spec === spec);
}

export function agUnits(layout, project, hook) {
  if (!agOrderable(hook)) return null;
  const cell = projectAntigravity(layout, project).cells.get(`${hook.source_file}|${hook.event}`);
  if (!cell) return null;
  if (cell.frame && cell.frame.some((item) => item.id === hook.id)) return { kind: "frame", cell, ids: cell.frame.map((item) => item.id), reason: null };
  const group = cell.groups.find((item) => item.hooks.some((entry) => entry.id === hook.id));
  if (!group || group.name === null) return null;
  const ids = group.hooks.filter(agOrderable).map((item) => item.id);
  if (ids.length < 2) return null;
  let reason = null;
  if (cell.base.members.length) reason = AG_SEQUENCE_FIRST;
  else if (!entryAllows(cell.entry, "inplace", group.name)) reason = AG_CONFLICT;
  return { kind: "group", cell, group, ids, reason };
}

export function agSequenceReason(layout, project, hook, ids) {
  if (!agOrderable(hook)) return "This hook cannot be sequenced";
  const cell = projectAntigravity(layout, project).cells.get(`${hook.source_file}|${hook.event}`);
  if (!cell) return "This hook cannot be sequenced";
  if (!entryAllows(cell.entry, "members")) return AG_CONFLICT;
  if (!cell.base.members.length && ids.length >= 2) {
    const specs = new Set(ids.map((id) => (cell.base.hooks.find((item) => item.id === id) || {}).hook_name));
    if (specs.size === 1) return AG_TWO_SPECS;
  }
  return null;
}

export function agCommit(layout, project, hook, kind, ids) {
  const cell = projectAntigravity(layout, project).cells.get(`${hook.source_file}|${hook.event}`);
  if (!cell) return false;
  const scope = antigravityScope(hook.scope, hook.source_file);
  const base = layout && layout.fingerprint ? layout.fingerprint.config : null;
  const original = cell.base.members.map((item) => item.id);
  if (kind === "group") {
    const group = cell.base.groups.find((item) => item.name === hook.hook_name);
    const first = group ? group.hooks.filter(agOrderable).map((item) => item.id) : [];
    setAgOrder(scope, project, base, hook.event, ids, first, "inplace", hook.hook_name);
    return true;
  }
  if (ids.length < 2 && original.length > 0) setAgRelease(scope, project, base, hook.event, original);
  else setAgOrder(scope, project, base, hook.event, ids, original, "members", null);
  return true;
}

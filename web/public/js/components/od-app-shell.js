import "./od-button.js";
import "./od-icon-button.js";
import "./od-segmented.js";
import "./od-toggle.js";
import "./od-combobox.js";
import "./od-text-field.js";
import "./od-theme-switcher.js";
import "./od-banner.js";
import "./od-state.js";
import "./od-skeleton.js";
import "./od-toaster.js";
import "./od-tooltip.js";
import "./od-digest.js";
import "./od-command.js";
import "./od-chip.js";
import "./od-dialog.js";
import "./od-drawer.js";
import "./od-kbd.js";
import "./od-confirm.js";
import "./od-tabs.js";
import "./od-shortcuts.js";
import "./od-source-bar.js";
import "./od-folder-picker.js";
import { app, READ_ONLY_REASON } from "../core/store.js";
import { get, put, endpoints } from "../core/api.js";
import { getPref, setPref } from "../core/cache.js";
import { toast, announce } from "../core/announce.js";
import { setDefault } from "../core/theme.js";
import * as keys from "../core/keys.js";
import { allHooks, draftKeys, draftScopes, visibleHooks } from "../core/hooks.js";
import { createSources, providersOf } from "../core/sources.js";
import { queryParam } from "../core/query.js";

const PICK_FOLDER = "od:pick-folder";
const SYNC_MS = 5000;
const SYNC_BACKOFF_MS = 30000;
const NARROW = 768;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function segmented(label, options, value) {
  const node = document.createElement("od-segmented");
  node.setAttribute("label", label);
  node.setAttribute("size", "sm");
  node.options = options;
  node.setAttribute("value", value);
  return node;
}

function projectItems(projects) {
  const names = new Map();
  for (const project of projects) names.set(project.name, (names.get(project.name) || 0) + 1);
  const items = [
    { value: "none", label: "Global Shelf", kind: "shelf" },
    { value: PICK_FOLDER, label: "Select a Folder...", kind: "action", icon: "folder" },
  ];
  for (const project of projects) {
    const label = names.get(project.name) > 1 ? `${project.name} (${project.root})` : project.name;
    items.push({ value: project.root, label });
  }
  return items;
}

function bootView() {
  const value = queryParam("view");
  return value === "list" || value === "map" ? value : null;
}

class OdAppShell extends HTMLElement {
  registerView(view) {
    this.viewModule = view;
    if (this.mounted) this.mountView();
  }

  connectedCallback() {
    if (this.topbar) return;
    this.projects = [];
    this.notes = [];
    this.layout = null;
    this.layoutError = null;
    this.loading = true;
    this.syncState = "synced";
    this.syncDelay = SYNC_MS;
    this.changedOnDisk = false;
    this.notesOpen = false;
    this.mounted = false;
    this.viewHandle = null;
    this.project = getPref("project", null);
    this.harness = getPref("harness", "both");
    this.density = getPref("density", "detailed");
    this.showEmpty = getPref("empty", false) === true;
    this.sources = createSources();
    const storedView = getPref("view", null);
    this.view = bootView() || storedView || (window.innerWidth < NARROW ? "list" : "map");
    this.build();
    this.unsubscribe = app.subscribe(() => this.renderBanners());
    this.unregister = this.registerKeys();
    this.onVisibility = () => {
      if (document.visibilityState === "visible") this.scheduleSync(0);
    };
    document.addEventListener("visibilitychange", this.onVisibility);
    this.onRetry = (event) => {
      if (event.target.closest && event.target.closest(".od-view")) this.loadLayout(true);
    };
    this.addEventListener("od-retry", this.onRetry);
    this.onDraft = () => this.renderBanners();
    document.addEventListener("od-draft-change", this.onDraft);
    this.start();
  }

  disconnectedCallback() {
    if (this.trayWatch) this.trayWatch.disconnect();
    if (this.unsubscribe) this.unsubscribe();
    if (this.unregister) this.unregister();
    document.removeEventListener("visibilitychange", this.onVisibility);
    document.removeEventListener("od-draft-change", this.onDraft);
    clearTimeout(this.syncTimer);
  }

  build() {
    this.topbar = el("header", "od-topbar");
    const left = el("div", "od-group od-group-start");
    const mark = el("span", "od-wordmark", "ordonnateur");
    this.version = document.createElement("od-digest");
    this.version.setAttribute("kind", "version");
    this.version.className = "od-version";
    this.harnessControl = segmented(
      "Harness",
      [
        { value: "claude-code", label: "Claude Code" },
        { value: "codex", label: "Codex" },
        { value: "hermes", label: "Hermes" },
        { value: "both", label: "All" },
      ],
      this.harness,
    );
    left.append(mark, this.version, this.harnessControl);
    const right = el("div", "od-group od-group-end");
    this.projectControl = document.createElement("od-combobox");
    this.projectControl.setAttribute("label", "Project");
    this.projectControl.setAttribute("hide-label", "");
    this.projectControl.setAttribute("placeholder", "Global Shelf");
    this.projectControl.setAttribute("size", "sm");
    this.projectControl.options = projectItems([]);
    this.projectControl.value = this.project || "none";
    this.syncEl = el("span", "od-sync");
    this.syncEl.setAttribute("role", "status");
    this.syncDot = el("span", "od-sync-dot");
    this.syncDot.setAttribute("aria-hidden", "true");
    this.syncText = el("span", "od-sync-text");
    this.syncEl.append(this.syncDot, this.syncText);
    this.themeSwitcher = document.createElement("od-theme-switcher");
    right.append(this.syncEl, this.projectControl, this.themeSwitcher);
    this.topbar.append(left, right);

    this.toolbar = el("div", "od-toolbar");
    const toolLeft = el("div", "od-group od-group-start");
    const title = el("h1", "od-title", "Hooks");
    title.tabIndex = -1;
    this.viewControl = segmented(
      "View",
      [
        { value: "map", label: "Map" },
        { value: "list", label: "List" },
      ],
      this.view,
    );
    toolLeft.append(title, this.viewControl);
    const toolRight = el("div", "od-group od-group-end");
    this.densityControl = segmented(
      "Density",
      [
        { value: "detailed", label: "Detailed" },
        { value: "compact", label: "Compact" },
      ],
      this.density,
    );
    this.emptyToggle = document.createElement("od-toggle");
    this.emptyToggle.setAttribute("label", "Empty events");
    if (this.showEmpty) this.emptyToggle.setAttribute("checked", "");
    this.helpButton = document.createElement("od-icon-button");
    this.helpButton.setAttribute("icon", "question");
    this.helpButton.setAttribute("label", "Keyboard shortcuts");
    this.helpButton.setAttribute("size", "sm");
    toolRight.append(this.densityControl, this.emptyToggle, this.helpButton);
    this.sourceBar = document.createElement("od-source-bar");
    this.sourceBar.setAttribute("data-density", "cockpit");
    this.sourceBar.setAttribute("data-pending", "");
    this.toolbar.append(toolLeft, toolRight, this.sourceBar);

    this.banners = el("div", "od-banners");
    this.main = el("main", "od-main");
    this.main.id = "main";
    this.viewHost = el("div", "od-view");
    this.inspectorHost = el("div", "od-inspector-host");
    this.inspectorHost.hidden = true;
    this.main.append(this.viewHost, this.inspectorHost);
    this.trayHost = el("div", "od-tray-host");
    this.trayHost.hidden = true;
    this.toaster = document.createElement("od-toaster");
    this.shortcuts = document.createElement("od-shortcuts");
    this.append(this.topbar, this.toolbar, this.banners, this.main, this.trayHost, this.toaster, this.shortcuts);
    if (typeof ResizeObserver === "function") {
      this.trayWatch = new ResizeObserver(() => {
        const height = this.trayHost.hidden ? 0 : Math.round(this.trayHost.getBoundingClientRect().height);
        document.documentElement.style.setProperty("--tray-offset", `${height}px`);
      });
      this.trayWatch.observe(this.trayHost);
    }

    this.harnessControl.addEventListener("od-change", (event) => {
      this.harness = event.detail.value;
      setPref("harness", this.harness);
      this.pushContext();
    });
    this.viewControl.addEventListener("od-change", (event) => this.setView(event.detail.value));
    this.densityControl.addEventListener("od-change", (event) => this.setDensity(event.detail.value));
    this.emptyToggle.addEventListener("od-change", (event) => this.setEmpty(event.detail.checked));
    this.projectControl.addEventListener("od-change", (event) => this.setProject(event.detail.value));
    this.projectControl.addEventListener("od-combo-action", () => this.openFolderPicker());
    this.helpButton.addEventListener("click", () => this.openShortcuts());
    this.addEventListener("od-sources-toggle", (event) => this.toggleSource(event.detail.key));
    this.addEventListener("od-sources-only", (event) => this.onlySource(event.detail.key));
    this.addEventListener("od-sources-all", () => this.showAllSources());
    this.addEventListener("od-sources-none", () => this.hideAllSources());
    this.syncChrome();
  }

  syncChrome() {
    this.densityControl.hidden = this.view !== "map";
    const labels = { synced: "In sync", changed: "Changed on disk", offline: "Offline" };
    this.syncEl.dataset.state = this.syncState;
    this.syncText.textContent = labels[this.syncState];
  }

  registerKeys() {
    const offs = [
      keys.register({ keys: "m", description: "Show the map", group: "View", handler: () => this.setView("map", true) }),
      keys.register({ keys: "l", description: "Show the list", group: "View", handler: () => this.setView("list", true) }),
      keys.register({ keys: "d", description: "Toggle density", group: "View", handler: () => this.setDensity(this.density === "compact" ? "detailed" : "compact", true) }),
      keys.register({ keys: "e", description: "Toggle empty events", group: "View", handler: () => this.setEmpty(!this.showEmpty, true) }),
      keys.register({ keys: "/", description: "Pick a project", group: "General", handler: () => this.projectControl.focus() }),
      keys.register({ keys: "p", description: "Plan the draft", group: "General", handler: () => this.planDraft() }),
      keys.register({ keys: "?", description: "Show keyboard shortcuts", group: "General", handler: () => this.openShortcuts() }),
    ];
    return () => offs.forEach((off) => off());
  }

  openShortcuts() {
    this.shortcuts.show(this.helpButton);
  }

  planDraft() {
    const scopes = draftScopes(this.project);
    if (scopes.length !== 1) return;
    document.dispatchEvent(new CustomEvent("od-open-plan", { detail: { scope: scopes[0], project: this.project } }));
  }

  setView(value, focus) {
    if (value !== "map" && value !== "list") return;
    this.view = value;
    setPref("view", value);
    this.viewControl.setAttribute("value", value);
    if (focus) announce(value === "map" ? "Map view" : "List view");
    this.syncChrome();
    this.pushContext();
  }

  setDensity(value, focus) {
    this.density = value;
    setPref("density", value);
    this.densityControl.setAttribute("value", value);
    if (focus) announce(`${value === "compact" ? "Compact" : "Detailed"} density`);
    this.pushContext();
  }

  setEmpty(value, focus) {
    this.showEmpty = Boolean(value);
    setPref("empty", this.showEmpty);
    this.emptyToggle.toggleAttribute("checked", this.showEmpty);
    if (focus) announce(this.showEmpty ? "Empty events shown" : "Empty events hidden");
    this.pushContext();
  }

  openFolderPicker() {
    if (!this.folderPicker) {
      this.folderPicker = document.createElement("od-folder-picker");
      this.folderPicker.addEventListener("od-folder-pick", (event) => this.openProject(event.detail.path));
      this.append(this.folderPicker);
    }
    this.folderPicker.open(this.project || "", this.projectControl.input);
  }

  async openProject(path) {
    const pinned = this.projects.filter((project) => project.sources.includes("pinned")).map((project) => project.root);
    try {
      await put(endpoints.projectsState, { pinned: [...new Set([...pinned, path])] });
    } catch (error) {
      toast(error && error.message ? error.message : "The server refused the folder.", { kind: "error", title: "Could not open the folder" });
      return;
    }
    this.project = path;
    setPref("project", path);
    this.changedOnDisk = false;
    await this.loadProjects();
    this.projectControl.value = path;
    this.loadLayout(true);
    announce(`Opened ${path.split("/").filter(Boolean).pop() || path}.`);
  }

  setProject(value) {
    const next = value && value !== "none" ? value : null;
    if (next === this.project) return;
    this.project = next;
    setPref("project", next);
    this.changedOnDisk = false;
    this.loadLayout(true);
  }

  sourceState() {
    const providers = this.layout ? providersOf(this.layout, this.harness, this.project) : [];
    const active = providers.length >= 2;
    return { providers, hidden: active ? new Set(this.sources.hidden) : new Set(), active };
  }

  syncBar() {
    const state = this.sourceState();
    this.sourceBar.providers = state.providers;
    this.sourceBar.off = state.hidden;
    this.sourceBar.removeAttribute("data-pending");
    this.sourceBar.hidden = !state.active;
  }

  counts(state) {
    const total = allHooks(this.layout, this.harness).length;
    const shown = visibleHooks(this.layout, this.harness, state.hidden).length;
    return { total, shown };
  }

  sourcesChanged(key) {
    this.pushContext();
    const state = this.sourceState();
    document.dispatchEvent(new CustomEvent("od-sources-change", { detail: { hidden: state.hidden, key } }));
    return state;
  }

  toggleSource(key) {
    const before = this.sourceState();
    if (!before.active) return;
    const meta = before.providers.find((item) => item.key === key);
    if (!meta) return;
    const hiddenNow = this.sources.toggle(key);
    const state = this.sourcesChanged(key);
    const { total, shown } = this.counts(state);
    if (state.providers.every((item) => state.hidden.has(item.key))) {
      announce("All sources hidden.", { assertive: true });
      return;
    }
    announce(`${meta.label} ${hiddenNow ? "hidden" : "shown"}. ${shown} of ${total} hooks shown.`);
  }

  onlySource(key) {
    const before = this.sourceState();
    if (!before.active) return;
    const meta = before.providers.find((item) => item.key === key);
    if (!meta) return;
    const result = this.sources.only(key, before.providers.map((item) => item.key));
    const state = this.sourcesChanged(key);
    const { total, shown } = this.counts(state);
    if (result === "all") announce(`All sources shown. ${total} hooks shown.`);
    else announce(`Showing only ${meta.label}. ${shown} hooks shown.`);
  }

  showAllSources() {
    const before = this.sourceState();
    if (!before.active) return;
    this.sources.showAll();
    const state = this.sourcesChanged(null);
    const { total } = this.counts(state);
    announce(`All sources shown. ${total} hooks shown.`);
  }

  hideAllSources() {
    const before = this.sourceState();
    if (!before.active) return;
    this.sources.setHidden(before.providers.map((item) => item.key));
    this.sourcesChanged(null);
    announce("All sources hidden.", { assertive: true });
  }

  context() {
    return {
      config: app.get().config,
      layout: this.layout,
      projects: this.projects,
      harness: this.harness,
      project: this.project,
      view: this.view,
      density: this.density,
      showEmpty: this.showEmpty,
      readOnly: Boolean(app.get().config && app.get().config.read_only),
      sources: this.sourceState(),
    };
  }

  async start() {
    const config = app.get().config;
    if (config) {
      setDefault(config.theme);
      this.version.setAttribute("value", String(config.version || ""));
      this.version.setAttribute("length", String(String(config.version || "").length || 8));
    }
    this.renderBanners();
    this.renderLoading();
    await this.loadProjects();
    await this.loadLayout(false);
    this.scheduleSync(this.syncDelay);
  }

  async loadProjects() {
    try {
      const result = await get(endpoints.projects);
      this.projects = result.projects || [];
      this.projectNotes = result.notes || [];
    } catch (error) {
      this.projects = [];
      this.projectNotes = [];
    }
    this.projectControl.options = projectItems(this.projects);
    if (this.project && !this.projects.some((project) => project.root === this.project)) {
      this.projects = [...this.projects, { root: this.project, name: this.project.split("/").filter(Boolean).pop() || this.project, sources: ["pinned"], local_hooks: 0, local_card: false }];
      this.projectControl.options = projectItems(this.projects);
    }
    this.projectControl.value = this.project || "none";
  }

  renderLoading() {
    const grid = el("div", "od-skeleton-grid");
    grid.setAttribute("aria-busy", "true");
    for (let row = 0; row < 5; row += 1) {
      const line = el("div", "od-skeleton-row");
      for (let col = 0; col < 5; col += 1) line.append(document.createElement("od-skeleton"));
      grid.append(line);
    }
    this.viewHost.replaceChildren(grid);
    this.viewHandle = null;
    this.mounted = false;
  }

  async loadLayout(showLoading) {
    if (showLoading) this.renderLoading();
    this.loading = true;
    try {
      const layout = await get(endpoints.layout({ project: this.project }));
      this.layout = layout;
      if (this.sources.pendingAll) this.sources.resolve(providersOf(layout, "both", this.project).map((item) => item.key));
      this.layoutError = null;
      this.notes = layout.notes || [];
      this.setSync("synced");
    } catch (error) {
      this.layoutError = error;
      this.layout = null;
    }
    this.loading = false;
    this.syncBar();
    this.renderBanners();
    if (this.layoutError) this.renderError(this.layoutError);
    else this.mountView();
    document.dispatchEvent(new CustomEvent("od-layout-loaded", { detail: { project: this.project } }));
  }

  renderError(error) {
    const state = document.createElement("od-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The hook layout could not be loaded");
    state.setAttribute("body", error.message);
    state.setAttribute("error-id", error.requestId || error.errorId);
    this.viewHost.replaceChildren(state);
    this.viewHandle = null;
    this.mounted = false;
  }

  mountView() {
    if (!this.viewModule || !this.layout) return;
    if (this.viewHandle) {
      this.viewHandle.update(this.context());
      return;
    }
    this.viewHandle = this.viewModule.mount(this.viewHost, this.context());
    this.mounted = true;
  }

  pushContext() {
    this.syncBar();
    if (this.viewHandle) this.viewHandle.update(this.context());
  }

  setSync(state) {
    this.syncState = state;
    this.syncChrome();
  }

  scheduleSync(delay) {
    clearTimeout(this.syncTimer);
    this.syncTimer = setTimeout(() => this.tick(), delay);
  }

  hasDraft() {
    return draftKeys(this.project).length > 0;
  }

  async tick() {
    if (document.visibilityState !== "visible" || app.get().session !== "active") {
      this.scheduleSync(this.syncDelay);
      return;
    }
    try {
      const result = await get(endpoints.fingerprint({ project: this.project }), { retry: false });
      this.syncDelay = SYNC_MS;
      const current = this.layout && this.layout.fingerprint;
      if (current && result.config !== current.config) {
        if (this.hasDraft()) {
          this.changedOnDisk = true;
          this.setSync("changed");
          this.renderBanners();
        } else {
          await this.loadLayout(false);
          toast("Hook settings changed on disk; the layout was reloaded.");
        }
      } else if (current && result.timings !== current.timings) {
        await this.loadLayout(false);
      } else if (!this.changedOnDisk) {
        this.setSync("synced");
      }
    } catch (error) {
      this.syncDelay = SYNC_BACKOFF_MS;
      this.setSync("offline");
    }
    this.scheduleSync(this.syncDelay);
  }

  reloadKeepingDraft() {
    this.changedOnDisk = false;
    this.setSync("synced");
    this.loadLayout(false).then(() => {
      document.dispatchEvent(new CustomEvent("od-layout-reloaded", { detail: { project: this.project } }));
    });
  }

  discardDraft() {
    try {
      for (const key of draftKeys(this.project)) window.sessionStorage.removeItem(key);
    } catch (error) {
      return;
    }
    document.dispatchEvent(new CustomEvent("od-draft-discarded", { detail: { project: this.project } }));
    document.dispatchEvent(new CustomEvent("od-draft-change", { detail: { count: 0 } }));
    this.reloadKeepingDraft();
  }

  renderBanners() {
    const config = app.get().config;
    const banner = document.createElement("od-banner");
    let shown = false;
    let extra = null;
    if (config && config.enabled === false) {
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", "Applying changes is turned off on this server (web.enabled is false).");
      shown = true;
    } else if (config && config.read_only) {
      banner.setAttribute("severity", "info");
      banner.setAttribute("icon", "lock");
      banner.setAttribute("text", READ_ONLY_REASON);
      shown = true;
    } else if (this.changedOnDisk && this.hasDraft()) {
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", "The hook settings changed after this draft was started.");
      banner.setAttribute("action", "Reload and keep draft");
      banner.addEventListener("od-action", () => this.reloadKeepingDraft());
      const discard = document.createElement("od-button");
      discard.setAttribute("variant", "ghost");
      discard.setAttribute("size", "xs");
      discard.text = "Discard draft";
      discard.addEventListener("click", () => this.discardDraft());
      extra = discard;
      shown = true;
    } else {
      const notes = [...(this.notes || []), ...(this.projectNotes || [])];
      if (notes.length) {
        banner.setAttribute("severity", "info");
        banner.classList.add("od-banner-notes");
        banner.classList.toggle("od-notes-open", this.notesOpen);
        banner.setAttribute("text", this.notesOpen ? notes.join(" · ") : notes[0] + (notes.length > 1 ? ` (+${notes.length - 1} more)` : ""));
        banner.setAttribute("action", this.notesOpen ? "Hide notes" : "Show notes");
        banner.addEventListener("od-action", () => {
          this.notesOpen = !this.notesOpen;
          this.renderBanners();
        });
        shown = true;
      }
    }
    if (!shown) {
      this.banners.replaceChildren();
      return;
    }
    banner.classList.add("od-banner-row");
    this.banners.replaceChildren(banner);
    if (extra) banner.append(extra);
  }
}

customElements.define("od-app-shell", OdAppShell);

export const STORAGE_KEY = "ordonnateur.web.theme";

export const CHOICES = ["system", "minimal-dark", "minimal-light", "apple-noir", "apple-austere", "tronwave"];

export const LABELS = {
  system: "System",
  "minimal-dark": "Minimal Dark",
  "minimal-light": "Minimal Light",
  "apple-noir": "Apple Noir",
  "apple-austere": "Apple Austere",
  tronwave: "Tronwave",
};

let query = null;
try {
  query = typeof window.matchMedia === "function" ? window.matchMedia("(prefers-color-scheme: light)") : null;
} catch (error) {
  query = null;
}

let fallback = "system";

function readStored() {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    return CHOICES.includes(stored) ? stored : null;
  } catch (error) {
    return null;
  }
}

function writeStored(id) {
  try {
    window.localStorage.setItem(STORAGE_KEY, id);
  } catch (error) {
    return;
  }
}

export function resolve(id) {
  if (id === "system") return query && query.matches ? "minimal-light" : "minimal-dark";
  return id;
}

export function getChoice() {
  const stored = readStored();
  if (stored) return stored;
  return fallback;
}

function apply(id) {
  const root = document.documentElement;
  const theme = resolve(id);
  root.setAttribute("data-theme-choice", id);
  root.setAttribute("data-theme", theme);
  document.dispatchEvent(new CustomEvent("od-theme-change", { detail: { choice: id, theme } }));
}

export function setDefault(id) {
  if (!CHOICES.includes(id)) return;
  fallback = id;
  if (!readStored()) apply(id);
}

export function setChoice(id) {
  if (!CHOICES.includes(id)) return getChoice();
  writeStored(id);
  apply(id);
  return id;
}

export function cycle(direction = 1) {
  const step = direction < 0 ? -1 : 1;
  const index = CHOICES.indexOf(getChoice());
  const next = CHOICES[(index + step + CHOICES.length) % CHOICES.length];
  return setChoice(next);
}

if (query) {
  query.addEventListener("change", () => {
    if (getChoice() === "system") apply("system");
  });
}

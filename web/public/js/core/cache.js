const PREF_PREFIX = "ordonnateur.web.pref.";
const memoryPrefs = new Map();

function area() {
  try {
    return window.localStorage;
  } catch (error) {
    return null;
  }
}

export function getPref(name, fallback) {
  if (memoryPrefs.has(name)) return memoryPrefs.get(name);
  const storage = area();
  if (!storage) return fallback;
  try {
    const raw = storage.getItem(PREF_PREFIX + name);
    if (raw === null) return fallback;
    return JSON.parse(raw);
  } catch (error) {
    return fallback;
  }
}

export function setPref(name, value) {
  memoryPrefs.set(name, value);
  const storage = area();
  if (!storage) return;
  try {
    storage.setItem(PREF_PREFIX + name, JSON.stringify(value));
  } catch (error) {
    return;
  }
}

import { get, post, del, endpoints, setSessionToken, hasSessionToken, isTokenInStorage } from "./api.js";
import { app } from "./store.js";
import { toast } from "./announce.js";

function clearHash() {
  try {
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
  } catch (error) {
    window.location.hash = "";
  }
}

function takeCode() {
  const hash = window.location.hash;
  if (!hash.startsWith("#k=")) return null;
  let code = hash.slice(3);
  try {
    code = decodeURIComponent(code);
  } catch (error) {
    code = hash.slice(3);
  }
  clearHash();
  return code;
}

function gateForFailure(error, fallback) {
  if (error.kind === "offline" || error.kind === "timeout") return "server_unreachable";
  return fallback;
}

export async function loadConfig() {
  const config = await get(endpoints.config);
  app.set({ config });
  return config;
}

function openApp() {
  app.set({ session: "active", cause: null, offline: false });
  if (!isTokenInStorage()) toast("This tab could not store its session, so reloading it will end the session.", { kind: "error" });
}

async function exchange(code) {
  app.set({ session: "exchanging", cause: null });
  try {
    const result = await post(endpoints.session, { code });
    setSessionToken(result && result.token);
  } catch (error) {
    app.set({ session: gateForFailure(error, "link_used_or_expired"), cause: error.message });
    return false;
  }
  try {
    await loadConfig();
  } catch (error) {
    app.set({ session: gateForFailure(error, "session_ended"), cause: error.message });
    return false;
  }
  openApp();
  return true;
}

async function probe() {
  if (!hasSessionToken()) {
    app.set({ session: "no_session", cause: null });
    return false;
  }
  app.set({ session: "exchanging", cause: null });
  try {
    await get(endpoints.session);
    await loadConfig();
    openApp();
    return true;
  } catch (error) {
    if (error.kind === "unauthorized") {
      app.set({ session: "no_session", cause: null });
    } else {
      app.set({ session: "server_unreachable", cause: error.message });
    }
    return false;
  }
}

export async function bootSession() {
  const code = takeCode();
  if (code !== null) return exchange(code);
  return probe();
}

export function watchLinks() {
  window.addEventListener("hashchange", () => {
    if (!window.location.hash.startsWith("#k=")) return;
    const code = takeCode();
    if (code !== null) exchange(code);
  });
}

export async function endSession() {
  try {
    await del(endpoints.session);
  } finally {
    const cleared = setSessionToken(null);
    const cause = cleared ? "Signed out of this tab" : "Signed out of this tab. Close the tab to clear any stored session";
    app.set({ session: "session_ended", cause });
  }
}

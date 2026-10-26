export function queryParam(name) {
  try {
    return new URLSearchParams(window.location.search).get(name);
  } catch (error) {
    return null;
  }
}

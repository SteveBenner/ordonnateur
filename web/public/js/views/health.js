import "../components/od-health-view.js";

export function mount(host, context) {
  const view = document.createElement("od-health-view");
  view.context = context;
  host.replaceChildren(view);
  return {
    update(next) {
      view.context = next;
    },
    destroy() {
      view.remove();
    },
  };
}

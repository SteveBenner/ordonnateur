import "../components/od-settings-view.js";

export function mount(host, context) {
  const view = document.createElement("od-settings-view");
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

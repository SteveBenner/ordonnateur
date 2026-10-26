import "../components/od-list.js";
import "../components/od-matrix.js";
import "../components/od-hook-menu.js";
import { rebase } from "../core/draft.js";

export function mount(host, context) {
  let current = context;
  let view = null;
  let kind = null;
  const menu = document.createElement("od-hook-menu");
  menu.context = context;

  function show(ctx) {
    const want = ctx.view === "list" ? "od-list-view" : "od-matrix";
    if (kind !== want) {
      if (view) view.remove();
      view = document.createElement(want);
      kind = want;
      host.replaceChildren(view, menu);
    }
    menu.context = ctx;
    view.context = ctx;
  }

  const onReloaded = () => rebase(current.project, current.layout);
  document.addEventListener("od-layout-reloaded", onReloaded);
  show(context);

  return {
    update(next) {
      current = next;
      show(next);
    },
    destroy() {
      document.removeEventListener("od-layout-reloaded", onReloaded);
      if (view) view.remove();
      menu.remove();
    },
  };
}

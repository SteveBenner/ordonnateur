(function () {
  var choices = ["system", "minimal-dark", "minimal-light", "apple-noir", "apple-austere", "tronwave"];
  var choice = "system";
  try {
    var stored = window.localStorage.getItem("ordonnateur.web.theme");
    if (stored && choices.indexOf(stored) !== -1) choice = stored;
  } catch (error) {
    choice = "system";
  }
  var resolved = choice;
  if (choice === "system") {
    var light = false;
    try {
      light = window.matchMedia("(prefers-color-scheme: light)").matches;
    } catch (error) {
      light = false;
    }
    resolved = light ? "minimal-light" : "minimal-dark";
  }
  var root = document.documentElement;
  root.setAttribute("data-theme-choice", choice);
  root.setAttribute("data-theme", resolved);
})();

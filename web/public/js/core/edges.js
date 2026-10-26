const NS = "http://www.w3.org/2000/svg";
export const EDGE_LIMIT = 60;

export function pathD(edge) {
  const d = edge.y2 - edge.y1;
  return `M${edge.x1} ${edge.y1} C${edge.x1} ${edge.y1 + d / 2} ${edge.x2} ${edge.y2 - d / 2} ${edge.x2} ${edge.y2}`;
}

function relative(node, canvas) {
  const box = node.getBoundingClientRect();
  const origin = canvas.getBoundingClientRect();
  return {
    x: box.left - origin.left,
    y: box.top - origin.top,
    w: box.width,
    h: box.height,
  };
}

export function buildEdges(canvas, from, targets) {
  const a = relative(from, canvas);
  const edges = [];
  for (const target of targets.slice(0, EDGE_LIMIT)) {
    const b = relative(target, canvas);
    const edge = { key: `${from.dataset.hookId}>${target.dataset.hookId}`, x1: a.x + a.w / 2, x2: b.x + b.w / 2 };
    if (b.y >= a.y + a.h) {
      edge.y1 = a.y + a.h;
      edge.y2 = b.y;
    } else if (b.y + b.h <= a.y) {
      edge.y1 = a.y;
      edge.y2 = b.y + b.h;
    } else {
      edge.y1 = a.y + a.h / 2;
      edge.y2 = b.y + b.h / 2;
    }
    edges.push(edge);
  }
  return edges;
}

export function createSvg() {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "od-edges");
  svg.setAttribute("aria-hidden", "true");
  return svg;
}

export function sizeSvg(svg, canvas) {
  const width = canvas.offsetWidth;
  const height = canvas.offsetHeight;
  svg.setAttribute("width", String(width));
  svg.setAttribute("height", String(height));
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
}

export function renderEdges(svg, edges) {
  svg.textContent = "";
  for (const edge of edges) {
    const path = document.createElementNS(NS, "path");
    path.setAttribute("class", "od-edge");
    path.setAttribute("d", pathD(edge));
    svg.append(path);
  }
}

export function clearEdges(svg) {
  svg.textContent = "";
}

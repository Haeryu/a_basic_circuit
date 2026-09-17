const SVG_NS = "http://www.w3.org/2000/svg";

const LABELS = Object.freeze({
  dff: "D",
  clock: "CNT",
  decoder: "DEC",
  adder: "Σ",
  split: "SPLIT",
  join: "JOIN",
  register: "REG",
  alu: "ALU",
  ram: "RAM",
});

function svgNode(name, attributes = {}) {
  const element = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, String(value));
  return element;
}

function path(d, className = "primitive-symbol-shape") {
  return svgNode("path", { d, class: className });
}

function bubble(x = 104, y = 36) {
  return svgNode("circle", { cx: x, cy: y, r: 5, class: "primitive-symbol-shape primitive-symbol-bubble" });
}

function text(value, x = 60, y = 39, className = "primitive-symbol-text") {
  const element = svgNode("text", { x, y, class: className, "text-anchor": "middle" });
  element.textContent = value;
  return element;
}

function logicGate(kind, svg) {
  const negated = kind === "nand2" || kind === "nor2" || kind === "xnor2";
  const base = kind === "nand2" ? "and2" : kind === "nor2" ? "or2" : kind === "xnor2" ? "xor2" : kind;
  const end = negated ? 96 : 104;
  if (base === "and2") {
    svg.append(path(`M 20 10 H 57 A 26 26 0 0 1 57 62 H 20 Z`));
  } else if (base === "or2" || base === "xor2") {
    svg.append(path(`M 20 10 Q 39 36 20 62 Q 67 62 ${end} 36 Q 67 10 20 10 Z`));
    if (base === "xor2") svg.append(path("M 12 10 Q 31 36 12 62", "primitive-symbol-shape primitive-symbol-extra"));
  }
  if (negated) svg.append(bubble());
}

function mux(kind, svg) {
  if (kind === "mux") {
    svg.append(path("M 24 8 L 94 20 L 94 52 L 24 64 Z"));
    svg.append(text("MUX", 61, 39, "primitive-symbol-text primitive-symbol-small-text"));
  } else {
    svg.append(path("M 24 20 L 94 8 L 94 64 L 24 52 Z"));
    svg.append(text("DEMUX", 61, 39, "primitive-symbol-text primitive-symbol-tiny-text"));
  }
  svg.append(path("M 58 62 V 70", "primitive-symbol-shape primitive-symbol-control"));
}

function triangle(kind, svg) {
  svg.append(path("M 24 10 L 92 36 L 24 62 Z"));
  if (kind === "not") svg.append(bubble(100, 36));
}

function block(kind, svg) {
  if (kind === "adder") {
    svg.append(svgNode("circle", { cx: 60, cy: 36, r: 27, class: "primitive-symbol-shape" }));
    svg.append(text("+", 60, 44, "primitive-symbol-text primitive-symbol-plus"));
    return;
  }
  if (kind === "split") {
    svg.append(path("M 18 36 H 52 M 52 36 L 96 16 M 52 36 L 96 56", "primitive-symbol-shape primitive-symbol-flow"));
    return;
  }
  if (kind === "join") {
    svg.append(path("M 18 16 L 62 36 M 18 56 L 62 36 H 104", "primitive-symbol-shape primitive-symbol-flow"));
    return;
  }
  svg.append(svgNode("rect", { x: 24, y: 9, width: 72, height: 54, rx: 4, class: "primitive-symbol-shape" }));
  svg.append(text(LABELS[kind] ?? kind.toUpperCase(), 60, 40,
    kind === "decoder" ? "primitive-symbol-text primitive-symbol-small-text" : "primitive-symbol-text"));
  if (kind === "dff") {
    svg.append(text("D", 38, 30, "primitive-symbol-pin-text"));
    svg.append(text("Q", 82, 30, "primitive-symbol-pin-text"));
    svg.append(path("M 24 47 L 31 52 L 24 57", "primitive-symbol-shape primitive-symbol-clock-mark"));
  } else if (kind === "register" || kind === "ram") {
    svg.append(path("M 24 47 L 31 52 L 24 57", "primitive-symbol-shape primitive-symbol-clock-mark"));
  }
}

export function hasPrimitiveSymbol(kind) {
  return [
    "not", "buffer", "and2", "or2", "xor2", "nand2", "nor2", "xnor2",
    "mux", "demux", "dff", "clock", "decoder", "adder", "split", "join", "register", "alu", "ram",
  ].includes(kind);
}

export function createPrimitiveSymbol(kind) {
  if (!hasPrimitiveSymbol(kind)) return null;
  const svg = svgNode("svg", {
    class: `primitive-symbol primitive-symbol-${kind}`,
    viewBox: "0 0 120 72",
    "aria-hidden": "true",
    focusable: "false",
  });
  if (["and2", "or2", "xor2", "nand2", "nor2", "xnor2"].includes(kind)) logicGate(kind, svg);
  else if (kind === "not" || kind === "buffer") triangle(kind, svg);
  else if (kind === "mux" || kind === "demux") mux(kind, svg);
  else block(kind, svg);
  return svg;
}

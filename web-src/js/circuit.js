// Zig owns circuit semantics and lowering; this module projects them into DOM-friendly objects.
export const MAX_WIDTH = 64;
export const MAX_ADDRESS_WIDTH = 6;
const SEMANTIC_KIND = Object.freeze({ input: 0, output: 1, not: 2, and2: 3, or2: 4,
  xor2: 5, dff: 6, buffer: 7, nand2: 8, nor2: 9, xnor2: 10, oscillator: 11,
  clock: 12, mux: 13, demux: 14, decoder: 15, adder: 16, split: 17, join: 18, display: 19,
  register: 20, alu: 21, ram: 22 });
const DOCUMENT_KIND = Object.freeze({ ...SEMANTIC_KIND, custom: 23 });
const SEMANTIC_NAME = Object.freeze(Object.entries(SEMANTIC_KIND)
  .sort((a, b) => a[1] - b[1]).map(([name]) => name));
const FIELD = Object.freeze([null, "width", "one", "addressWidth", "splitWidth", "highWidth", "decodedWidth", "two"]);
let semanticWasm = null;

export function setSemanticWasm(wasm) {
  semanticWasm = wasm;
}

function semantics() {
  if (!semanticWasm) throw new Error("Circuit semantics WASM is not configured");
  return semanticWasm;
}
export const META = Object.freeze({
  input: { title: "INPUT", symbol: "IN", inputs: [] },
  oscillator: { title: "OSCILLATOR", symbol: "OSC", inputs: [] },
  clock: { title: "CLOCK", symbol: "COUNT", inputs: ["CLK", "LOAD", "DATA"] },
  output: { title: "OUTPUT", symbol: "OUT", inputs: ["IN"] },
  not: { title: "NOT", symbol: "¬", inputs: ["A"] },
  buffer: { title: "BUFFER", symbol: "▷", inputs: ["A"] },
  and2: { title: "AND", symbol: "&", inputs: ["A", "B"] },
  or2: { title: "OR", symbol: "≥1", inputs: ["A", "B"] },
  xor2: { title: "XOR", symbol: "=1", inputs: ["A", "B"] },
  nand2: { title: "NAND", symbol: "!&", inputs: ["A", "B"] },
  nor2: { title: "NOR", symbol: "!≥1", inputs: ["A", "B"] },
  xnor2: { title: "XNOR", symbol: "≡", inputs: ["A", "B"] },
  dff: { title: "DFF", symbol: "D", inputs: ["D", "CLK"] },
  register: { title: "REGISTER", symbol: "REG", inputs: ["DATA", "LOAD", "CLK"] },
  alu: { title: "ALU", symbol: "ALU", inputs: ["A", "B", "OP"] },
  ram: { title: "RAM", symbol: "RAM", inputs: ["ADDR", "DATA", "WE", "CLK"] },
  mux: { title: "MUX", symbol: "MUX" },
  demux: { title: "DEMUX", symbol: "DEMUX" },
  decoder: { title: "DECODER", symbol: "DEC" },
  adder: { title: "ADDER", symbol: "+" },
  split: { title: "SPLIT", symbol: "↗↘" },
  join: { title: "JOIN", symbol: "⇉" },
  display: { title: "LED", symbol: "LED" },
});

export function validWidth(value, min = 1, max = MAX_WIDTH) {
  return Number.isInteger(value) && value >= min && value <= max;
}

export function validNodeShape(kind, width, addressWidth, splitWidth) {
  if (kind === "custom") return validWidth(width) && validWidth(addressWidth, 1, MAX_ADDRESS_WIDTH)
    && validWidth(splitWidth);
  const semanticKind = SEMANTIC_KIND[kind];
  return semanticKind != null && semantics().abc_sem_valid_shape(semanticKind, width, addressWidth, splitWidth) !== 0;
}

export function maskValue(value, width) {
  if (!validWidth(width)) throw new Error("Bus width must be an integer from 1 to 64");
  return BigInt.asUintN(width, BigInt(value));
}

export function bitValue(value, bit) {
  return Number((BigInt(value) >> BigInt(bit)) & 1n);
}

export function parseInputValue(text, width) {
  text = text.trim();
  if (!/^(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|[0-9]+)$/.test(text)) {
    throw new Error("Use decimal, 0x hexadecimal, 0b binary, or 0o octal");
  }
  const value = BigInt(text);
  if (value > maskValue(-1n, width)) throw new Error(`Value does not fit ${width} bits`);
  const radix = /^0x/i.test(text) ? 16 : /^0b/i.test(text) ? 2 : /^0o/i.test(text) ? 8 : 10;
  return { value, radix };
}

export function formatBusValue(value, width, radix = 16) {
  const prefix = radix === 16 ? "0x" : radix === 2 ? "0b" : radix === 8 ? "0o" : "";
  const digits = radix === 10 ? 1 : Math.ceil(width / Math.log2(radix));
  return prefix + BigInt(value).toString(radix).toUpperCase().padStart(digits, "0");
}

export function busValue(bits) {
  let result = 0n;
  for (let bit = bits.length - 1; bit >= 0; bit -= 1) result = (result << 1n) | BigInt(Boolean(bits[bit]));
  return result;
}

export function makeNode(documentId, kind, x, y, width = 1, definitionId = null) {
  if (kind === "oscillator") width = 1;
  if (kind === "split" || kind === "join") width = Math.max(2, width);
  if (!validWidth(width)) throw new Error("Invalid bus width");
  const node = { documentId, kind, definitionId, width, addressWidth: 1,
    splitWidth: Math.max(1, Math.floor(width / 2)), widthParameters: {},
    label: "", x, y, inputs: [], inputValue: 0n, values: [] };
  if (kind === "oscillator") Object.assign(node, { clockHz: 1, clockRunning: false });
  if (kind === "input" || kind === "clock") node.inputRadix = 16;
  if (kind === "display") Object.assign(node, defaultDisplayLayout(width), { ledMode: "mono", ledColor: "#ffd36f" });
  return node;
}

export function defaultDisplayLayout(width) {
  let columns = Math.min(width === 4 ? 2 : width <= 8 ? 4 : 8, width);
  while (width % columns !== 0) columns -= 1;
  return { ledColumns: columns, ledRows: width / columns };
}

export function resizeDisplay(node, columns, rows) {
  if (!validWidth(columns) || !validWidth(rows) || !validWidth(columns * rows)) {
    throw new Error("LED X × Y must contain 1–64 pixels");
  }
  Object.assign(node, { ledColumns: columns, ledRows: rows, width: columns * rows });
}

function port(label, width, field = "width") { return { label, width, field }; }

function primitivePort(node, output, pin) {
  const wasm = semantics();
  const kind = SEMANTIC_KIND[node.kind];
  if (kind == null) throw new Error(`Unknown chip ${node.kind}`);
  const args = [kind, node.width, node.addressWidth ?? 1, node.splitWidth ?? 1,
    node.ledMode === "rgb" ? 1 : 0, pin];
  const width = output ? wasm.abc_sem_output_width(...args) : wasm.abc_sem_input_width(...args);
  if (!width) throw new Error(`Invalid ${output ? "output" : "input"} port ${pin} for ${node.kind}`);
  const fieldCode = output ? wasm.abc_sem_output_field(...args) : wasm.abc_sem_input_field(...args);
  return { width, field: FIELD[fieldCode] ?? null };
}

function primitivePortCount(node, output) {
  const wasm = semantics();
  const kind = SEMANTIC_KIND[node.kind];
  if (kind == null) throw new Error(`Unknown chip ${node.kind}`);
  const fn = output ? wasm.abc_sem_output_count : wasm.abc_sem_input_count;
  const count = fn(kind, node.width, node.addressWidth ?? 1, node.splitWidth ?? 1,
    node.ledMode === "rgb" ? 1 : 0) >>> 0;
  if (count === 0xffffffff) throw new Error(`Invalid port layout for ${node.kind}`);
  return count;
}

function inputLabel(node, pin) {
  switch (node.kind) {
    case "clock": return ["CLK", "LOAD", "DATA"][pin];
    case "register": return ["DATA", "LOAD", "CLK"][pin];
    case "alu": return ["A", "B", "OP"][pin];
    case "ram": return ["ADDR", "DATA", "WE", "CLK"][pin];
    case "display": return node.ledMode === "rgb" ? ["R", "G", "B"][pin] : "IN";
    case "mux": return pin === 0 ? "SEL" : `D${pin - 1}`;
    case "demux": return pin === 0 ? "D" : "SEL";
    case "decoder": return "ADDR";
    case "adder": return ["A", "B", "CIN"][pin];
    case "split": return "IN";
    case "join": return pin === 0 ? "LOW" : "HIGH";
    default: return META[node.kind]?.inputs?.[pin];
  }
}

function outputLabel(node, pin) {
  switch (node.kind) {
    case "oscillator": return "OSC";
    case "clock": return "COUNT";
    case "register": return "Q";
    case "alu": return pin === 0 ? "Y" : "COUT";
    case "ram": return "Q";
    case "demux": return `Q${pin}`;
    case "decoder": return "ONEHOT";
    case "adder": return pin === 0 ? "SUM" : "COUT";
    case "split": return pin === 0 ? "LOW" : "HIGH";
    default: return "OUT";
  }
}

// Selector is pin zero so changing its width never renumbers the data pins.
export function inputDefs(node, lookup = () => null) {
  if (node.kind === "custom") {
    const resolved = resolveCustom(node, lookup);
    return resolved.definition.inputs.map((p) => port(p.label, resolved.byId.get(p.localId).width, null));
  }
  return Array.from({ length: primitivePortCount(node, false) }, (_, pin) => {
    const info = primitivePort(node, false, pin);
    return port(inputLabel(node, pin), info.width, info.field);
  });
}

export function outputDefs(node, lookup = () => null) {
  if (node.kind === "custom") {
    const resolved = resolveCustom(node, lookup);
    return resolved.definition.outputs.map((p) => port(p.label, resolved.byId.get(p.localId).width, null));
  }
  return Array.from({ length: primitivePortCount(node, true) }, (_, pin) => {
    const info = primitivePort(node, true, pin);
    return port(outputLabel(node, pin), info.width, info.field);
  });
}

export function ensureInputSlots(node, lookup) {
  const count = inputDefs(node, lookup).length;
  while (node.inputs.length < count) node.inputs.push(null);
  // Dormant pins are retained, including connections hidden by a smaller MUX.
}

function cloneDefinitionCandidate(node) {
  return { ...node, widthParameters: { ...(node.widthParameters ?? {}) },
    inputs: (node.inputs ?? []).map((connection) => connection && { ...connection }) };
}

// Turn the boundary of an ordinary selection into compact custom-chip
// interface nodes. External nets are grouped, so one source feeding several
// selected pins becomes one interface input. When the user did not place
// explicit interface nodes, open inputs and terminal outputs are exposed too.
export function inferDefinitionSelection(allNodes, selectedIds, lookup = () => null) {
  if (!(selectedIds instanceof Set)) throw new TypeError("selectedIds must be a Set");
  const selected = allNodes.filter((node) => selectedIds.has(node.documentId));
  if (!selected.length) return [];
  if (selected.some((node) => ["display", "oscillator"].includes(node.kind))) {
    throw new Error("Displays and oscillators stay outside custom chip definitions");
  }
  const copies = new Map(selected.map((node) => [node.documentId, cloneDefinitionCandidate(node)]));
  const byId = new Map(allNodes.map((node) => [node.documentId, node]));
  const bounds = {
    left: Math.min(...selected.map((node) => Number.isFinite(node.x) ? node.x : 0)),
    right: Math.max(...selected.map((node) => (Number.isFinite(node.x) ? node.x : 0) + 200)),
    top: Math.min(...selected.map((node) => Number.isFinite(node.y) ? node.y : 0)),
  };
  let syntheticId = -1;
  let inputIndex = 0, outputIndex = 0;
  const usedInputLabels = new Map(), usedOutputLabels = new Map();
  const uniqueLabel = (value, used, fallback) => {
    const base = (value || fallback).trim().slice(0, 70) || fallback;
    const count = used.get(base) ?? 0;
    used.set(base, count + 1);
    return count ? `${base}${count}` : base;
  };
  const synthetic = (kind, width, label, index) => {
    const node = makeNode(syntheticId--, kind,
      kind === "input" ? bounds.left - 260 : bounds.right + 60,
      bounds.top + index * 110, width);
    node.label = label;
    ensureInputSlots(node, lookup);
    return node;
  };

  const generatedInputs = [];
  const incoming = new Map();
  const hasExplicitInput = selected.some((node) => node.kind === "input");
  for (const original of selected) {
    const target = copies.get(original.documentId);
    const ports = inputDefs(original, lookup);
    for (let pin = 0; pin < ports.length; pin += 1) {
      const connection = original.inputs?.[pin] ?? null;
      if (connection && selectedIds.has(connection.sourceId)) continue;
      if (!connection && hasExplicitInput) continue;
      const key = connection ? `net:${connection.sourceId}/${connection.sourcePort}` : `open:${original.documentId}/${pin}`;
      let interfaceNode = incoming.get(key);
      if (!interfaceNode) {
        const source = connection ? byId.get(connection.sourceId) : null;
        const label = uniqueLabel(source?.label || ports[pin]?.label, usedInputLabels, `IN${inputIndex}`);
        interfaceNode = synthetic("input", ports[pin].width, label, inputIndex++);
        if (connection) interfaceNode._externalConnection = { sourceId: connection.sourceId, sourcePort: connection.sourcePort,
          ...(connection.color ? { color: connection.color } : {}) };
        incoming.set(key, interfaceNode); generatedInputs.push(interfaceNode);
      }
      while (target.inputs.length <= pin) target.inputs.push(null);
      target.inputs[pin] = { sourceId: interfaceNode.documentId, sourcePort: 0,
        ...(connection?.color ? { color: connection.color } : {}) };
    }
  }

  const internallyConsumed = new Set();
  const crossingOutputs = new Set();
  for (const target of allNodes) for (const connection of target.inputs ?? []) {
    if (!connection || !selectedIds.has(connection.sourceId)) continue;
    const key = `${connection.sourceId}/${connection.sourcePort}`;
    if (selectedIds.has(target.documentId)) internallyConsumed.add(key);
    else crossingOutputs.add(key);
  }
  const hasExplicitOutput = selected.some((node) => node.kind === "output");
  const outputNets = new Set(crossingOutputs);
  if (!hasExplicitOutput) {
    for (const source of selected) {
      for (let port = 0; port < outputDefs(source, lookup).length; port += 1) {
        const key = `${source.documentId}/${port}`;
        if (!internallyConsumed.has(key)) outputNets.add(key);
      }
    }
  }
  const generatedOutputs = [];
  for (const key of outputNets) {
    const [sourceIdText, sourcePortText] = key.split("/");
    const sourceId = Number(sourceIdText), sourcePort = Number(sourcePortText);
    const source = byId.get(sourceId), sourceCopy = copies.get(sourceId);
    if (!source || !sourceCopy) continue;
    const port = outputDefs(source, lookup)[sourcePort];
    if (!port) continue;
    const label = uniqueLabel(source.label || port.label, usedOutputLabels, `OUT${outputIndex}`);
    const interfaceNode = synthetic("output", port.width, label, outputIndex++);
    interfaceNode.inputs[0] = { sourceId, sourcePort };
    interfaceNode._exposedSource = { sourceId, sourcePort };
    generatedOutputs.push(interfaceNode);
  }

  return [...generatedInputs, ...selected.map((node) => copies.get(node.documentId)), ...generatedOutputs];
}

export function connectionProblem(target, pin, source, sourcePort, lookup) {
  const out = source ? outputDefs(source, lookup)[sourcePort] : null;
  const input = inputDefs(target, lookup)[pin];
  const status = semantics().abc_sem_connection_status(source ? 1 : 0, out ? 1 : 0, out?.width ?? 0,
    input ? 1 : 0, input?.width ?? 0) >>> 0;
  if (status === 0) return null;
  if (status === 1) return "missing source";
  if (status === 2) return "inactive output";
  if (status === 3) return "inactive input";
  if (status === 4) return `${out.width} → ${input.width} bit`;
  throw new Error("Invalid connection status from WASM");
}

const customCache = new WeakMap();

// Width classes follow internal wires and the data ports of each primitive.
// Fixed one-bit controls cannot accidentally turn into data buses. Split/join
// and decoder dimensions add arithmetic constraints instead of forcing equality.
function definitionReaches(startId, targetId, lookup, seen = new Set()) {
  if (startId === targetId) return true;
  if (seen.has(startId)) return false;
  seen.add(startId);
  const definition = lookup(startId);
  if (!definition) return false;
  return definition.nodes.some((node) => node.kind === "custom" && definitionReaches(node.definitionId, targetId, lookup, seen));
}

export function createDefinition(selected, name, id, lookup = () => null) {
  const selectedIds = new Set(selected.map((n) => n.documentId));
  if (selected.some((n) => ["display", "oscillator"].includes(n.kind))) {
    throw new Error("Displays and oscillators stay outside custom chip definitions");
  }
  for (const node of selected) if (node.kind === "custom") {
    if (!lookup(node.definitionId)) throw new Error("Missing nested custom chip definition");
    if (definitionReaches(node.definitionId, id, lookup)) throw new Error("Custom chip definitions cannot contain themselves recursively");
    resolveCustom(node, lookup);
  }
  const localIds = new Map(selected.map((n, i) => [n.documentId, i + 1]));
  const nodes = selected.map((n) => ({ localId: localIds.get(n.documentId), kind: n.kind,
    width: n.width, addressWidth: n.addressWidth, splitWidth: n.splitWidth, inputValue: 0n,
    x: n.x, y: n.y, label: n.label, definitionId: n.kind === "custom" ? n.definitionId : null,
    widthParameters: n.kind === "custom" ? { ...(n.widthParameters ?? {}) } : {},
    inputs: n.inputs.map((c) => {
      if (!c) return null;
      if (!selectedIds.has(c.sourceId)) throw new Error("Chip input comes from outside the selection");
      return { sourceId: localIds.get(c.sourceId), sourcePort: c.sourcePort,
        ...(/^#[0-9a-fA-F]{6}$/.test(c.color) ? { color: c.color } : {}) };
    }) }));
  const inputs = selected.filter((n) => n.kind === "input").map((n, i) => ({
    localId: localIds.get(n.documentId), label: n.label || `IN${i}` }));
  const outputs = selected.filter((n) => n.kind === "output").map((n, i) => ({
    localId: localIds.get(n.documentId), label: n.label || `OUT${i}` }));
  const wasm = semantics();
  wasm.abc_def_reset();
  const semanticNodes = nodes.filter((node) => node.kind !== "custom");
  const semanticIndex = new Map(semanticNodes.map((node, index) => [node.localId, index]));
  semanticNodes.forEach((node, index) => {
    const kind = SEMANTIC_KIND[node.kind];
    if (kind == null || (wasm.abc_def_add_node(kind, node.width, node.addressWidth ?? 1, node.splitWidth ?? 1) >>> 0) !== index) {
      throw new Error("Invalid chip definition");
    }
  });
  for (const target of selected) target.inputs.forEach((connection, pin) => {
    if (!connection) return;
    const source = selected.find((node) => node.documentId === connection.sourceId);
    const problem = connectionProblem(target, pin, source, connection.sourcePort, lookup);
    if (problem) throw new Error(`Fix the chip's internal wire: ${problem}`);
  });
  semanticNodes.forEach((node) => node.inputs.forEach((connection, pin) => {
    if (!connection) return;
    const target = semanticIndex.get(node.localId);
    const source = semanticIndex.get(connection.sourceId);
    if (source == null) return;
    const status = wasm.abc_def_add_wire(target, pin, source, connection.sourcePort) >>> 0;
    if (status !== 0) throw new Error("Fix the chip's internal wire: invalid port");
  }));
  const compileStatus = wasm.abc_def_compile() >>> 0;
  if (compileStatus === 1) throw new Error("A chip needs valid Input/Output interfaces and internal ports");
  if (compileStatus === 2) throw new Error("Fix the chip's internal wire: bus width mismatch");
  if (compileStatus === 3) throw new Error("Inconsistent internal bus widths");
  if (compileStatus !== 0) throw new Error("Could not build custom chip width semantics");

  const groupCount = wasm.abc_def_group_count() >>> 0;
  const groups = Array.from({ length: groupCount }, (_, index) => ({
    id: `w${index}`,
    value: wasm.abc_def_group_value(index) >>> 0,
    min: wasm.abc_def_group_min(index) >>> 0,
    max: wasm.abc_def_group_max(index) >>> 0,
    labels: [],
  }));
  const bindings = {};
  const fieldCodes = ["width", "addressWidth", "splitWidth", "highWidth", "decodedWidth"]
    .map((field) => [field, FIELD.indexOf(field)]);
  const one = wasm.abc_def_binding(0, FIELD.indexOf("one")) >>> 0;
  if (one !== 0xffffffff) bindings.one = one;
  semanticNodes.forEach((node, index) => {
    for (const [field, code] of fieldCodes) {
      const group = wasm.abc_def_binding(index, code) >>> 0;
      if (group !== 0xffffffff) bindings[`${node.localId}:${field}`] = group;
    }
  });
  const normalizedRelations = Array.from({ length: wasm.abc_def_relation_count() >>> 0 }, (_, index) => {
    const kind = wasm.abc_def_relation_kind(index) >>> 0;
    const a = wasm.abc_def_relation_a(index) >>> 0;
    const b = wasm.abc_def_relation_b(index) >>> 0;
    return kind === 0
      ? { kind: "sum", total: a, low: b, high: wasm.abc_def_relation_c(index) >>> 0 }
      : { kind: "pow", address: a, out: b };
  });
  for (const target of nodes) target.inputs.forEach((wire, pin) => {
    if (!wire) return;
    const source = nodes.find((node) => node.localId === wire.sourceId);
    if (!source || (source.kind !== "custom" && target.kind !== "custom")) return;
    if (target.kind !== "custom") {
      const field = inputDefs(target, lookup)[pin]?.field;
      const group = field && bindings[`${target.localId}:${field}`];
      if (group != null) groups[group].min = groups[group].max = groups[group].value;
    }
    if (source.kind !== "custom") {
      const field = outputDefs(source, lookup)[wire.sourcePort]?.field;
      const group = field && bindings[`${source.localId}:${field}`];
      if (group != null) groups[group].min = groups[group].max = groups[group].value;
    }
  });
  for (const p of [...inputs, ...outputs]) groups[bindings[`${p.localId}:width`]].labels.push(p.label);
  const dependent = groups.flatMap((_, index) => wasm.abc_def_group_dependent(index) ? [index] : []);
  const dependentSet = new Set(dependent);
  const parameters = groups.flatMap((group, index) => group.min !== group.max && !dependentSet.has(index) && group.labels.length
    ? [{ ...group, index, label: group.labels.join(" / ") }] : []);
  const definition = { id, name, nodes, inputs, outputs, groups, bindings, relations: normalizedRelations,
    dependent, parameters };
  resolveWidths(definition, {});
  return definition;
}

// Small finite domains make these constraints exact. Equality classes need no
// search. Arithmetic is solved while editing a custom chip, never per frame.
function resolveWidths(definition, overrides) {
  const wasm = semantics();
  const dependent = new Set(definition.dependent);
  wasm.abc_width_reset();
  definition.groups.forEach((group, index) => {
    const override = overrides[group.id] ?? 0;
    if (override !== 0 && !validWidth(override, group.min, group.max)) {
      throw new Error(`${group.labels.join(" / ") || group.id}: width must be ${group.min}–${group.max}`);
    }
    const added = wasm.abc_width_add_group(group.min, group.max, group.value,
      dependent.has(index) ? 1 : 0, override) >>> 0;
    if (added !== index) throw new Error("Could not prepare custom chip width solver");
  });
  for (const relation of definition.relations) {
    const status = relation.kind === "sum"
      ? wasm.abc_width_add_sum(relation.total, relation.low, relation.high)
      : wasm.abc_width_add_pow(relation.address, relation.out);
    if (status !== 0) throw new Error("Could not prepare custom chip width constraints");
  }
  const status = wasm.abc_width_solve();
  if (status === 2) throw new Error("Could not allocate custom chip width solver");
  if (status !== 0) throw new Error("Widths cannot satisfy the chip's split/join or decoder connections");
  return definition.groups.map((_, index) => wasm.abc_width_value(index));
}

export function resolveCustom(node, lookup) {
  const definition = lookup(node.definitionId);
  if (!definition) throw new Error("Missing custom chip definition");
  const cached = customCache.get(node);
  if (cached?.definition === definition && cached.parameters === node.widthParameters) return cached;
  const widths = resolveWidths(definition, node.widthParameters ?? {});
  const resolved = definition.nodes.map((spec) => {
    const result = { ...spec };
    for (const field of ["width", "addressWidth", "splitWidth"]) {
      const group = definition.bindings[`${spec.localId}:${field}`];
      if (group != null) result[field] = widths[group];
    }
    return result;
  });
  const result = { definition, widths, parameters: node.widthParameters, nodes: resolved,
    byId: new Map(resolved.map((n) => [n.localId, n])) };
  customCache.set(node, result);
  return result;
}

export function changeCustomWidth(node, parameter, width, lookup) {
  const trial = { ...node, widthParameters: { ...node.widthParameters, [parameter]: width } };
  resolveCustom(trial, lookup);
  node.widthParameters = trial.widthParameters;
}

export function readBus(wasm, bus) {
  return (bus ?? []).map((id) => {
    const value = wasm.abc_value(id);
    if (value > 1) throw new Error("Invalid runtime signal");
    return value === 1;
  });
}

export function setRuntimeInput(wasm, handle, value, previous = null) {
  const bus = handle.outputs[0];
  if (previous != null) {
    let changed = BigInt.asUintN(bus.length, BigInt(value) ^ BigInt(previous));
    for (let bit = 0; changed !== 0n; bit += 1, changed >>= 1n) {
      if ((changed & 1n) !== 0n && wasm.abc_set_input(bus[bit], bitValue(value, bit)) !== 0) throw new Error("Could not update input");
    }
    return;
  }
  for (let bit = 0; bit < bus.length; bit += 1) {
    if (wasm.abc_set_input(bus[bit], bitValue(value, bit)) !== 0) throw new Error("Could not update input");
  }
}

export function setRuntimeCounter(wasm, handle, value) {
  if (wasm.abc_set_counter(handle.outputs[0][0], Number(value & 0xffffffffn), Number(value >> 32n)) !== 0) {
    throw new Error("Could not set counter value");
  }
}

const INVALID_ID = 0xffffffff;

function nestedLocalId(path, used) {
  let hash = 0x811c9dc5;
  for (const value of path) {
    let word = Number(value) >>> 0;
    for (let byte = 0; byte < 4; byte += 1) {
      hash ^= word & 0xff;
      hash = Math.imul(hash, 0x01000193) >>> 0;
      word >>>= 8;
    }
  }
  let id = (0x80000000 | (hash & 0x7fffffff)) >>> 0;
  if (id === INVALID_ID) id = 0x80000000;
  while (used.has(id)) {
    id = (0x80000000 | ((id + 1) & 0x7fffffff)) >>> 0;
    if (id === INVALID_ID) id = 0x80000000;
  }
  used.add(id);
  return id;
}

function flattenCustomInstance(instance, lookup) {
  const flatNodes = [];
  const flatById = new Map();
  const usedIds = new Set();

  const addPrimitive = (spec, path, top) => {
    const localId = top ? spec.localId : nestedLocalId([...path, spec.localId], usedIds);
    if (top) {
      if (usedIds.has(localId)) throw new Error("Duplicate custom chip local id");
      usedIds.add(localId);
    }
    const node = { ...spec, localId, kind: !top && spec.kind === "input" ? "buffer" : spec.kind,
      inputs: [] };
    node.flatIndex = flatNodes.length;
    flatNodes.push(node); flatById.set(localId, node);
    return { type: "primitive", localId, flatIndex: node.flatIndex, originalKind: spec.kind };
  };

  const expand = (current, path, top, stack) => {
    if (stack.has(current.definitionId)) throw new Error("Custom chip definitions cannot contain themselves recursively");
    const nextStack = new Set(stack); nextStack.add(current.definitionId);
    const resolved = resolveCustom(current, lookup);
    const entries = new Map();
    const tree = { definition: resolved.definition, entries, inputRefs: [], outputRefs: [] };

    for (const spec of resolved.nodes) {
      if (spec.kind === "custom") {
        const child = expand(spec, [...path, spec.localId], false, nextStack);
        entries.set(spec.localId, { type: "custom", expansion: child, definitionId: spec.definitionId });
      } else {
        entries.set(spec.localId, addPrimitive(spec, path, top));
      }
    }

    const endpoint = (entry, output, pin) => {
      if (!entry) return null;
      if (entry.type === "primitive") return output
        ? { localId: entry.localId, port: pin }
        : { localId: entry.localId, pin };
      return output ? entry.expansion.outputRefs[pin] : entry.expansion.inputRefs[pin];
    };

    for (const target of resolved.nodes) {
      const targetEntry = entries.get(target.localId);
      for (let pin = 0; pin < (target.inputs?.length ?? 0); pin += 1) {
        const wire = target.inputs[pin];
        if (!wire) continue;
        const dst = endpoint(targetEntry, false, pin);
        const src = endpoint(entries.get(wire.sourceId), true, wire.sourcePort);
        if (!dst || !src) throw new Error("Invalid nested custom chip port");
        const flat = flatById.get(dst.localId);
        if (!flat) throw new Error("Invalid nested custom chip target");
        while (flat.inputs.length <= dst.pin) flat.inputs.push(null);
        flat.inputs[dst.pin] = { sourceId: src.localId, sourcePort: src.port,
          ...(/^#[0-9a-fA-F]{6}$/.test(wire.color ?? "") ? { color: wire.color } : {}) };
      }
    }

    tree.inputRefs = resolved.definition.inputs.map((port) => endpoint(entries.get(port.localId), false, 0));
    tree.outputRefs = resolved.definition.outputs.map((port) => endpoint(entries.get(port.localId), true, 0));
    if (tree.inputRefs.some((ref) => !ref) || tree.outputRefs.some((ref) => !ref)) {
      throw new Error("Invalid nested custom chip interface");
    }
    return tree;
  };

  // Generated child ids are part of runtime state keys. Keep them tied to the
  // structural path inside the definition, not to palette definition ids: a
  // save/open or clipboard paste is free to remap definition ids.
  const tree = expand(instance, [], true, new Set());
  return { flatNodes, flatById, tree };
}

function documentStatus(status) {
  if (status === 0) return;
  if (status === 3) throw new Error("Circuit exceeds 250,000 scalar nodes");
  if (status === 4) throw new Error("Could not allocate circuit document compiler");
  if (status === 5) throw new Error("WASM could not compile the circuit document");
  throw new Error("Invalid circuit document");
}

function submitDocument(wasm, nodes, definitions) {
  const lookup = (id) => definitions.find((definition) => definition.id === id);
  const nodeIndex = new Map(nodes.map((node, index) => [node.documentId, index]));
  const customInfo = new Map();
  wasm.abc_doc_reset();
  nodes.forEach((node, index) => {
    const kind = DOCUMENT_KIND[node.kind];
    if (kind == null) throw new Error(`Unknown chip ${node.kind}`);
    const added = wasm.abc_doc_add_node(index, kind, node.width, node.addressWidth ?? 1,
      node.splitWidth ?? 1, node.ledMode === "rgb" ? 1 : 0) >>> 0;
    if (added !== index) throw new Error(`Invalid ${node.kind} shape`);
  });
  nodes.forEach((node, rootIndex) => {
    if (node.kind !== "custom") return;
    const expansion = flattenCustomInstance(node, lookup);
    const custom = wasm.abc_doc_begin_custom(rootIndex) >>> 0;
    if (custom === INVALID_ID) throw new Error("Could not prepare custom chip instance");
    const localIndex = new Map(expansion.flatNodes.map((child, index) => [child.localId, index]));
    expansion.flatNodes.forEach((child, index) => {
      const kind = SEMANTIC_KIND[child.kind];
      if (kind == null) throw new Error(`Unsupported custom chip child ${child.kind}`);
      const added = wasm.abc_doc_add_custom_child(custom, child.localId, kind, child.width,
        child.addressWidth ?? 1, child.splitWidth ?? 1) >>> 0;
      if (added !== index) throw new Error("Invalid custom chip child");
    });
    expansion.flatNodes.forEach((target, targetIndex) => target.inputs.forEach((connection, pin) => {
      if (!connection) return;
      const source = localIndex.get(connection.sourceId) ?? INVALID_ID;
      if (wasm.abc_doc_add_custom_wire(custom, targetIndex, pin, source, connection.sourcePort) !== 0) {
        throw new Error("Could not prepare custom chip wire");
      }
    }));
    for (const port of expansion.tree.inputRefs) {
      const child = localIndex.get(port.localId);
      if (child == null || wasm.abc_doc_add_custom_input(custom, child) !== 0) throw new Error("Invalid custom chip input");
    }
    for (const port of expansion.tree.outputRefs) {
      const child = localIndex.get(port.localId);
      if (child == null || wasm.abc_doc_add_custom_output(custom, child) !== 0) throw new Error("Invalid custom chip output");
    }
    if (wasm.abc_doc_finish_custom(custom) !== 0) throw new Error("Invalid custom chip interface");
    customInfo.set(rootIndex, { custom, expansion });
  });
  nodes.forEach((target, targetIndex) => target.inputs.forEach((connection, pin) => {
    if (!connection) return;
    const source = nodeIndex.get(connection.sourceId) ?? INVALID_ID;
    if (wasm.abc_doc_add_wire(targetIndex, pin, source, connection.sourcePort) !== 0) {
      throw new Error("Could not prepare circuit wire");
    }
  }));
  return { customInfo };
}

function stateRecord(wasm, index, nodes) {
  const rootToken = wasm.abc_doc_state_root(index) >>> 0;
  const root = nodes[rootToken]?.documentId;
  if (root == null) throw new Error("WASM returned an invalid state owner");
  const hasLocal = wasm.abc_doc_state_has_local(index) !== 0;
  const local = wasm.abc_doc_state_local(index) >>> 0;
  const prefix = hasLocal ? `${root}/${local}` : String(root);
  const lane = wasm.abc_doc_state_index(index) >>> 0;
  const style = wasm.abc_doc_state_style(index) >>> 0;
  const kind = SEMANTIC_NAME[wasm.abc_doc_state_kind(index) >>> 0];
  let key;
  if (style === 0 && kind) key = `${prefix}/bit${lane}:${kind}`;
  else if (style === 1) key = `${prefix}/count${lane}:counter`;
  else if (style === 2) key = `${prefix}/oscillator:input`;
  else if (style === 3) key = `${prefix}/native${lane}:node`;
  else throw new Error("WASM returned an invalid state descriptor");
  return { key, node: wasm.abc_doc_state_node(index) >>> 0, restore: wasm.abc_doc_state_restore(index) !== 0 };
}

function documentDiagnostics(wasm, nodes) {
  return Array.from({ length: wasm.abc_doc_diagnostic_count() >>> 0 }, (_, index) => {
    const internal = wasm.abc_doc_diagnostic_internal(index) !== 0;
    const rootToken = wasm.abc_doc_diagnostic_root(index) >>> 0;
    const targetToken = wasm.abc_doc_diagnostic_target(index) >>> 0;
    const rootId = internal ? nodes[rootToken]?.documentId : null;
    const targetId = internal ? targetToken : nodes[targetToken]?.documentId;
    const pin = wasm.abc_doc_diagnostic_pin(index) >>> 0;
    const status = wasm.abc_doc_diagnostic_status(index) >>> 0;
    const problem = status === 1 ? "missing source" : status === 2 ? "inactive output"
      : status === 3 ? "inactive input" : status === 4
        ? `${wasm.abc_doc_diagnostic_source_width(index)} → ${wasm.abc_doc_diagnostic_target_width(index)} bit`
        : "invalid connection";
    const prefix = internal ? `chip #${rootId}: ` : "";
    return { targetId, pin, internal, message: `${prefix}#${targetId} pin ${pin}: ${problem}` };
  });
}

function readDocumentHandle(wasm, handleId, probe = true) {
  if (handleId === INVALID_ID) throw new Error("WASM returned an invalid component handle");
  const inputs = Array.from({ length: wasm.abc_doc_handle_input_count(handleId) >>> 0 }, (_, pin) => {
    const width = wasm.abc_doc_handle_input_width(handleId, pin) >>> 0;
    const connected = wasm.abc_doc_handle_input_connected(handleId, pin) !== 0;
    const bus = connected ? Array.from({ length: width }, (_, bit) => {
      const node = wasm.abc_doc_handle_input_node(handleId, pin, bit) >>> 0;
      if (node === INVALID_ID) throw new Error("WASM returned an invalid input bus");
      return node;
    }) : null;
    return { width, bus };
  });
  const outputs = Array.from({ length: wasm.abc_doc_handle_output_count(handleId) >>> 0 }, (_, pin) => {
    const width = wasm.abc_doc_handle_output_width(handleId, pin) >>> 0;
    return Array.from({ length: width }, (_, bit) => {
      const node = wasm.abc_doc_handle_output_node(handleId, pin, bit) >>> 0;
      if (node === INVALID_ID) throw new Error("WASM returned an invalid output bus");
      return node;
    });
  });
  return { inputs, outputs, probe: probe ? outputs[0] ?? null : null };
}

export function analyzeCircuit(nodes, definitions) {
  const wasm = semantics();
  submitDocument(wasm, nodes, definitions);
  documentStatus(wasm.abc_doc_analyze() >>> 0);
  const stateKeys = new Map();
  for (let index = 0; index < (wasm.abc_doc_state_count() >>> 0); index += 1) {
    stateKeys.set(stateRecord(wasm, index, nodes).key, null);
  }
  return { stateKeys, diagnostics: documentDiagnostics(wasm, nodes), scalarNodes: wasm.abc_doc_scalar_count() >>> 0 };
}

export function compileCircuit(wasm, nodes, definitions, previous = null, stateStore = null) {
  const snapshots = stateStore ?? new Map();
  if (previous) for (const [key, id] of previous.stateKeys) {
    const state = wasm.abc_state(id);
    if (state <= 3) snapshots.set(key, state);
  }
  const { customInfo } = submitDocument(wasm, nodes, definitions);
  documentStatus(wasm.abc_doc_compile() >>> 0);
  const stateKeys = new Map();
  for (let index = 0; index < (wasm.abc_doc_state_count() >>> 0); index += 1) {
    const state = stateRecord(wasm, index, nodes);
    if (state.node === INVALID_ID) throw new Error("WASM returned an invalid state slot");
    stateKeys.set(state.key, state.node);
    if (state.restore && snapshots.has(state.key) && wasm.abc_restore_state(state.node, snapshots.get(state.key)) !== 0) {
      throw new Error("Could not restore circuit state");
    }
  }
  const handles = new Map();
  nodes.forEach((node, index) => {
    const top = readDocumentHandle(wasm, wasm.abc_doc_top_handle(index) >>> 0,
      node.kind !== "custom" && node.kind !== "display");
    const custom = customInfo.get(index);
    if (custom) {
      const flatHandles = custom.expansion.flatNodes.map((_, childIndex) =>
        readDocumentHandle(wasm, wasm.abc_doc_custom_child_handle(custom.custom, childIndex) >>> 0));
      const aliasTree = (tree) => {
        const children = new Map();
        for (const [localId, entry] of tree.entries) {
          if (entry.type === "primitive") children.set(localId, flatHandles[entry.flatIndex]);
          else children.set(localId, aliasTree(entry.expansion));
        }
        const inputs = tree.inputRefs.map((ref) => flatHandles[custom.expansion.flatById.get(ref.localId).flatIndex].inputs[0]);
        const outputs = tree.outputRefs.map((ref) => flatHandles[custom.expansion.flatById.get(ref.localId).flatIndex].outputs[ref.port]);
        return { inputs, outputs, probe: outputs[0] ?? null, children };
      };
      top.children = aliasTree(custom.expansion.tree).children;
    }
    handles.set(node.documentId, top);
  });
  for (const node of nodes) if (node.kind === "input" || node.kind === "oscillator") {
    setRuntimeInput(wasm, handles.get(node.documentId), maskValue(node.inputValue, node.width));
  }
  return { handles, diagnostics: documentDiagnostics(wasm, nodes), stateKeys,
    scalarNodes: wasm.abc_doc_scalar_count() >>> 0 };
}

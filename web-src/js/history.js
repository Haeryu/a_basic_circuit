const MERGE_WINDOW_MS = 800;

function requireArray(value, name) {
  if (!Array.isArray(value)) throw new TypeError(`${name} must be an array`);
  return value;
}

function normalizedDefinitionId(node) {
  return node.definitionId ?? null;
}

function parameterEntries(value) {
  if (value == null) return [];
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("widthParameters must be an object");
  }
  return Object.entries(value).sort(([a], [b]) => a.localeCompare(b));
}

function captureParameters(value) {
  return Object.freeze(Object.fromEntries(parameterEntries(value)));
}

function sameParameters(saved, live) {
  const entries = parameterEntries(live);
  const keys = Object.keys(saved);
  if (keys.length !== entries.length) return false;
  for (let i = 0; i < keys.length; i += 1) {
    if (keys[i] !== entries[i][0] || !Object.is(saved[keys[i]], entries[i][1])) return false;
  }
  return true;
}

function captureConnection(connection) {
  if (connection == null) return null;
  if (typeof connection !== "object" || Array.isArray(connection)) {
    throw new TypeError("node inputs must contain connections or null");
  }
  const saved = {
    sourceId: connection.sourceId,
    sourcePort: connection.sourcePort,
  };
  if (Object.hasOwn(connection, "color")) saved.color = connection.color;
  return Object.freeze(saved);
}

function sameConnection(saved, live) {
  if (saved == null || live == null) return saved == null && live == null;
  if (typeof live !== "object" || Array.isArray(live)) return false;
  if (!Object.is(saved.sourceId, live.sourceId) || !Object.is(saved.sourcePort, live.sourcePort)) return false;
  const savedHasColor = Object.hasOwn(saved, "color");
  return savedHasColor === Object.hasOwn(live, "color") &&
    (!savedHasColor || Object.is(saved.color, live.color));
}

function captureInputs(value) {
  return Object.freeze(requireArray(value, "node.inputs").map(captureConnection));
}

function sameInputs(saved, live) {
  if (!Array.isArray(live) || saved.length !== live.length) return false;
  for (let i = 0; i < saved.length; i += 1) {
    if (!sameConnection(saved[i], live[i])) return false;
  }
  return true;
}

function inputValue(node) {
  const value = node.inputValue ?? 0n;
  if (typeof value !== "bigint") throw new TypeError("inputValue must be a BigInt");
  return value;
}

function ramEntries(value) {
  if (value == null) return [];
  const entries = value instanceof Map ? [...value] : Array.isArray(value) ? [...value] : null;
  if (!entries) throw new TypeError("ramCells must be a Map or entry array");
  for (const entry of entries) {
    if (!Array.isArray(entry) || entry.length !== 2 || typeof entry[0] !== "bigint" || typeof entry[1] !== "bigint") {
      throw new TypeError("ramCells entries must contain BigInt address/value pairs");
    }
  }
  entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  return entries;
}

function captureRamCells(value) {
  return Object.freeze(ramEntries(value).map(([address, word]) => Object.freeze([address, word])));
}

function sameRamCells(saved, live) {
  const entries = ramEntries(live);
  if (saved.length !== entries.length) return false;
  for (let index = 0; index < saved.length; index += 1) {
    if (!Object.is(saved[index][0], entries[index][0]) || !Object.is(saved[index][1], entries[index][1])) return false;
  }
  return true;
}

function captureNode(node) {
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    throw new TypeError("nodes must contain objects");
  }
  const saved = {
    documentId: node.documentId,
    kind: node.kind,
    definitionId: normalizedDefinitionId(node),
    width: node.width,
    addressWidth: node.addressWidth,
    splitWidth: node.splitWidth,
    widthParameters: captureParameters(node.widthParameters),
    label: node.label,
    x: node.x,
    y: node.y,
    inputs: captureInputs(node.inputs),
  };

  if (node.kind === "input") {
    saved.inputValue = inputValue(node);
    saved.inputRadix = node.inputRadix ?? 16;
  } else if (node.kind === "clock") {
    saved.inputRadix = node.inputRadix ?? 16;
  } else if (node.kind === "oscillator") {
    saved.clockHz = node.clockHz;
  } else if (node.kind === "display") {
    saved.ledColumns = node.ledColumns;
    saved.ledRows = node.ledRows;
    saved.ledMode = node.ledMode;
    saved.ledColor = node.ledColor;
  } else if (node.kind === "ram") {
    if (typeof node.ramBase !== "bigint" || typeof node.ramEnd !== "bigint") {
      throw new TypeError("RAM mapped range must use BigInt addresses");
    }
    saved.ramBase = node.ramBase;
    saved.ramEnd = node.ramEnd;
    saved.ramCells = captureRamCells(node.ramCells);
  }

  return Object.freeze(saved);
}

const BASE_FIELDS = Object.freeze([
  "documentId", "kind", "definitionId", "width", "addressWidth", "splitWidth",
  "label", "x", "y",
]);

function descriptorMatchesNode(saved, live) {
  if (live === null || typeof live !== "object" || Array.isArray(live)) return false;
  for (const field of BASE_FIELDS) {
    const value = field === "definitionId" ? normalizedDefinitionId(live) : live[field];
    if (!Object.is(saved[field], value)) return false;
  }
  if (!sameParameters(saved.widthParameters, live.widthParameters) || !sameInputs(saved.inputs, live.inputs)) return false;

  if (saved.kind === "input") {
    return typeof (live.inputValue ?? 0n) === "bigint" &&
      Object.is(saved.inputValue, live.inputValue ?? 0n) &&
      Object.is(saved.inputRadix, live.inputRadix ?? 16);
  }
  if (saved.kind === "oscillator") return Object.is(saved.clockHz, live.clockHz);
  if (saved.kind === "clock") return Object.is(saved.inputRadix, live.inputRadix ?? 16);
  if (saved.kind === "display") {
    return Object.is(saved.ledColumns, live.ledColumns) &&
      Object.is(saved.ledRows, live.ledRows) &&
      Object.is(saved.ledMode, live.ledMode) &&
      Object.is(saved.ledColor, live.ledColor);
  }
  if (saved.kind === "ram") {
    return Object.is(saved.ramBase, live.ramBase) && Object.is(saved.ramEnd, live.ramEnd) &&
      sameRamCells(saved.ramCells, live.ramCells);
  }
  return true;
}

function sameDescriptor(a, b) {
  if (a === b) return true;
  if (a == null || b == null) return false;
  for (const field of BASE_FIELDS) if (!Object.is(a[field], b[field])) return false;

  const aParameters = Object.keys(a.widthParameters);
  const bParameters = Object.keys(b.widthParameters);
  if (aParameters.length !== bParameters.length) return false;
  for (let i = 0; i < aParameters.length; i += 1) {
    const key = aParameters[i];
    if (key !== bParameters[i] || !Object.is(a.widthParameters[key], b.widthParameters[key])) return false;
  }

  if (a.inputs.length !== b.inputs.length) return false;
  for (let i = 0; i < a.inputs.length; i += 1) {
    if (!sameConnection(a.inputs[i], b.inputs[i])) return false;
  }

  if (a.kind === "input") {
    return Object.is(a.inputValue, b.inputValue) && Object.is(a.inputRadix, b.inputRadix);
  }
  if (a.kind === "oscillator") return Object.is(a.clockHz, b.clockHz);
  if (a.kind === "clock") return Object.is(a.inputRadix, b.inputRadix);
  if (a.kind === "display") {
    return Object.is(a.ledColumns, b.ledColumns) &&
      Object.is(a.ledRows, b.ledRows) &&
      Object.is(a.ledMode, b.ledMode) &&
      Object.is(a.ledColor, b.ledColor);
  }
  if (a.kind === "ram") {
    return Object.is(a.ramBase, b.ramBase) && Object.is(a.ramEnd, b.ramEnd) && sameRamCells(a.ramCells, b.ramCells);
  }
  return true;
}

function sameReferenceArray(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) if (a[i] !== b[i]) return false;
  return true;
}

function sameNodeOrder(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (!Object.is(a[i].documentId, b[i].documentId)) return false;
  }
  return true;
}

function sameIdArray(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) if (!Object.is(a[i], b[i])) return false;
  return true;
}

function nodeOrder(nodes) {
  return Object.freeze(nodes.map((node) => node.documentId));
}

function makeSnapshot(nodes, definitions) {
  const frozenNodes = Object.freeze(nodes);
  const frozenDefinitions = Object.freeze(definitions);
  const byId = new Map();
  for (const node of frozenNodes) {
    if (byId.has(node.documentId)) throw new TypeError("documentId values must be unique");
    byId.set(node.documentId, node);
  }
  return {
    nodes: frozenNodes,
    definitions: frozenDefinitions,
    byId,
    view: Object.freeze({ nodes: frozenNodes, definitions: frozenDefinitions }),
  };
}

function initialSnapshot(nodes, definitions) {
  requireArray(nodes, "nodes");
  requireArray(definitions, "definitions");
  return makeSnapshot(nodes.map(captureNode), [...definitions]);
}

function stringBytes(value) {
  return typeof value === "string" ? value.length * 2 : 8;
}

function bigintBytes(value) {
  const magnitude = value < 0n ? -value : value;
  return Math.max(8, Math.ceil(magnitude.toString(2).length / 8));
}

function descriptorBytes(node) {
  if (!node) return 0;
  let bytes = 128 + stringBytes(node.kind) + stringBytes(node.label);
  for (const [key] of Object.entries(node.widthParameters)) bytes += 24 + stringBytes(key);
  for (const connection of node.inputs) {
    bytes += 8;
    if (connection) bytes += 32 + (Object.hasOwn(connection, "color") ? stringBytes(connection.color) : 0);
  }
  if (node.kind === "input") bytes += bigintBytes(node.inputValue) + 8;
  else if (node.kind === "oscillator") bytes += 8;
  else if (node.kind === "display") bytes += 32 + stringBytes(node.ledMode) + stringBytes(node.ledColor);
  else if (node.kind === "ram") {
    bytes += bigintBytes(node.ramBase) + bigintBytes(node.ramEnd);
    for (const [address, word] of node.ramCells) bytes += 16 + bigintBytes(address) + bigintBytes(word);
  }
  return bytes;
}

function frameBytes(changes, beforeOrder, afterOrder, beforeDefinitions, afterDefinitions, mergeKey) {
  let bytes = 96 + stringBytes(mergeKey);
  for (const change of changes) bytes += 40 + descriptorBytes(change.before) + descriptorBytes(change.after);
  if (beforeOrder) bytes += 24 + beforeOrder.length * 8;
  if (afterOrder) bytes += 24 + afterOrder.length * 8;
  if (beforeDefinitions) bytes += 24 + beforeDefinitions.length * 8;
  if (afterDefinitions) bytes += 24 + afterDefinitions.length * 8;
  return bytes;
}

function makeFrame({ changes, beforeOrder = null, afterOrder = null,
  beforeDefinitions = null, afterDefinitions = null, mergeKey = null, mergeTime = 0, effect = null }) {
  const frozenChanges = Object.freeze(changes.map((change) => Object.freeze(change)));
  return Object.freeze({
    changes: frozenChanges,
    beforeOrder,
    afterOrder,
    beforeDefinitions,
    afterDefinitions,
    mergeKey,
    mergeTime,
    effect,
    bytes: frameBytes(frozenChanges, beforeOrder, afterOrder, beforeDefinitions, afterDefinitions, mergeKey) + (effect ? 128 : 0),
  });
}

function isEmptyFrame(frame) {
  return !frame.effect && frame.changes.length === 0 &&
    frame.beforeOrder == null && frame.afterOrder == null &&
    frame.beforeDefinitions == null && frame.afterDefinitions == null;
}

function captureEffect(effect) {
  if (effect == null) return null;
  const capture = (value) => {
    if (!value || !Number.isSafeInteger(value.documentId) || value.documentId < 1 ||
        typeof value.value !== "bigint" || value.value < 0n || value.value > 0xffffffffffffffffn ||
        ![2,8,10,16].includes(value.radix)) throw new TypeError("Invalid counter history effect");
    return Object.freeze({ documentId: value.documentId, value: value.value, radix: value.radix });
  };
  const before = capture(effect.before), after = capture(effect.after);
  if (before.documentId !== after.documentId) throw new TypeError("Counter history effect ids must match");
  if (before.value === after.value && before.radix === after.radix) return null;
  return Object.freeze({ before, after });
}

function transition(current, liveNodes, liveDefinitions, mergeKey, mergeTime, effect = null) {
  requireArray(liveNodes, "nodes");
  requireArray(liveDefinitions, "definitions");

  const seen = new Set();
  const nextNodes = [];
  const changes = [];
  for (const live of liveNodes) {
    if (live === null || typeof live !== "object" || Array.isArray(live)) {
      throw new TypeError("nodes must contain objects");
    }
    const id = live.documentId;
    if (seen.has(id)) throw new TypeError("documentId values must be unique");
    seen.add(id);

    const before = current.byId.get(id) ?? null;
    const after = before && descriptorMatchesNode(before, live) ? before : captureNode(live);
    nextNodes.push(after);
    if (before !== after) changes.push({ id, before, after });
  }

  for (const before of current.nodes) {
    if (!seen.has(before.documentId)) changes.push({ id: before.documentId, before, after: null });
  }

  const orderChanged = !sameNodeOrder(current.nodes, nextNodes);
  const definitionsChanged = !sameReferenceArray(current.definitions, liveDefinitions);
  if (changes.length === 0 && !orderChanged && !definitionsChanged && !effect) return null;

  const nextDefinitions = definitionsChanged ? Object.freeze([...liveDefinitions]) : current.definitions;
  const next = makeSnapshot(nextNodes, nextDefinitions);
  const frame = makeFrame({
    changes,
    beforeOrder: orderChanged ? nodeOrder(current.nodes) : null,
    afterOrder: orderChanged ? nodeOrder(nextNodes) : null,
    beforeDefinitions: definitionsChanged ? current.definitions : null,
    afterDefinitions: definitionsChanged ? nextDefinitions : null,
    mergeKey,
    mergeTime,
    effect,
  });
  return { next, frame };
}

function mergeFrames(first, second) {
  const byId = new Map();
  for (const change of first.changes) {
    byId.set(change.id, { id: change.id, before: change.before, after: change.after });
  }
  for (const change of second.changes) {
    const existing = byId.get(change.id);
    if (existing) existing.after = change.after;
    else byId.set(change.id, { id: change.id, before: change.before, after: change.after });
  }
  const changes = [...byId.values()].filter((change) => !sameDescriptor(change.before, change.after));

  let beforeOrder = first.beforeOrder ?? second.beforeOrder;
  let afterOrder = second.afterOrder ?? first.afterOrder;
  if (beforeOrder && afterOrder && sameIdArray(beforeOrder, afterOrder)) {
    beforeOrder = null;
    afterOrder = null;
  }

  let beforeDefinitions = first.beforeDefinitions ?? second.beforeDefinitions;
  let afterDefinitions = second.afterDefinitions ?? first.afterDefinitions;
  if (beforeDefinitions && afterDefinitions && sameReferenceArray(beforeDefinitions, afterDefinitions)) {
    beforeDefinitions = null;
    afterDefinitions = null;
  }

  const merged = makeFrame({
    changes,
    beforeOrder,
    afterOrder,
    beforeDefinitions,
    afterDefinitions,
    mergeKey: second.mergeKey,
    mergeTime: second.mergeTime,
  });
  return isEmptyFrame(merged) ? null : merged;
}

function addReferencedIds(ids, node) {
  if (!node) return;
  ids.add(node.documentId);
  for (const connection of node.inputs) if (connection) ids.add(connection.sourceId);
}

export class DocumentHistory {
  #limit;
  #byteLimit;
  #current = makeSnapshot([], []);
  #undo = [];
  #redo = [];
  #undoBytes = 0;
  #redoBytes = 0;
  #lastActionWasRecord = false;

  constructor({ limit = 100, byteLimit = 16 * 1024 * 1024 } = {}) {
    if (limit !== Infinity && (!Number.isSafeInteger(limit) || limit < 0)) {
      throw new RangeError("history limit must be a non-negative safe integer or Infinity");
    }
    if (byteLimit !== Infinity && (!Number.isFinite(byteLimit) || byteLimit < 0)) {
      throw new RangeError("history byteLimit must be a non-negative number or Infinity");
    }
    this.#limit = limit;
    this.#byteLimit = byteLimit;
  }

  get canUndo() {
    return this.#undo.length !== 0;
  }

  get canRedo() {
    return this.#redo.length !== 0;
  }

  get current() {
    return this.#current.view;
  }

  reset(nodes, definitions) {
    this.#current = initialSnapshot(nodes, definitions);
    this.#undo = [];
    this.#redo = [];
    this.#undoBytes = 0;
    this.#redoBytes = 0;
    this.#lastActionWasRecord = false;
    return this.#current.view;
  }

  record(nodes, definitions, { mergeKey = null, now = Date.now(), effect = null } = {}) {
    if (!Number.isFinite(now)) throw new TypeError("history time must be finite");
    effect = captureEffect(effect);
    const captured = transition(this.#current, nodes, definitions, mergeKey, now, effect);
    if (!captured) return false;

    this.#clearRedo();
    const previous = this.#undo.at(-1);
    const elapsed = previous ? now - previous.mergeTime : Infinity;
    const canMerge = !effect && !previous?.effect && mergeKey != null && this.#lastActionWasRecord &&
      previous?.mergeKey === mergeKey && elapsed >= 0 && elapsed <= MERGE_WINDOW_MS;

    if (canMerge) {
      this.#undo.pop();
      this.#undoBytes -= previous.bytes;
      const merged = mergeFrames(previous, captured.frame);
      if (merged) {
        this.#undo.push(merged);
        this.#undoBytes += merged.bytes;
        this.#lastActionWasRecord = true;
      } else {
        this.#lastActionWasRecord = false;
      }
    } else {
      this.#undo.push(captured.frame);
      this.#undoBytes += captured.frame.bytes;
      this.#lastActionWasRecord = true;
    }

    this.#current = captured.next;
    this.#trimUndo();
    return true;
  }

  undo() {
    const frame = this.#undo.pop();
    if (!frame) return null;
    this.#undoBytes -= frame.bytes;
    const result = this.#apply(frame, true);
    this.#redo.push(frame);
    this.#redoBytes += frame.bytes;
    this.#lastActionWasRecord = false;
    return result;
  }

  redo() {
    const frame = this.#redo.pop();
    if (!frame) return null;
    this.#redoBytes -= frame.bytes;
    const result = this.#apply(frame, false);
    this.#undo.push(frame);
    this.#undoBytes += frame.bytes;
    this.#lastActionWasRecord = false;
    return result;
  }

  referencedIds() {
    const ids = new Set();
    for (const node of this.#current.nodes) addReferencedIds(ids, node);
    for (const stack of [this.#undo, this.#redo]) {
      for (const frame of stack) {
        if (frame.effect) ids.add(frame.effect.before.documentId);
        for (const change of frame.changes) {
          addReferencedIds(ids, change.before);
          addReferencedIds(ids, change.after);
        }
        for (const order of [frame.beforeOrder, frame.afterOrder]) {
          if (order) for (const id of order) ids.add(id);
        }
      }
    }
    return ids;
  }

  #apply(frame, backwards) {
    const byId = new Map(this.#current.byId);
    for (const change of frame.changes) {
      const node = backwards ? change.before : change.after;
      if (node) byId.set(change.id, node);
      else byId.delete(change.id);
    }

    const savedOrder = backwards ? frame.beforeOrder : frame.afterOrder;
    const order = savedOrder ?? this.#current.nodes.map((node) => node.documentId);
    const nodes = order.map((id) => {
      const node = byId.get(id);
      if (!node) throw new Error("history node order is inconsistent with its delta");
      return node;
    });
    const definitions = (backwards ? frame.beforeDefinitions : frame.afterDefinitions) ?? this.#current.definitions;
    this.#current = makeSnapshot(nodes, definitions);
    return {
      nodes: this.#current.nodes,
      definitions: this.#current.definitions,
      changedIds: new Set(frame.changes.map((change) => change.id)),
      effect: frame.effect ? backwards ? frame.effect.before : frame.effect.after : null,
    };
  }

  #clearRedo() {
    this.#redo = [];
    this.#redoBytes = 0;
  }

  #trimUndo() {
    const countLimit = Math.max(1, this.#limit);
    while (this.#undo.length > 1 &&
      (this.#undo.length > countLimit || this.#undoBytes > this.#byteLimit)) {
      this.#undoBytes -= this.#undo.shift().bytes;
    }
  }
}

import { analyzeCircuit, cloneRamCells, ramAddressLimit } from "./circuit.js";
import { decodeDocumentPayload, encodeDocumentPayload } from "./clipboard.js";

const FORMAT = "a_basic_circuit/project";
const VERSION = 1;
const MAX_TEXT_LENGTH = 32 * 1024 * 1024;
const MAX_STATE_ENTRIES = 250_000;
const MAX_RAM_STATE_CELLS = 250_000;

function projectError(message) {
  const error = new Error(`Invalid circuit project data: ${message}`);
  error.name = "CircuitProjectError";
  return error;
}

function invalid(message) {
  throw projectError(message);
}

function record(value, context) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid(`${context} must be an object`);
  }
  return value;
}

function integer(value, context, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    invalid(`${context} must be an integer from ${min} to ${max}`);
  }
  return value;
}

function counter(value, context) {
  return integer(value, context, 1, Number.MAX_SAFE_INTEGER);
}

function finite(value, context) {
  if (typeof value !== "number" || !Number.isFinite(value)) invalid(`${context} must be finite`);
  return value;
}

function normalizedView(value) {
  if (value === undefined) return { x: 0, y: 0, zoom: 1 };
  record(value, "view");
  const x = value.x === undefined ? 0 : finite(value.x, "view.x");
  const y = value.y === undefined ? 0 : finite(value.y, "view.y");
  const zoom = value.zoom === undefined ? 1 : finite(value.zoom, "view.zoom");
  if (zoom < 0.1 || zoom > 3) invalid("view.zoom must be from 0.1 to 3");
  return { x, y, zoom };
}

function shared(action) {
  try {
    return action();
  } catch (error) {
    if (error?.name === "CircuitProjectError") throw error;
    const message = error instanceof Error ? error.message : String(error);
    invalid(message.replace(/^Invalid circuit clipboard data:\s*/, ""));
  }
}

function validationRuntime(nodes, definitions) {
  return shared(() => analyzeCircuit(nodes, definitions));
}

function originalStateKey(value, documentIndex, context) {
  if (typeof value !== "string") invalid(`${context} must be a string`);
  const slash = value.indexOf("/");
  if (slash <= 0) invalid(`${context} is not a runtime state key`);
  const rootText = value.slice(0, slash);
  if (!/^[1-9][0-9]*$/.test(rootText)) invalid(`${context} has an invalid root document id`);
  const rootId = Number(rootText);
  if (!Number.isSafeInteger(rootId) || String(rootId) !== rootText || !documentIndex.has(rootId)) {
    invalid(`${context} refers to an unknown root document id`);
  }
  return `${documentIndex.get(rootId)}${value.slice(slash)}`;
}

function restoredStateKey(value, nodes, context) {
  if (typeof value !== "string") invalid(`${context} must be a string`);
  const match = /^(0|[1-9][0-9]*)(\/.+)$/.exec(value);
  if (!match) invalid(`${context} is not an encoded runtime state key`);
  const index = Number(match[1]);
  if (!Number.isSafeInteger(index) || index >= nodes.length) {
    invalid(`${context} refers to an unknown root node`);
  }
  return `${nodes[index].documentId}${match[2]}`;
}

function encodedStates(states, expectedStateKeys, nodes) {
  if (!(states instanceof Map)) invalid("options.states must be a Map");
  if (states.size > MAX_STATE_ENTRIES) invalid(`options.states must contain at most ${MAX_STATE_ENTRIES} entries`);
  for (const [key, value] of states) {
    if (typeof key !== "string") invalid("options.states keys must be strings");
    if (!expectedStateKeys.has(key)) invalid(`options.states contains an unknown state key: ${key}`);
    integer(value, `options.states[${key}]`, 0, 3);
  }

  const documentIndex = new Map(nodes.map((node, index) => [node.documentId, index]));
  const result = [];
  for (const key of expectedStateKeys.keys()) {
    if (!states.has(key)) continue;
    result.push([originalStateKey(key, documentIndex, `options.states[${key}]`), states.get(key)]);
  }
  return result;
}

function decodedStates(value, expectedStateKeys, nodes) {
  if (value === undefined) return new Map();
  if (!Array.isArray(value) || value.length > MAX_STATE_ENTRIES) {
    invalid(`root.states must contain at most ${MAX_STATE_ENTRIES} entries`);
  }
  const result = new Map();
  const encodedKeys = new Set();
  for (const [index, entry] of value.entries()) {
    const context = `root.states[${index}]`;
    if (!Array.isArray(entry) || entry.length !== 2) invalid(`${context} must be a [key, value] pair`);
    const [encodedKey, rawValue] = entry;
    if (encodedKeys.has(encodedKey)) invalid(`${context} duplicates a state key`);
    encodedKeys.add(encodedKey);
    const key = restoredStateKey(encodedKey, nodes, `${context}[0]`);
    if (!expectedStateKeys.has(key)) invalid(`${context}[0] is not a live runtime state key`);
    if (result.has(key)) invalid(`${context}[0] duplicates a remapped state key`);
    result.set(key, integer(rawValue, `${context}[1]`, 0, 3));
  }
  return result;
}

function decimalBigInt(value, context, maximum) {
  if (typeof value !== "string" || !/^(?:0|[1-9][0-9]{0,19})$/.test(value)) {
    invalid(`${context} must be an unsigned decimal string`);
  }
  const result = BigInt(value);
  if (result > maximum) invalid(`${context} is out of range`);
  return result;
}

function ramSpecRange(spec) {
  const limit = ramAddressLimit(spec.addressWidth);
  return {
    base: spec.ramBase ?? 0n,
    end: spec.ramEnd ?? limit,
    wordLimit: (1n << BigInt(spec.width)) - 1n,
  };
}

function encodedRamStates(ramStates, ramSpecs, nodes) {
  if (!(ramStates instanceof Map)) invalid("options.ramStates must be a Map");
  if (ramStates.size > ramSpecs.size) invalid("options.ramStates contains too many RAM instances");
  const documentIndex = new Map(nodes.map((node, index) => [node.documentId, index]));
  let totalCells = 0;
  const result = [];
  for (const [key, rawCells] of ramStates) {
    if (typeof key !== "string" || !ramSpecs.has(key)) {
      invalid(`options.ramStates contains an unknown RAM state key: ${key}`);
    }
    let cells;
    try { cells = cloneRamCells(rawCells); }
    catch { invalid(`options.ramStates[${key}] must be a RAM cell Map`); }
    const spec = ramSpecs.get(key);
    const { base, end, wordLimit } = ramSpecRange(spec);
    totalCells += cells.size;
    if (totalCells > MAX_RAM_STATE_CELLS) invalid(`options.ramStates must contain at most ${MAX_RAM_STATE_CELLS} cells`);
    const encodedCells = [];
    for (const [address, word] of cells) {
      if (typeof address !== "bigint" || typeof word !== "bigint" || address < base || address > end) {
        invalid(`options.ramStates[${key}] contains an address outside the mapped range`);
      }
      if (word < 0n || word > wordLimit) invalid(`options.ramStates[${key}] contains a value wider than ${spec.width} bits`);
      if (word !== 0n) encodedCells.push([address.toString(10), word.toString(10)]);
    }
    encodedCells.sort((a, b) => {
      const left = BigInt(a[0]), right = BigInt(b[0]);
      return left < right ? -1 : left > right ? 1 : 0;
    });
    result.push([originalStateKey(key, documentIndex, `options.ramStates[${key}]`), encodedCells]);
  }
  result.sort(([a], [b]) => a.localeCompare(b));
  return result;
}

function decodedRamStates(value, ramSpecs, nodes) {
  if (value === undefined) return new Map();
  if (!Array.isArray(value) || value.length > ramSpecs.size) invalid("root.ramStates contains too many RAM instances");
  const result = new Map();
  let totalCells = 0;
  for (const [index, entry] of value.entries()) {
    const context = `root.ramStates[${index}]`;
    if (!Array.isArray(entry) || entry.length !== 2) invalid(`${context} must be a [key, cells] pair`);
    const key = restoredStateKey(entry[0], nodes, `${context}[0]`);
    const spec = ramSpecs.get(key);
    if (!spec) invalid(`${context}[0] is not a live RAM state key`);
    if (result.has(key)) invalid(`${context}[0] duplicates a remapped RAM state key`);
    if (!Array.isArray(entry[1])) invalid(`${context}[1] must be an array`);
    totalCells += entry[1].length;
    if (totalCells > MAX_RAM_STATE_CELLS) invalid(`root.ramStates must contain at most ${MAX_RAM_STATE_CELLS} cells`);
    const { base, end, wordLimit } = ramSpecRange(spec);
    const limit = ramAddressLimit(spec.addressWidth);
    const cells = new Map();
    for (const [cellIndex, pair] of entry[1].entries()) {
      const cellContext = `${context}[1][${cellIndex}]`;
      if (!Array.isArray(pair) || pair.length !== 2) invalid(`${cellContext} must be an [address, value] pair`);
      const address = decimalBigInt(pair[0], `${cellContext}[0]`, limit);
      if (address < base || address > end) invalid(`${cellContext}[0] is outside the mapped range`);
      if (cells.has(address)) invalid(`${cellContext}[0] duplicates a RAM address`);
      const word = decimalBigInt(pair[1], `${cellContext}[1]`, wordLimit);
      if (word !== 0n) cells.set(address, word);
    }
    result.set(key, cells);
  }
  return result;
}

function encodedOscillatorLevels(nodes) {
  const levels = [];
  for (const [index, node] of nodes.entries()) {
    if (node.kind !== "oscillator") continue;
    if (typeof node.inputValue !== "bigint" || (node.inputValue !== 0n && node.inputValue !== 1n)) {
      invalid(`nodes[${index}].inputValue must be 0n or 1n for an oscillator`);
    }
    levels.push([index, Number(node.inputValue)]);
  }
  return levels;
}

function restoreOscillatorLevels(value, nodes) {
  if (!Array.isArray(value)) invalid("root.oscillatorLevels must be an array");
  const seen = new Set();
  for (const [entryIndex, entry] of value.entries()) {
    const context = `root.oscillatorLevels[${entryIndex}]`;
    if (!Array.isArray(entry) || entry.length !== 2) invalid(`${context} must be a [node, level] pair`);
    const index = integer(entry[0], `${context}[0]`, 0, Math.max(0, nodes.length - 1));
    if (index >= nodes.length || nodes[index].kind !== "oscillator") {
      invalid(`${context}[0] does not refer to an oscillator`);
    }
    if (seen.has(index)) invalid(`${context}[0] duplicates an oscillator`);
    seen.add(index);
    const level = integer(entry[1], `${context}[1]`, 0, 1);
    nodes[index].inputValue = BigInt(level);
    nodes[index].clockRunning = false;
  }
  for (const [index, node] of nodes.entries()) {
    if (node.kind === "oscillator" && !seen.has(index)) invalid(`root.oscillatorLevels is missing node ${index}`);
  }
}

function parseProject(textValue) {
  if (typeof textValue !== "string" || textValue.length === 0 || textValue.length > MAX_TEXT_LENGTH) {
    invalid(`text must contain 1–${MAX_TEXT_LENGTH} characters`);
  }
  let value;
  try {
    value = JSON.parse(textValue);
  } catch {
    invalid("text is not valid JSON");
  }
  record(value, "root");
  if (value.format !== FORMAT || value.version !== VERSION) invalid("unsupported format or version");
  return value;
}

export function serializeProject(nodes, definitions, options = {}) {
  record(options, "options");
  const view = normalizedView(options.view);
  const states = options.states === undefined ? new Map() : options.states;
  const ramStates = options.ramStates === undefined ? new Map() : options.ramStates;
  const document = shared(() => encodeDocumentPayload(nodes, definitions));
  const oscillatorLevels = encodedOscillatorLevels(nodes);
  const runtime = validationRuntime(nodes, definitions);
  const payload = {
    format: FORMAT,
    version: VERSION,
    view,
    definitions: document.definitions,
    nodes: document.nodes,
    oscillatorLevels,
    states: encodedStates(states, runtime.stateKeys, nodes),
    ramStates: encodedRamStates(ramStates, runtime.ramSpecs, nodes),
  };
  const result = JSON.stringify(payload);
  if (result.length > MAX_TEXT_LENGTH) invalid("project is too large to save");
  return result;
}

export function deserializeProject(textValue, options) {
  record(options, "options");
  const nextDocumentId = counter(options.nextDocumentId, "options.nextDocumentId");
  const nextDefinitionId = counter(options.nextDefinitionId, "options.nextDefinitionId");
  const root = parseProject(textValue);
  const view = normalizedView(root.view);
  const decoded = shared(() => decodeDocumentPayload(root, { nextDocumentId, nextDefinitionId }));
  restoreOscillatorLevels(root.oscillatorLevels === undefined ? [] : root.oscillatorLevels, decoded.nodes);
  const runtime = validationRuntime(decoded.nodes, decoded.definitions);
  const states = decodedStates(root.states, runtime.stateKeys, decoded.nodes);
  const ramStates = decodedRamStates(root.ramStates, runtime.ramSpecs, decoded.nodes);
  return {
    nodes: decoded.nodes,
    definitions: decoded.definitions,
    nextDocumentId: decoded.nextDocumentId,
    nextDefinitionId: decoded.nextDefinitionId,
    view,
    states,
    ramStates,
  };
}

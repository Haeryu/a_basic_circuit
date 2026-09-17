import {
  MAX_ADDRESS_WIDTH,
  MAX_WIDTH,
  createDefinition,
  makeNode,
  resolveCustom,
  validNodeShape,
} from "./circuit.js";
import { MIN_CLOCK_HZ, MAX_CLOCK_HZ, validClockHz } from "./clock.js";

const FORMAT = "a_basic_circuit/selection";
const CHIP_FORMAT = "a_basic_circuit/chip";
const CHIPS_FORMAT = "a_basic_circuit/chips";
const VERSION = 1;
const MAX_TEXT_LENGTH = 4 * 1024 * 1024;
const MAX_NODES = 10_000;
const MAX_DEFINITIONS = 512;
const MAX_DEFINITION_NODES = 10_000;
const MAX_TOTAL_DEFINITION_NODES = 20_000;
const MAX_INPUTS = 4_096;
const MAX_SOURCE_PORT = 4_095;
const MAX_PARAMETERS = 4_096;
const MAX_LABEL_LENGTH = 80;
const CLOCK_INPUT_SLOTS = 3; // CLK, LOAD, DATA. Legacy payloads may contain only CLK.

const DOCUMENT_KINDS = new Set([
  "input", "output", "not", "and2", "or2", "xor2", "dff", "buffer",
  "nand2", "nor2", "xnor2", "mux", "demux", "decoder", "adder",
  "split", "join", "display", "custom", "clock", "oscillator", "register", "alu", "ram",
]);
const DEFINITION_KINDS = new Set([...DOCUMENT_KINDS].filter((kind) =>
  kind !== "display" && kind !== "oscillator"));

function clipboardError(message) {
  const error = new Error(`Invalid circuit clipboard data: ${message}`);
  error.name = "CircuitClipboardError";
  return error;
}

function invalid(message) {
  throw clipboardError(message);
}

function record(value, context) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid(`${context} must be an object`);
  }
  return value;
}

function array(value, context, max, minimum = 0) {
  if (!Array.isArray(value) || value.length < minimum || value.length > max) {
    invalid(`${context} must contain ${minimum}–${max} items`);
  }
  return value;
}

function integer(value, context, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    invalid(`${context} must be an integer from ${min} to ${max}`);
  }
  return value;
}

function finite(value, context) {
  if (typeof value !== "number" || !Number.isFinite(value)) invalid(`${context} must be finite`);
  return value;
}

function text(value, context, max = MAX_LABEL_LENGTH, allowEmpty = true) {
  if (typeof value !== "string" || value.length > max || (!allowEmpty && value.length === 0)) {
    invalid(`${context} must be ${allowEmpty ? `at most ${max}` : `1–${max}`} characters`);
  }
  return value;
}

function counter(value, context) {
  return integer(value, context, 1, Number.MAX_SAFE_INTEGER);
}

function id(value, context) {
  return integer(value, context, 1, Number.MAX_SAFE_INTEGER);
}

function nodeFields(raw, context, allowedKinds = DOCUMENT_KINDS) {
  record(raw, context);
  const kind = text(raw.kind, `${context}.kind`, 24, false);
  if (!allowedKinds.has(kind)) invalid(`${context}.kind is not supported`);
  const width = integer(raw.width, `${context}.width`, 1, MAX_WIDTH);
  const addressWidth = integer(raw.addressWidth, `${context}.addressWidth`, 1, MAX_ADDRESS_WIDTH);
  const splitWidth = integer(raw.splitWidth, `${context}.splitWidth`, 1, MAX_WIDTH);
  if (!validNodeShape(kind, width, addressWidth, splitWidth)) invalid(`${context} has an invalid ${kind} shape`);
  return { kind, width, addressWidth, splitWidth };
}

function clockHz(value, context) {
  value = finite(value, context);
  if (!validClockHz(value)) invalid(`${context} must be ${MIN_CLOCK_HZ}–${MAX_CLOCK_HZ} Hz`);
  return value;
}

function inputRadix(value, context) {
  if (![2, 8, 10, 16].includes(value)) invalid(`${context} must be 2, 8, 10, or 16`);
  return value;
}

function ledFields(raw, width, context) {
  const ledColumns = integer(raw.ledColumns, `${context}.ledColumns`, 1, MAX_WIDTH);
  const ledRows = integer(raw.ledRows, `${context}.ledRows`, 1, MAX_WIDTH);
  if (ledColumns * ledRows !== width) invalid(`${context} LED rows × columns must equal its width`);
  const ledMode = raw.ledMode;
  if (ledMode !== "mono" && ledMode !== "rgb") invalid(`${context}.ledMode must be mono or rgb`);
  const ledColor = text(raw.ledColor, `${context}.ledColor`, 7, false);
  if (!/^#[0-9a-fA-F]{6}$/.test(ledColor)) invalid(`${context}.ledColor must be #RRGGBB`);
  return { ledColumns, ledRows, ledMode, ledColor };
}

function wireColor(value, context) {
  if (value == null) return null;
  const color = text(value, context, 7, false);
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) invalid(`${context} must be #RRGGBB`);
  return color;
}

function parameterValues(value, context) {
  record(value, context);
  const entries = Object.entries(value);
  if (entries.length > MAX_PARAMETERS) invalid(`${context} has too many entries`);
  entries.sort(([a], [b]) => a.localeCompare(b));
  const result = {};
  for (const [key, width] of entries) {
    if (!/^w[0-9]+$/.test(key)) invalid(`${context} contains an invalid parameter id`);
    result[key] = integer(width, `${context}.${key}`, 1, MAX_WIDTH);
  }
  return result;
}

function encodedInputValue(node, kind, width, context) {
  if (kind === "clock" || kind === "oscillator") return "0";
  const value = node.inputValue ?? 0n;
  if (typeof value !== "bigint") invalid(`${context}.inputValue must be a BigInt`);
  if (value < 0n || value >= (1n << BigInt(width))) invalid(`${context}.inputValue does not fit its width`);
  return value.toString(10);
}

function decodedInputValue(value, kind, width, context) {
  if (typeof value !== "string" || !/^(?:0|[1-9][0-9]{0,19})$/.test(value)) {
    invalid(`${context}.inputValue must be an unsigned decimal string`);
  }
  const result = BigInt(value);
  if (result >= (1n << BigInt(width))) invalid(`${context}.inputValue does not fit its width`);
  if ((kind === "clock" || kind === "oscillator") && result !== 0n) invalid(`${context} clocks must be copied low`);
  return result;
}

function inputArray(value, context) {
  return array(value, context, MAX_INPUTS);
}

function normalizeClockInputs(kind, inputs, context) {
  if (kind === "clock") {
    if (inputs.length > CLOCK_INPUT_SLOTS) invalid(`${context}.inputs must contain at most ${CLOCK_INPUT_SLOTS} items`);
    while (inputs.length < CLOCK_INPUT_SLOTS) inputs.push(null);
  }
  return inputs;
}

function validateSpecialInputs(kind, inputs, ledMode, context) {
  if (kind === "oscillator" && inputs.length !== 0) invalid(`${context} oscillators cannot have input pins`);
  if (kind === "display") {
    const required = ledMode === "rgb" ? 3 : 1;
    if (inputs.length < required) invalid(`${context} needs ${required} LED input pin${required === 1 ? "" : "s"}`);
  }
}

function encodeSelectionInputs(inputs, selectedIndex, context, rejectExternal = false) {
  return inputArray(inputs, `${context}.inputs`).map((connection, pin) => {
    if (connection == null) return null;
    record(connection, `${context}.inputs[${pin}]`);
    const sourceId = id(connection.sourceId, `${context}.inputs[${pin}].sourceId`);
    const sourcePort = integer(connection.sourcePort, `${context}.inputs[${pin}].sourcePort`, 0, MAX_SOURCE_PORT);
    const color = wireColor(connection.color, `${context}.inputs[${pin}].color`);
    if (!selectedIndex.has(sourceId)) {
      if (rejectExternal) invalid(`${context}.inputs[${pin}] refers to a missing source node`);
      return null;
    }
    const result = { source: selectedIndex.get(sourceId), sourcePort };
    if (color !== null) result.color = color;
    return result;
  });
}

function decodeSelectionInputs(inputs, newIds, context) {
  return inputArray(inputs, `${context}.inputs`).map((connection, pin) => {
    if (connection == null) return null;
    record(connection, `${context}.inputs[${pin}]`);
    const source = integer(connection.source, `${context}.inputs[${pin}].source`, 0, newIds.length - 1);
    const sourcePort = integer(connection.sourcePort, `${context}.inputs[${pin}].sourcePort`, 0, MAX_SOURCE_PORT);
    const color = wireColor(connection.color, `${context}.inputs[${pin}].color`);
    const result = { sourceId: newIds[source], sourcePort };
    if (color !== null) result.color = color;
    return result;
  });
}

function interfaceLabels(definition, localIndex, context) {
  const labels = new Map();
  const add = (ports, kind, field) => {
    for (const [index, port] of array(ports, `${context}.${field}`, MAX_DEFINITION_NODES).entries()) {
      record(port, `${context}.${field}[${index}]`);
      const localId = id(port.localId, `${context}.${field}[${index}].localId`);
      if (!localIndex.has(localId)) invalid(`${context}.${field}[${index}] refers to a missing node`);
      if (definition.nodes[localIndex.get(localId)].kind !== kind) {
        invalid(`${context}.${field}[${index}] refers to a non-${kind} node`);
      }
      if (labels.has(localId)) invalid(`${context} contains a duplicate interface node`);
      labels.set(localId, text(port.label, `${context}.${field}[${index}].label`));
    }
  };
  add(definition.inputs, "input", "inputs");
  add(definition.outputs, "output", "outputs");
  return labels;
}

function definitionSource(definition, context = "definition", definitionIndex = null, lookup = null) {
  record(definition, context);
  const name = text(definition.name, `${context}.name`, MAX_LABEL_LENGTH, false);
  const specs = array(definition.nodes, `${context}.nodes`, MAX_DEFINITION_NODES, 1);
  const localIndex = new Map();
  for (const [index, spec] of specs.entries()) {
    record(spec, `${context}.nodes[${index}]`);
    const localId = id(spec.localId, `${context}.nodes[${index}].localId`);
    if (localIndex.has(localId)) invalid(`${context} contains duplicate local node ids`);
    localIndex.set(localId, index);
  }
  const labels = interfaceLabels(definition, localIndex, context);
  for (const spec of specs) {
    if ((spec.kind === "input" || spec.kind === "output") && !labels.has(spec.localId)) {
      invalid(`${context} is missing an interface label`);
    }
  }
  const nodes = specs.map((spec, index) => {
    const nodeContext = `${context}.nodes[${index}]`;
    const fields = nodeFields(spec, nodeContext, DEFINITION_KINDS);
    const inputs = normalizeClockInputs(fields.kind,
      inputArray(spec.inputs, `${nodeContext}.inputs`).map((connection, pin) => {
        if (connection == null) return null;
        record(connection, `${nodeContext}.inputs[${pin}]`);
        const sourceId = id(connection.sourceId, `${nodeContext}.inputs[${pin}].sourceId`);
        if (!localIndex.has(sourceId)) invalid(`${nodeContext}.inputs[${pin}] comes from outside the definition`);
        return {
          source: localIndex.get(sourceId),
          sourcePort: integer(connection.sourcePort, `${nodeContext}.inputs[${pin}].sourcePort`, 0, MAX_SOURCE_PORT),
          ...(wireColor(connection.color, `${nodeContext}.inputs[${pin}].color`) == null ? {} : { color: connection.color }),
        };
      }), nodeContext);
    const result = {
      kind: fields.kind,
      width: fields.width,
      addressWidth: fields.addressWidth,
      splitWidth: fields.splitWidth,
      label: text(labels.get(spec.localId) ?? spec.label ?? "", `${nodeContext}.label`),
      inputs,
    };
    if (fields.kind === "custom") {
      const definitionId = id(spec.definitionId, `${nodeContext}.definitionId`);
      if (definitionIndex != null && !definitionIndex.has(definitionId)) {
        invalid(`${nodeContext} refers to a missing nested custom definition`);
      }
      const nested = lookup?.(definitionId) ?? null;
      if (lookup && !nested) invalid(`${nodeContext} refers to a missing nested custom definition`);
      const widthParameters = parameterValues(spec.widthParameters ?? {}, `${nodeContext}.widthParameters`);
      if (nested) validateCustomParameters(widthParameters, nested, nodeContext);
      result.definition = definitionIndex == null ? definitionId : definitionIndex.get(definitionId);
      result.widthParameters = widthParameters;
    } else {
      if (spec.definitionId != null) invalid(`${nodeContext}.definitionId is only valid on custom chips`);
      if (Object.keys(parameterValues(spec.widthParameters ?? {}, `${nodeContext}.widthParameters`)).length !== 0) {
        invalid(`${nodeContext}.widthParameters is only valid on custom chips`);
      }
    }
    if (fields.kind === "clock") {
      result.inputRadix = inputRadix(spec.inputRadix ?? 16, `${nodeContext}.inputRadix`);
    } else if (spec.inputRadix !== undefined) {
      invalid(`${nodeContext}.inputRadix is only valid on clocks`);
    }
    if (spec.x != null && spec.y != null) {
      result.x = finite(spec.x, `${nodeContext}.x`); result.y = finite(spec.y, `${nodeContext}.y`);
    }
    return result;
  });
  return { name, nodes };
}

function rebuildDefinition(source, definitionId, context = "definition", resolveDefinition = (value) => value,
  lookup = () => null) {
  record(source, context);
  const name = text(source.name, `${context}.name`, MAX_LABEL_LENGTH, false);
  const specs = array(source.nodes, `${context}.nodes`, MAX_DEFINITION_NODES, 1);
  const nodes = specs.map((spec, index) => {
    const nodeContext = `${context}.nodes[${index}]`;
    const fields = nodeFields(spec, nodeContext, DEFINITION_KINDS);
    const label = text(spec.label, `${nodeContext}.label`);
    let nestedDefinitionId = null;
    let widthParameters = {};
    if (fields.kind === "custom") {
      const reference = integer(spec.definition, `${nodeContext}.definition`, 0, Number.MAX_SAFE_INTEGER);
      nestedDefinitionId = resolveDefinition(reference, nodeContext);
      if (!Number.isSafeInteger(nestedDefinitionId) || nestedDefinitionId < 1) {
        invalid(`${nodeContext} refers to an invalid nested custom definition`);
      }
      const nested = lookup(nestedDefinitionId);
      if (!nested) invalid(`${nodeContext} refers to a missing nested custom definition`);
      widthParameters = parameterValues(spec.widthParameters ?? {}, `${nodeContext}.widthParameters`);
      validateCustomParameters(widthParameters, nested, nodeContext);
    } else {
      if (spec.definition != null) invalid(`${nodeContext}.definition is only valid on custom chips`);
      if (Object.keys(parameterValues(spec.widthParameters ?? {}, `${nodeContext}.widthParameters`)).length !== 0) {
        invalid(`${nodeContext}.widthParameters is only valid on custom chips`);
      }
    }
    let node;
    try {
      node = makeNode(index + 1, fields.kind, finite(spec.x ?? 0, `${nodeContext}.x`), finite(spec.y ?? 0, `${nodeContext}.y`),
        fields.width, nestedDefinitionId);
    } catch (error) {
      invalid(`${nodeContext}: ${error instanceof Error ? error.message : String(error)}`);
    }
    node.addressWidth = fields.addressWidth;
    node.splitWidth = fields.splitWidth;
    node.widthParameters = widthParameters;
    node.label = label;
    node.inputValue = 0n;
    if (fields.kind === "clock") {
      node.inputRadix = inputRadix(spec.inputRadix ?? 16, `${nodeContext}.inputRadix`);
    } else if (spec.inputRadix !== undefined) {
      invalid(`${nodeContext}.inputRadix is only valid on clocks`);
    }
    return node;
  });
  for (const [index, spec] of specs.entries()) {
    const nodeContext = `${context}.nodes[${index}]`;
    nodes[index].inputs = normalizeClockInputs(nodes[index].kind,
      inputArray(spec.inputs, `${nodeContext}.inputs`).map((connection, pin) => {
        if (connection == null) return null;
        record(connection, `${nodeContext}.inputs[${pin}]`);
        const source = integer(connection.source, `${nodeContext}.inputs[${pin}].source`, 0, nodes.length - 1);
        return {
          sourceId: nodes[source].documentId,
          sourcePort: integer(connection.sourcePort, `${nodeContext}.inputs[${pin}].sourcePort`, 0, MAX_SOURCE_PORT),
          ...(wireColor(connection.color, `${nodeContext}.inputs[${pin}].color`) == null ? {} : { color: connection.color }),
        };
      }), nodeContext);
  }
  try {
    const definition = createDefinition(nodes, name, definitionId, lookup);
    for (const [index, node] of nodes.entries()) {
      if (node.kind === "clock") definition.nodes[index].inputRadix = node.inputRadix;
    }
    return definition;
  } catch (error) {
    invalid(`${context}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function definitionFingerprint(definition, context) {
  const source = definitionSource(definition, context);
  for (const node of source.nodes) {
    delete node.x; delete node.y;
    for (const connection of node.inputs) if (connection) delete connection.color;
  }
  return JSON.stringify(source);
}

function validateCustomParameters(parameters, definition, context) {
  const allowed = new Set(definition.parameters.map((parameter) => parameter.id));
  for (const key of Object.keys(parameters)) {
    if (!allowed.has(key)) invalid(`${context}.widthParameters contains an unknown parameter`);
  }
  try {
    resolveCustom({ definitionId: definition.id, widthParameters: parameters },
      (definitionId) => definitionId === definition.id ? definition : null);
  } catch (error) {
    invalid(`${context}.widthParameters: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function encodeDocumentNode(node, selectedIndex, definitionIndex, normalizedDefinitions, minX, minY, context,
  rejectExternalInputs = false) {
  const fields = nodeFields(node, context);
  const widthParameters = parameterValues(node.widthParameters ?? {}, `${context}.widthParameters`);
  if (fields.kind !== "custom" && Object.keys(widthParameters).length !== 0) {
    invalid(`${context}.widthParameters is only valid on custom chips`);
  }
  const inputs = normalizeClockInputs(fields.kind,
    encodeSelectionInputs(node.inputs, selectedIndex, context, rejectExternalInputs), context);
  const result = {
    kind: fields.kind,
    width: fields.width,
    addressWidth: fields.addressWidth,
    splitWidth: fields.splitWidth,
    widthParameters,
    label: text(node.label, `${context}.label`),
    x: finite(node.x, `${context}.x`) - minX,
    y: finite(node.y, `${context}.y`) - minY,
    inputs,
    inputValue: encodedInputValue(node, fields.kind, fields.width, context),
    inputRadix: fields.kind === "input" || fields.kind === "clock"
      ? inputRadix(node.inputRadix ?? 16, `${context}.inputRadix`) : null,
    definition: null,
  };
  if (fields.kind === "custom") {
    const definitionId = id(node.definitionId, `${context}.definitionId`);
    if (!definitionIndex.has(definitionId)) invalid(`${context} refers to a missing custom definition`);
    result.definition = definitionIndex.get(definitionId);
    const normalized = normalizedDefinitions.get(definitionId);
    validateCustomParameters(widthParameters, normalized, context);
    if (inputs.length < normalized.inputs.length) invalid(`${context} is missing custom input slots`);
  }
  if (fields.kind === "oscillator") {
    result.clockHz = clockHz(node.clockHz, `${context}.clockHz`);
    result.clockRunning = false;
  }
  if (fields.kind === "display") Object.assign(result, ledFields(node, fields.width, context));
  validateSpecialInputs(fields.kind, inputs, result.ledMode, context);
  return result;
}

function documentPayload(value, allowEmpty = false) {
  record(value, "root");
  const nodes = array(value.nodes, "root.nodes", MAX_NODES, allowEmpty ? 0 : 1);
  const definitions = array(value.definitions, "root.definitions", MAX_DEFINITIONS);
  let totalDefinitionNodes = 0;
  for (const [index, definition] of definitions.entries()) {
    record(definition, `root.definitions[${index}]`);
    totalDefinitionNodes += array(definition.nodes, `root.definitions[${index}].nodes`, MAX_DEFINITION_NODES, 1).length;
    if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("too many embedded definition nodes");
  }
  return { nodes, definitions };
}

function parsedPayload(value) {
  record(value, "root");
  if (value.format !== FORMAT || value.version !== VERSION) invalid("unsupported format or version");
  return documentPayload(value);
}

function parseClipboard(textValue) {
  if (typeof textValue !== "string" || textValue.length === 0 || textValue.length > MAX_TEXT_LENGTH) {
    invalid(`text must contain 1–${MAX_TEXT_LENGTH} characters`);
  }
  let value;
  try {
    value = JSON.parse(textValue);
  } catch {
    invalid("text is not valid JSON");
  }
  return parsedPayload(value);
}

function advanceDefinitionId(value, used) {
  while (used.has(value)) {
    if (value === Number.MAX_SAFE_INTEGER) invalid("definition id space is exhausted");
    value += 1;
  }
  return value;
}

function buildEncodedPayload(nodes, selectedIds, definitions, {
  allowEmpty = false,
  includeAllDefinitions = false,
  normalizeOrigin = true,
  rejectExternalInputs = false,
  selectAll = false,
  nodeContext = "selection",
} = {}) {
  array(nodes, "nodes", MAX_NODES);
  if (!selectAll && !(selectedIds instanceof Set)) invalid("selectedIds must be a Set");
  array(definitions, "definitions", MAX_DEFINITIONS);

  const selected = [];
  const allIds = new Set();
  for (const [index, node] of nodes.entries()) {
    record(node, `nodes[${index}]`);
    const documentId = id(node.documentId, `nodes[${index}].documentId`);
    if (allIds.has(documentId)) invalid("document contains duplicate node ids");
    allIds.add(documentId);
    if (selectAll || selectedIds.has(documentId)) selected.push(node);
  }
  if (selected.length === 0 && !allowEmpty) throw new Error("Select at least one chip to copy");
  if (!selectAll && selected.length !== selectedIds.size) invalid("selection contains missing node ids");

  const definitionsById = new Map();
  for (const [index, definition] of definitions.entries()) {
    record(definition, `definitions[${index}]`);
    const definitionId = id(definition.id, `definitions[${index}].id`);
    if (definitionsById.has(definitionId)) invalid("definitions contain duplicate ids");
    definitionsById.set(definitionId, definition);
  }

  const selectedIndex = new Map(selected.map((node, index) => [node.documentId, index]));
  const definitionIndex = new Map();
  const normalizedDefinitions = new Map();
  const embeddedDefinitions = [];
  let totalDefinitionNodes = 0;
  const requiredDefinitions = new Set();
  const visitingDefinitions = new Set();
  const visitedDefinitions = new Set();
  const requireDefinition = (definitionId, context) => {
    const definition = definitionsById.get(definitionId);
    if (!definition) invalid(`${context} refers to a missing custom definition`);
    requiredDefinitions.add(definitionId);
    if (visitingDefinitions.has(definitionId)) invalid("custom definitions contain a recursive dependency cycle");
    if (visitedDefinitions.has(definitionId)) return;
    visitingDefinitions.add(definitionId);
    const specs = array(definition.nodes, `definition #${definitionId}.nodes`, MAX_DEFINITION_NODES, 1);
    for (const [index, spec] of specs.entries()) {
      record(spec, `definition #${definitionId}.nodes[${index}]`);
      if (spec.kind !== "custom") continue;
      requireDefinition(id(spec.definitionId, `definition #${definitionId}.nodes[${index}].definitionId`),
        `definition #${definitionId}.nodes[${index}]`);
    }
    visitingDefinitions.delete(definitionId);
    visitedDefinitions.add(definitionId);
  };
  if (includeAllDefinitions) {
    for (const definitionId of definitionsById.keys()) requireDefinition(definitionId, `definition #${definitionId}`);
  } else {
    for (const [index, node] of selected.entries()) {
      if (node.kind !== "custom") continue;
      const definitionId = id(node.definitionId, `${nodeContext}[${index}].definitionId`);
      requireDefinition(definitionId, `${nodeContext}[${index}]`);
    }
  }
  const definitionIds = [...definitionsById.keys()].filter((definitionId) => requiredDefinitions.has(definitionId));
  definitionIds.forEach((definitionId, index) => definitionIndex.set(definitionId, index));
  const sourceLookup = (definitionId) => normalizedDefinitions.get(definitionId) ?? definitionsById.get(definitionId) ?? null;
  for (const definitionId of definitionIds) {
    const definition = definitionsById.get(definitionId);
    const context = `definition #${definitionId}`;
    const source = definitionSource(definition, context, null, sourceLookup);
    const normalized = rebuildDefinition(source, definitionId, context, (value) => value, sourceLookup);
    const normalizedSource = definitionSource(normalized, context, definitionIndex, sourceLookup);
    totalDefinitionNodes += normalizedSource.nodes.length;
    if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("too many embedded definition nodes");
    normalizedDefinitions.set(definitionId, normalized);
    embeddedDefinitions.push(normalizedSource);
  }

  const minX = normalizeOrigin && selected.length
    ? Math.min(...selected.map((node, index) => finite(node.x, `${nodeContext}[${index}].x`))) : 0;
  const minY = normalizeOrigin && selected.length
    ? Math.min(...selected.map((node, index) => finite(node.y, `${nodeContext}[${index}].y`))) : 0;
  return {
    definitions: embeddedDefinitions,
    nodes: selected.map((node, index) => encodeDocumentNode(node, selectedIndex, definitionIndex,
      normalizedDefinitions, minX, minY, `${nodeContext}[${index}]`, rejectExternalInputs)),
  };
}

export function encodeDocumentPayload(nodes, definitions) {
  return buildEncodedPayload(nodes, null, definitions, {
    allowEmpty: true,
    includeAllDefinitions: true,
    normalizeOrigin: false,
    rejectExternalInputs: true,
    selectAll: true,
    nodeContext: "nodes",
  });
}

export function serializeSelection(nodes, selectedIds, definitions) {
  const encoded = buildEncodedPayload(nodes, selectedIds, definitions);
  const payload = {
    format: FORMAT,
    version: VERSION,
    ...encoded,
  };
  const result = JSON.stringify(payload);
  if (result.length > MAX_TEXT_LENGTH) invalid("selection is too large to copy");
  return result;
}

export function serializeChipPackage(definitionId, definitions) {
  const definition = definitions.find((value) => value.id === definitionId);
  if (!definition) throw new Error("Choose an existing custom chip to export");
  const instance = makeNode(1, "custom", 0, 0, 1, definition.id);
  instance.inputs = Array(definition.inputs.length).fill(null);
  const encoded = buildEncodedPayload([instance], new Set([instance.documentId]), definitions, {
    normalizeOrigin: false,
    nodeContext: "chip",
  });
  const root = encoded.nodes[0]?.definition;
  if (!Number.isSafeInteger(root) || root < 0 || root >= encoded.definitions.length) {
    invalid("exported chip root is invalid");
  }
  const result = JSON.stringify({
    format: CHIP_FORMAT,
    version: VERSION,
    root,
    definitions: encoded.definitions,
  });
  if (result.length > MAX_TEXT_LENGTH) invalid("chip package is too large to export");
  return result;
}

export function serializeChipBundle(definitionIds, definitions, { moduleName = "chips" } = {}) {
  if (!Array.isArray(definitionIds) && !(definitionIds instanceof Set)) {
    throw new TypeError("definitionIds must be an array or Set");
  }
  const roots = [...new Set(definitionIds)];
  if (!roots.length) throw new Error("Select at least one custom chip to export");
  moduleName = text(moduleName, "moduleName", MAX_LABEL_LENGTH, false).trim();
  if (!moduleName) throw new Error("Module name cannot be empty");
  const byId = new Map(definitions.map((definition) => [definition.id, definition]));
  const instances = roots.map((definitionId, index) => {
    const definition = byId.get(definitionId);
    if (!definition) throw new Error("Choose existing custom chips to export");
    const instance = makeNode(index + 1, "custom", 0, 0, 1, definition.id);
    instance.inputs = Array(definition.inputs.length).fill(null);
    return instance;
  });
  const encoded = buildEncodedPayload(instances, new Set(instances.map((node) => node.documentId)), definitions, {
    normalizeOrigin: false,
    nodeContext: "chips",
  });
  const encodedRoots = encoded.nodes.map((node) => node.definition);
  if (encodedRoots.some((root) => !Number.isSafeInteger(root) || root < 0 || root >= encoded.definitions.length)) {
    invalid("exported chip bundle root is invalid");
  }
  const exportNames = roots.map((definitionId) => {
    const name = byId.get(definitionId).name;
    return name.startsWith(`${moduleName}.`) ? name.slice(moduleName.length + 1) : name;
  });
  if (new Set(exportNames).size !== exportNames.length) throw new Error("Module export names must be unique");
  const result = JSON.stringify({
    format: CHIPS_FORMAT,
    version: VERSION,
    module: moduleName,
    exports: encodedRoots.map((definition, index) => ({ name: exportNames[index], definition })),
    definitions: encoded.definitions,
  });
  if (result.length > MAX_TEXT_LENGTH) invalid("chip bundle is too large to export");
  return result;
}

function decodePayload(payload, {
  baseDefinitions,
  nextDocumentId,
  nextDefinitionId,
  targetX,
  targetY,
  reuseEquivalentDefinitions,
  allowUnusedDefinitions,
}) {
  if (nextDocumentId > Number.MAX_SAFE_INTEGER - payload.nodes.length) invalid("node id space is exhausted");

  const usedDefinitionIds = new Set();
  const definitions = [...baseDefinitions];
  const equivalent = new Map();
  const validationDefinitions = new Map();
  const baseDefinitionsById = new Map();
  let totalDefinitionNodes = 0;
  for (const [index, definition] of baseDefinitions.entries()) {
    record(definition, `options.definitions[${index}]`);
    const definitionId = id(definition.id, `options.definitions[${index}].id`);
    if (usedDefinitionIds.has(definitionId)) invalid("options.definitions contains duplicate ids");
    usedDefinitionIds.add(definitionId);
    baseDefinitionsById.set(definitionId, definition);
  }
  const baseLookup = (definitionId) => validationDefinitions.get(definitionId) ?? baseDefinitionsById.get(definitionId) ?? null;
  for (const [index, definition] of baseDefinitions.entries()) {
    const definitionId = definition.id;
    const context = `options.definitions[${index}]`;
    const source = definitionSource(definition, context, null, baseLookup);
    totalDefinitionNodes += source.nodes.length;
    if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("options.definitions contains too many nodes");
    const normalized = rebuildDefinition(source, definitionId, context, (value) => value, baseLookup);
    if (reuseEquivalentDefinitions) {
      const fingerprint = definitionFingerprint(normalized, context);
      if (!equivalent.has(fingerprint)) equivalent.set(fingerprint, { definition, normalized });
    }
    validationDefinitions.set(definitionId, normalized);
  }
  nextDefinitionId = advanceDefinitionId(nextDefinitionId, usedDefinitionIds);

  const mappedDefinitionIds = Array(payload.definitions.length).fill(null);
  const definitionState = new Uint8Array(payload.definitions.length);
  const decodedLookup = (definitionId) => validationDefinitions.get(definitionId) ?? baseDefinitionsById.get(definitionId) ?? null;
  const mapDefinition = (index) => {
    if (definitionState[index] === 2) return mappedDefinitionIds[index];
    if (definitionState[index] === 1) invalid("custom definitions contain a recursive dependency cycle");
    definitionState[index] = 1;
    const source = payload.definitions[index];
    const context = `root.definitions[${index}]`;
    record(source, context);
    const specs = array(source.nodes, `${context}.nodes`, MAX_DEFINITION_NODES, 1);
    for (const [nodeIndex, spec] of specs.entries()) {
      record(spec, `${context}.nodes[${nodeIndex}]`);
      if (spec.kind !== "custom") continue;
      const dependency = integer(spec.definition, `${context}.nodes[${nodeIndex}].definition`, 0, payload.definitions.length - 1);
      mapDefinition(dependency);
    }
    const candidate = rebuildDefinition(source, nextDefinitionId, context, (reference, nodeContext) => {
      if (reference >= mappedDefinitionIds.length || mappedDefinitionIds[reference] == null) {
        invalid(`${nodeContext} refers to a missing nested custom definition`);
      }
      return mappedDefinitionIds[reference];
    }, decodedLookup);
    const fingerprint = reuseEquivalentDefinitions ? definitionFingerprint(candidate, context) : null;
    const existing = fingerprint == null ? null : equivalent.get(fingerprint);
    if (existing) {
      mappedDefinitionIds[index] = existing.definition.id;
    } else {
      if (definitions.length === MAX_DEFINITIONS) invalid("too many definitions after paste");
      totalDefinitionNodes += candidate.nodes.length;
      if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("too many definition nodes after paste");
      definitions.push(candidate);
      if (fingerprint != null) equivalent.set(fingerprint, { definition: candidate, normalized: candidate });
      validationDefinitions.set(candidate.id, candidate);
      mappedDefinitionIds[index] = candidate.id;
      usedDefinitionIds.add(candidate.id);
      if (nextDefinitionId === Number.MAX_SAFE_INTEGER) invalid("definition id space is exhausted");
      nextDefinitionId = advanceDefinitionId(nextDefinitionId + 1, usedDefinitionIds);
    }
    definitionState[index] = 2;
    return mappedDefinitionIds[index];
  };
  for (let index = 0; index < payload.definitions.length; index += 1) mapDefinition(index);

  const newIds = payload.nodes.map((_, index) => nextDocumentId + index);
  const referencedDefinitions = new Set();
  const markReferencedDefinition = (index) => {
    if (referencedDefinitions.has(index)) return;
    referencedDefinitions.add(index);
    const source = payload.definitions[index];
    if (!source) invalid("document refers to a missing custom definition");
    const specs = array(source.nodes, `root.definitions[${index}].nodes`, MAX_DEFINITION_NODES, 1);
    for (const [nodeIndex, spec] of specs.entries()) {
      if (spec.kind !== "custom") continue;
      const dependency = integer(spec.definition, `root.definitions[${index}].nodes[${nodeIndex}].definition`,
        0, payload.definitions.length - 1);
      markReferencedDefinition(dependency);
    }
  };
  const nodes = payload.nodes.map((raw, index) => {
    const context = `root.nodes[${index}]`;
    const fields = nodeFields(raw, context);
    const x = targetX + finite(raw.x, `${context}.x`);
    const y = targetY + finite(raw.y, `${context}.y`);
    if (!Number.isFinite(x) || !Number.isFinite(y)) invalid(`${context} position overflows`);
    const widthParameters = parameterValues(raw.widthParameters, `${context}.widthParameters`);
    if (fields.kind !== "custom" && Object.keys(widthParameters).length !== 0) {
      invalid(`${context}.widthParameters is only valid on custom chips`);
    }
    let definitionId = null;
    if (fields.kind === "custom") {
      const definition = integer(raw.definition, `${context}.definition`, 0, mappedDefinitionIds.length - 1);
      markReferencedDefinition(definition);
      definitionId = mappedDefinitionIds[definition];
    } else if (raw.definition !== null) {
      invalid(`${context}.definition is only valid on custom chips`);
    }
    let node;
    try {
      node = makeNode(newIds[index], fields.kind, x, y, fields.width, definitionId);
    } catch (error) {
      invalid(`${context}: ${error instanceof Error ? error.message : String(error)}`);
    }
    node.addressWidth = fields.addressWidth;
    node.splitWidth = fields.splitWidth;
    node.widthParameters = widthParameters;
    node.label = text(raw.label, `${context}.label`);
    node.inputValue = decodedInputValue(raw.inputValue, fields.kind, fields.width, context);
    if (fields.kind === "input") {
      node.inputRadix = inputRadix(raw.inputRadix, `${context}.inputRadix`);
    } else if (fields.kind === "clock") {
      node.inputRadix = raw.inputRadix == null ? 16 : inputRadix(raw.inputRadix, `${context}.inputRadix`);
    } else if (raw.inputRadix !== null) invalid(`${context}.inputRadix is only valid on inputs and clocks`);
    if (fields.kind === "oscillator") {
      node.clockHz = clockHz(raw.clockHz, `${context}.clockHz`);
      if (raw.clockRunning !== false) invalid(`${context}.clockRunning must be false`);
      node.clockRunning = false;
      node.inputValue = 0n;
    }
    if (fields.kind === "display") Object.assign(node, ledFields(raw, fields.width, context));
    return node;
  });

  if (!allowUnusedDefinitions && referencedDefinitions.size !== payload.definitions.length) {
    invalid("clipboard contains an unused custom definition");
  }
  for (const [index, raw] of payload.nodes.entries()) {
    const context = `root.nodes[${index}]`;
    nodes[index].inputs = normalizeClockInputs(nodes[index].kind,
      decodeSelectionInputs(raw.inputs, newIds, context), context);
    validateSpecialInputs(nodes[index].kind, nodes[index].inputs, nodes[index].ledMode, context);
    if (nodes[index].kind === "custom") {
      const definition = validationDefinitions.get(nodes[index].definitionId);
      if (!definition) invalid(`${context} refers to a missing custom definition`);
      if (nodes[index].inputs.length < definition.inputs.length) invalid(`${context} is missing custom input slots`);
      validateCustomParameters(nodes[index].widthParameters, definition, context);
    }
  }

  nextDocumentId += nodes.length;
  return { nodes, definitions: definitions.slice(baseDefinitions.length), nextDocumentId, nextDefinitionId };
}

export function decodeDocumentPayload(value, options) {
  record(options, "options");
  const payload = documentPayload(value, true);
  return decodePayload(payload, {
    baseDefinitions: [],
    nextDocumentId: counter(options.nextDocumentId, "options.nextDocumentId"),
    nextDefinitionId: counter(options.nextDefinitionId, "options.nextDefinitionId"),
    targetX: 0,
    targetY: 0,
    reuseEquivalentDefinitions: false,
    allowUnusedDefinitions: true,
  });
}

export function deserializeSelection(textValue, options) {
  record(options, "options");
  const payload = parseClipboard(textValue);
  return decodePayload(payload, {
    baseDefinitions: array(options.definitions, "options.definitions", MAX_DEFINITIONS),
    nextDocumentId: counter(options.nextDocumentId, "options.nextDocumentId"),
    nextDefinitionId: counter(options.nextDefinitionId, "options.nextDefinitionId"),
    targetX: finite(options.x, "options.x"),
    targetY: finite(options.y, "options.y"),
    reuseEquivalentDefinitions: true,
    allowUnusedDefinitions: false,
  });
}

export function deserializeChipPackage(textValue, options) {
  record(options, "options");
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
  if (value.format !== CHIP_FORMAT || value.version !== VERSION) invalid("unsupported chip format or version");
  const definitions = array(value.definitions, "root.definitions", MAX_DEFINITIONS, 1);
  let totalDefinitionNodes = 0;
  for (const [index, definition] of definitions.entries()) {
    record(definition, `root.definitions[${index}]`);
    totalDefinitionNodes += array(definition.nodes, `root.definitions[${index}].nodes`, MAX_DEFINITION_NODES, 1).length;
    if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("too many embedded definition nodes");
  }
  const root = integer(value.root, "root.root", 0, definitions.length - 1);
  const rootSource = definitions[root];
  const inputCount = rootSource.nodes.reduce((count, spec) => count + (spec?.kind === "input" ? 1 : 0), 0);
  const pseudoNode = {
    kind: "custom",
    width: 1,
    addressWidth: 1,
    splitWidth: 1,
    widthParameters: {},
    label: "",
    x: 0,
    y: 0,
    inputs: Array(inputCount).fill(null),
    inputValue: "0",
    inputRadix: null,
    definition: root,
  };
  const decoded = decodePayload({ definitions, nodes: [pseudoNode] }, {
    baseDefinitions: array(options.definitions, "options.definitions", MAX_DEFINITIONS),
    nextDocumentId: 1,
    nextDefinitionId: counter(options.nextDefinitionId, "options.nextDefinitionId"),
    targetX: 0,
    targetY: 0,
    reuseEquivalentDefinitions: true,
    allowUnusedDefinitions: false,
  });
  return {
    definitions: decoded.definitions,
    rootDefinitionId: decoded.nodes[0].definitionId,
    nextDefinitionId: decoded.nextDefinitionId,
  };
}

export function deserializeChipBundle(textValue, options) {
  record(options, "options");
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
  // Keep the short-lived single-chip format importable; all new exports use the bundle format.
  if (value.format === CHIP_FORMAT && value.version === VERSION) {
    const single = deserializeChipPackage(textValue, options);
    const definition = single.definitions.find((item) => item.id === single.rootDefinitionId) ??
      options.definitions.find((item) => item.id === single.rootDefinitionId) ?? null;
    return { ...single, moduleName: definition?.name ?? "chip",
      exports: [{ name: definition?.name ?? "chip", definitionId: single.rootDefinitionId }],
      rootDefinitionIds: [single.rootDefinitionId] };
  }
  if (value.format !== CHIPS_FORMAT || value.version !== VERSION) invalid("unsupported chip bundle format or version");
  const definitions = array(value.definitions, "root.definitions", MAX_DEFINITIONS, 1);
  let totalDefinitionNodes = 0;
  for (const [index, definition] of definitions.entries()) {
    record(definition, `root.definitions[${index}]`);
    totalDefinitionNodes += array(definition.nodes, `root.definitions[${index}].nodes`, MAX_DEFINITION_NODES, 1).length;
    if (totalDefinitionNodes > MAX_TOTAL_DEFINITION_NODES) invalid("too many embedded definition nodes");
  }
  const moduleName = value.module == null ? "chips" : text(value.module, "root.module", MAX_LABEL_LENGTH, false).trim();
  if (!moduleName) invalid("root.module cannot be empty");
  let exportNames;
  let roots;
  if (value.exports !== undefined) {
    const exports = array(value.exports, "root.exports", MAX_DEFINITIONS, 1);
    exportNames = exports.map((item, index) => {
      record(item, `root.exports[${index}]`);
      return text(item.name, `root.exports[${index}].name`, MAX_LABEL_LENGTH, false);
    });
    roots = exports.map((item, index) => integer(item.definition, `root.exports[${index}].definition`, 0, definitions.length - 1));
    if (new Set(exportNames).size !== exportNames.length) invalid("root.exports contains duplicate names");
  } else {
    roots = array(value.roots, "root.roots", MAX_DEFINITIONS, 1).map((root, index) =>
      integer(root, `root.roots[${index}]`, 0, definitions.length - 1));
    exportNames = roots.map((root) => definitions[root].name);
  }
  if (new Set(roots).size !== roots.length) invalid("root.roots contains duplicate chip roots");
  const pseudoNodes = roots.map((root, index) => {
    const source = definitions[root];
    const inputCount = source.nodes.reduce((count, spec) => count + (spec?.kind === "input" ? 1 : 0), 0);
    return {
      kind: "custom",
      width: 1,
      addressWidth: 1,
      splitWidth: 1,
      widthParameters: {},
      label: "",
      x: index * 20,
      y: 0,
      inputs: Array(inputCount).fill(null),
      inputValue: "0",
      inputRadix: null,
      definition: root,
    };
  });
  const decoded = decodePayload({ definitions, nodes: pseudoNodes }, {
    baseDefinitions: array(options.definitions, "options.definitions", MAX_DEFINITIONS),
    nextDocumentId: 1,
    nextDefinitionId: counter(options.nextDefinitionId, "options.nextDefinitionId"),
    targetX: 0,
    targetY: 0,
    reuseEquivalentDefinitions: true,
    allowUnusedDefinitions: false,
  });
  return {
    definitions: decoded.definitions,
    moduleName,
    exports: decoded.nodes.map((node, index) => ({ name: exportNames[index], definitionId: node.definitionId })),
    rootDefinitionIds: decoded.nodes.map((node) => node.definitionId),
    nextDefinitionId: decoded.nextDefinitionId,
  };
}

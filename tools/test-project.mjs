import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { analyzeCircuit, createDefinition, makeNode, resolveCustom, setSemanticWasm } from "../web-src/js/circuit.js";
import { deserializeSelection, serializeSelection } from "../web-src/js/clipboard.js";
import { deserializeProject, serializeProject } from "../web-src/js/project.js";

const { instance } = await WebAssembly.instantiate(await readFile(new URL("../zig-out/web/wasm/a_basic_circuit.wasm", import.meta.url)), {});
setSemanticWasm(instance.exports);

function node(documentId, kind, x, y, width = 1, extra = {}) {
  return Object.assign(makeNode(documentId, kind, x, y, width, extra.definitionId ?? null), extra);
}

function link(source, target, pin = 0, sourcePort = 0, color) {
  while (target.inputs.length <= pin) target.inputs.push(null);
  const connection = { sourceId: source.documentId, sourcePort };
  if (color !== undefined) connection.color = color;
  target.inputs[pin] = connection;
}

function counterDefinition(id, name = "COUNT CELL") {
  const trigger = node(1, "input", 12, 25, 1, { label: "CLK" });
  const counter = node(2, "clock", 330, 65, 4, { label: "COUNT", inputRadix: 8 });
  const output = node(3, "output", 680, 105, 4, { label: "Q" });
  link(trigger, counter, 0, 0, "#AA5500");
  link(counter, output, 0, 0, "#00AACC");
  const definition = createDefinition([trigger, counter, output], name, id);
  definition.nodes[1].inputRadix = counter.inputRadix;
  return definition;
}

function loadableCounterDefinition(id, name = "LOADABLE COUNT CELL") {
  const clock = node(1, "input", 0, 0, 1, { label: "CLK" });
  const load = node(2, "input", 0, 100, 1, { label: "LOAD" });
  const data = node(3, "input", 0, 200, 8, { label: "DATA" });
  const counter = node(4, "clock", 330, 100, 8, { label: "COUNT", inputRadix: 2 });
  const output = node(5, "output", 660, 100, 8, { label: "Q" });
  link(clock, counter, 0, 0, "#101010");
  link(load, counter, 1, 0, "#202020");
  link(data, counter, 2, 0, "#303030");
  link(counter, output, 0, 0, "#404040");
  const definition = createDefinition([clock, load, data, counter, output], name, id);
  definition.nodes[3].inputRadix = counter.inputRadix;
  return definition;
}

function nestedCounterDefinitions(innerId = 80, outerId = 81) {
  const inner = counterDefinition(innerId, "INNER COUNT CELL");
  const lookup = (id) => id === inner.id ? inner : null;
  const clk = node(1, "input", 0, 0, 1, { label: "CLK" });
  const nested = node(2, "custom", 300, 0, 1, { definitionId: inner.id });
  nested.inputs = [null];
  const output = node(3, "output", 620, 0, 4, { label: "Q" });
  link(clk, nested, 0, 0, "#1234AB");
  link(nested, output, 0, 0, "#AB3412");
  const outer = createDefinition([clk, nested, output], "OUTER COUNT CELL", outerId, lookup);
  return { inner, outer };
}

function fullFixture() {
  const firstDefinition = counterDefinition(30);
  const unusedEquivalentDefinition = counterDefinition(31);
  assert.equal(firstDefinition.parameters.length, 1);

  const data = node(10, "input", -120, 40, 64, {
    inputValue: 0xffffffffffffffffn,
    inputRadix: 2,
    label: "DATA64",
  });
  const selector = node(11, "input", -80, 220, 1, { inputValue: 1n, inputRadix: 10 });
  const mux = node(12, "mux", 160, 80, 64, { addressWidth: 1, label: "MUX" });
  mux.inputs = Array(5).fill(null);
  link(selector, mux, 0, 0, "#112233");
  link(data, mux, 1, 0, "#445566");
  link(data, mux, 4, 0, "#778899");
  const output = node(13, "output", 520, 80, 64, { label: "RESULT" });
  link(mux, output, 0, 0, "#ABCDEF");
  const display = node(14, "display", 520, 300, 15, {
    ledColumns: 3,
    ledRows: 5,
    ledMode: "rgb",
    ledColor: "#12AbEf",
    inputs: [null, null, null],
  });
  const oscillator = node(15, "oscillator", -100, 430, 1, {
    inputValue: 1n,
    clockHz: 2.5,
    clockRunning: true,
  });
  const clock = node(16, "clock", 170, 430, 4, { label: "NATIVE", inputRadix: 8 });
  link(oscillator, clock, 0, 0, "#FEDCBA");
  const custom = node(17, "custom", 510, 480, 1, {
    definitionId: firstDefinition.id,
    widthParameters: { [firstDefinition.parameters[0].id]: 3 },
    label: "CUSTOM COUNT",
  });
  custom.inputs = [null];
  link(oscillator, custom, 0, 0, "#C0FFEE");

  const nodes = [data, selector, mux, output, display, oscillator, clock, custom];
  const definitions = [firstDefinition, unusedEquivalentDefinition];
  const states = new Map([
    ["10/bit63:input", 2],
    ["15/oscillator:input", 3],
    ["16/count3:counter", 2],
    ["17/2/count1:counter", 3],
  ]);
  return { nodes, definitions, states };
}

test("full projects retain the whole graph and palette while normal clipboard paste remains selection-local", () => {
  const { nodes, definitions, states } = fullFixture();
  const text = serializeProject(nodes, definitions, {
    view: { x: -123.5, y: 456.25, zoom: 1.75 },
    states,
  });
  const encoded = JSON.parse(text);
  assert.equal(encoded.format, "a_basic_circuit/project");
  assert.equal(encoded.version, 1);
  assert.equal(encoded.nodes[0].inputValue, "18446744073709551615");
  assert.equal(encoded.nodes[0].inputRadix, 2);
  assert.equal(encoded.nodes[6].inputRadix, 8);
  assert.deepEqual(encoded.nodes[2].inputs[4], { source: 0, sourcePort: 0, color: "#778899" });
  assert.equal(encoded.nodes[5].inputValue, "0", "shared clipboard descriptors keep oscillators normalized low");
  assert.deepEqual(encoded.oscillatorLevels, [[5, 1]]);
  assert.equal(encoded.definitions.length, 2, "unused equivalent palette entries are not deduplicated");
  assert.deepEqual(new Map(encoded.states), new Map([
    ["0/bit63:input", 2],
    ["5/oscillator:input", 3],
    ["6/count3:counter", 2],
    ["7/2/count1:counter", 3],
  ]));

  const loaded = deserializeProject(text, { nextDocumentId: 100, nextDefinitionId: 200 });
  assert.deepEqual(loaded.nodes.map((value) => value.documentId), [100, 101, 102, 103, 104, 105, 106, 107]);
  assert.deepEqual(loaded.definitions.map((value) => value.id), [200, 201]);
  assert.equal(loaded.nextDocumentId, 108);
  assert.equal(loaded.nextDefinitionId, 202);
  assert.deepEqual(loaded.view, { x: -123.5, y: 456.25, zoom: 1.75 });
  assert.equal(loaded.nodes[0].inputValue, 0xffffffffffffffffn);
  assert.equal(loaded.nodes[0].inputRadix, 2);
  assert.equal(loaded.nodes[6].inputRadix, 8);
  assert.deepEqual(loaded.nodes[2].inputs[4], { sourceId: 100, sourcePort: 0, color: "#778899" });
  assert.deepEqual(loaded.nodes[3].inputs[0], { sourceId: 102, sourcePort: 0, color: "#ABCDEF" });
  assert.deepEqual(
    [loaded.nodes[4].ledColumns, loaded.nodes[4].ledRows, loaded.nodes[4].ledMode, loaded.nodes[4].ledColor],
    [3, 5, "rgb", "#12AbEf"],
  );
  assert.equal(loaded.nodes[5].inputValue, 1n);
  assert.equal(loaded.nodes[5].clockHz, 2.5);
  assert.equal(loaded.nodes[5].clockRunning, false);
  assert.equal(loaded.nodes[7].definitionId, 200);
  assert.deepEqual(loaded.nodes[7].widthParameters, { [definitions[0].parameters[0].id]: 3 });
  const resolved = resolveCustom(loaded.nodes[7], (id) => loaded.definitions.find((value) => value.id === id));
  assert.equal(resolved.byId.get(2).width, 3);
  assert.deepEqual(
    [loaded.definitions[0].nodes[1].x, loaded.definitions[0].nodes[1].y, loaded.definitions[0].nodes[1].label],
    [330, 65, "COUNT"],
  );
  assert.equal(loaded.definitions[0].nodes[1].inputRadix, 8);
  assert.deepEqual(loaded.definitions[0].nodes[1].inputs[0], { sourceId: 1, sourcePort: 0, color: "#AA5500" });
  assert.deepEqual(loaded.definitions[0].nodes[2].inputs[0], { sourceId: 2, sourcePort: 0, color: "#00AACC" });
  assert.equal(loaded.states.get("100/bit63:input"), 2);
  assert.equal(loaded.states.get("105/oscillator:input"), 3);
  assert.equal(loaded.states.get("106/count3:counter"), 2);
  assert.equal(loaded.states.get("107/2/count1:counter"), 3);

  const clipboardText = serializeSelection(nodes, new Set([13]), definitions);
  const pasted = deserializeSelection(clipboardText, {
    nextDocumentId: 500,
    nextDefinitionId: 500,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.equal(pasted.nodes[0].inputs[0], null, "selection copy still drops a wire whose source was not selected");
  assert.deepEqual(loaded.nodes[3].inputs[0], { sourceId: 102, sourcePort: 0, color: "#ABCDEF" });
  assert.throws(() => serializeSelection(nodes, null, definitions), /selectedIds must be a Set/);

  const clockText = serializeSelection(nodes, new Set([16]), definitions);
  const pastedClock = deserializeSelection(clockText, {
    nextDocumentId: 600,
    nextDefinitionId: 600,
    definitions: [],
    x: 20,
    y: 30,
  });
  assert.equal(pastedClock.nodes[0].inputRadix, 8);
  assert.equal(pastedClock.nodes[0].inputValue, 0n, "native counter count stays in runtime state, not clipboard fields");

  loaded.nodes[0].label = "CHANGED";
  loaded.nodes[2].inputs[4].color = "#000000";
  assert.equal(nodes[0].label, "DATA64");
  assert.equal(nodes[2].inputs[4].color, "#778899");
});

test("projects preserve counter load wiring and native history while clipboard paste starts fresh", () => {
  const edge = node(20, "input", 0, 0, 1, { inputValue: 1n });
  const load = node(21, "input", 0, 100, 1, { inputValue: 1n });
  const data = node(22, "input", 0, 200, 8, { inputValue: 0xa5n, inputRadix: 16 });
  const counter = node(23, "clock", 300, 100, 8, { inputRadix: 2 });
  link(edge, counter, 0, 0, "#123456");
  link(load, counter, 1, 0, "#234567");
  link(data, counter, 2, 0, "#345678");

  const definition = loadableCounterDefinition(90);
  const custom = node(24, "custom", 600, 100, 1, { definitionId: definition.id });
  custom.inputs = [null, null, null];
  link(edge, custom, 0, 0, "#456789");
  link(load, custom, 1, 0, "#56789A");
  link(data, custom, 2, 0, "#6789AB");

  const savedCounterStates = [3, 2, 3, 2, 2, 3, 2, 3];
  const states = new Map([
    ["20/bit0:input", 3],
    ...savedCounterStates.map((value, bit) => [`23/count${bit}:counter`, value]),
    ["24/4/count0:counter", 1],
    ["24/4/count7:counter", 3],
  ]);
  const text = serializeProject([edge, load, data, counter, custom], [definition], { states });
  const encoded = JSON.parse(text);
  assert.deepEqual(encoded.nodes[3].inputs, [
    { source: 0, sourcePort: 0, color: "#123456" },
    { source: 1, sourcePort: 0, color: "#234567" },
    { source: 2, sourcePort: 0, color: "#345678" },
  ]);
  assert.deepEqual(encoded.nodes[4].inputs, [
    { source: 0, sourcePort: 0, color: "#456789" },
    { source: 1, sourcePort: 0, color: "#56789A" },
    { source: 2, sourcePort: 0, color: "#6789AB" },
  ]);
  assert.deepEqual(encoded.definitions[0].nodes[3].inputs, [
    { source: 0, sourcePort: 0, color: "#101010" },
    { source: 1, sourcePort: 0, color: "#202020" },
    { source: 2, sourcePort: 0, color: "#303030" },
  ]);
  const encodedStates = new Map(encoded.states);
  assert.equal(encodedStates.get("0/bit0:input"), 3);
  for (const [bit, value] of savedCounterStates.entries()) {
    assert.equal(encodedStates.get(`3/count${bit}:counter`), value);
  }
  assert.equal(encodedStates.get("4/4/count0:counter"), 1);
  assert.equal(encodedStates.get("4/4/count7:counter"), 3);

  const loaded = deserializeProject(text, { nextDocumentId: 100, nextDefinitionId: 200 });
  assert.deepEqual(loaded.nodes[3].inputs, [
    { sourceId: 100, sourcePort: 0, color: "#123456" },
    { sourceId: 101, sourcePort: 0, color: "#234567" },
    { sourceId: 102, sourcePort: 0, color: "#345678" },
  ]);
  assert.deepEqual(loaded.nodes[4].inputs, [
    { sourceId: 100, sourcePort: 0, color: "#456789" },
    { sourceId: 101, sourcePort: 0, color: "#56789A" },
    { sourceId: 102, sourcePort: 0, color: "#6789AB" },
  ]);
  assert.deepEqual(loaded.definitions[0].nodes[3].inputs, [
    { sourceId: 1, sourcePort: 0, color: "#101010" },
    { sourceId: 2, sourcePort: 0, color: "#202020" },
    { sourceId: 3, sourcePort: 0, color: "#303030" },
  ]);
  assert.equal(loaded.nodes[3].inputRadix, 2);
  assert.equal(loaded.definitions[0].nodes[3].inputRadix, 2);
  assert.equal(loaded.states.get("100/bit0:input"), 3);
  for (const [bit, value] of savedCounterStates.entries()) {
    assert.equal(loaded.states.get(`103/count${bit}:counter`), value);
  }
  assert.equal(loaded.states.get("104/4/count0:counter"), 1);
  assert.equal(loaded.states.get("104/4/count7:counter"), 3);

  const clipboardText = serializeSelection(
    [edge, load, data, counter],
    new Set([20, 21, 22, 23]),
    [definition],
  );
  const clipboardPayload = JSON.parse(clipboardText);
  assert.equal(Object.hasOwn(clipboardPayload, "states"), false);
  const pasted = deserializeSelection(clipboardText, {
    nextDocumentId: 300,
    nextDefinitionId: 400,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.equal(Object.hasOwn(pasted, "states"), false);
  assert.equal(pasted.nodes[3].inputValue, 0n);
  assert.deepEqual(pasted.nodes[3].inputs, [
    { sourceId: 300, sourcePort: 0, color: "#123456" },
    { sourceId: 301, sourcePort: 0, color: "#234567" },
    { sourceId: 302, sourcePort: 0, color: "#345678" },
  ]);
});

test("projects preserve mapped RAM image and live sparse state above 2^53", () => {
  const base = 0x0020000000000001n, end = base + 0xffn;
  const ram = node(42, "ram", 100, 100, 64, {
    addressWidth: 64,
    ramBase: base,
    ramEnd: end,
    ramCells: new Map([[base, 0x1111222233334444n]]),
  });
  const liveCells = new Map([
    [base, 0xaaaaaaaaaaaaaaaan],
    [base + 0x80n, 0x8000000100000001n],
    [end, 0xffffffffffffffffn],
  ]);
  const text = serializeProject([ram], [], { ramStates: new Map([["42/ram", liveCells]]) });
  const encoded = JSON.parse(text);
  assert.equal(encoded.nodes[0].ramBase, base.toString(10));
  assert.equal(encoded.nodes[0].ramEnd, end.toString(10));
  assert.deepEqual(encoded.nodes[0].ramCells, [[base.toString(10), "1229801703532086340"]]);
  assert.deepEqual(encoded.ramStates, [["0/ram", [
    [base.toString(10), "12297829382473034410"],
    [(base + 0x80n).toString(10), "9223372041149743105"],
    [end.toString(10), "18446744073709551615"],
  ]]]);

  const loaded = deserializeProject(text, { nextDocumentId: 100, nextDefinitionId: 1 });
  assert.equal(loaded.nodes[0].documentId, 100);
  assert.equal(loaded.nodes[0].addressWidth, 64);
  assert.equal(loaded.nodes[0].ramBase, base);
  assert.equal(loaded.nodes[0].ramEnd, end);
  assert.equal(loaded.nodes[0].ramCells.get(base), 0x1111222233334444n);
  assert.deepEqual([...loaded.ramStates.get("100/ram")], [...liveCells]);

  const legacy = JSON.parse(text);
  delete legacy.ramStates;
  const legacyLoaded = deserializeProject(JSON.stringify(legacy), { nextDocumentId: 200, nextDefinitionId: 1 });
  assert.equal(legacyLoaded.ramStates.size, 0);
  assert.equal(legacyLoaded.nodes[0].ramCells.get(base), 0x1111222233334444n,
    "legacy projects without runtime RAM snapshots still retain the document image");
});

test("legacy projects normalize empty and CLK-only clock inputs in documents and custom definitions", () => {
  const edge = node(1, "input", 0, 0, 1);
  const connected = node(2, "clock", 200, 0, 4, { inputRadix: 8 });
  const empty = node(3, "clock", 200, 200, 4, { inputRadix: 16 });
  link(edge, connected, 0, 0, "#ABCDEF");

  const definition = counterDefinition(70);
  const custom = node(4, "custom", 500, 0, 1, { definitionId: definition.id });
  custom.inputs = [null];
  link(edge, custom);

  const payload = JSON.parse(serializeProject([edge, connected, empty, custom], [definition]));
  assert.equal(connected.inputs.length, 1, "encoding does not mutate a legacy document clock");
  assert.equal(empty.inputs.length, 0, "encoding does not add slots to the caller's empty clock");
  assert.equal(definition.nodes[1].inputs.length, 1, "encoding does not mutate a palette definition");
  assert.equal(payload.nodes[1].inputs.length, 3);
  assert.deepEqual(payload.nodes[2].inputs, [null, null, null]);
  assert.equal(payload.definitions[0].nodes[1].inputs.length, 3);
  payload.nodes[1].inputs = payload.nodes[1].inputs.slice(0, 1);
  payload.nodes[2].inputs = [];
  payload.definitions[0].nodes[1].inputs = payload.definitions[0].nodes[1].inputs.slice(0, 1);

  const loaded = deserializeProject(JSON.stringify(payload), {
    nextDocumentId: 100,
    nextDefinitionId: 200,
  });
  assert.deepEqual(loaded.nodes[1].inputs, [
    { sourceId: 100, sourcePort: 0, color: "#ABCDEF" },
    null,
    null,
  ]);
  assert.deepEqual(loaded.nodes[2].inputs, [null, null, null]);
  assert.deepEqual(loaded.definitions[0].nodes[1].inputs, [
    { sourceId: 1, sourcePort: 0, color: "#AA5500" },
    null,
    null,
  ]);

  const invalidDocument = JSON.parse(JSON.stringify(payload));
  invalidDocument.nodes[1].inputs.push(null, null, null);
  assert.throws(() => deserializeProject(JSON.stringify(invalidDocument), {
    nextDocumentId: 300,
    nextDefinitionId: 400,
  }), /at most 3 items/);

  const invalidDefinition = JSON.parse(JSON.stringify(payload));
  invalidDefinition.definitions[0].nodes[1].inputs.push(null, null, null);
  assert.throws(() => deserializeProject(JSON.stringify(invalidDefinition), {
    nextDocumentId: 300,
    nextDefinitionId: 400,
  }), /at most 3 items/);
});

test("empty canvases preserve every unused palette definition with fresh ids", () => {
  const definitions = [counterDefinition(70), counterDefinition(71)];
  const text = serializeProject([], definitions);
  const loaded = deserializeProject(text, { nextDocumentId: 40, nextDefinitionId: 90 });
  assert.deepEqual(loaded.nodes, []);
  assert.deepEqual(loaded.definitions.map((definition) => definition.id), [90, 91]);
  assert.deepEqual(loaded.definitions.map((definition) => definition.name), ["COUNT CELL", "COUNT CELL"]);
  assert.equal(loaded.nextDocumentId, 40);
  assert.equal(loaded.nextDefinitionId, 92);
  assert.deepEqual(loaded.view, { x: 0, y: 0, zoom: 1 });
  assert.deepEqual([...loaded.states], []);
});

test("projects roundtrip nested custom definitions and remap stable nested runtime state keys", () => {
  const { inner, outer } = nestedCounterDefinitions();
  const edge = node(10, "input", 0, 0, 1);
  const custom = node(11, "custom", 300, 0, 1, { definitionId: outer.id });
  custom.inputs = [null];
  link(edge, custom, 0, 0, "#0F1E2D");
  const definitions = [outer, inner]; // Parent first: serialized definitions contain a forward reference.
  const analysis = analyzeCircuit([edge, custom], definitions);
  const nestedCounterKey = [...analysis.stateKeys.keys()].find((key) => key.startsWith("11/") && key.endsWith(":counter"));
  assert.ok(nestedCounterKey);
  const text = serializeProject([edge, custom], definitions, {
    view: { x: 13, y: -27, zoom: 1.25 },
    states: new Map([[nestedCounterKey, 3]]),
  });
  const encoded = JSON.parse(text);
  assert.equal(encoded.definitions.length, 2);
  const outerIndex = encoded.definitions.findIndex((definition) => definition.name === "OUTER COUNT CELL");
  const innerIndex = encoded.definitions.findIndex((definition) => definition.name === "INNER COUNT CELL");
  assert.equal(encoded.definitions[outerIndex].nodes.find((value) => value.kind === "custom").definition, innerIndex);

  const loaded = deserializeProject(text, { nextDocumentId: 100, nextDefinitionId: 200 });
  const loadedInner = loaded.definitions.find((definition) => definition.name === "INNER COUNT CELL");
  const loadedOuter = loaded.definitions.find((definition) => definition.name === "OUTER COUNT CELL");
  assert.ok(loadedInner); assert.ok(loadedOuter);
  assert.equal(loaded.nodes[1].definitionId, loadedOuter.id);
  const loadedNested = loadedOuter.nodes.find((value) => value.kind === "custom");
  assert.equal(loadedNested.definitionId, loadedInner.id);
  assert.deepEqual(loadedNested.inputs[0], { sourceId: 1, sourcePort: 0, color: "#1234AB" });
  assert.deepEqual(loadedOuter.nodes.find((value) => value.kind === "output").inputs[0],
    { sourceId: 2, sourcePort: 0, color: "#AB3412" });
  assert.deepEqual(loaded.nodes[1].inputs[0], { sourceId: 100, sourcePort: 0, color: "#0F1E2D" });
  assert.deepEqual(loaded.view, { x: 13, y: -27, zoom: 1.25 });

  const suffix = nestedCounterKey.slice(nestedCounterKey.indexOf("/"));
  assert.equal(loaded.states.get(`101${suffix}`), 3,
    "nested state survives even though both palette definition ids were remapped");
  const loadedAnalysis = analyzeCircuit(loaded.nodes, loaded.definitions);
  assert.ok(loadedAnalysis.stateKeys.has(`101${suffix}`));
});

test("oscillator phase is separate from clipboard data and loads paused at the saved output level", () => {
  const oscillator = node(4, "oscillator", 20, 30, 1, {
    inputValue: 1n,
    clockHz: 7.25,
    clockRunning: true,
  });
  const states = new Map([["4/oscillator:input", 3]]);
  const projectText = serializeProject([oscillator], [], { states });
  const encoded = JSON.parse(projectText);
  assert.equal(encoded.nodes[0].inputValue, "0");
  assert.deepEqual(encoded.oscillatorLevels, [[0, 1]]);

  const loaded = deserializeProject(projectText, { nextDocumentId: 44, nextDefinitionId: 1 });
  assert.equal(loaded.nodes[0].inputValue, 1n);
  assert.equal(loaded.nodes[0].clockRunning, false);
  assert.equal(loaded.nodes[0].clockHz, 7.25);
  assert.equal(loaded.states.get("44/oscillator:input"), 3);

  const clipboardText = serializeSelection([oscillator], new Set([4]), []);
  const pasted = deserializeSelection(clipboardText, {
    nextDocumentId: 50, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  });
  assert.equal(pasted.nodes[0].inputValue, 0n);
  assert.equal(pasted.nodes[0].clockRunning, false);
});

test("malformed projects reject sources, state keys and types, view ranges, radix, and missing oscillator phase", () => {
  const oscillator = node(1, "oscillator", 0, 0, 1, { inputValue: 1n, clockHz: 1, clockRunning: true });
  const clock = node(2, "clock", 200, 0, 2, { inputRadix: 16 });
  link(oscillator, clock);
  const text = serializeProject([oscillator, clock], [], {
    states: new Map([["1/oscillator:input", 3], ["2/count0:counter", 2]]),
  });
  const original = JSON.parse(text);
  const changed = (mutate) => {
    const value = JSON.parse(JSON.stringify(original));
    mutate(value);
    return JSON.stringify(value);
  };
  const load = (value) => deserializeProject(value, { nextDocumentId: 10, nextDefinitionId: 10 });

  assert.throws(() => load(changed((value) => { value.format = "other"; })), /format or version/);
  assert.throws(() => load(changed((value) => { value.nodes[1].inputs[0].source = 99; })), /source/);
  assert.throws(() => load(changed((value) => { value.states = [["0/not-a-state:counter", 0]]; })), /live runtime state key/);
  assert.throws(() => load(changed((value) => { value.states[0][1] = 4; })), /integer from 0 to 3/);
  assert.throws(() => load(changed((value) => { value.states[0][0] = "00/oscillator:input"; })), /encoded runtime state key/);
  assert.throws(() => load(changed((value) => { value.view.zoom = 3.01; })), /0.1 to 3/);
  assert.throws(() => load(changed((value) => { value.view = null; })), /view must be an object/);
  assert.throws(() => load(changed((value) => { value.states = null; })), /root.states must contain/);
  assert.throws(() => load(changed((value) => { value.nodes[1].inputRadix = 3; })), /2, 8, 10, or 16/);
  assert.throws(() => load(changed((value) => { value.oscillatorLevels = []; })), /missing node 0/);
  assert.throws(() => load(changed((value) => { value.oscillatorLevels = null; })), /oscillatorLevels must be an array/);

  const defaults = JSON.parse(JSON.stringify(original));
  delete defaults.view;
  delete defaults.states;
  const defaulted = load(JSON.stringify(defaults));
  assert.deepEqual(defaulted.view, { x: 0, y: 0, zoom: 1 });
  assert.deepEqual([...defaulted.states], []);

  const wire = clock.inputs[0];
  assert.throws(() => serializeProject([oscillator, clock], [], {
    states: new Map([["1/not-a-state:counter", 0]]),
  }), /unknown state key/);
  assert.throws(() => serializeProject([oscillator, clock], [], { states: null }), /states must be a Map/);
  assert.strictEqual(clock.inputs[0], wire);
  assert.equal(oscillator.inputValue, 1n);
  assert.equal(oscillator.clockRunning, true);

  const missing = node(9, "output", 0, 0, 1);
  missing.inputs = [{ sourceId: 999, sourcePort: 0 }];
  assert.throws(() => serializeProject([missing], []), /missing source node/);
  assert.deepEqual(missing.inputs[0], { sourceId: 999, sourcePort: 0 });
});

test("project validation enforces scalar expansion and serialized state entry budgets", () => {
  const heavy = Array.from({ length: 16 }, (_, index) => node(index + 1, "mux", index * 20, 0, 64, {
    addressWidth: 6,
  }));
  assert.throws(() => serializeProject(heavy, []), /250,000 scalar nodes/);

  const oscillator = node(1, "oscillator", 0, 0, 1, { inputValue: 0n, clockHz: 1 });
  const payload = JSON.parse(serializeProject([oscillator], []));
  payload.states = Array.from({ length: 250_001 }, () => ["0/oscillator:input", 0]);
  assert.throws(() => deserializeProject(JSON.stringify(payload), {
    nextDocumentId: 1,
    nextDefinitionId: 1,
  }), /at most 250000 entries/);
});

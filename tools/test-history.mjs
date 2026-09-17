import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createDefinition, makeNode, setSemanticWasm } from "../web-src/js/circuit.js";
import { DocumentHistory } from "../web-src/js/history.js";

const { instance } = await WebAssembly.instantiate(await readFile(new URL("../zig-out/web/wasm/a_basic_circuit.wasm", import.meta.url)), {});
setSemanticWasm(instance.exports);

function node(documentId, kind, x = 0, y = 0, width = 1, extra = {}) {
  return Object.assign(makeNode(documentId, kind, x, y, width, extra.definitionId ?? null), extra);
}

function link(source, target, pin = 0, sourcePort = 0, color) {
  while (target.inputs.length <= pin) target.inputs.push(null);
  const connection = { sourceId: source.documentId, sourcePort };
  if (color !== undefined) connection.color = color;
  target.inputs[pin] = connection;
}

function byId(snapshot, id) {
  return snapshot.nodes.find((value) => value.documentId === id);
}

function ids(set) {
  return [...set].sort((a, b) => a - b);
}

function bufferDefinition(id = 7) {
  const input = node(1, "input", 0, 0, 8, { label: "DATA" });
  const output = node(2, "output", 240, 0, 8, { label: "Q" });
  link(input, output, 0, 0, "#13579B");
  return createDefinition([input, output], "BUFFER CHIP", id);
}

test("a pasted wired custom group and its later deletion undo as document transactions", () => {
  const history = new DocumentHistory();
  const base = node(1, "input", 0, 0, 1);
  history.reset([base], []);

  const definition = bufferDefinition(40);
  const pastedInput = node(2, "input", 100, 80, 8, { inputValue: 0xa5n, inputRadix: 16 });
  const custom = node(3, "custom", 360, 80, 1, { definitionId: definition.id });
  custom.widthParameters = { [definition.parameters[0].id]: 8 };
  custom.inputs = [null];
  link(pastedInput, custom, 0, 0, "#2468AC");
  const output = node(4, "output", 640, 80, 8);
  link(custom, output);

  const pastedNodes = [base, pastedInput, custom, output];
  const definitions = [definition];
  assert.equal(history.record(pastedNodes, definitions), true);
  assert.equal(history.current.definitions[0], definition);
  assert.deepEqual(byId(history.current, 3).inputs[0], {
    sourceId: 2,
    sourcePort: 0,
    color: "#2468AC",
  });

  assert.equal(history.record([base], definitions), true);
  assert.deepEqual(history.current.nodes.map((value) => value.documentId), [1]);
  assert.deepEqual(ids(history.referencedIds()), [1, 2, 3, 4]);

  const restoredDelete = history.undo();
  assert.deepEqual(ids(restoredDelete.changedIds), [2, 3, 4]);
  assert.deepEqual(restoredDelete.nodes.map((value) => value.documentId), [1, 2, 3, 4]);
  assert.equal(restoredDelete.definitions[0], definition);
  assert.deepEqual(byId(restoredDelete, 4).inputs[0], { sourceId: 3, sourcePort: 0 });

  const restoredPaste = history.undo();
  assert.deepEqual(ids(restoredPaste.changedIds), [2, 3, 4]);
  assert.deepEqual(restoredPaste.nodes.map((value) => value.documentId), [1]);
  assert.deepEqual(restoredPaste.definitions, []);
  assert.equal(history.canUndo, false);

  assert.deepEqual(history.redo().nodes.map((value) => value.documentId), [1, 2, 3, 4]);
  assert.deepEqual(history.redo().nodes.map((value) => value.documentId), [1]);
});

test("wide values, positions, custom parameters, LED geometry, colors, and dormant wires do not alias live nodes", () => {
  const history = new DocumentHistory();
  const input = node(10, "input", 10, 20, 8, { inputValue: 1n, inputRadix: 16 });
  const mux = node(11, "mux", 200, 20, 8, { addressWidth: 1 });
  mux.inputs = Array(5).fill(null);
  const custom = node(12, "custom", 400, 20, 1, {
    definitionId: 99,
    widthParameters: { w0: 8, w2: 4 },
    inputs: [null],
  });
  const display = node(13, "display", 600, 20, 6, {
    ledColumns: 3,
    ledRows: 2,
    ledMode: "rgb",
    ledColor: "#12AbEf",
    inputs: [null, null, null],
  });
  const untouched = node(14, "output", 800, 20, 1);
  history.reset([input, mux, custom, display, untouched], []);
  const untouchedBefore = byId(history.current, 14);
  const definitionsBefore = history.current.definitions;

  input.x = -123.5;
  input.y = 987.25;
  input.width = 64;
  input.inputValue = 0x8000000100000001n;
  input.inputRadix = 2;
  input.label = "WIDE";
  mux.width = 64;
  mux.inputs[4] = { sourceId: 10, sourcePort: 3, color: "#AbCdEf" };
  custom.widthParameters.w0 = 64;
  display.ledColor = "#FEDCBA";
  assert.equal(history.record([input, mux, custom, display, untouched], []), true);

  const saved = history.current;
  assert.equal(byId(saved, 10).inputValue, 0x8000000100000001n);
  assert.deepEqual([byId(saved, 10).x, byId(saved, 10).y, byId(saved, 10).inputRadix], [-123.5, 987.25, 2]);
  assert.equal(byId(saved, 11).inputs.length, 5);
  assert.deepEqual(byId(saved, 11).inputs[4], { sourceId: 10, sourcePort: 3, color: "#AbCdEf" });
  assert.deepEqual(byId(saved, 12).widthParameters, { w0: 64, w2: 4 });
  assert.deepEqual(
    [byId(saved, 13).ledColumns, byId(saved, 13).ledRows, byId(saved, 13).ledMode, byId(saved, 13).ledColor],
    [3, 2, "rgb", "#FEDCBA"],
  );
  assert.strictEqual(byId(saved, 14), untouchedBefore);
  assert.strictEqual(saved.definitions, definitionsBefore);
  assert.equal(Object.isFrozen(saved), true);
  assert.equal(Object.isFrozen(saved.nodes), true);
  assert.equal(Object.isFrozen(byId(saved, 11)), true);
  assert.equal(Object.isFrozen(byId(saved, 11).inputs), true);
  assert.equal(Object.isFrozen(byId(saved, 11).inputs[4]), true);
  assert.equal(Object.isFrozen(byId(saved, 12).widthParameters), true);

  input.inputValue = 0n;
  input.x = 9999;
  mux.inputs[4].sourcePort = 9;
  mux.inputs[4].color = "#000000";
  custom.widthParameters.w0 = 1;
  display.ledColumns = 6;
  display.ledRows = 1;
  display.ledColor = "#000000";
  assert.equal(byId(saved, 10).inputValue, 0x8000000100000001n);
  assert.equal(byId(saved, 10).x, -123.5);
  assert.deepEqual(byId(saved, 11).inputs[4], { sourceId: 10, sourcePort: 3, color: "#AbCdEf" });
  assert.equal(byId(saved, 12).widthParameters.w0, 64);
  assert.deepEqual([byId(saved, 13).ledColumns, byId(saved, 13).ledRows, byId(saved, 13).ledColor], [3, 2, "#FEDCBA"]);

  const original = history.undo();
  assert.equal(byId(original, 10).width, 8);
  assert.equal(byId(original, 10).inputValue, 1n);
  assert.equal(byId(original, 11).inputs[4], null);
  const replayed = history.redo();
  assert.equal(byId(replayed, 10).inputValue, 0x8000000100000001n);
  assert.equal(byId(replayed, 12).widthParameters.w0, 64);
});

test("simulation outputs, oscillator level and play state, and native counter state never create history", () => {
  const history = new DocumentHistory();
  const oscillator = node(1, "oscillator", 0, 0, 1, { clockHz: 1, clockRunning: false, inputValue: 0n });
  const counter = node(2, "clock", 200, 0, 16);
  history.reset([oscillator, counter], []);

  oscillator.clockRunning = true;
  oscillator.inputValue = 1n;
  oscillator.ticks = 9001;
  oscillator.values = [true];
  oscillator.outputValues = [[true]];
  counter.inputValue = 0xffffn;
  counter.nativeCount = 0xffffn;
  counter.values = Array(16).fill(true);
  counter.outputValues = [Array(16).fill(true)];
  counter.channelValues = [[true]];
  assert.equal(history.record([oscillator, counter], []), false);
  assert.equal(history.canUndo, false);
  assert.equal(Object.hasOwn(byId(history.current, 1), "inputValue"), false);
  assert.equal(Object.hasOwn(byId(history.current, 1), "clockRunning"), false);
  assert.equal(Object.hasOwn(byId(history.current, 2), "nativeCount"), false);
  assert.equal(Object.hasOwn(byId(history.current, 2), "values"), false);

  oscillator.clockHz = 2.5;
  assert.equal(history.record([oscillator, counter], []), true);
  assert.equal(byId(history.current, 1).clockHz, 2.5);
  assert.equal(Object.hasOwn(byId(history.current, 1), "inputValue"), false);
});

test("RAM mapped range and sparse cell edits undo and redo without aliasing", () => {
  const history = new DocumentHistory();
  const ram = node(30, "ram", 0, 0, 64, {
    addressWidth: 64,
    ramBase: 0x0020000000000001n,
    ramEnd: 0x00200000000000ffn,
    ramCells: new Map([[0x0020000000000001n, 0x1111222233334444n]]),
  });
  history.reset([ram], []);
  const baseline = history.current.nodes[0];
  assert.equal(Object.isFrozen(baseline.ramCells), true);

  ram.ramBase = 0x0020000000000010n;
  ram.ramEnd = 0x0020000000000200n;
  ram.ramCells = new Map([
    [0x0020000000000010n, 0xffffffffffffffffn],
    [0x0020000000000100n, 0x8000000100000001n],
  ]);
  assert.equal(history.record([ram], []), true);
  ram.ramCells.set(0x0020000000000010n, 0n);
  assert.deepEqual(history.current.nodes[0].ramCells, [
    [0x0020000000000010n, 0xffffffffffffffffn],
    [0x0020000000000100n, 0x8000000100000001n],
  ], "captured RAM image does not alias the live Map");

  const undone = history.undo().nodes[0];
  assert.equal(undone.ramBase, 0x0020000000000001n);
  assert.deepEqual(undone.ramCells, [[0x0020000000000001n, 0x1111222233334444n]]);
  const redone = history.redo().nodes[0];
  assert.equal(redone.ramEnd, 0x0020000000000200n);
  assert.deepEqual(redone.ramCells, [
    [0x0020000000000010n, 0xffffffffffffffffn],
    [0x0020000000000100n, 0x8000000100000001n],
  ]);

  // Runtime-only simulation state is deliberately not represented in the
  // descriptor and therefore cannot create editor history.
  history.reset([ram], []);
  ram.runtimeRamCells = new Map([[0x0020000000000011n, 0x55n]]);
  assert.equal(history.record([ram], []), false);
});

test("a no-op after undo preserves redo while a real branch clears it", () => {
  const history = new DocumentHistory();
  const input = node(1, "input", 0, 0, 8);
  history.reset([input], []);

  input.label = "A";
  assert.equal(history.record([input], []), true);
  input.label = "B";
  assert.equal(history.record([input], []), true);

  const undone = history.undo();
  assert.equal(undone.nodes[0].label, "A");
  assert.equal(history.canRedo, true);
  input.label = "A";
  input.values = [true, false];
  assert.equal(history.record([input], []), false);
  assert.equal(history.canRedo, true);

  input.x = 42;
  assert.equal(history.record([input], []), true);
  assert.equal(history.canRedo, false);
  assert.equal(history.redo(), null);
  assert.equal(history.undo().nodes[0].x, 0);
});

test("color picker records merge within 800 ms and a merged return to the baseline drops the undo", () => {
  const history = new DocumentHistory();
  const source = node(1, "input");
  const output = node(2, "output");
  link(source, output);
  history.reset([source, output], []);

  output.inputs[0].color = "#111111";
  assert.equal(history.record([source, output], [], { mergeKey: "wire:2:0:color", now: 100 }), true);
  output.inputs[0].color = "#222222";
  assert.equal(history.record([source, output], [], { mergeKey: "wire:2:0:color", now: 500 }), true);
  output.inputs[0].color = "#333333";
  assert.equal(history.record([source, output], [], { mergeKey: "wire:2:0:color", now: 1200 }), true);
  assert.equal(history.canUndo, true);
  const baseline = history.undo();
  assert.equal(Object.hasOwn(byId(baseline, 2).inputs[0], "color"), false);
  assert.equal(history.undo(), null, "three picker events are one undo");
  assert.equal(byId(history.redo(), 2).inputs[0].color, "#333333");

  const freshSource = node(10, "input");
  const freshOutput = node(11, "output");
  link(freshSource, freshOutput);
  history.reset([freshSource, freshOutput], []);
  freshOutput.inputs[0].color = "#ABCDEF";
  history.record([freshSource, freshOutput], [], { mergeKey: "wire:11:0:color", now: 10 });
  delete freshOutput.inputs[0].color;
  history.record([freshSource, freshOutput], [], { mergeKey: "wire:11:0:color", now: 700 });
  assert.equal(history.canUndo, false);
  assert.equal(Object.hasOwn(byId(history.current, 11).inputs[0], "color"), false);
});

test("count and byte trimming keep the newest usable undo", () => {
  const history = new DocumentHistory({ limit: 2, byteLimit: 1024 * 1024 });
  const input = node(1, "input");
  history.reset([input], []);
  for (const label of ["one", "two", "three"]) {
    input.label = label;
    history.record([input], []);
  }

  assert.equal(history.undo().nodes[0].label, "two");
  assert.equal(history.undo().nodes[0].label, "one");
  assert.equal(history.undo(), null, "the oldest baseline frame was trimmed");

  const tiny = new DocumentHistory({ limit: 0, byteLimit: 0 });
  const large = node(9, "input");
  tiny.reset([large], []);
  large.label = "x".repeat(4096);
  assert.equal(tiny.record([large], []), true);
  assert.equal(tiny.canUndo, true, "an oversized newest frame remains available");
  assert.equal(tiny.undo().nodes[0].label, "");
});

test("definition-only make-chip history preserves template references and node descriptors", () => {
  const history = new DocumentHistory();
  const input = node(1, "input");
  const first = bufferDefinition(20);
  const second = bufferDefinition(21);
  history.reset([input], []);
  const originalNode = history.current.nodes[0];
  const originalDefinitions = history.current.definitions;

  assert.equal(history.record([input], [first]), true);
  assert.strictEqual(history.current.nodes[0], originalNode);
  assert.notStrictEqual(history.current.definitions, originalDefinitions);
  assert.strictEqual(history.current.definitions[0], first);
  assert.equal(Object.isFrozen(history.current.definitions), true);

  const removed = history.undo();
  assert.deepEqual(removed.definitions, []);
  assert.deepEqual([...removed.changedIds], []);
  assert.strictEqual(removed.nodes[0], originalNode);
  const restored = history.redo();
  assert.strictEqual(restored.definitions[0], first);
  assert.deepEqual([...restored.changedIds], []);

  assert.equal(history.record([input], [first]), false, "a fresh array with the same refs and order is unchanged");
  assert.equal(history.record([input], [second, first]), true, "definition order and membership are persistent");
  assert.deepEqual(history.current.definitions, [second, first]);

  const editedFirst = { ...first, name: "BUFFER EDITED" };
  history.reset([input], [first]);
  assert.equal(history.record([input], [editedFirst]), true, "replacing a shared definition object is an edit even when its id is stable");
  assert.strictEqual(history.undo().definitions[0], first);
  assert.strictEqual(history.redo().definitions[0], editedFirst);
});

test("manual counter edits record exact live before values without recording automatic ticks", () => {
  const history = new DocumentHistory();
  const clock = node(7,"clock",0,0,64);
  history.reset([clock],[]);
  clock.values = [true,false,true]; clock.inputValue = 13n;
  assert.equal(history.record([clock],[]),false);
  const effect = { before: { documentId:7,value:13n,radix:16 },
    after: { documentId:7,value:0x8000000100000001n,radix:16 } };
  assert.equal(history.record([clock],[],{effect}),true,"runtime-only edit is undoable");
  effect.before.value = 0n;
  clock.values = [false,false]; clock.inputValue = 200n;
  assert.equal(history.record([clock],[]),false,"later simulation does not alter history");
  const undone = history.undo();
  assert.deepEqual([...undone.changedIds],[]);
  assert.equal(undone.effect.value,13n,"actual value before manual edit, not a prior tick snapshot");
  assert.equal(Object.isFrozen(undone.effect),true);
  assert.equal(history.redo().effect.value,0x8000000100000001n);
  clock.inputRadix = 8;
  history.record([clock],[],{effect:{before:{documentId:7,value:44n,radix:16},after:{documentId:7,value:55n,radix:8}}});
  assert.equal(history.undo().nodes[0].inputRadix,16);
  clock.label = "BRANCH"; clock.inputRadix = 16;
  history.record([clock],[]);
  assert.equal(history.canRedo,false);
  assert.ok(history.referencedIds().has(7));
  assert.throws(()=>history.record([clock],[],{effect:{before:{documentId:7,value:-1n,radix:16},after:{documentId:7,value:0n,radix:16}}}));
});

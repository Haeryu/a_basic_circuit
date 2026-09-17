import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createDefinition, makeNode, resolveCustom, setSemanticWasm } from "../web-src/js/circuit.js";
import { deserializeSelection, serializeSelection, deserializeChipPackage, serializeChipPackage,
  deserializeChipBundle, serializeChipBundle } from "../web-src/js/clipboard.js";

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

function busBufferDefinition(id = 7, name = "BUS BUFFER") {
  const input = node(1, "input", 0, 0, 8, { label: "DATA" });
  const buffer = node(2, "buffer", 330, 40, 8, { label: "PIPE" });
  const output = node(3, "output", 0, 0, 8, { label: "Q" });
  link(input, buffer);
  link(buffer, output);
  return createDefinition([input, buffer, output], name, id);
}

function loadableCounterDefinition(id = 8, name = "LOADABLE COUNTER") {
  const clock = node(1, "input", 0, 0, 1, { label: "CLK" });
  const load = node(2, "input", 0, 100, 1, { label: "LOAD" });
  const data = node(3, "input", 0, 200, 8, { label: "DATA" });
  const counter = node(4, "clock", 330, 100, 8, { label: "COUNT", inputRadix: 2 });
  const output = node(5, "output", 660, 100, 8, { label: "Q" });
  link(clock, counter, 0, 0, "#110011");
  link(load, counter, 1, 0, "#220022");
  link(data, counter, 2, 0, "#330033");
  link(counter, output, 0, 0, "#440044");
  const definition = createDefinition([clock, load, data, counter, output], name, id);
  definition.nodes[3].inputRadix = counter.inputRadix;
  return definition;
}

function nestedBufferDefinitions(innerId = 70, outerId = 71) {
  const inner = busBufferDefinition(innerId, "INNER BUFFER");
  const lookup = (id) => id === inner.id ? inner : null;
  const input = node(1, "input", 0, 0, 64, { label: "IN64" });
  const nested = node(2, "custom", 300, 0, 1, {
    definitionId: inner.id,
    widthParameters: { [inner.parameters[0].id]: 64 },
  });
  nested.inputs = [null];
  const output = node(3, "output", 620, 0, 64, { label: "OUT64" });
  link(input, nested, 0, 0, "#102030");
  link(nested, output, 0, 0, "#405060");
  const outer = createDefinition([input, nested, output], "OUTER BUFFER", outerId, lookup);
  return { inner, outer };
}

test("selection paste assigns fresh ids, offsets positions, and keeps only internal wires", () => {
  const external = node(1, "input", 0, 0, 1, { inputValue: 1n });
  const source = node(2, "input", 100, 200, 64, {
    inputValue: 0x8000000100000001n,
    inputRadix: 2,
    label: "DATA",
  });
  const mux = node(3, "mux", 140, 260, 8, { addressWidth: 1 });
  mux.inputs = Array(5).fill(null);
  link(external, mux, 0);
  link(source, mux, 1);
  link(external, mux, 2);
  link(source, mux, 4); // Dormant D3 remains serialized even at address width 1.
  const output = node(4, "output", 200, 220, 8);
  link(mux, output);
  const originalDormant = mux.inputs[4];

  const text = serializeSelection([external, source, mux, output], new Set([2, 3, 4]), []);
  const pasted = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 50,
    definitions: [],
    x: 1000,
    y: 2000,
  });

  assert.deepEqual(pasted.nodes.map((value) => value.documentId), [100, 101, 102]);
  assert.deepEqual(pasted.nodes.map(({ x, y }) => [x, y]), [[1000, 2000], [1040, 2060], [1100, 2020]]);
  assert.equal(pasted.nodes[0].inputValue, 0x8000000100000001n);
  assert.equal(pasted.nodes[0].inputRadix, 2);
  assert.equal(pasted.nodes[1].inputs[0], null, "external selector is dropped");
  assert.deepEqual(pasted.nodes[1].inputs[1], { sourceId: 100, sourcePort: 0 });
  assert.equal(pasted.nodes[1].inputs[2], null, "external data wire is dropped");
  assert.deepEqual(pasted.nodes[1].inputs[4], { sourceId: 100, sourcePort: 0 });
  assert.deepEqual(pasted.nodes[2].inputs[0], { sourceId: 101, sourcePort: 0 });
  assert.equal(pasted.nextDocumentId, 103);
  assert.equal(pasted.nextDefinitionId, 50);
  assert.deepEqual(pasted.definitions, []);

  assert.notStrictEqual(pasted.nodes[1].inputs[4], originalDormant);
  pasted.nodes[1].inputs[4].sourcePort = 9;
  pasted.nodes[0].label = "CHANGED";
  assert.equal(originalDormant.sourcePort, 0);
  assert.equal(source.label, "DATA");
});

test("mapped RAM clipboard keeps 64-bit addresses and sparse cells losslessly", () => {
  const base = 0x0020000000000001n, end = base + 0xffn;
  const ram = node(40, "ram", 100, 200, 64, {
    addressWidth: 64,
    ramBase: base,
    ramEnd: end,
    ramCells: new Map([
      [base, 0x8000000100000001n],
      [end, 0xffffffffffffffffn],
    ]),
  });
  const text = serializeSelection([ram], new Set([40]), []);
  const encoded = JSON.parse(text).nodes[0];
  assert.equal(encoded.ramBase, base.toString(10));
  assert.equal(encoded.ramEnd, end.toString(10));
  assert.deepEqual(encoded.ramCells, [
    [base.toString(10), "9223372041149743105"],
    [end.toString(10), "18446744073709551615"],
  ]);

  const pasted = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 1,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.equal(pasted.nodes[0].addressWidth, 64);
  assert.equal(pasted.nodes[0].ramBase, base);
  assert.equal(pasted.nodes[0].ramEnd, end);
  assert.deepEqual([...pasted.nodes[0].ramCells], [
    [base, 0x8000000100000001n],
    [end, 0xffffffffffffffffn],
  ]);

  const legacy = JSON.parse(text);
  delete legacy.nodes[0].ramBase; delete legacy.nodes[0].ramEnd; delete legacy.nodes[0].ramCells;
  const legacyRam = deserializeSelection(JSON.stringify(legacy), {
    nextDocumentId: 200, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }).nodes[0];
  assert.equal(legacyRam.ramBase, 0n);
  assert.equal(legacyRam.ramEnd, 0xffffffffffffffffn);
  assert.equal(legacyRam.ramCells.size, 0);

  const invalid = JSON.parse(text);
  invalid.nodes[0].ramCells.push([(end + 1n).toString(10), "1"]);
  assert.throws(() => deserializeSelection(JSON.stringify(invalid), {
    nextDocumentId: 300, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }), /outside the mapped range/);
});

test("chip packages preserve mapped RAM images inside custom definitions", () => {
  const address = node(1, "input", 0, 0, 64, { label: "ADDR" });
  const data = node(2, "input", 0, 100, 64, { label: "DATA" });
  const we = node(3, "input", 0, 200, 1, { label: "WE" });
  const clock = node(4, "input", 0, 300, 1, { label: "CLK" });
  const base = 0x1000000000000000n, end = base + 0x3fn;
  const ram = node(5, "ram", 300, 120, 64, {
    addressWidth: 64, ramBase: base, ramEnd: end,
    ramCells: new Map([[base + 7n, 0xabcdef0123456789n]]),
  });
  const output = node(6, "output", 650, 120, 64, { label: "Q" });
  link(address, ram, 0); link(data, ram, 1); link(we, ram, 2); link(clock, ram, 3); link(ram, output);
  const definition = createDefinition([address, data, we, clock, ram, output], "MAPPED RAM", 77);
  const text = serializeChipPackage(definition.id, [definition]);
  const encodedRam = JSON.parse(text).definitions[0].nodes.find((value) => value.kind === "ram");
  assert.deepEqual([encodedRam.ramBase, encodedRam.ramEnd], [base.toString(10), end.toString(10)]);
  assert.deepEqual(encodedRam.ramCells, [[(base + 7n).toString(10), "12379813738877118345"]]);

  const loaded = deserializeChipPackage(text, { definitions: [], nextDefinitionId: 200 });
  const loadedRam = loaded.definitions[0].nodes.find((value) => value.kind === "ram");
  assert.equal(loadedRam.ramBase, base);
  assert.equal(loadedRam.ramEnd, end);
  assert.equal(loadedRam.ramCells.get(base + 7n), 0xabcdef0123456789n);
});

test("loadable counter pins and colors roundtrip while legacy short clocks gain empty LOAD and DATA slots", () => {
  const edge = node(1, "input", 0, 0, 1, { inputValue: 1n });
  const load = node(2, "input", 0, 100, 1, { inputValue: 1n });
  const data = node(3, "input", 0, 200, 8, { inputValue: 0xa5n, inputRadix: 16 });
  const counter = node(4, "clock", 300, 100, 8, { inputRadix: 2 });
  link(edge, counter, 0, 0, "#123456");
  link(load, counter, 1, 0, "#234567");
  link(data, counter, 2, 0, "#345678");

  const text = serializeSelection([edge, load, data, counter], new Set([1, 2, 3, 4]), []);
  const encoded = JSON.parse(text);
  assert.deepEqual(encoded.nodes[3].inputs, [
    { source: 0, sourcePort: 0, color: "#123456" },
    { source: 1, sourcePort: 0, color: "#234567" },
    { source: 2, sourcePort: 0, color: "#345678" },
  ]);

  const pasted = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 1,
    definitions: [],
    x: 500,
    y: 600,
  });
  assert.equal(pasted.nodes[3].inputValue, 0n, "clipboard paste starts with a fresh counter state");
  assert.equal(pasted.nodes[3].inputRadix, 2);
  assert.deepEqual(pasted.nodes[3].inputs, [
    { sourceId: 100, sourcePort: 0, color: "#123456" },
    { sourceId: 101, sourcePort: 0, color: "#234567" },
    { sourceId: 102, sourcePort: 0, color: "#345678" },
  ]);

  for (const retainedInputs of [0, 1]) {
    const legacy = JSON.parse(text);
    legacy.nodes[3].inputs = legacy.nodes[3].inputs.slice(0, retainedInputs);
    const base = 200 + retainedInputs * 10;
    const restored = deserializeSelection(JSON.stringify(legacy), {
      nextDocumentId: base,
      nextDefinitionId: 1,
      definitions: [],
      x: 0,
      y: 0,
    });
    assert.equal(restored.nodes[3].inputs.length, 3);
    assert.deepEqual(restored.nodes[3].inputs.slice(retainedInputs), Array(3 - retainedInputs).fill(null));
    if (retainedInputs === 1) {
      assert.deepEqual(restored.nodes[3].inputs[0], {
        sourceId: base,
        sourcePort: 0,
        color: "#123456",
      });
    }
  }

  const invalid = JSON.parse(text);
  invalid.nodes[3].inputs.push(null);
  assert.throws(() => deserializeSelection(JSON.stringify(invalid), {
    nextDocumentId: 240,
    nextDefinitionId: 1,
    definitions: [],
    x: 0,
    y: 0,
  }), /at most 3 items/);
});

test("custom loadable counters preserve external and internal CLK, LOAD, and DATA wiring", () => {
  const definition = loadableCounterDefinition(80);
  const edge = node(10, "input", 0, 0, 1);
  const load = node(11, "input", 0, 100, 1);
  const data = node(12, "input", 0, 200, 8, { inputValue: 0x5an });
  const custom = node(13, "custom", 300, 100, 1, { definitionId: definition.id });
  custom.inputs = [null, null, null];
  link(edge, custom, 0, 0, "#551100");
  link(load, custom, 1, 0, "#662200");
  link(data, custom, 2, 0, "#773300");

  const text = serializeSelection([edge, load, data, custom], new Set([10, 11, 12, 13]), [definition]);
  const encoded = JSON.parse(text);
  assert.deepEqual(encoded.nodes[3].inputs, [
    { source: 0, sourcePort: 0, color: "#551100" },
    { source: 1, sourcePort: 0, color: "#662200" },
    { source: 2, sourcePort: 0, color: "#773300" },
  ]);
  assert.deepEqual(encoded.definitions[0].nodes[3].inputs, [
    { source: 0, sourcePort: 0, color: "#110011" },
    { source: 1, sourcePort: 0, color: "#220022" },
    { source: 2, sourcePort: 0, color: "#330033" },
  ]);

  const pasted = deserializeSelection(text, {
    nextDocumentId: 300,
    nextDefinitionId: 400,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.deepEqual(pasted.nodes[3].inputs, [
    { sourceId: 300, sourcePort: 0, color: "#551100" },
    { sourceId: 301, sourcePort: 0, color: "#662200" },
    { sourceId: 302, sourcePort: 0, color: "#773300" },
  ]);
  assert.equal(pasted.definitions[0].nodes[3].inputRadix, 2);
  assert.deepEqual(pasted.definitions[0].nodes[3].inputs, [
    { sourceId: 1, sourcePort: 0, color: "#110011" },
    { sourceId: 2, sourcePort: 0, color: "#220022" },
    { sourceId: 3, sourcePort: 0, color: "#330033" },
  ]);

  const legacy = JSON.parse(text);
  legacy.definitions[0].nodes[3].inputs = legacy.definitions[0].nodes[3].inputs.slice(0, 1);
  const restored = deserializeSelection(JSON.stringify(legacy), {
    nextDocumentId: 500,
    nextDefinitionId: 600,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.deepEqual(restored.definitions[0].nodes[3].inputs, [
    { sourceId: 1, sourcePort: 0, color: "#110011" },
    null,
    null,
  ]);

  const invalidDefinition = JSON.parse(text);
  invalidDefinition.definitions[0].nodes[3].inputs.push(null);
  assert.throws(() => deserializeSelection(JSON.stringify(invalidDefinition), {
    nextDocumentId: 700,
    nextDefinitionId: 800,
    definitions: [],
    x: 0,
    y: 0,
  }), /at most 3 items/);
});

test("wire colors survive regular, mismatched, and dormant wires while automatic color stays absent", () => {
  const external = node(5, "input", -100, 0, 1);
  const data = node(1, "input", 0, 0, 8);
  const wide = node(2, "input", 0, 100, 64);
  const mux = node(3, "mux", 100, 0, 8, { addressWidth: 1 });
  mux.inputs = Array(5).fill(null);
  link(external, mux, 0, 0, "#FEDCBA"); // Colored wires from outside the selection are dropped.
  link(data, mux, 1, 0, "#123456"); // Active and width-matched D0.
  link(wide, mux, 2, 0, "#AbCdEf"); // Active width mismatch on D1.
  link(data, mux, 4, 0, "#0A1B2C"); // Dormant D3 while address width is one.
  const output = node(4, "output", 200, 0, 8);
  link(mux, output, 0, 0, null); // Explicit automatic color normalizes to no field.

  const originals = [mux.inputs[1], mux.inputs[2], mux.inputs[4], output.inputs[0]];
  const text = serializeSelection([external, data, wide, mux, output], new Set([1, 2, 3, 4]), []);
  const encoded = JSON.parse(text);
  assert.equal(encoded.nodes[2].inputs[0], null);
  assert.equal(encoded.nodes[2].inputs[1].color, "#123456");
  assert.equal(encoded.nodes[2].inputs[2].color, "#AbCdEf");
  assert.equal(encoded.nodes[2].inputs[4].color, "#0A1B2C");
  assert.equal(Object.hasOwn(encoded.nodes[3].inputs[0], "color"), false);

  const pasted = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 1,
    definitions: [],
    x: 500,
    y: 600,
  });
  assert.equal(pasted.nodes[2].inputs[0], null);
  assert.deepEqual(pasted.nodes[2].inputs[1], { sourceId: 100, sourcePort: 0, color: "#123456" });
  assert.deepEqual(pasted.nodes[2].inputs[2], { sourceId: 101, sourcePort: 0, color: "#AbCdEf" });
  assert.deepEqual(pasted.nodes[2].inputs[4], { sourceId: 100, sourcePort: 0, color: "#0A1B2C" });
  assert.deepEqual(pasted.nodes[3].inputs[0], { sourceId: 102, sourcePort: 0 });
  assert.equal(Object.hasOwn(pasted.nodes[3].inputs[0], "color"), false);

  for (let index = 0; index < originals.length; index += 1) {
    const pastedConnection = index < 3 ? pasted.nodes[2].inputs[[1, 2, 4][index]] : pasted.nodes[3].inputs[0];
    assert.notStrictEqual(pastedConnection, originals[index]);
  }
  pasted.nodes[2].inputs[1].color = "#FFFFFF";
  pasted.nodes[2].inputs[4].sourcePort = 7;
  assert.equal(originals[0].color, "#123456");
  assert.equal(originals[2].sourcePort, 0);
  assert.equal(originals[3].color, null);
});

test("custom definitions are rebuilt, overrides survive, and equivalent definitions are reused", () => {
  const definition = busBufferDefinition();
  const parameter = definition.parameters[0].id;
  const source = node(10, "input", 10, 20, 64, { inputValue: 0xffffffffffffffffn });
  const custom = node(11, "custom", 50, 70, 1, {
    definitionId: definition.id,
    widthParameters: { [parameter]: 64 },
  });
  custom.inputs = [null];
  link(source, custom);

  const text = serializeSelection([source, custom], new Set([10, 11]), [definition]);
  const first = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 20,
    definitions: [],
    x: 0,
    y: 0,
  });
  assert.equal(first.definitions.length, 1);
  assert.equal(first.definitions[0].id, 20);
  assert.deepEqual([first.definitions[0].nodes[1].x,first.definitions[0].nodes[1].y,first.definitions[0].nodes[1].label],[330,40,"PIPE"]);
  assert.equal(first.nodes[1].definitionId, 20);
  assert.deepEqual(first.nodes[1].widthParameters, { [parameter]: 64 });
  const resolved = resolveCustom(first.nodes[1], (id) => first.definitions.find((value) => value.id === id));
  assert.equal(resolved.byId.get(resolved.definition.inputs[0].localId).width, 64);
  assert.equal(resolved.byId.get(resolved.definition.outputs[0].localId).width, 64);

  const reused = deserializeSelection(text, {
    nextDocumentId: first.nextDocumentId,
    nextDefinitionId: first.nextDefinitionId,
    definitions: first.definitions,
    x: 300,
    y: 400,
  });
  assert.deepEqual(reused.definitions, [], "an equivalent palette definition is not returned again");
  assert.equal(first.definitions.length, 1);
  assert.equal(reused.nodes[1].definitionId, 20);
  assert.equal(reused.nextDefinitionId, first.nextDefinitionId);

  reused.nodes[1].widthParameters[parameter] = 3;
  reused.nodes[1].inputs[0].sourcePort = 7;
  assert.equal(custom.widthParameters[parameter], 64);
  assert.equal(custom.inputs[0].sourcePort, 0);
});

test("nested custom clipboard carries transitive definitions, parameters and colors and safely reuses them", () => {
  const { inner, outer } = nestedBufferDefinitions();
  const custom = node(10, "custom", 20, 30, 1, { definitionId: outer.id });
  custom.inputs = [null];

  // Parent first deliberately exercises a forward definition reference in the payload.
  const text = serializeSelection([custom], new Set([10]), [outer, inner]);
  const encoded = JSON.parse(text);
  assert.equal(encoded.definitions.length, 2);
  const outerIndex = encoded.definitions.findIndex((definition) => definition.name === "OUTER BUFFER");
  const innerIndex = encoded.definitions.findIndex((definition) => definition.name === "INNER BUFFER");
  assert.equal(outerIndex, 0);
  assert.equal(innerIndex, 1);
  const encodedNested = encoded.definitions[outerIndex].nodes.find((value) => value.kind === "custom");
  assert.equal(encodedNested.definition, innerIndex);
  assert.deepEqual(encodedNested.widthParameters, { [inner.parameters[0].id]: 64 });
  assert.deepEqual(encodedNested.inputs[0], { source: 0, sourcePort: 0, color: "#102030" });
  assert.deepEqual(encoded.definitions[outerIndex].nodes.find((value) => value.kind === "output").inputs[0],
    { source: 1, sourcePort: 0, color: "#405060" });

  const first = deserializeSelection(text, {
    nextDocumentId: 100,
    nextDefinitionId: 200,
    definitions: [],
    x: 400,
    y: 500,
  });
  assert.equal(first.definitions.length, 2);
  const loadedInner = first.definitions.find((definition) => definition.name === "INNER BUFFER");
  const loadedOuter = first.definitions.find((definition) => definition.name === "OUTER BUFFER");
  assert.ok(loadedInner); assert.ok(loadedOuter);
  assert.equal(first.nodes[0].definitionId, loadedOuter.id);
  const loadedNested = loadedOuter.nodes.find((value) => value.kind === "custom");
  assert.equal(loadedNested.definitionId, loadedInner.id);
  assert.deepEqual(loadedNested.widthParameters, { [loadedInner.parameters[0].id]: 64 });
  assert.deepEqual(loadedNested.inputs[0], { sourceId: 1, sourcePort: 0, color: "#102030" });
  assert.deepEqual(loadedOuter.nodes.find((value) => value.kind === "output").inputs[0],
    { sourceId: 2, sourcePort: 0, color: "#405060" });
  const resolvedNested = resolveCustom(loadedNested, (id) => first.definitions.find((definition) => definition.id === id));
  assert.equal(resolvedNested.byId.get(resolvedNested.definition.outputs[0].localId).width, 64);

  const reused = deserializeSelection(text, {
    nextDocumentId: first.nextDocumentId,
    nextDefinitionId: first.nextDefinitionId,
    definitions: first.definitions,
    x: 800,
    y: 900,
  });
  assert.deepEqual(reused.definitions, [], "the complete equivalent nested definition DAG is reused");
  assert.equal(reused.nodes[0].definitionId, loadedOuter.id);

  const cyclic = JSON.parse(text);
  cyclic.definitions[outerIndex].nodes.find((value) => value.kind === "custom").definition = outerIndex;
  assert.throws(() => deserializeSelection(JSON.stringify(cyclic), {
    nextDocumentId: 300, nextDefinitionId: 300, definitions: [], x: 0, y: 0,
  }), /recursive dependency cycle/);

  const missing = JSON.parse(text);
  missing.definitions[outerIndex].nodes.find((value) => value.kind === "custom").definition = 99;
  assert.throws(() => deserializeSelection(JSON.stringify(missing), {
    nextDocumentId: 300, nextDefinitionId: 300, definitions: [], x: 0, y: 0,
  }), /definition/);
});

test("chip export/import carries only the selected definition DAG and reuses equivalent palette chips", () => {
  const { inner, outer } = nestedBufferDefinitions(170, 171);
  const unrelated = busBufferDefinition(172, "UNRELATED");
  const text = serializeChipPackage(outer.id, [outer, inner, unrelated]);
  const encoded = JSON.parse(text);
  assert.equal(encoded.format, "a_basic_circuit/chip");
  assert.equal(encoded.version, 1);
  assert.equal(Object.hasOwn(encoded, "nodes"), false, "chip packages do not contain a root circuit");
  assert.equal(encoded.definitions.length, 2, "unrelated palette definitions stay out of the package");
  assert.equal(encoded.definitions[encoded.root].name, "OUTER BUFFER");
  const encodedOuter = encoded.definitions[encoded.root];
  const encodedNested = encodedOuter.nodes.find((value) => value.kind === "custom");
  assert.equal(encoded.definitions[encodedNested.definition].name, "INNER BUFFER");
  assert.deepEqual(encodedNested.widthParameters, { [inner.parameters[0].id]: 64 });
  assert.deepEqual(encodedNested.inputs[0], { source: 0, sourcePort: 0, color: "#102030" });

  const first = deserializeChipPackage(text, {
    definitions: [],
    nextDefinitionId: 300,
  });
  assert.equal(first.definitions.length, 2);
  assert.equal(first.nextDefinitionId, 302);
  const loadedRoot = first.definitions.find((definition) => definition.id === first.rootDefinitionId);
  const loadedInner = first.definitions.find((definition) => definition.name === "INNER BUFFER");
  assert.equal(loadedRoot.name, "OUTER BUFFER");
  assert.ok(loadedInner);
  const loadedNested = loadedRoot.nodes.find((value) => value.kind === "custom");
  assert.equal(loadedNested.definitionId, loadedInner.id);
  assert.deepEqual(loadedNested.inputs[0], { sourceId: 1, sourcePort: 0, color: "#102030" });

  const reused = deserializeChipPackage(text, {
    definitions: first.definitions,
    nextDefinitionId: first.nextDefinitionId,
  });
  assert.deepEqual(reused.definitions, []);
  assert.equal(reused.rootDefinitionId, loadedRoot.id);
  assert.equal(reused.nextDefinitionId, first.nextDefinitionId);

  const withUnused = JSON.parse(text);
  const unrelatedText = JSON.parse(serializeChipPackage(unrelated.id, [unrelated]));
  withUnused.definitions.push(unrelatedText.definitions[unrelatedText.root]);
  assert.throws(() => deserializeChipPackage(JSON.stringify(withUnused), {
    definitions: [], nextDefinitionId: 400,
  }), /unused custom definition/);

  const cyclic = JSON.parse(text);
  cyclic.definitions[cyclic.root].nodes.find((value) => value.kind === "custom").definition = cyclic.root;
  assert.throws(() => deserializeChipPackage(JSON.stringify(cyclic), {
    definitions: [], nextDefinitionId: 400,
  }), /recursive dependency cycle/);
  assert.throws(() => deserializeChipPackage(JSON.stringify({ ...encoded, format: "a_basic_circuit/project" }), {
    definitions: [], nextDefinitionId: 400,
  }), /chip format or version/);
});

test("chip modules export multiple named roots with shared dependencies exactly once", () => {
  const shared = busBufferDefinition(180, "cpu.shared");
  const lookup = (id) => id === shared.id ? shared : null;
  const makeCpu = (id, name, color) => {
    const input = node(1, "input", 0, 0, 8, { label: "IN" });
    const nested = node(2, "custom", 260, 0, 1, { definitionId: shared.id,
      widthParameters: { [shared.parameters[0].id]: 8 } });
    nested.inputs = [null];
    const output = node(3, "output", 520, 0, 8, { label: "OUT" });
    link(input, nested, 0, 0, color);
    link(nested, output);
    return createDefinition([input, nested, output], name, id, lookup);
  };
  const x86 = makeCpu(181, "cpu.x86", "#112233");
  const rv32i = makeCpu(182, "cpu.rv32I", "#445566");
  const text = serializeChipBundle([x86.id, rv32i.id], [x86, shared, rv32i], { moduleName: "cpu" });
  const encoded = JSON.parse(text);
  assert.equal(encoded.format, "a_basic_circuit/chips");
  assert.equal(encoded.module, "cpu");
  assert.deepEqual(encoded.exports.map((entry) => entry.name), ["x86", "rv32I"]);
  assert.equal(encoded.definitions.length, 3, "two public roots share one embedded dependency");
  assert.equal(Object.hasOwn(encoded, "nodes"), false);

  const loaded = deserializeChipBundle(text, { definitions: [], nextDefinitionId: 500 });
  assert.equal(loaded.moduleName, "cpu");
  assert.deepEqual(loaded.exports.map((entry) => entry.name), ["x86", "rv32I"]);
  assert.equal(loaded.rootDefinitionIds.length, 2);
  assert.equal(loaded.definitions.length, 3);
  const roots = loaded.rootDefinitionIds.map((id) => loaded.definitions.find((definition) => definition.id === id));
  assert.deepEqual(roots.map((definition) => definition.name), ["cpu.x86", "cpu.rv32I"]);
  const sharedLoaded = loaded.definitions.find((definition) => definition.name === "cpu.shared");
  assert.ok(sharedLoaded);
  assert.ok(roots.every((definition) => definition.nodes.find((value) => value.kind === "custom").definitionId === sharedLoaded.id));

  const reused = deserializeChipBundle(text, { definitions: loaded.definitions, nextDefinitionId: loaded.nextDefinitionId });
  assert.deepEqual(reused.definitions, []);
  assert.deepEqual(reused.rootDefinitionIds, loaded.rootDefinitionIds);
  assert.equal(reused.nextDefinitionId, loaded.nextDefinitionId);

  const duplicateExport = JSON.parse(text);
  duplicateExport.exports[1].name = duplicateExport.exports[0].name;
  assert.throws(() => deserializeChipBundle(JSON.stringify(duplicateExport), {
    definitions: [], nextDefinitionId: 700,
  }), /duplicate names/);
});

test("clock state is normalized and mono/RGB LED geometry and pins are copied", () => {
  const clock = node(1, "oscillator", 0, 0, 1, {
    inputValue: 1n,
    clockHz: 2.5,
    clockRunning: true,
    inputs: [],
  });
  const red = node(2, "input", 20, 0, 6, { inputValue: 0x21n });
  const green = node(3, "input", 40, 0, 6, { inputValue: 0x12n });
  const blue = node(4, "input", 60, 0, 6, { inputValue: 0x3fn });
  const rgb = node(5, "display", 100, 0, 6, {
    ledColumns: 3,
    ledRows: 2,
    ledMode: "rgb",
    ledColor: "#12AbEf",
    inputs: [null, null, null],
  });
  link(red, rgb, 0);
  link(green, rgb, 1);
  link(blue, rgb, 2);
  const mono = node(6, "display", 140, 0, 4, {
    ledColumns: 2,
    ledRows: 2,
    ledMode: "mono",
    ledColor: "#ffd36f",
    inputs: [null],
  });
  link(red, mono);

  const text = serializeSelection([clock, red, green, blue, rgb, mono], new Set([1, 2, 3, 4, 5, 6]), []);
  const encoded = JSON.parse(text);
  assert.equal(encoded.nodes[0].inputValue, "0");
  assert.equal(encoded.nodes[0].clockRunning, false);
  const pasted = deserializeSelection(text, {
    nextDocumentId: 10,
    nextDefinitionId: 1,
    definitions: [],
    x: 500,
    y: 600,
  });

  assert.equal(pasted.nodes[0].inputValue, 0n);
  assert.equal(pasted.nodes[0].clockHz, 2.5);
  assert.equal(pasted.nodes[0].clockRunning, false);
  assert.deepEqual(
    [pasted.nodes[4].ledColumns, pasted.nodes[4].ledRows, pasted.nodes[4].ledMode, pasted.nodes[4].ledColor],
    [3, 2, "rgb", "#12AbEf"],
  );
  assert.deepEqual(pasted.nodes[4].inputs, [
    { sourceId: 11, sourcePort: 0 },
    { sourceId: 12, sourcePort: 0 },
    { sourceId: 13, sourcePort: 0 },
  ]);
  assert.deepEqual(
    [pasted.nodes[5].ledColumns, pasted.nodes[5].ledRows, pasted.nodes[5].ledMode, pasted.nodes[5].ledColor],
    [2, 2, "mono", "#ffd36f"],
  );
  assert.equal(pasted.nodes[5].inputs.length, 1);
});

test("malformed payloads are rejected without mutating definitions or source nodes", () => {
  assert.throws(() => serializeSelection([], new Set(), []), /Select at least one chip/);
  assert.throws(() => deserializeSelection("not json", {
    nextDocumentId: 1, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }), /valid JSON/);

  const definition = busBufferDefinition(40);
  const custom = node(10, "custom", 0, 0, 1, {
    definitionId: 40,
    widthParameters: { [definition.parameters[0].id]: 8 },
    inputs: [null],
  });
  const originalDefinitions = [definition];
  const text = serializeSelection([custom], new Set([10]), originalDefinitions);
  const malformedDefinition = JSON.parse(text);
  malformedDefinition.definitions[0].nodes[1].width = 3;
  assert.throws(() => deserializeSelection(JSON.stringify(malformedDefinition), {
    nextDocumentId: 100,
    nextDefinitionId: 41,
    definitions: originalDefinitions,
    x: 0,
    y: 0,
  }), /internal wire|Inconsistent/);
  assert.equal(originalDefinitions.length, 1);
  assert.strictEqual(originalDefinitions[0], definition);
  assert.equal(custom.definitionId, 40);
  assert.deepEqual(custom.inputs, [null]);

  const badLed = JSON.parse(serializeSelection([
    node(1, "display", 0, 0, 4, {
      ledColumns: 2, ledRows: 2, ledMode: "mono", ledColor: "#ffffff", inputs: [null],
    }),
  ], new Set([1]), []));
  badLed.nodes[0].ledColumns = 3;
  assert.throws(() => deserializeSelection(JSON.stringify(badLed), {
    nextDocumentId: 1, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }), /rows × columns/);
  badLed.nodes[0].ledColumns = 2;
  badLed.nodes[0].ledColor = "red";
  assert.throws(() => deserializeSelection(JSON.stringify(badLed), {
    nextDocumentId: 1, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }), /#RRGGBB/);
  badLed.nodes[0].ledColor = "#ffffff";
  badLed.nodes[0].ledMode = "rgb";
  assert.throws(() => deserializeSelection(JSON.stringify(badLed), {
    nextDocumentId: 1, nextDefinitionId: 1, definitions: [], x: 0, y: 0,
  }), /needs 3 LED input pins/);

  const unknownParameter = JSON.parse(text);
  unknownParameter.nodes[0].widthParameters.w999 = 8;
  assert.throws(() => deserializeSelection(JSON.stringify(unknownParameter), {
    nextDocumentId: 100,
    nextDefinitionId: 41,
    definitions: originalDefinitions,
    x: 0,
    y: 0,
  }), /unknown parameter/);
  assert.equal(originalDefinitions.length, 1);

  const colorSource = node(20, "input", 0, 0, 8);
  const colorOutput = node(21, "output", 100, 0, 8);
  link(colorSource, colorOutput, 0, 0, "#13579B");
  const invalidColor = JSON.parse(serializeSelection(
    [colorSource, colorOutput], new Set([20, 21]), originalDefinitions,
  ));
  invalidColor.nodes[1].inputs[0].color = "blue";
  assert.throws(() => deserializeSelection(JSON.stringify(invalidColor), {
    nextDocumentId: 200,
    nextDefinitionId: 41,
    definitions: originalDefinitions,
    x: 0,
    y: 0,
  }), /#RRGGBB/);
  assert.equal(originalDefinitions.length, 1);
  assert.deepEqual(colorOutput.inputs[0], { sourceId: 20, sourcePort: 0, color: "#13579B" });
});

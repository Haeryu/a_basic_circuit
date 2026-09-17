import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { makeNode, inputDefs, outputDefs, ensureInputSlots, validWidth, maskValue, bitValue,
  busValue, createDefinition, inferDefinitionSelection, resolveCustom, changeCustomWidth, compileCircuit, readBus, setRuntimeInput,
  setRuntimeCounter, setSemanticWasm } from "../web-src/js/circuit.js";

const { instance } = await WebAssembly.instantiate(await readFile(new URL("../zig-out/web/wasm/a_basic_circuit.wasm", import.meta.url)), {});
const wasm = instance.exports;
setSemanticWasm(wasm);
function fixture() {
  wasm.abc_reset();
  const nodes = [], definitions = [];
  let runtime = null;
  const lookup = (id) => definitions.find((d) => d.id === id);
  const add = (kind, width = 1, extra = {}) => {
    const node = Object.assign(makeNode(nodes.length + 1, kind, 0, 0, width), extra);
    ensureInputSlots(node, lookup); nodes.push(node); return node;
  };
  const link = (source, target, pin = 0, sourcePort = 0) => {
    target.inputs[pin] = { sourceId: source.documentId, sourcePort };
  };
  const settle = () => {
    for (let i = 0; i < 1024; i += 1) {
      const status = wasm.abc_run(32);
      assert.notEqual(status, 2, "WASM propagation failed");
      if (status === 1) return;
    }
    assert.fail("Fixture did not settle");
  };
  const build = (preserve = true) => {
    runtime = compileCircuit(wasm, nodes, definitions, preserve ? runtime : null);
    settle(); return runtime;
  };
  const value = (node, port = 0) => busValue(readBus(wasm, runtime.handles.get(node.documentId).outputs[port]));
  const set = (node, value) => {
    node.inputValue = maskValue(value, node.width);
    setRuntimeInput(wasm, runtime.handles.get(node.documentId), node.inputValue); settle();
  };
  return { nodes, definitions, lookup, add, link, settle, build, value, set, get runtime() { return runtime; } };
}

test("every integer bus width 1..64 preserves its most significant bit", () => {
  const f = fixture();
  const source = f.add("input"), inverter = f.add("not"), out = f.add("output");
  f.link(source, inverter); f.link(inverter, out);
  for (let width = 1; width <= 64; width += 1) {
    source.width = inverter.width = out.width = width;
    source.inputValue = 1n << BigInt(width - 1);
    const result = f.build();
    assert.equal(result.diagnostics.length, 0);
    assert.equal(f.value(out), maskValue(~source.inputValue, width), `${width}-bit NOT`);
  }
  for (const invalid of [0, 65, 3.5, NaN, Infinity]) assert.equal(validWidth(invalid), false);
  assert.throws(() => maskValue(1n, 65));
});

test("64-bit input toggles do not alias bits 0, 31, 32, 53, or 63", () => {
  const f = fixture(), source = f.add("input", 64), out = f.add("output", 64);
  f.link(source, out); f.build();
  let expected = 0n;
  for (const bit of [0, 31, 32, 53, 63, 31, 0]) {
    expected ^= 1n << BigInt(bit); f.set(source, expected);
    assert.equal(f.value(out), expected);
    for (let i = 0; i < 64; i += 1) assert.equal(bitValue(expected, i), Number((expected >> BigInt(i)) & 1n));
  }
  f.set(source, 0xffffffffffffffffn);
  assert.equal(f.value(out), 18446744073709551615n);
});

test("load-enabled register updates only on rising CLK while LOAD is high", () => {
  const f = fixture();
  const data = f.add("input", 8), load = f.add("input"), clock = f.add("input"), reg = f.add("register", 8);
  f.link(data, reg, 0); f.link(load, reg, 1); f.link(clock, reg, 2);
  f.build();
  assert.deepEqual(inputDefs(reg).map((p) => [p.label,p.width]), [["DATA",8],["LOAD",1],["CLK",1]]);
  assert.equal(outputDefs(reg)[0].width, 8);
  f.set(data, 0xa5n); f.set(load, 0n); f.set(clock, 1n);
  assert.equal(f.value(reg), 0n, "LOAD low holds the register");
  f.set(clock, 0n); f.set(load, 1n); f.set(clock, 1n);
  assert.equal(f.value(reg), 0xa5n);
  f.set(data, 0x3cn);
  assert.equal(f.value(reg), 0xa5n, "changing DATA while CLK is high does not write");
  f.build();
  assert.equal(f.value(reg), 0xa5n, "unrelated rebuild preserves register state and held-high history");
  f.set(clock, 0n); f.set(load, 0n); f.set(clock, 1n);
  assert.equal(f.value(reg), 0xa5n);
});

test("ALU implements ADD AND OR XOR with a fixed two-bit opcode", () => {
  const f = fixture();
  const a = f.add("input", 8), b = f.add("input", 8), op = f.add("input", 2), alu = f.add("alu", 8);
  f.link(a, alu, 0); f.link(b, alu, 1); f.link(op, alu, 2); f.build();
  assert.deepEqual(inputDefs(alu).map((p) => [p.label,p.width]), [["A",8],["B",8],["OP",2]]);
  assert.deepEqual(outputDefs(alu).map((p) => [p.label,p.width]), [["Y",8],["COUT",1]]);
  f.set(a, 0xf0n); f.set(b, 0x30n);
  const cases = [
    [0n, 0x20n, 1n],
    [1n, 0x30n, 0n],
    [2n, 0xf0n, 0n],
    [3n, 0xc0n, 0n],
  ];
  for (const [opcode, value, carry] of cases) {
    f.set(op, opcode);
    assert.equal(f.value(alu, 0), value, `opcode ${opcode}`);
    assert.equal(f.value(alu, 1), carry, `carry opcode ${opcode}`);
  }
});

test("RAM writes selected words on rising WE clock and reads addresses asynchronously", () => {
  const f = fixture();
  const address = f.add("input", 2), data = f.add("input", 8), we = f.add("input"), clock = f.add("input");
  const ram = f.add("ram", 8, { addressWidth: 2 });
  f.link(address, ram, 0); f.link(data, ram, 1); f.link(we, ram, 2); f.link(clock, ram, 3); f.build();
  assert.deepEqual(inputDefs(ram).map((p) => [p.label,p.width]), [["ADDR",2],["DATA",8],["WE",1],["CLK",1]]);
  assert.equal(f.value(ram), 0n);
  f.set(address, 2n); f.set(data, 0xa5n); f.set(we, 1n); f.set(clock, 1n);
  assert.equal(f.value(ram), 0xa5n);
  f.set(clock, 0n); f.set(address, 1n); f.set(data, 0x33n); f.set(clock, 1n);
  assert.equal(f.value(ram), 0x33n);
  f.set(address, 2n);
  assert.equal(f.value(ram), 0xa5n, "read changes immediately without a clock edge");
  f.set(clock, 0n); f.set(we, 0n); f.set(data, 0n); f.set(clock, 1n);
  assert.equal(f.value(ram), 0xa5n, "WE low holds memory");
  f.build();
  assert.equal(f.value(ram), 0xa5n, "rebuild preserves RAM state when its shape is unchanged");
});

test("Make chip infers compact interface ports from open pins and terminal outputs", () => {
  const gate = makeNode(10, "and2", 300, 120, 8);
  ensureInputSlots(gate);
  const candidates = inferDefinitionSelection([gate], new Set([gate.documentId]));
  assert.equal(candidates.filter((node) => node.kind === "input").length, 2);
  assert.equal(candidates.filter((node) => node.kind === "output").length, 1);
  const definition = createDefinition(candidates, "AUTO AND", 900);
  assert.deepEqual(definition.inputs.map((port) => port.label), ["A", "B"]);
  assert.equal(definition.outputs.length, 1);
  assert.equal(definition.nodes.find((node) => node.kind === "and2").width, 8);

  const gateLocalId = definition.nodes.find((node) => node.kind === "and2").localId;
  const widthGroup = definition.bindings[`${gateLocalId}:width`];
  const resized = resolveCustom({ definitionId: definition.id, widthParameters: { [`w${widthGroup}`]: 16 } },
    (id) => id === definition.id ? definition : null);
  assert.ok(resized.nodes.every((node) => node.width === 16), "the connected interface/gate width group resizes together");
  const editable = resized.nodes.map((node) => ({ ...node, documentId: node.localId,
    inputs: node.inputs.map((connection) => connection && { ...connection }) }));
  assert.doesNotThrow(() => createDefinition(editable, definition.name, definition.id),
    "a solved width group can be rebuilt as an edited template");
});

test("Make chip groups crossing boundary nets and preserves explicit interfaces", () => {
  const source = makeNode(1, "input", 0, 0, 8), gate = makeNode(2, "and2", 300, 0, 8), sink = makeNode(3, "output", 620, 0, 8);
  source.label = "BUS"; ensureInputSlots(gate); ensureInputSlots(sink);
  gate.inputs[0] = { sourceId: source.documentId, sourcePort: 0 };
  gate.inputs[1] = { sourceId: source.documentId, sourcePort: 0 };
  sink.inputs[0] = { sourceId: gate.documentId, sourcePort: 0 };
  const inferred = inferDefinitionSelection([source, gate, sink], new Set([gate.documentId]));
  assert.equal(inferred.filter((node) => node.kind === "input").length, 1, "one external net becomes one input port");
  assert.equal(inferred.filter((node) => node.kind === "output").length, 1, "one crossing output net becomes one output port");
  const inferredGate = inferred.find((node) => node.documentId === gate.documentId);
  assert.equal(inferredGate.inputs[0].sourceId, inferredGate.inputs[1].sourceId);

  const explicit = inferDefinitionSelection([source, gate, sink], new Set([1, 2, 3]));
  assert.deepEqual(explicit.map((node) => node.kind), ["input", "and2", "output"], "explicit interface nodes are not duplicated");
});

test("all bus logic gates and fanout work on 64-bit patterns", () => {
  const f = fixture(), a = f.add("input", 64), b = f.add("input", 64);
  const ops = { and2: (a,b) => a & b, or2: (a,b) => a | b, xor2: (a,b) => a ^ b,
    nand2: (a,b) => ~(a & b), nor2: (a,b) => ~(a | b), xnor2: (a,b) => ~(a ^ b), buffer: (a) => a };
  const gates = Object.keys(ops).map((kind) => {
    const node = f.add(kind, 64); f.link(a, node); if (kind !== "buffer") f.link(b, node, 1); return node;
  });
  f.build(); f.set(a, 0xfedcba9876543210n); f.set(b, 0x80000001000000ffn);
  for (const gate of gates) assert.equal(f.value(gate), maskValue(ops[gate.kind](a.inputValue,b.inputValue),64), gate.kind);
});

test("MUX has independent 4-bit address and 8-bit data for all sixteen lanes", () => {
  const f = fixture(), select = f.add("input", 4), mux = f.add("mux", 8, { addressWidth: 4 });
  f.link(select, mux, 0);
  const data = Array.from({ length: 16 }, (_, i) => f.add("input", 8, { inputValue: BigInt(i * 13 + 7) }));
  data.forEach((source, i) => f.link(source, mux, i + 1));
  assert.equal(inputDefs(mux)[0].width, 4); assert.equal(outputDefs(mux)[0].width, 8);
  f.build();
  for (let address = 0; address < 16; address += 1) {
    f.set(select, BigInt(address)); assert.equal(f.value(mux), data[address].inputValue);
  }
});

test("MUX keeps 3-bit selectors independent from 3/32/64-bit data", () => {
  for (const width of [3, 32, 64]) {
    const f = fixture(), select = f.add("input", 3), mux = f.add("mux", width, { addressWidth: 3 });
    f.link(select, mux);
    const highBit = 1n << BigInt(width - 1);
    const data = Array.from({ length: 8 }, (_, i) => {
      const value = width === 3 ? BigInt(7 - i) : highBit | BigInt(i * 17 + 3);
      const source = f.add("input", width, { inputValue: value });
      f.link(source, mux, i + 1);
      return source;
    });
    const ports = inputDefs(mux);
    assert.equal(ports.length, 9); assert.equal(ports[0].width, 3);
    assert.ok(ports.slice(1).every((p) => p.width === width));
    assert.equal(outputDefs(mux)[0].width, width);
    f.build();
    for (let i = 0; i < 8; i += 1) {
      f.set(select, BigInt(i)); assert.equal(f.value(mux), data[i].inputValue);
    }
  }
});

test("DEMUX and decoder route exactly one of 64 lanes, including bit 63", () => {
  const f = fixture(), address = f.add("input", 6), data = f.add("input", 3, { inputValue: 5n });
  const demux = f.add("demux", 3, { addressWidth: 6 }), decoder = f.add("decoder", 1, { addressWidth: 6 });
  f.link(data, demux); f.link(address, demux, 1); f.link(address, decoder);
  f.build();
  for (let lane = 0; lane < 64; lane += 1) {
    f.set(address, BigInt(lane)); assert.equal(f.value(decoder), 1n << BigInt(lane));
    for (let port = 0; port < 64; port += 1) assert.equal(f.value(demux, port), port === lane ? 5n : 0n);
  }
});

test("adder has 1-bit carry ports and propagates a carry across 64 bits", () => {
  for (const width of [1, 3, 32, 64]) {
    const f = fixture(), a = f.add("input", width), b = f.add("input", width), cin = f.add("input");
    const adder = f.add("adder", width);
    f.link(a, adder); f.link(b, adder, 1); f.link(cin, adder, 2); f.build();
    assert.equal(inputDefs(adder)[2].width, 1); assert.equal(outputDefs(adder)[1].width, 1);
    const max = maskValue(-1n, width);
    for (const [av,bv,cv] of [[max,0n,1n],[max,max,1n],[0n,0n,0n],[max >> 1n,1n,0n]]) {
      f.set(a,av); f.set(b,bv); f.set(cin,cv);
      const total = av + bv + cv;
      assert.equal(f.value(adder), maskValue(total,width));
      assert.equal(f.value(adder,1), total >> BigInt(width));
    }
  }
});

test("split and join preserve LOW/HIGH ordering at arbitrary split positions", () => {
  const f = fixture(), data = f.add("input",64), split = f.add("split",64), join = f.add("join",64);
  f.link(data,split); f.link(split,join,0,0); f.link(split,join,1,1);
  data.inputValue = 0xfedcba9876543210n;
  for (const low of [1,3,17,32,63]) {
    split.splitWidth = join.splitWidth = low; f.build();
    assert.equal(f.value(split,0), maskValue(data.inputValue,low));
    assert.equal(f.value(split,1), data.inputValue >> BigInt(low));
    assert.equal(f.value(join), data.inputValue);
  }
});

test("width mismatch preserves connection objects and automatically reconnects", () => {
  const f = fixture(), a = f.add("input",8,{inputValue:255n}), gate = f.add("buffer",8), out = f.add("output",8);
  f.link(a,gate); f.link(gate,out); f.build();
  const originalIn = gate.inputs[0], originalOut = out.inputs[0];
  gate.width = 3;
  assert.equal(f.build().diagnostics.length,2);
  assert.strictEqual(gate.inputs[0],originalIn); assert.strictEqual(out.inputs[0],originalOut);
  assert.equal(f.value(out),0n);
  gate.width = 8;
  assert.equal(f.build().diagnostics.length,0); assert.equal(f.value(out),255n);
});

test("clock DATA mismatch is retained, reads zero, and reconnects without a phantom HIGH edge", () => {
  const f = fixture();
  const edge = f.add("input"), load = f.add("input",1,{inputValue:1n});
  const data = f.add("input",64,{inputValue:0x80000001000000a5n});
  const counter = f.add("clock",8), out = f.add("output",8);
  f.link(edge,counter,0); f.link(load,counter,1); f.link(data,counter,2); f.link(counter,out);
  const dataWire = counter.inputs[2];

  let runtime = f.build();
  assert.deepEqual(inputDefs(counter).map((port) => [port.label,port.width]),[["CLK",1],["LOAD",1],["DATA",8]]);
  assert.ok(runtime.diagnostics.some((diagnostic) => diagnostic.targetId === counter.documentId &&
    diagnostic.pin === 2 && diagnostic.message.includes("64 → 8 bit")));
  assert.strictEqual(counter.inputs[2],dataWire);

  setRuntimeCounter(wasm,runtime.handles.get(counter.documentId),0xa5n); f.settle();
  f.set(edge,1n);
  assert.equal(f.value(counter),0n,"LOAD samples zero when the DATA connection is width-mismatched");

  f.set(edge,0n);
  counter.width = out.width = 64;
  runtime = f.build();
  assert.equal(runtime.diagnostics.length,0);
  assert.strictEqual(counter.inputs[2],dataWire);
  f.set(edge,1n);
  assert.equal(f.value(counter),data.inputValue);

  counter.width = out.width = 8;
  runtime = f.build();
  assert.ok(runtime.diagnostics.some((diagnostic) => diagnostic.targetId === counter.documentId && diagnostic.pin === 2));
  assert.strictEqual(counter.inputs[2],dataWire);
  assert.equal(f.value(counter),0xa5n,"rebuilding while CLK is HIGH does not load mismatched DATA");

  data.width = 8; data.inputValue = 0x3cn;
  runtime = f.build();
  assert.equal(runtime.diagnostics.length,0);
  assert.strictEqual(counter.inputs[2],dataWire);
  assert.equal(f.value(counter),0xa5n,"repairing DATA width while CLK is HIGH is not an asynchronous load");
  f.set(edge,0n); f.set(edge,1n);
  assert.equal(f.value(counter),0x3cn);
});

test("shrinking a MUX address retains dormant data wires and the selector pin", () => {
  const f = fixture(), sel = f.add("input",3,{inputValue:7n}), data = f.add("input",8,{inputValue:0xa5n});
  const mux = f.add("mux",8,{addressWidth:3}); f.link(sel,mux); f.link(data,mux,8);
  f.build(); assert.equal(f.value(mux),0xa5n);
  const original = mux.inputs[8]; mux.addressWidth = 2; sel.width = 2; sel.inputValue = 3n;
  const warnings = f.build().diagnostics;
  assert.ok(warnings.some((d) => d.message.includes("inactive input")));
  assert.strictEqual(mux.inputs[8],original); assert.equal(mux.inputs[0].sourceId,sel.documentId);
  mux.addressWidth = 3; sel.width = 3; sel.inputValue = 7n;
  assert.equal(f.build().diagnostics.length,0); assert.equal(f.value(mux),0xa5n);
});

test("shrinking DEMUX outputs preserves consumers on inactive lanes", () => {
  const f = fixture(), sel = f.add("input",3,{inputValue:7n}), data = f.add("input",8,{inputValue:99n});
  const demux = f.add("demux",8,{addressWidth:3}), out = f.add("output",8);
  f.link(data,demux); f.link(sel,demux,1); f.link(demux,out,0,7); f.build();
  const original = out.inputs[0]; demux.addressWidth = 2;
  assert.ok(f.build().diagnostics.some((d) => d.message.includes("inactive output")));
  assert.strictEqual(out.inputs[0],original); assert.equal(f.value(out),0n);
  demux.addressWidth = 3; assert.equal(f.build().diagnostics.length,0); assert.equal(f.value(out),99n);
});

test("custom chips resize connected data ports together without changing other instances", () => {
  const f = fixture(), a = f.add("input",8), b = f.add("input",8), gate = f.add("and2",8), out = f.add("output",8);
  f.link(a,gate); f.link(b,gate,1); f.link(gate,out);
  const definition = createDefinition(f.nodes,"AND BUS",1); f.definitions.push(definition);
  const first = f.add("custom",1,{definitionId:1}), second = f.add("custom",1,{definitionId:1});
  assert.equal(definition.parameters.length,1);
  const parameter = definition.parameters[0].id;
  f.link(a,first); f.link(b,first,1);
  for (const width of [3,32,64]) {
    changeCustomWidth(first,parameter,width,f.lookup); a.width = b.width = width;
    a.inputValue = maskValue(-1n,width); b.inputValue = 1n << BigInt(width - 1);
    f.build(); assert.equal(f.value(first),b.inputValue);
    assert.deepEqual(inputDefs(first,f.lookup).map((p) => p.width),[width,width]);
    assert.equal(outputDefs(first,f.lookup)[0].width,width);
    assert.equal(outputDefs(second,f.lookup)[0].width,8);
    assert.equal(definition.nodes[0].width,8);
  }
});

test("custom DFF data width is configurable while its connected clock remains one bit", () => {
  const f = fixture(), d = f.add("input",8,{label:"DATA"}), clk = f.add("input",1,{label:"CLK"});
  const flop = f.add("dff",8), q = f.add("output",8,{label:"Q"});
  f.link(d,flop); f.link(clk,flop,1); f.link(flop,q);
  const def = createDefinition(f.nodes,"REGISTER",1); f.definitions.push(def);
  const chip = f.add("custom",1,{definitionId:1});
  assert.equal(def.parameters.length,1); assert.ok(!def.parameters[0].label.includes("CLK"));
  changeCustomWidth(chip,def.parameters[0].id,64,f.lookup);
  assert.deepEqual(inputDefs(chip,f.lookup).map((p) => p.width),[64,1]);
  const data = f.add("input",64,{inputValue:0x8000000000000001n}), clock = f.add("input");
  f.link(data,chip); f.link(clock,chip,1); f.build(); f.set(clock,1n);
  assert.equal(f.value(chip),data.inputValue);
});

test("custom loadable counter keeps CLK and LOAD fixed while DATA resizes independently", () => {
  const f = fixture();
  const clk = f.add("input",1,{label:"CLK"}), load = f.add("input",1,{label:"LOAD"});
  const data = f.add("input",8,{label:"DATA"}), counter = f.add("clock",8);
  const out = f.add("output",8,{label:"COUNT"});
  f.link(clk,counter,0); f.link(load,counter,1); f.link(data,counter,2); f.link(counter,out);
  const definition = createDefinition(f.nodes,"LOADABLE COUNTER",1); f.definitions.push(definition);
  assert.equal(definition.parameters.length,1);
  assert.ok(definition.parameters[0].label.includes("DATA"));
  assert.ok(!definition.parameters[0].label.includes("CLK"));
  assert.ok(!definition.parameters[0].label.includes("LOAD"));

  const first = f.add("custom",1,{definitionId:1}), second = f.add("custom",1,{definitionId:1});
  changeCustomWidth(first,definition.parameters[0].id,64,f.lookup);
  assert.deepEqual(inputDefs(first,f.lookup).map((port) => port.width),[1,1,64]);
  assert.equal(outputDefs(first,f.lookup)[0].width,64);
  assert.deepEqual(inputDefs(second,f.lookup).map((port) => port.width),[1,1,8]);
  assert.equal(outputDefs(second,f.lookup)[0].width,8);
  assert.equal(definition.nodes.find((node) => node.kind === "clock").width,8);

  const edge = f.add("input"), loadSource = f.add("input"), wideData = f.add("input",64);
  const exact = 0x8000000100000001n;
  f.link(edge,first,0); f.link(loadSource,first,1); f.link(wideData,first,2);
  f.build();
  f.set(wideData,exact); f.set(loadSource,1n);
  assert.equal(f.value(first),0n);
  f.set(edge,1n);
  assert.equal(f.value(first),exact);
  f.set(loadSource,0n); f.set(edge,0n); f.set(edge,1n);
  assert.equal(f.value(first),exact+1n);
});

test("custom Register keeps LOAD and CLK fixed while DATA and Q resize together", () => {
  const f = fixture();
  const data = f.add("input",8,{label:"DATA"}), load = f.add("input",1,{label:"LOAD"}), clk = f.add("input",1,{label:"CLK"});
  const reg = f.add("register",8), out = f.add("output",8,{label:"Q"});
  f.link(data,reg,0); f.link(load,reg,1); f.link(clk,reg,2); f.link(reg,out);
  const def = createDefinition(f.nodes,"REG FILE CELL",1); f.definitions.push(def);
  assert.equal(def.parameters.length,1);
  assert.ok(def.parameters[0].label.includes("DATA"));
  assert.ok(def.parameters[0].label.includes("Q"));
  assert.ok(!def.parameters[0].label.includes("LOAD"));
  assert.ok(!def.parameters[0].label.includes("CLK"));
  const chip = f.add("custom",1,{definitionId:1});
  changeCustomWidth(chip,def.parameters[0].id,64,f.lookup);
  assert.deepEqual(inputDefs(chip,f.lookup).map((p) => p.width),[64,1,1]);
  assert.equal(outputDefs(chip,f.lookup)[0].width,64);
});

test("custom ALU keeps OP fixed at two bits while its data group resizes", () => {
  const f = fixture();
  const a = f.add("input",8,{label:"A"}), b = f.add("input",8,{label:"B"}), op = f.add("input",2,{label:"OP"});
  const alu = f.add("alu",8), y = f.add("output",8,{label:"Y"}), carry = f.add("output",1,{label:"COUT"});
  f.link(a,alu,0); f.link(b,alu,1); f.link(op,alu,2); f.link(alu,y,0,0); f.link(alu,carry,0,1);
  const def = createDefinition(f.nodes,"ALU CELL",1); f.definitions.push(def);
  assert.equal(def.parameters.length,1);
  assert.ok(!def.parameters[0].label.includes("OP"));
  const chip = f.add("custom",1,{definitionId:1});
  changeCustomWidth(chip,def.parameters[0].id,32,f.lookup);
  assert.deepEqual(inputDefs(chip,f.lookup).map((p) => p.width),[32,32,2]);
  assert.deepEqual(outputDefs(chip,f.lookup).map((p) => p.width),[32,1]);
});

test("custom RAM exposes independent address and data groups with fixed WE and CLK", () => {
  const f = fixture();
  const addr = f.add("input",3,{label:"ADDR"}), data = f.add("input",8,{label:"DATA"});
  const we = f.add("input",1,{label:"WE"}), clk = f.add("input",1,{label:"CLK"});
  const ram = f.add("ram",8,{addressWidth:3}), out = f.add("output",8,{label:"Q"});
  f.link(addr,ram,0); f.link(data,ram,1); f.link(we,ram,2); f.link(clk,ram,3); f.link(ram,out);
  const def = createDefinition(f.nodes,"RAM CELL",1); f.definitions.push(def);
  assert.equal(def.parameters.length,2);
  const addressParam = def.parameters.find((p) => p.label === "ADDR");
  const dataParam = def.parameters.find((p) => p.label.includes("DATA"));
  assert.ok(addressParam); assert.ok(dataParam); assert.notEqual(addressParam.id,dataParam.id);
  assert.ok(!def.parameters.some((p) => p.label.includes("WE") || p.label.includes("CLK")));
  const chip = f.add("custom",1,{definitionId:1});
  changeCustomWidth(chip,addressParam.id,6,f.lookup);
  changeCustomWidth(chip,dataParam.id,32,f.lookup);
  assert.deepEqual(inputDefs(chip,f.lookup).map((p) => p.width),[6,32,1,1]);
  assert.equal(outputDefs(chip,f.lookup)[0].width,32);
});

test("custom MUX keeps address and data width groups independent", () => {
  const f = fixture(), sel = f.add("input",3,{label:"ADDR"}), mux = f.add("mux",8,{addressWidth:3});
  f.link(sel,mux);
  const data = Array.from({length:8}, (_,i) => f.add("input",8,{label:`D${i}`}));
  data.forEach((n,i) => f.link(n,mux,i+1));
  const out = f.add("output",8,{label:"Q"}); f.link(mux,out);
  const def = createDefinition(f.nodes,"MUX8",1); f.definitions.push(def);
  const chip = f.add("custom",1,{definitionId:1});
  assert.equal(def.parameters.length,2);
  const addressParam = def.parameters.find((p) => p.label === "ADDR");
  const dataParam = def.parameters.find((p) => p.label.includes("D0"));
  assert.ok(addressParam); assert.ok(dataParam); assert.notEqual(addressParam.id,dataParam.id);
  for (const width of [3,32,64]) {
    changeCustomWidth(chip,dataParam.id,width,f.lookup);
    const ports = inputDefs(chip,f.lookup);
    assert.equal(ports[0].width,3); assert.ok(ports.slice(1).every((p) => p.width === width));
    assert.equal(outputDefs(chip,f.lookup)[0].width,width);
  }
  const address = f.add("input",3,{inputValue:7n}), source = f.add("input",64,{inputValue:0x80000000000000ffn});
  f.link(address,chip); f.link(source,chip,8); f.build(); assert.equal(f.value(chip),source.inputValue);
});

test("custom split derives high width from total and low width", () => {
  const f = fixture(), data = f.add("input",8,{label:"TOTAL"}), split = f.add("split",8,{splitWidth:3});
  const low = f.add("output",3,{label:"LOW"}), high = f.add("output",5,{label:"HIGH"});
  f.link(data,split); f.link(split,low,0,0); f.link(split,high,0,1);
  const def = createDefinition(f.nodes,"SLICE",1); f.definitions.push(def);
  const chip = f.add("custom",1,{definitionId:1});
  const totalParam = def.parameters.find((p) => p.label === "TOTAL");
  changeCustomWidth(chip,totalParam.id,64,f.lookup);
  assert.deepEqual(outputDefs(chip,f.lookup).map((p) => p.width),[3,61]);
  const source = f.add("input",64,{inputValue:0xfedcba9876543210n}); f.link(source,chip);
  f.build(); assert.equal(f.value(chip,0),0n); assert.equal(f.value(chip,1),source.inputValue >> 3n);
  assert.throws(() => changeCustomWidth(chip,totalParam.id,2,f.lookup), /Widths cannot/);
  assert.equal(inputDefs(chip,f.lookup)[0].width,64, "rejected changes leave the instance intact");
});

test("custom split derives an unexposed internal width before hiding interface controls", () => {
  const f = fixture(), data = f.add("input",8,{label:"TOTAL"}), split = f.add("split",8,{splitWidth:7});
  const high = f.add("output",1,{label:"HIGH"});
  f.link(data,split); f.link(split,high,0,1);
  const def = createDefinition(f.nodes,"HIGH SLICE",1); f.definitions.push(def);
  assert.deepEqual(def.parameters.map((p) => p.label).sort(),["HIGH","TOTAL"]);
  const chip = f.add("custom",1,{definitionId:1});
  const totalParam = def.parameters.find((p) => p.label === "TOTAL");
  const highParam = def.parameters.find((p) => p.label === "HIGH");
  changeCustomWidth(chip,totalParam.id,64,f.lookup);
  changeCustomWidth(chip,highParam.id,32,f.lookup);
  assert.equal(inputDefs(chip,f.lookup)[0].width,64);
  assert.equal(outputDefs(chip,f.lookup)[0].width,32);
  const source = f.add("input",64,{inputValue:0xfedcba9876543210n});
  f.link(source,chip); assert.equal(f.build().diagnostics.length,0);
  assert.equal(f.value(chip),source.inputValue >> 32n);
});

test("custom decoder derives output bus width from its address width", () => {
  const f = fixture(), address = f.add("input",3,{label:"ADDR"}), decoder = f.add("decoder",1,{addressWidth:3});
  const out = f.add("output",8,{label:"ONEHOT"}); f.link(address,decoder); f.link(decoder,out);
  const def = createDefinition(f.nodes,"DECODE",1); f.definitions.push(def);
  const chip = f.add("custom",1,{definitionId:1});
  assert.equal(def.parameters.length,1);
  changeCustomWidth(chip,def.parameters[0].id,6,f.lookup);
  assert.equal(outputDefs(chip,f.lookup)[0].width,64);
  const source = f.add("input",6,{inputValue:63n}); f.link(source,chip); f.build();
  assert.equal(f.value(chip),1n << 63n);
  assert.throws(() => changeCustomWidth(chip,def.parameters[0].id,7,f.lookup));
});

test("duplicate decoder constraints keep one address width parameter", () => {
  const f = fixture(), address = f.add("input",3,{label:"ADDR"});
  const left = f.add("decoder",1,{addressWidth:3}), right = f.add("decoder",1,{addressWidth:3});
  const both = f.add("and2",8), out = f.add("output",8,{label:"BOTH"});
  f.link(address,left);
  f.link(address,right);
  f.link(left,both);
  f.link(right,both,1);
  f.link(both,out);
  const def = createDefinition(f.nodes,"DOUBLE DECODE",1); f.definitions.push(def);
  assert.deepEqual(def.parameters.map((p) => p.label),["ADDR"]);
  const chip = f.add("custom",1,{definitionId:1});
  changeCustomWidth(chip,def.parameters[0].id,5,f.lookup);
  assert.equal(inputDefs(chip,f.lookup)[0].width,5);
  assert.equal(outputDefs(chip,f.lookup)[0].width,32);
  const source = f.add("input",5,{inputValue:31n});
  f.link(source,chip); assert.equal(f.build().diagnostics.length,0);
  assert.equal(f.value(chip),1n << 31n);
});

test("custom decoder feeding JOIN derives packed width from address changes", () => {
  const f = fixture(), address = f.add("input",3,{label:"ADDR"}), low = f.add("input",3,{label:"LOW"});
  const decoder = f.add("decoder",1,{addressWidth:3}), join = f.add("join",11,{splitWidth:3});
  const out = f.add("output",11,{label:"PACKED"});
  f.link(address,decoder);
  f.link(low,join);
  f.link(decoder,join,1);
  f.link(join,out);
  const def = createDefinition(f.nodes,"PACKED DECODE",1);
  f.definitions.push(def);
  assert.deepEqual(def.parameters.map((p) => p.label).sort(),["ADDR","LOW"]);
  const chip = f.add("custom",1,{definitionId:1});
  const addressParam = def.parameters.find((p) => p.label === "ADDR");
  assert.ok(addressParam);
  changeCustomWidth(chip,addressParam.id,5,f.lookup);
  assert.deepEqual(inputDefs(chip,f.lookup).map((p) => p.width),[5,3]);
  assert.equal(outputDefs(chip,f.lookup)[0].width,35);
  const addressSource = f.add("input",5,{inputValue:31n});
  const lowSource = f.add("input",3,{inputValue:5n});
  f.link(addressSource,chip);
  f.link(lowSource,chip,1);
  assert.equal(f.build().diagnostics.length,0);
  assert.equal(f.value(chip),5n | (1n << 34n));
});

test("custom definitions reject outside inputs and inconsistent internal widths", () => {
  const f = fixture(), a = f.add("input",8), outside = f.add("input",8), gate = f.add("and2",8), out = f.add("output",8);
  f.link(a,gate); f.link(outside,gate,1); f.link(gate,out);
  assert.throws(() => createDefinition([a,gate,out],"INVALID",1), /outside/);
  outside.width = 3;
  assert.throws(() => createDefinition(f.nodes,"INVALID",1), /internal wire/);
});

test("nested custom chips propagate exact 64-bit values through recursive definitions", () => {
  const input = makeNode(1,"input",0,0,64), buffer = makeNode(2,"buffer",240,0,64), output = makeNode(3,"output",480,0,64);
  input.label = "IN"; output.label = "OUT"; ensureInputSlots(buffer); ensureInputSlots(output);
  buffer.inputs[0] = {sourceId:1,sourcePort:0}; output.inputs[0] = {sourceId:2,sourcePort:0};
  const inner = createDefinition([input,buffer,output],"INNER64",100);
  const innerLookup = (id) => id === inner.id ? inner : null;

  const outerIn = makeNode(10,"input",0,0,64), nested = makeNode(11,"custom",240,0,1,inner.id), outerOut = makeNode(12,"output",480,0,64);
  outerIn.label = "IN"; outerOut.label = "OUT"; ensureInputSlots(nested,innerLookup); ensureInputSlots(outerOut);
  nested.inputs[0] = {sourceId:10,sourcePort:0}; outerOut.inputs[0] = {sourceId:11,sourcePort:0};
  const outer = createDefinition([outerIn,nested,outerOut],"OUTER64",200,innerLookup);

  wasm.abc_reset();
  const source = makeNode(500,"input",0,0,64), chip = makeNode(501,"custom",300,0,1,outer.id), sink = makeNode(502,"output",600,0,64);
  source.inputValue = 0x80000001000000ffn;
  const definitions = [inner,outer], lookup = (id) => definitions.find((definition) => definition.id === id);
  ensureInputSlots(chip,lookup); ensureInputSlots(sink,lookup);
  chip.inputs[0] = {sourceId:source.documentId,sourcePort:0}; sink.inputs[0] = {sourceId:chip.documentId,sourcePort:0};
  const runtime = compileCircuit(wasm,[source,chip,sink],definitions);
  for (let i = 0; i < 1024 && wasm.abc_run(32) === 0; i += 1) {}
  assert.equal(busValue(readBus(wasm,runtime.handles.get(sink.documentId).outputs[0])),source.inputValue);
  assert.equal(runtime.handles.get(chip.documentId).children.get(2).children.get(2).outputs[0].length,64);
});

test("nested stateful custom instances have isolated stable state keys across definition id remapping", () => {
  const makeInner = (id) => {
    const clk = makeNode(1,"input",0,0,1), counter = makeNode(2,"clock",220,0,4), out = makeNode(3,"output",460,0,4);
    clk.label = "CLK"; out.label = "COUNT"; ensureInputSlots(counter); ensureInputSlots(out);
    counter.inputs[0] = {sourceId:1,sourcePort:0}; out.inputs[0] = {sourceId:2,sourcePort:0};
    return createDefinition([clk,counter,out],"CELL",id);
  };
  const makeOuter = (id, inner) => {
    const lookup = (value) => value === inner.id ? inner : null;
    const clk = makeNode(10,"input",0,0,1), left = makeNode(11,"custom",220,-80,1,inner.id), right = makeNode(12,"custom",220,100,1,inner.id);
    const q0 = makeNode(13,"output",520,-80,4), q1 = makeNode(14,"output",520,100,4);
    clk.label = "CLK"; q0.label = "LEFT"; q1.label = "RIGHT";
    ensureInputSlots(left,lookup); ensureInputSlots(right,lookup); ensureInputSlots(q0); ensureInputSlots(q1);
    left.inputs[0] = {sourceId:10,sourcePort:0}; right.inputs[0] = {sourceId:10,sourcePort:0};
    q0.inputs[0] = {sourceId:11,sourcePort:0}; q1.inputs[0] = {sourceId:12,sourcePort:0};
    return createDefinition([clk,left,right,q0,q1],"PAIR",id,lookup);
  };

  const inner = makeInner(100), outer = makeOuter(200,inner);
  const definitions = [inner,outer], lookup = (id) => definitions.find((definition) => definition.id === id);
  const rootClk = makeNode(700,"input",0,0,1), root = makeNode(701,"custom",300,0,1,outer.id);
  ensureInputSlots(root,lookup); root.inputs[0] = {sourceId:rootClk.documentId,sourcePort:0};
  wasm.abc_reset();
  const runtime = compileCircuit(wasm,[rootClk,root],definitions);
  const leftCounter = runtime.handles.get(root.documentId).children.get(2).children.get(2);
  const rightCounter = runtime.handles.get(root.documentId).children.get(3).children.get(2);
  setRuntimeCounter(wasm,leftCounter,9n);
  for (let i = 0; i < 1024 && wasm.abc_run(32) === 0; i += 1) {}
  assert.equal(busValue(readBus(wasm,leftCounter.outputs[0])),9n);
  assert.equal(busValue(readBus(wasm,rightCounter.outputs[0])),0n,"two uses of the same nested definition must not alias state");
  const originalKeys = [...runtime.stateKeys.keys()].filter((key) => key.endsWith(":counter"))
    .map((key) => key.slice(key.indexOf("/"))).sort();
  assert.equal(new Set(originalKeys).size,8,"two four-bit counters own distinct state slots");

  const remappedInner = makeInner(900), remappedOuter = makeOuter(901,remappedInner);
  const remappedDefinitions = [remappedInner,remappedOuter];
  const remappedRoot = makeNode(701,"custom",300,0,1,remappedOuter.id);
  ensureInputSlots(remappedRoot,(id) => remappedDefinitions.find((definition) => definition.id === id));
  remappedRoot.inputs[0] = {sourceId:rootClk.documentId,sourcePort:0};
  wasm.abc_reset();
  const remappedRuntime = compileCircuit(wasm,[rootClk,remappedRoot],remappedDefinitions);
  const remappedKeys = [...remappedRuntime.stateKeys.keys()].filter((key) => key.endsWith(":counter"))
    .map((key) => key.slice(key.indexOf("/"))).sort();
  assert.deepEqual(remappedKeys,originalKeys,"runtime state keys must not depend on palette definition ids");
});

test("recursive custom definition cycles are rejected while a shared DAG is accepted", () => {
  const baseIn = makeNode(1,"input",0,0,1), baseOut = makeNode(2,"output",240,0,1);
  baseIn.label = "IN"; baseOut.label = "OUT"; ensureInputSlots(baseOut); baseOut.inputs[0] = {sourceId:1,sourcePort:0};
  const a = createDefinition([baseIn,baseOut],"A",1);
  const defs = [a];
  const lookup = (id) => defs.find((definition) => definition.id === id);
  const wrap = (child,id,name) => {
    const input = makeNode(10,"input",0,0,1), nested = makeNode(11,"custom",220,0,1,child.id), output = makeNode(12,"output",480,0,1);
    input.label = "IN"; output.label = "OUT"; ensureInputSlots(nested,lookup); ensureInputSlots(output);
    nested.inputs[0] = {sourceId:10,sourcePort:0}; output.inputs[0] = {sourceId:11,sourcePort:0};
    return createDefinition([input,nested,output],name,id,lookup);
  };
  const b = wrap(a,2,"B"); defs.push(b);
  const c = wrap(b,3,"C"); defs.push(c);
  assert.doesNotThrow(() => wrap(a,4,"D"),"multiple parents may share the same child definition");

  const self = makeNode(20,"custom",0,0,1,a.id);
  assert.throws(() => createDefinition([baseIn,self,baseOut],"A",a.id,lookup),/cannot contain themselves recursively/);
  const cycleNode = makeNode(21,"custom",0,0,1,c.id);
  ensureInputSlots(cycleNode,lookup);
  const cycleOut = makeNode(22,"output",300,0,1); ensureInputSlots(cycleOut); cycleOut.inputs[0] = {sourceId:21,sourcePort:0};
  assert.throws(() => createDefinition([baseIn,cycleNode,cycleOut],"A",a.id,lookup),/cannot contain themselves recursively/);
});

test("unrelated editor rebuild retains DFF state while clock is already high", () => {
  const f = fixture(), d = f.add("input",64), clk = f.add("input"), flop = f.add("dff",64);
  f.link(d,flop); f.link(clk,flop,1);
  const dataWire = flop.inputs[0], clockWire = flop.inputs[1];
  f.build();
  f.set(d,0x8000000100000001n); f.set(clk,1n);
  const sampled = f.value(flop); f.set(d,0n);
  f.add("not",3); f.build();
  assert.strictEqual(flop.inputs[0],dataWire);
  assert.strictEqual(flop.inputs[1],clockWire);
  assert.equal(f.value(flop),sampled);
  f.set(clk,0n); f.set(clk,1n); assert.equal(f.value(flop),0n);
});

test("rebuild restores combinational clock paths without synthesizing a new edge", () => {
  const f = fixture(), d = f.add("input",8,{inputValue:0xa5n}), clockInput = f.add("input");
  const inverter = f.add("not"), buffer = f.add("buffer"), flop = f.add("dff",8);
  f.link(clockInput,inverter); f.link(inverter,buffer); f.link(buffer,flop,1); f.link(d,flop);
  f.build(); assert.equal(f.value(flop),0xa5n);
  f.set(d,0n); f.add("output",32); f.build(); assert.equal(f.value(flop),0xa5n);
  f.set(clockInput,1n); f.set(clockInput,0n); assert.equal(f.value(flop),0n);
});

test("custom register state survives instance resizing and unrelated document edits", () => {
  const f = fixture(), d = f.add("input",8), clk = f.add("input"), flop = f.add("dff",8), q = f.add("output",8);
  f.link(d,flop); f.link(clk,flop,1); f.link(flop,q);
  const def = createDefinition(f.nodes,"REG",1); f.definitions.push(def);
  const chip = f.add("custom",1,{definitionId:1}); f.link(d,chip); f.link(clk,chip,1);
  f.build(); f.set(d,0xa5n); f.set(clk,1n); f.set(d,0n);
  f.build(); assert.equal(f.value(chip),0xa5n);
  changeCustomWidth(chip,def.parameters[0].id,64,f.lookup); d.width = 64; f.build();
  assert.equal(f.value(chip) & 255n,0xa5n, "existing register bits survive growth");
  assert.equal(inputDefs(chip,f.lookup)[1].width,1);
});

test("native counter ABI shares CLK and LOAD across lanes and keeps DATA lane-local", () => {
  wasm.abc_reset();
  const width = 64, counter = wasm.abc_add_counter(width) >>> 0;
  assert.notEqual(counter,0xffffffff);
  const clock = wasm.abc_add_node(0) >>> 0, load = wasm.abc_add_node(0) >>> 0;
  const data = Array.from({length:width},() => wasm.abc_add_node(0) >>> 0);
  for (const id of [clock,load,...data]) assert.notEqual(id,0xffffffff);

  assert.equal(wasm.abc_connect(clock,counter+17,0),0);
  assert.equal(wasm.abc_connect(load,counter+42,1),0);
  data.forEach((id,bit) => assert.equal(wasm.abc_connect(id,counter+bit,2),0));
  const settle = () => {
    for (let round = 0; round < 128; round += 1) {
      const status = wasm.abc_run(32);
      assert.notEqual(status,2);
      if (status === 1) return;
    }
    assert.fail("native counter ABI fixture did not settle");
  };
  const set = (id,value) => assert.equal(wasm.abc_set_input(id,value ? 1 : 0),0);
  const setData = (value) => data.forEach((id,bit) => set(id,(value & (1n << BigInt(bit))) !== 0n));
  const value = () => busValue(Array.from({length:width},(_,bit) => wasm.abc_value(counter+bit) === 1));

  const first = 0x8000000100000021n;
  setData(first); set(load,true); set(clock,true); settle();
  assert.equal(value(),first,"LOAD has priority over increment on the rising edge");

  const second = 0xf000000100000063n;
  setData(second); set(load,false); settle();
  assert.equal(value(),first,"DATA and LOAD changes while CLK is HIGH are not asynchronous");
  set(load,true); settle();
  assert.equal(value(),first);
  set(clock,false); settle();
  assert.equal(wasm.abc_disconnect(counter+5,2),1);
  set(clock,true); settle();
  const loadedWithoutBit5 = second & ~(1n << 5n);
  assert.equal(value(),loadedWithoutBit5,"DATA pin 2 belongs only to its output lane");

  set(clock,false); settle();
  assert.equal(wasm.abc_disconnect(counter+63,1),1,"LOAD disconnects through any lane");
  set(clock,true); settle();
  assert.equal(value(),BigInt.asUintN(width,loadedWithoutBit5+1n),"unwired LOAD resumes incrementing");

  set(clock,false); settle();
  assert.equal(wasm.abc_set_counter(counter+31,0xffffffff,0xffffffff),0);
  settle();
  assert.equal(value(),0xffffffffffffffffn);
  set(clock,true); settle();
  assert.equal(value(),0n,"64-bit increment wraps modulo 2^64");

  set(clock,false); settle();
  assert.equal(wasm.abc_disconnect(counter+7,0),1,"CLK disconnects through any lane");
  set(clock,true); settle();
  assert.equal(value(),0n,"an unwired CLK cannot create an edge");
});

test("checkpoint ABI rejects invalid handles and packed values", () => {
  wasm.abc_reset();
  assert.equal(wasm.abc_state(0xffffffff),4);
  assert.equal(wasm.abc_restore_state(0xffffffff,0),1);
  const node = wasm.abc_add_node(6);
  assert.equal(wasm.abc_restore_state(node,4),2);
  assert.equal(wasm.abc_restore_state(node,3),0); assert.equal(wasm.abc_state(node),3);
  assert.equal(wasm.abc_remove_node(node),1); assert.equal(wasm.abc_state(node),4);
});

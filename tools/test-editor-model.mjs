import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { makeNode, inputDefs, outputDefs, ensureInputSlots, compileCircuit, setRuntimeInput,
  readBus, busValue, resizeDisplay, parseInputValue, formatBusValue, setSemanticWasm } from "../web-src/js/circuit.js";
import { createDefinition, changeCustomWidth, setRuntimeCounter } from "../web-src/js/circuit.js";
import { serializeProject, deserializeProject } from "../web-src/js/project.js";

const { instance } = await WebAssembly.instantiate(await readFile(new URL("../zig-out/web/wasm/a_basic_circuit.wasm", import.meta.url)), {});
const wasm = instance.exports;
setSemanticWasm(wasm);
function settle() {
  for (let i = 0; i < 100; i += 1) {
    const status = wasm.abc_run(32);
    assert.notEqual(status, 2);
    if (status === 1) return;
  }
  assert.fail("circuit did not settle");
}
const link = (source, target, pin = 0) => { target.inputs[pin] = { sourceId: source.documentId, sourcePort: 0 }; };

test("all four input bases roundtrip maximum u64 and reject invalid digits or overflow", () => {
  const max = 18446744073709551615n;
  for (const radix of [2, 8, 10, 16]) {
    const text = formatBusValue(max,64,radix);
    assert.deepEqual(parseInputValue(`  ${text}  `,64),{value:max,radix});
    assert.deepEqual(parseInputValue(formatBusValue(5n,3,radix),3),{value:5n,radix});
  }
  assert.equal(parseInputValue("0O177",8).value,127n);
  assert.equal(parseInputValue("0009",8).value,9n);
  for (const text of ["0o8", "0b2", "0xG", "-1", "1.5", "1e3", "", "0o", "0x10000000000000000", "18446744073709551616"]) {
    assert.throws(() => parseInputValue(text,64));
  }
  assert.throws(() => parseInputValue("0o10",3));
});

test("one-bit oscillator pulses DFF data and retains high state on rebuild", () => {
  const clock = makeNode(1,"oscillator",0,0), data = makeNode(2,"input",0,0,64), flop = makeNode(3,"dff",0,0,64);
  assert.equal(clock.width,1); assert.deepEqual(inputDefs(clock),[]); assert.equal(outputDefs(clock)[0].width,1);
  data.inputValue = 0x8000000100000001n; link(data,flop); link(clock,flop,1);
  let runtime = compileCircuit(wasm,[clock,data,flop],[]); settle();
  const value = () => busValue(readBus(wasm,runtime.handles.get(3).outputs[0]));
  assert.equal(value(),0n);
  clock.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle(); assert.equal(value(),data.inputValue);
  data.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(2),0n); settle();
  runtime = compileCircuit(wasm,[clock,data,flop],[],runtime); settle(); assert.equal(value(),0x8000000100000001n);
  clock.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(1),0n); settle();
  clock.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle(); assert.equal(value(),0n);
});

test("native clock counters increment on oscillator rising edges for widths 1 through 64", () => {
  const clock = makeNode(1,"clock",0,0,64), output = makeNode(2,"output",0,0,64), oscillator = makeNode(3,"oscillator",0,0);
  link(clock,output); link(oscillator,clock);
  let runtime = null;
  for (let width = 1; width <= 64; width += 1) {
    clock.width = output.width = width;
    oscillator.inputValue = 0n;
    runtime = compileCircuit(wasm,[clock,output,oscillator],[]); settle();
    assert.equal(outputDefs(clock)[0].width,width);
    assert.deepEqual(inputDefs(clock).map((port) => [port.label,port.width]),[["CLK",1],["LOAD",1],["DATA",width]]);
    assert.deepEqual(runtime.handles.get(clock.documentId).inputs.map((port) => port.width),[1,1,width]);
    for (let step = 1; step <= 10; step += 1) {
      setRuntimeInput(wasm,runtime.handles.get(3),1n); settle();
      const expected = BigInt.asUintN(width,BigInt(step));
      assert.equal(busValue(readBus(wasm,runtime.handles.get(2).outputs[0])),expected);
      setRuntimeInput(wasm,runtime.handles.get(3),1n); settle();
      assert.equal(busValue(readBus(wasm,runtime.handles.get(2).outputs[0])),expected,"holding HIGH does not count twice");
      setRuntimeInput(wasm,runtime.handles.get(3),0n); settle();
    }
  }
});

test("loadable counter samples DATA on an edge while a DFF sees the old COUNT", () => {
  const edge = makeNode(1,"oscillator",0,0), load = makeNode(2,"input",0,100);
  const data = makeNode(3,"input",0,200,64), counter = makeNode(4,"clock",240,100,64);
  const flop = makeNode(5,"dff",520,100,64), nodes = [edge,load,data,counter,flop];
  const exact = 0x8000000100000001n, replacement = 0xf000000000000055n;
  load.inputValue = 1n; data.inputValue = exact;
  link(edge,counter,0); link(load,counter,1); link(data,counter,2);
  link(counter,flop,0); link(edge,flop,1);

  let runtime = compileCircuit(wasm,nodes,[]); settle();
  const counterValue = () => busValue(readBus(wasm,runtime.handles.get(4).outputs[0]));
  const flopValue = () => busValue(readBus(wasm,runtime.handles.get(5).outputs[0]));
  const counterKeys = () => [...runtime.stateKeys.keys()].filter((key) => key.startsWith("4/"));
  assert.deepEqual(counterKeys(),Array.from({length:64},(_,bit) => `4/count${bit}:counter`));
  assert.equal(counterValue(),0n,"LOAD and DATA do nothing while CLK remains LOW");
  assert.equal(flopValue(),0n);

  edge.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle();
  assert.equal(counterValue(),exact);
  assert.equal(flopValue(),0n,"DFF samples the counter output from before the shared edge");

  data.inputValue = replacement; setRuntimeInput(wasm,runtime.handles.get(3),replacement); settle();
  load.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(2),0n); settle();
  assert.equal(counterValue(),exact,"changing DATA and LOAD while CLK is HIGH does not alter COUNT");
  runtime = compileCircuit(wasm,nodes,[],runtime); settle();
  assert.deepEqual(counterKeys(),Array.from({length:64},(_,bit) => `4/count${bit}:counter`));
  assert.equal(counterValue(),exact,"a HIGH-clock rebuild does not synthesize another edge");
  assert.equal(flopValue(),0n);

  edge.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(1),0n); settle();
  edge.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle();
  assert.equal(counterValue(),exact+1n);
  assert.equal(flopValue(),exact,"the following real edge resumes incrementing and samples old COUNT");
});

test("arbitrary LED dimensions and RGB buses retain mismatched and inactive wires", () => {
  const display = makeNode(4,"display",0,0,8);
  resizeDisplay(display,3,5); display.ledMode = "rgb";
  assert.equal(display.width,15); assert.deepEqual(inputDefs(display).map((p) => [p.label,p.width]),[["R",15],["G",15],["B",15]]);
  const sources = [1,2,3].map((id) => makeNode(id,"input",0,0,15));
  sources[0].inputValue = 0x4001n; sources[1].inputValue = 0x4002n; sources[2].inputValue = 4n;
  sources.forEach((source,pin) => link(source,display,pin));
  const wires = [...display.inputs];
  let runtime = compileCircuit(wasm,[...sources,display],[]); settle();
  const channels = () => runtime.handles.get(4).inputs.map((p) => busValue(readBus(wasm,p.bus)));
  assert.deepEqual(channels(),[0x4001n,0x4002n,4n]);
  resizeDisplay(display,4,4); runtime = compileCircuit(wasm,[...sources,display],[],runtime); settle();
  assert.equal(runtime.diagnostics.length,3); assert.deepEqual(channels(),[0n,0n,0n]);
  resizeDisplay(display,3,5); display.ledMode = "mono";
  ensureInputSlots(display); runtime = compileCircuit(wasm,[...sources,display],[],runtime); settle();
  assert.equal(runtime.diagnostics.length,2); assert.equal(channels()[0],0x4001n);
  display.ledMode = "rgb"; runtime = compileCircuit(wasm,[...sources,display],[],runtime); settle();
  assert.equal(runtime.diagnostics.length,0); assert.deepEqual(channels(),[0x4001n,0x4002n,4n]);
  display.inputs.forEach((c,pin) => assert.strictEqual(c,wires[pin]));
  assert.throws(() => resizeDisplay(display,9,8));
  assert.deepEqual([display.ledColumns,display.ledRows,display.width],[3,5,15]);
});

test("custom runtime exposes live instance children with resolved widths and preserved DFF state", () => {
  const input = makeNode(1,"input",20,30,8), clockPort = makeNode(2,"input",20,200);
  const flop = makeNode(3,"dff",330,70,8), output = makeNode(4,"output",660,70,8);
  input.label = "DATA"; clockPort.label = "CLK"; flop.label = "STORAGE"; output.label = "Q";
  link(input,flop); link(clockPort,flop,1); link(flop,output);
  const definition = createDefinition([input,clockPort,flop,output],"REGISTER",1);
  assert.deepEqual([definition.nodes[2].x,definition.nodes[2].y,definition.nodes[2].label],[330,70,"STORAGE"]);
  const lookup = id => id === 1 ? definition : null;
  const first = makeNode(10,"custom",0,0,1,1), second = makeNode(11,"custom",0,0,1,1);
  changeCustomWidth(first,definition.parameters[0].id,64,lookup);
  const data = makeNode(12,"input",0,0,64), clock = makeNode(13,"oscillator",0,0);
  data.inputValue = 0x8000000100000001n;
  link(data,first); link(clock,first,1);
  const nodes = [first,second,data,clock];
  let runtime = compileCircuit(wasm,nodes,[definition]); settle();
  const children = () => runtime.handles.get(10).children;
  assert.equal(children().get(1).outputs[0].length,64);
  assert.equal(children().get(2).outputs[0].length,1);
  assert.equal(runtime.handles.get(11).children.get(3).outputs[0].length,8);
  clock.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(13),1n); settle();
  const value = () => busValue(readBus(wasm,children().get(3).outputs[0]));
  assert.equal(value(),0x8000000100000001n);
  data.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(12),0n); settle();
  runtime = compileCircuit(wasm,nodes,[definition],runtime); settle();
  assert.equal(value(),0x8000000100000001n);
  assert.equal(busValue(readBus(wasm,runtime.handles.get(11).children.get(3).outputs[0])),0n);
});

test("manual counter values preserve exact u64 and held-high history through undo-style resurrection", () => {
  const oscillator = makeNode(1,"oscillator",0,0), counter = makeNode(2,"clock",200,0,64), out = makeNode(3,"output",500,0,64);
  link(oscillator,counter); link(counter,out);
  const cache = new Map();
  let runtime = compileCircuit(wasm,[oscillator,counter,out],[],null,cache); settle();
  oscillator.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle();
  const exact = 0x8000000100000001n;
  setRuntimeCounter(wasm,runtime.handles.get(2),exact); settle();
  const result = () => busValue(readBus(wasm,runtime.handles.get(2).outputs[0]));
  assert.equal(result(),exact);
  assert.equal(wasm.abc_state(runtime.handles.get(2).outputs[0][0]),3,"manual value keeps HIGH clock history");
  runtime = compileCircuit(wasm,[oscillator],[],runtime,cache); settle();
  runtime = compileCircuit(wasm,[oscillator,counter,out],[],runtime,cache); settle();
  assert.equal(result(),exact,"deleted counter resurrects without an extra rising edge");
  setRuntimeCounter(wasm,runtime.handles.get(2),0xffffffffffffffffn); settle();
  oscillator.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(1),0n); settle();
  oscillator.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle();
  assert.equal(result(),0n,"max u64 wraps on the next real rising edge");
});

test("project restoration with a HIGH oscillator preserves loaded counter and DFF history", () => {
  const oscillator = makeNode(1,"oscillator",0,0), counter = makeNode(2,"clock",240,0,64);
  const load = makeNode(3,"input",0,100), counterData = makeNode(4,"input",0,200,64);
  const dffData = makeNode(5,"input",0,320,64), flop = makeNode(6,"dff",240,320,64);
  link(oscillator,counter,0); link(load,counter,1); link(counterData,counter,2);
  link(oscillator,flop,1); link(dffData,flop);
  const nodes = [oscillator,counter,load,counterData,dffData,flop], exact = 0x8000000100000001n;
  load.inputValue = 1n; counterData.inputValue = exact; dffData.inputValue = exact;
  let runtime = compileCircuit(wasm,nodes,[]); settle();
  oscillator.inputValue = 1n; setRuntimeInput(wasm,runtime.handles.get(1),1n); settle();
  load.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(3),0n); settle();
  counterData.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(4),0n); settle();
  dffData.inputValue = 0n; setRuntimeInput(wasm,runtime.handles.get(5),0n); settle();
  assert.deepEqual([...runtime.stateKeys.keys()].filter((key) => key.startsWith("2/")),
    Array.from({length:64},(_,bit) => `2/count${bit}:counter`));
  const states = new Map([...runtime.stateKeys].map(([key,id])=>[key,wasm.abc_state(id)]));
  const loaded = deserializeProject(serializeProject(nodes,[],{states}),{nextDocumentId:20,nextDefinitionId:1});
  runtime = compileCircuit(wasm,loaded.nodes,loaded.definitions,null,loaded.states); settle();
  const value = (id) => busValue(readBus(wasm,runtime.handles.get(id).outputs[0]));
  assert.equal(value(20),1n);
  assert.equal(value(21),exact,"counter retains saved HIGH edge history");
  assert.equal(value(25),exact,"DFF does not sample current zero data during restore");
  setRuntimeInput(wasm,runtime.handles.get(20),0n); settle();
  setRuntimeInput(wasm,runtime.handles.get(20),1n); settle();
  assert.equal(value(21),exact+1n);
  assert.equal(value(25),0n);
});

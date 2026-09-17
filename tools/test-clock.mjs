import test from "node:test";
import assert from "node:assert/strict";
import { MIN_CLOCK_HZ, MAX_CLOCK_HZ, ClockScheduler, validClockHz, toggleClockLevel } from "../web-src/js/clock.js";
import { setRuntimeInput, busValue } from "../web-src/js/circuit.js";

const clock = (documentId, clockHz, extra = {}) => ({
  documentId,
  kind: "oscillator",
  clockHz,
  clockRunning: true,
  inputValue: 0n,
  ...extra,
});

test("clock frequency validation accepts the documented range only", () => {
  assert.equal(validClockHz(MIN_CLOCK_HZ), true);
  assert.equal(validClockHz(MAX_CLOCK_HZ), true);
  for (const value of [0, 0.099, 60.001, NaN, Infinity, "1"]) assert.equal(validClockHz(value), false);
});

test("manual Pulse toggles both LOW to HIGH and HIGH to LOW", () => {
  assert.equal(toggleClockLevel(0n), 1n);
  assert.equal(toggleClockLevel(1n), 0n);
  assert.equal(toggleClockLevel(toggleClockLevel(0n)), 0n);
  assert.throws(() => toggleClockLevel(2n), /0 or 1/);
});

test("multiple clocks return only the earliest chronological deadline group", () => {
  const scheduler = new ClockScheduler();
  const slow = clock(1, 1), fastA = clock(2, 2), fastB = clock(3, 2);
  scheduler.sync([slow, fastA, fastB], 0);

  assert.equal(scheduler.delay(249), 1);
  assert.deepEqual(scheduler.due(249), []);
  assert.deepEqual(scheduler.due(250), [fastA, fastB]);
  assert.equal(scheduler.delay(250), 250);
  assert.deepEqual(scheduler.due(500), [slow, fastA, fastB]);
  assert.equal(scheduler.delay(500), 250);
});

test("sync cleans paused and deleted clocks while preserving phase across rebuilt node references", () => {
  const scheduler = new ClockScheduler();
  const original = clock(7, 1);
  scheduler.sync([original], 100);

  const rebuilt = { ...original, inputValue: 1n };
  scheduler.sync([rebuilt], 300);
  assert.equal(scheduler.delay(300), 300, "same id and frequency keep the original deadline");
  assert.deepEqual(scheduler.due(600), [rebuilt], "due returns the current document object");
  assert.equal(rebuilt.inputValue, 1n, "the scheduler never toggles document state");

  rebuilt.clockRunning = false;
  scheduler.sync([rebuilt], 650);
  assert.equal(scheduler.size, 0);
  assert.equal(scheduler.delay(650), null);

  rebuilt.clockRunning = true;
  scheduler.sync([rebuilt], 1000);
  assert.equal(scheduler.delay(1000), 500, "resume starts a fresh half-period");
  scheduler.sync([], 1100);
  assert.equal(scheduler.delay(1100), null, "deleted clocks leave no deadline behind");
});

test("a late wake emits one edge without a skipped phase or catch-up backlog", () => {
  const scheduler = new ClockScheduler();
  const node = clock(1, 4);
  scheduler.sync([node], 0); // 125 ms half-period

  assert.deepEqual(scheduler.due(1000), [node]);
  assert.equal(scheduler.delay(1000), 125);
  assert.deepEqual(scheduler.due(1000), []);
  assert.deepEqual(scheduler.due(1125), [node]);
  assert.equal(node.inputValue, 0n);
});

test("frequency changes and reset rebase deadlines from the supplied time", () => {
  const scheduler = new ClockScheduler();
  const node = clock(1, 1);
  scheduler.sync([node], 0);
  assert.equal(scheduler.delay(100), 400);

  node.clockHz = 2;
  scheduler.sync([node], 100);
  assert.equal(scheduler.delay(100), 250);
  assert.deepEqual(scheduler.due(349), []);
  assert.deepEqual(scheduler.due(350), [node]);

  scheduler.reset(2000);
  assert.equal(scheduler.delay(2000), 250);
  assert.deepEqual(scheduler.due(2249), []);
  assert.deepEqual(scheduler.due(2250), [node]);
});

test("delta input updates preserve wide binary patterns and avoid unchanged writes", () => {
  const bits = Array(64).fill(false);
  let writes = 0, value = 0n;
  const wasm = { abc_set_input(id, bit) { bits[id] = Boolean(bit); writes += 1; return 0; } };
  const handle = { outputs: [Array.from({length:64},(_,i)=>i)] };
  for (let i = 1; i <= 4096; i += 1) {
    const next = BigInt(i);
    setRuntimeInput(wasm,handle,next,value); value = next;
    assert.equal(busValue(bits),BigInt(i));
  }
  assert.equal(writes,8191,"4096 successive input values change 8191 bits, not 4096 × 64");
});

export const MIN_CLOCK_HZ = 0.1;
export const MAX_CLOCK_HZ = 60;

export function validClockHz(value) {
  return Number.isFinite(value) && value >= MIN_CLOCK_HZ && value <= MAX_CLOCK_HZ;
}

export function toggleClockLevel(value) {
  value = BigInt(value);
  if (value !== 0n && value !== 1n) throw new RangeError("Clock level must be 0 or 1");
  return value ^ 1n;
}

function requireNow(now) {
  if (!Number.isFinite(now)) throw new TypeError("Clock time must be a finite number");
  return now;
}

function halfPeriodMs(hz) {
  return 500 / hz;
}

// This class only decides which document clocks are due. The application owns
// signal toggles, WASM propagation, and the timer used to call delay()/due().
export class ClockScheduler {
  #entries = new Map();

  get size() {
    return this.#entries.size;
  }

  sync(nodes, now) {
    requireNow(now);
    const live = new Map();
    for (const node of nodes) {
      if (node?.kind !== "oscillator" || node.clockRunning !== true || !validClockHz(node.clockHz)) continue;
      live.set(node.documentId, node);
    }

    for (const id of this.#entries.keys()) {
      if (!live.has(id)) this.#entries.delete(id);
    }

    for (const [id, node] of live) {
      const current = this.#entries.get(id);
      if (current && current.hz === node.clockHz) {
        // Rebuilds may replace document objects. Preserve phase while returning
        // the latest live node reference from due().
        current.node = node;
      } else {
        this.#entries.set(id, {
          node,
          hz: node.clockHz,
          deadline: now + halfPeriodMs(node.clockHz),
        });
      }
    }
    return this;
  }

  due(now) {
    requireNow(now);
    let earliest = Infinity;
    for (const entry of this.#entries.values()) earliest = Math.min(earliest, entry.deadline);
    if (earliest > now) return [];

    const result = [];
    for (const entry of this.#entries.values()) {
      if (entry.deadline !== earliest) continue;
      result.push(entry.node);
      // A late wake produces one edge, then schedules from the wake time. It
      // never emits a backlog or collapses several missed edges into one phase.
      entry.deadline = Math.max(now, entry.deadline) + halfPeriodMs(entry.hz);
    }
    return result;
  }

  delay(now) {
    requireNow(now);
    let earliest = Infinity;
    for (const entry of this.#entries.values()) earliest = Math.min(earliest, entry.deadline);
    return earliest === Infinity ? null : Math.max(0, earliest - now);
  }

  reset(now) {
    requireNow(now);
    for (const entry of this.#entries.values()) entry.deadline = now + halfPeriodMs(entry.hz);
    return this;
  }
}

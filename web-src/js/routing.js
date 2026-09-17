// World-space orthogonal routing. Each chip is an obstacle, including the two
// endpoint chips: only the short outward pin stubs may enter their clearance.
const GAP = 18;
const EPSILON = 0.001;
const distance = (a, b) => Math.abs(a.x - b.x) + Math.abs(a.y - b.y);

function layoutOrder(nodes, edges) {
  const byId = new Map(nodes.map((node) => [node.documentId, node]));
  const outgoing = new Map(nodes.map((node) => [node.documentId, []]));
  for (const [source, target] of edges) outgoing.get(source)?.push(target);

  let serial = 0;
  const stack = [], onStack = new Set(), index = new Map(), low = new Map(), components = [];
  const visit = (id) => {
    index.set(id, serial); low.set(id, serial); serial += 1;
    stack.push(id); onStack.add(id);
    for (const target of outgoing.get(id) ?? []) {
      if (!index.has(target)) { visit(target); low.set(id, Math.min(low.get(id), low.get(target))); }
      else if (onStack.has(target)) low.set(id, Math.min(low.get(id), index.get(target)));
    }
    if (low.get(id) !== index.get(id)) return;
    const members = [];
    while (stack.length) {
      const member = stack.pop(); onStack.delete(member); members.push(member);
      if (member === id) break;
    }
    components.push(members);
  };
  for (const node of nodes) if (!index.has(node.documentId)) visit(node.documentId);

  const componentOf = new Map();
  components.forEach((members, component) => members.forEach((id) => componentOf.set(id, component)));
  const componentEdges = components.map(() => new Set()), indegree = new Uint32Array(components.length);
  for (const [source, target] of edges) {
    const a = componentOf.get(source), b = componentOf.get(target);
    if (a === b || componentEdges[a].has(b)) continue;
    componentEdges[a].add(b); indegree[b] += 1;
  }

  // Registers/DFFs break data-flow cycles. Within an SCC, ignore their outgoing
  // feedback edge and topologically order the remaining combinational path.
  const orderMembers = (members) => {
    if (members.length <= 1) return members;
    const memberSet = new Set(members), localOut = new Map(members.map((id) => [id, []]));
    const localIn = new Map(members.map((id) => [id, 0]));
    for (const [source, target] of edges) {
      if (!memberSet.has(source) || !memberSet.has(target) || source === target) continue;
      const kind = byId.get(source)?.kind;
      if (kind === "dff" || kind === "register" || kind === "clock") continue;
      localOut.get(source).push(target); localIn.set(target, localIn.get(target) + 1);
    }
    const compare = (a, b) => (byId.get(a)?.x ?? 0) - (byId.get(b)?.x ?? 0)
      || (byId.get(a)?.y ?? 0) - (byId.get(b)?.y ?? 0) || a - b;
    const ready = members.filter((id) => localIn.get(id) === 0).sort(compare), result = [];
    while (ready.length) {
      const id = ready.shift(); result.push(id);
      for (const target of localOut.get(id)) {
        localIn.set(target, localIn.get(target) - 1);
        if (localIn.get(target) === 0) { ready.push(target); ready.sort(compare); }
      }
    }
    const remaining = members.filter((id) => !result.includes(id)).sort(compare);
    return [...result, ...remaining];
  };
  const orderedMembers = components.map(orderMembers);

  const layer = new Uint32Array(components.length);
  const queue = [];
  for (let component = 0; component < components.length; component += 1) if (indegree[component] === 0) queue.push(component);
  while (queue.length) {
    const component = queue.shift();
    const nextLayer = layer[component] + orderedMembers[component].length;
    for (const target of componentEdges[component]) {
      layer[target] = Math.max(layer[target], nextLayer);
      indegree[target] -= 1;
      if (indegree[target] === 0) queue.push(target);
    }
  }
  const result = new Map();
  orderedMembers.forEach((members, component) => members.forEach((id, offset) => result.set(id, layer[component] + offset)));
  return result;
}

export function autoLayout(nodes, sizes = new Map(), { columnGap = 140, rowGap = 70 } = {}) {
  if (!Array.isArray(nodes)) throw new TypeError("autoLayout nodes must be an array");
  if (nodes.length === 0) return new Map();
  const ids = new Set();
  for (const node of nodes) {
    if (!Number.isSafeInteger(node?.documentId) || ids.has(node.documentId)) throw new TypeError("autoLayout requires unique numeric node ids");
    ids.add(node.documentId);
  }
  const edges = [];
  for (const target of nodes) for (const wire of target.inputs ?? []) {
    if (wire && ids.has(wire.sourceId) && wire.sourceId !== target.documentId) edges.push([wire.sourceId, target.documentId]);
  }
  const layers = layoutOrder(nodes, edges);
  let maxLayer = Math.max(...layers.values());
  for (const node of nodes) if ((node.kind === "output" || node.kind === "display") && !(targetHasOutgoing(node.documentId, edges))) {
    layers.set(node.documentId, maxLayer + 1);
  }
  maxLayer = Math.max(...layers.values());

  const columns = Array.from({ length: maxLayer + 1 }, () => []);
  for (const node of nodes) columns[layers.get(node.documentId)].push(node);
  for (const column of columns) column.sort((a, b) => (a.y ?? 0) - (b.y ?? 0) || a.documentId - b.documentId);
  const size = (node) => sizes.get(node.documentId) ?? { width: node.kind === "display" ? 220 : 200, height: 150 };
  const columnWidths = columns.map((column) => Math.max(0, ...column.map((node) => size(node).width)));
  const originX = Math.min(...nodes.map((node) => Number.isFinite(node.x) ? node.x : 0));
  const originY = Math.min(...nodes.map((node) => Number.isFinite(node.y) ? node.y : 0));
  const xByLayer = [];
  let x = originX;
  for (let layer = 0; layer < columns.length; layer += 1) {
    xByLayer[layer] = x; x += columnWidths[layer] + columnGap;
  }
  const result = new Map();
  for (let layer = 0; layer < columns.length; layer += 1) {
    let y = originY;
    for (const node of columns[layer]) {
      result.set(node.documentId, { x: xByLayer[layer], y });
      y += size(node).height + rowGap;
    }
  }
  return result;
}

function targetHasOutgoing(sourceId, edges) {
  return edges.some(([source]) => source === sourceId);
}

function clearSegment(a, b, boxes) {
  if (a.x !== b.x && a.y !== b.y) return false;
  return !boxes.some((r) => a.x === b.x
    ? a.x > r.left + EPSILON && a.x < r.right - EPSILON && Math.max(a.y, b.y) > r.top + EPSILON && Math.min(a.y, b.y) < r.bottom - EPSILON
    : a.y > r.top + EPSILON && a.y < r.bottom - EPSILON && Math.max(a.x, b.x) > r.left + EPSILON && Math.min(a.x, b.x) < r.right - EPSILON);
}

function simplify(points) {
  const result = [];
  for (const p of points) {
    if (result.length && result.at(-1).x === p.x && result.at(-1).y === p.y) continue;
    while (result.length > 1) {
      const a = result.at(-2), b = result.at(-1);
      if ((a.x === b.x && b.x === p.x) || (a.y === b.y && b.y === p.y)) result.pop();
      else break;
    }
    result.push(p);
  }
  return result;
}

function draw(points) {
  const d = points.map((p, i) => `${i ? "L" : "M"} ${p.x} ${p.y}`).join(" ");
  const length = points.slice(1).reduce((sum, p, i) => sum + distance(points[i], p), 0);
  let left = length / 2;
  let midpoint = points[0];
  for (let i = 1; i < points.length; i += 1) {
    const a = points[i - 1], b = points[i], span = distance(a, b);
    if (left <= span) { midpoint = { x: a.x + (b.x - a.x) * left / span, y: a.y + (b.y - a.y) * left / span }; break; }
    left -= span;
  }
  return { d, points, midpoint };
}

// The fallback searches a rectilinear visibility grid. It is only needed when
// no straight/dogleg/perimeter route clears the obstacles. Coordinates come
// from rectangle boundaries, so the search does not depend on zoom or pixels.
function search(start, end, boxes) {
  const xs = [...new Set([start.x, end.x, ...boxes.flatMap((r) => [r.left, r.right])])].sort((a, b) => a - b);
  const ys = [...new Set([start.y, end.y, ...boxes.flatMap((r) => [r.top, r.bottom])])].sort((a, b) => a - b);
  const nx = xs.length, count = nx * ys.length;
  if (count > 160000) return null;
  const index = (p) => ys.indexOf(p.y) * nx + xs.indexOf(p.x);
  const from = index(start), to = index(end);
  const costs = new Float64Array(count); costs.fill(Infinity); costs[from] = 0;
  const previous = new Int32Array(count); previous.fill(-1);
  const closed = new Uint8Array(count), heap = [];
  const point = (id) => ({ x: xs[id % nx], y: ys[Math.floor(id / nx)] });
  const push = (id, score) => {
    let i = heap.length; heap.push({ id, score });
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (heap[parent].score <= score) break;
      heap[i] = heap[parent]; i = parent;
    }
    heap[i] = { id, score };
  };
  const pop = () => {
    const first = heap[0], last = heap.pop();
    if (heap.length) {
      let i = 0;
      while (i * 2 + 1 < heap.length) {
        let child = i * 2 + 1;
        if (child + 1 < heap.length && heap[child + 1].score < heap[child].score) child += 1;
        if (heap[child].score >= last.score) break;
        heap[i] = heap[child]; i = child;
      }
      heap[i] = last;
    }
    return first.id;
  };
  push(from, distance(start, end));
  while (heap.length) {
    const id = pop();
    if (closed[id]) continue;
    if (id === to) {
      const path = [];
      for (let at = to; at !== -1; at = previous[at]) path.push(point(at));
      return path.reverse();
    }
    closed[id] = 1;
    const x = id % nx, y = Math.floor(id / nx), a = point(id);
    const neighbors = [];
    if (x > 0) neighbors.push(id - 1);
    if (x + 1 < nx) neighbors.push(id + 1);
    if (y > 0) neighbors.push(id - nx);
    if (y + 1 < ys.length) neighbors.push(id + nx);
    for (const next of neighbors) {
      if (closed[next]) continue;
      const b = point(next), cost = costs[id] + distance(a, b);
      if (cost >= costs[next] || !clearSegment(a, b, boxes)) continue;
      costs[next] = cost; previous[next] = id; push(next, cost + distance(b, end));
    }
  }
  return null;
}

export function routeWire(a, b, obstacles, sourceId, targetId) {
  const source = obstacles.find((r) => r.id === sourceId), target = obstacles.find((r) => r.id === targetId);
  const sourceEdge = Math.max(a.x, source?.right ?? a.x);
  const targetEdge = Math.min(b.x, target?.left ?? b.x);
  const facingRoom = targetEdge - sourceEdge;
  // When two forward-facing chips are closer than two normal stubs, the old
  // stubs started inside the opposite expanded box. Search then failed and its
  // emergency route could cross the opposite chip body. Share the real gap as
  // a narrow channel while keeping normal clearance on every other side.
  const tightFacing = Boolean(source && target && sourceId !== targetId && facingRoom >= 0 && facingRoom < GAP * 2);
  const boxes = obstacles.map((r) => {
    const box = { left: r.left - GAP, right: r.right + GAP, top: r.top - GAP, bottom: r.bottom + GAP };
    if (tightFacing && r.id === sourceId) box.right = r.right;
    if (tightFacing && r.id === targetId) box.left = r.left;
    return box;
  });
  const channelX = sourceEdge + facingRoom / 2;
  const start = { x: tightFacing ? channelX : sourceEdge + GAP, y: a.y };
  const end = { x: tightFacing ? channelX : targetEdge - GAP, y: b.y };
  const candidates = [];
  const consider = (path) => {
    if (path.slice(1).every((p, i) => clearSegment(path[i], p, boxes))) {
      const clean = simplify(path);
      const length = clean.slice(1).reduce((sum, p, i) => sum + distance(clean[i], p), 0);
      candidates.push({ path: clean, score: length + clean.length * 10 });
    }
  };
  if (start.x === end.x || start.y === end.y) consider([start, end]);
  const xs = new Set([(start.x + end.x) / 2, start.x, end.x]);
  const ys = new Set([start.y, end.y]);
  for (const r of boxes) { xs.add(r.left); xs.add(r.right); ys.add(r.top); ys.add(r.bottom); }
  for (const x of xs) consider([start, { x, y: start.y }, { x, y: end.y }, end]);
  for (const y of ys) consider([start, { x: start.x, y }, { x: end.x, y }, end]);
  candidates.sort((a, b) => a.score - b.score);
  let path = candidates[0]?.path ?? search(start, end, boxes);
  // Overlapping chips can cover a pin itself. Keep a visible external loop
  // rather than the former cubic curve through the endpoint chip's center.
  if (!path) {
    const top = Math.min(start.y, end.y, ...boxes.map((r) => r.top)) - GAP;
    path = [start, { x: start.x, y: top }, { x: end.x, y: top }, end];
  }
  return draw(simplify([a, ...path, b]));
}

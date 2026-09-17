import test from "node:test";
import assert from "node:assert/strict";
import { autoLayout, routeWire } from "../web-src/js/routing.js";

function verifyRoute(a, b, boxes, source, target) {
  const route = routeWire(a, b, boxes, source, target);
  assert.deepEqual(route.points[0], a);
  assert.deepEqual(route.points.at(-1), b);
  assert.ok(!route.d.includes("NaN"));
  const commands = route.d.trim().split(/\s+/).filter((token) => /^[A-Za-z]$/.test(token));
  assert.equal(commands[0], "M");
  assert.ok(commands.slice(1).every((command) => command === "L"), `non-angular path: ${route.d}`);
  for (let i = 1; i < route.points.length; i += 1) {
    const p = route.points[i - 1], q = route.points[i];
    assert.ok(p.x === q.x || p.y === q.y);
    for (const r of boxes) {
      const crosses = p.x === q.x
        ? p.x > r.left && p.x < r.right && Math.max(p.y,q.y) > r.top && Math.min(p.y,q.y) < r.bottom
        : p.y > r.top && p.y < r.bottom && Math.max(p.x,q.x) > r.left && Math.min(p.x,q.x) < r.right;
      assert.equal(crosses, false, `segment ${i} crosses chip ${r.id}`);
    }
  }
  assert.ok(boxes.every((r) => !(route.midpoint.x > r.left && route.midpoint.x < r.right && route.midpoint.y > r.top && route.midpoint.y < r.bottom)));
  return route;
}

test("self-wires and backwards wires route around both endpoint chips", () => {
  const left = { id:1,left:0,right:200,top:0,bottom:180 }, right = { id:2,left:350,right:550,top:-20,bottom:230 };
  const loop = verifyRoute({x:200,y:110},{x:0,y:130},[left],1,1);
  assert.ok(loop.points.some((p) => p.y < 0 || p.y > 180));
  verifyRoute({x:550,y:110},{x:0,y:100},[left,right],2,1);
});

test("closely spaced forward chips share the available gap without crossed endpoint stubs", () => {
  const source = {id:1,left:0,right:200,top:0,bottom:160};
  const target = {id:2,left:210,right:410,top:0,bottom:160};
  const route = verifyRoute({x:200,y:40},{x:210,y:120},[source,target],1,2);
  assert.ok(route.points.slice(1, -1).every((p) => p.x === 205));
  assert.deepEqual(route.midpoint, {x:205,y:80});
});

test("obstructing chips and alternating barriers are avoided in world coordinates", () => {
  const boxes = [
    {id:1,left:0,right:180,top:0,bottom:160},
    {id:2,left:1100,right:1280,top:0,bottom:160},
    {id:3,left:260,right:400,top:-150,bottom:110},
    {id:4,left:480,right:630,top:50,bottom:350},
    {id:5,left:720,right:900,top:-180,bottom:120},
  ];
  verifyRoute({x:180,y:80},{x:1100,y:80},boxes,1,2);
  const offset = -50000;
  verifyRoute({x:180+offset,y:80+offset},{x:1100+offset,y:80+offset},
    boxes.map((r) => ({id:r.id,left:r.left+offset,right:r.right+offset,top:r.top+offset,bottom:r.bottom+offset})),1,2);
});

test("auto layout layers data flow left to right and stacks sinks without overlap", () => {
  const nodes = [
    { documentId: 1, kind: "input", x: 500, y: 400, inputs: [] },
    { documentId: 2, kind: "input", x: -200, y: 20, inputs: [] },
    { documentId: 3, kind: "and2", x: 50, y: 900, inputs: [{sourceId:1,sourcePort:0},{sourceId:2,sourcePort:0}] },
    { documentId: 4, kind: "output", x: -600, y: 0, inputs: [{sourceId:3,sourcePort:0}] },
    { documentId: 5, kind: "display", x: 0, y: -100, inputs: [{sourceId:3,sourcePort:0}] },
  ];
  const sizes = new Map(nodes.map((node) => [node.documentId, { width: node.kind === "display" ? 260 : 200, height: 140 }]));
  const layout = autoLayout(nodes, sizes);
  assert.equal(layout.size, nodes.length);
  assert.equal(layout.get(1).x, layout.get(2).x);
  assert.ok(layout.get(3).x > layout.get(1).x);
  assert.equal(layout.get(4).x, layout.get(5).x);
  assert.ok(layout.get(4).x > layout.get(3).x);
  assert.ok(Math.abs(layout.get(4).y - layout.get(5).y) >= 210);
});

test("auto layout breaks register feedback cycles into a readable pipeline", () => {
  const nodes = [
    { documentId: 1, kind: "input", x: 700, y: 300, inputs: [] },
    { documentId: 2, kind: "adder", x: 500, y: 100, inputs: [{sourceId:4,sourcePort:0},{sourceId:1,sourcePort:0},null] },
    { documentId: 3, kind: "mux", x: 300, y: 100, inputs: [null,{sourceId:2,sourcePort:0},{sourceId:1,sourcePort:0}] },
    { documentId: 4, kind: "dff", x: 100, y: 100, inputs: [{sourceId:3,sourcePort:0},null] },
    { documentId: 5, kind: "output", x: 0, y: 100, inputs: [{sourceId:4,sourcePort:0}] },
  ];
  const layout = autoLayout(nodes);
  assert.ok(layout.get(2).x < layout.get(3).x, "adder precedes mux inside the feedback SCC");
  assert.ok(layout.get(3).x < layout.get(4).x, "state element closes the feedback path on the right");
  assert.ok(layout.get(5).x > layout.get(4).x, "sink remains to the right of the register");
});

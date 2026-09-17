# a_basic_circuit

Hierarchical browser circuit editor and simulator backed by a compact WebAssembly circuit runtime. Ordinary logic is lowered to scalar signals; stateful components that would be pathological to gate-expand, such as wide counters and mapped RAM, use bounded native groups while still exposing ordinary bit-lane ports to the rest of the circuit.

The core deliberately models what the editor manipulates:

- every node has one output signal;
- an input pin points directly at its source node;
- fan-out is just several pins pointing at the same source;
- disconnected inputs read `false`, so partially edited circuits remain runnable;
- `input` and `output` are ordinary node kinds, so there is no separate interface/net layer;
- DFFs update on rising edges and all DFFs in one delta round sample the same old state.

`Circuit.zig` is the low-level runtime. Document meaning lives in Zig above it: `Semantics.zig` defines component shapes and ports, `CustomDefinition.zig` owns custom-chip width groups and constraints, `PrimitiveCompiler.zig` / `ComponentCompiler.zig` lower visual components, and `DocumentCompiler.zig` owns whole-document wiring, diagnostics, scalar-node budgets, and stable runtime-state slots. Ordinary combinational logic remains scalar. `Circuit.zig` additionally owns native grouped state for counters and sparse mapped RAM so a 64-bit address bus does not imply `2^64` gates or cells. The runtime rebuilds a compact fan-out cache only after an edit; steady-state propagation reuses preallocated queues.

The browser keeps the editable presentation descriptor—positions, labels, selection, wire colors, file/clipboard text, routing geometry, and wall-clock scheduling—but does not decide circuit semantics. `web-src/js/circuit.js` submits typed records to WASM and projects returned port/handle data for the UI. Visual components support every integer bus width from 1 to 64 (including 3, 32, and 64 bits). An 8-bit AND therefore becomes eight scalar AND primitives at runtime, while DFF data/Q follow the selected width and CLK remains one bit. Custom instances are resolved with the Zig width solver and compiled by the Zig document compiler.

## Build

```sh
zig build -Doptimize=ReleaseFast
zig build test
zig build test-web
zig build wasm -Doptimize=ReleaseFast
zig build publish
zig build serve
```

`zig build publish` builds a ReleaseFast WASM module and writes a ready-to-serve static site to:

```text
zig-out/web/
├── index.html
├── css/style.css
├── js/app.js
├── js/circuit.js
├── js/clipboard.js
├── js/clock.js
├── js/routing.js
├── js/history.js
├── js/project.js
├── js/symbols.js
└── wasm/a_basic_circuit.wasm
```

`zig build serve` publishes first, starts the bundled Python stdlib server on an available loopback port, opens the browser, and stays in the foreground. Press Ctrl-D to stop it.

```sh
zig build serve
```

The browser editor owns presentation fields such as node positions and colors; the Zig document compiler owns connection validity and runtime topology. The WASM artifact itself also remains available under `zig-out/bin/` through the normal `wasm`/install steps. The bridge uses numeric ids and typed scalar arguments rather than a JSON compiler payload. Bus **values** use JavaScript `BigInt` so bits 32–63 remain exact; handles stay ordinary numbers. The low-level scalar API remains available for focused tests and embedding:

```text
abc_reset()
abc_add_node(kind) -> node_id or 0xffffffff
abc_add_counter(width) -> first of width contiguous output ids, or 0xffffffff
abc_remove_node(node_id) -> bool
abc_connect(source, target, pin) -> status
abc_disconnect(target, pin) -> bool
abc_set_input(node_id, bool) -> status
abc_set_counter(node_id, low_u32, high_u32) -> status
abc_ram_configure(node_id, base_low, base_high, end_low, end_high) -> status
abc_ram_read_low/high(node_id, address_low, address_high) -> u32 half
abc_ram_write(node_id, address_low, address_high, word_low, word_high) -> status
abc_ram_snapshot(node_id) -> sparse non-zero cell count or 0xffffffff
abc_ram_snapshot_address_low/high(index) -> u32 half
abc_ram_snapshot_word_low/high(index) -> u32 half
abc_run(max_rounds) -> 1 settled, 0 pending, 2 failure
abc_value(node_id) -> 0 false, 1 true, 2 invalid
abc_state(node_id) -> packed state 0..3, 4 invalid
abc_restore_state(node_id, packed) -> 0 restored, 1 invalid node, 2 invalid state
```

The editor normally uses the higher-level `abc_sem_*`, `abc_def_*`, `abc_width_*`, and `abc_doc_*` families. Those APIs project ports, validate custom definitions, solve width constraints, submit the current document, compile it, and return diagnostics, state slots, and input/output buses. JavaScript does not expand MUX/DEMUX/Adder/Split/Join gates or construct DFF/counter pin fan-out itself.

Node kinds are `0 input`, `1 output`, `2 not`, `3 and`, `4 or`, `5 xor`, `6 dff`, `7 buffer`, `8 nand`, `9 nor`, `10 xnor`, and `11 counter`. Use `abc_add_counter(width)` for a wide counter. Connecting pin 0 or 1 on any of its output ids sets the shared CLK or LOAD input, respectively. Pin 2 connects the DATA bit for that specific output lane. Disconnect uses the same mapping; existing CLK connections and checkpoint keys are unchanged.

## Buses and chips

Each component has editable width fields; type a width and press Enter. Inputs accept unsigned decimal, `0x` hexadecimal, `0b` binary, or `0o` octal values, as well as individual LED bit toggles. The entered base stays selected through edits and copy/paste; 64-bit values remain exact in every base. The leftmost LED is the most significant bit. A smaller Input width truncates its stored value to the new width. Values entered explicitly must fit the current width.

| Component | Data and control ports |
| --- | --- |
| Logic gates, Input, Output, LED | 1–64 data bits |
| Oscillator | One timed output bit, 0.1–60 Hz; Start / Pause or one manual Pulse edge |
| Clock counter | CLK and LOAD are 1 bit; DATA and COUNT are 1–64 bits; rising edge loads DATA when LOAD=1, otherwise increments modulo 2^width |
| LED | One palette component with editable X × Y geometry; single-color mode uses one bus, RGB mode uses three R/G/B buses |
| DFF | 1–64 data/Q bits; CLK is always 1 bit |
| Register | 1–64 DATA/Q bits; LOAD and CLK are 1 bit; rising edge stores DATA only when LOAD=1 |
| MUX | 1–64 data bits; independent 1–6 address bits; 2–64 data inputs |
| DEMUX | 1–64 data bits; independent 1–6 address bits; 2–64 data outputs |
| Decoder | 1–6 address bits; one bus of 2–64 one-hot output bits |
| Adder | 1–64 A/B/SUM bits; CIN and COUT are 1 bit; unsigned addition |
| ALU | 1–64 A/B/Y bits; OP is fixed 2 bits: `00 ADD`, `01 AND`, `10 OR`, `11 XOR`; COUT is 1 bit |
| RAM | 1–64-bit words, independent 1–64-bit ADDR, explicit mapped start/end range, WE/CLK are 1 bit; sparse native storage, asynchronous read, rising-edge write |
| Split / Join | 2–64 total bits, configurable LOW width; HIGH is the remaining width |

For example, set a MUX's **Data** to `8` and **Address** to `4` for sixteen 8-bit inputs. `SEL` is pin zero, followed by `D0` through `D15`; address zero selects `D0`. MUX, DEMUX, and Decoder selectors intentionally remain limited to 1–6 address bits because their lane count grows exponentially. RAM is different: its address bus may be 1–64 bits because it is not expanded into one register bank per possible address. Split and Join place LOW at the least significant end. They provide explicit bus adaptation instead of silently extending or truncating connected wires. `ComponentCompiler.zig` lowers the bounded composite components to scalar gates, while `PrimitiveCompiler.zig` routes RAM to the native sparse runtime; `web-src/js/circuit.js` only submits typed document records and reads returned handles.

### Mapped RAM

RAM separates the **address-bus width** from the **mapped address window**. A CPU can therefore expose a 32- or 64-bit address bus while one RAM chip owns only a small region such as `0x00001000..0x000010FF`, `0x10000000..0x1000FFFF`, or `0xFFFF0000..0xFFFFFFFF`. Range endpoints must fit the selected address width and are stored losslessly as 64-bit values. JavaScript uses `BigInt`; project, clipboard, and chip-module JSON serializes addresses and words as decimal strings so values above `2^53` remain exact.

The RAM card exposes **Data**, **Address**, **Range start**, and **Range end** controls plus a paged memory editor. Only eight rows are materialized at a time regardless of the mapped range size. Use the page-address field or the previous/next buttons to move through the map. Cell values accept the same unsigned decimal, `0x`, `0b`, and `0o` syntax as Input values and must fit the current data width. A manual cell edit updates the native RAM immediately and is an ordinary undoable document edit.

Native RAM storage is sparse: zero/unwritten cells consume no per-address entry, and changing a huge address bus does not allocate its theoretical address space. Reads are asynchronous. With **WE=1**, a rising **CLK** writes DATA at the currently addressed mapped cell; falling edges, a held-HIGH clock, and WE=0 do not write. An address outside the mapped window reads zero and simulated writes to it are ignored. Direct editor writes outside the mapped window are rejected. Rebuilding the document while CLK is already HIGH preserves the remembered clock level so it cannot synthesize a phantom write.

The descriptor's sparse RAM image travels through Ctrl+C/Ctrl+V and chip-module export/import. Each custom-chip instance gets independent native RAM state even when several instances share one definition. Project Save snapshots the current sparse runtime contents as well as the mapped descriptor image, so WE-driven writes survive Save/Open without turning every simulator write into an Undo history entry.

Changing a width **never removes a wire**. A mismatched wire is red, carries no signal, and appears in the warning panel. Matching the widths reconnects it automatically. Red means disconnected at that input, so ordinary gate truth tables still apply (for example, an unconnected NOT input produces one). Reducing MUX/DEMUX address width also retains connections to inactive pins, exposes them for deletion, and restores them if widened again.

Select components and use **Make chip**. Explicit Input and Output nodes are optional: incoming nets that cross the selection boundary become input ports, outgoing nets become output ports, and—when no explicit interface nodes are present—open input pins and terminal outputs are exposed automatically. Repeated uses of the same outside net are grouped into one interface input. The selected graph is replaced in place by one custom-chip instance, and its outside wires—including explicit wire colors—are rebound through the inferred interface. Explicit Input/Output nodes remain supported for cases where you want exact interface placement and naming before saving. A custom instance exposes width parameters for connected groups of interface ports. Data ports resize together; independent data/address groups remain separate, and controls wired to CLK/CIN/COUT remain one bit. Split/join and decoder width relationships are derived and validated; an impossible width change is rejected without mutating the instance.

Custom templates retain their interface **port count** when their widths change. Increasing an internal MUX's address width creates additional unconnected data slots, which read zero. Decreasing it preserves any now-inactive internal connections as warnings. Custom RAM keeps its address-width and data-width groups independent, preserves its mapped window and sparse image, and may expose a 64-bit address bus without relaxing the 1–6-bit selector limit on MUX/DEMUX/Decoder. Custom chips may contain other custom chips recursively, as well as primitives such as clock counters and RAM. Oscillator sources and LED displays remain root-level components; connect an external Oscillator through an Input interface port. Definition dependencies must remain acyclic: direct or indirect recursion such as `A → B → C → A` is rejected. When a nested hierarchy is compiled, the browser projects the hierarchy into typed child records while Zig remains authoritative for primitive port semantics, width solving, connection diagnostics, scalar lowering and runtime state. Save/Open and Ctrl+C/Ctrl+V retain the transitive definition dependency graph, nested width parameters, layouts and wire colors.

## Clocks and LED matrices

**Oscillator** and **Clock counter** separate time from circuit state. The Oscillator is a one-bit square-wave source with a 0.1–60 Hz setting. Start runs it, Pause holds its level, and Pulse advances exactly one manual edge: LOW→HIGH or HIGH→LOW. Press Pulse twice for a full cycle. Each edge waits for propagation before another manual edge can be sent. One oscillator can drive many counters and DFFs.

Connect an oscillator, an Input, or any other one-bit circuit output to a Clock counter's **CLK** pin. With **LOAD** LOW or unconnected, the counter increments once on each rising edge and wraps `0, 1, …, 2^width − 1, 0`. Its data width is any integer from 1 to 64. Holding CLK HIGH or sending a falling edge does not change it. Counter state and clock history live in the native engine; a wide counter has one count state with scalar output lanes, not a separate timer or assembled gate circuit per bit. Counters can be embedded in custom chips and their live values are projected into the active chip scope when that scope corresponds to a root instance path.

To set the count from another chip, connect its output bus to **DATA** and a one-bit control signal to **LOAD**. On a rising CLK edge, LOAD=1 stores DATA **instead of incrementing**; LOAD=0 resumes normal counting. For example, an 8-bit DATA value of 42 with LOAD=1 sets COUNT to 42 on the next rising edge. After LOAD returns to 0, the following rising edge produces 43. Changing DATA or LOAD alone does not change COUNT, and keeping LOAD HIGH reloads DATA on every rising edge. With LOAD HIGH, an unconnected or width-mismatched DATA bus loads zero under the editor's normal disconnected-input rule. Mismatched wires are retained in red and reconnect when widths match. Within a custom chip, DATA and COUNT share a width parameter while CLK and LOAD remain one bit. All sequential components sample the previous round's outputs on a shared edge.

The counter's value field accepts decimal, `0x` hex, `0b` binary, or `0o` octal. Enter applies a new current value without changing the remembered CLK level. The next real rising edge increments that value. Manual value changes are undoable, while automatically counted edges are simulation state rather than editor history.

Each oscillator update waits until the previous circuit propagation settles. The requested Hz is a wall-clock target, not a real-time guarantee: an expensive circuit slows the effective oscillator. Hidden tabs suspend timing and do not replay a backlog when visible again. The scheduler uses one entry per oscillator; counters receive ordinary native circuit events. DFF CLK and counter CLK both require one bit; use an Oscillator directly or split a wider bus explicitly.

LED displays have **X** columns and **Y** rows. Their product is the input bus width and must be 1–64 pixels, so 3×5, 1×64, and 8×8 are all valid. The card grows to fit the chosen columns. The top-left pixel is the highest bit, then bits descend left-to-right and top-to-bottom. Resizing keeps all wires, with the usual red warning until source widths match.

The palette exposes just one **LED** component. Its own card selects X × Y geometry, single-color versus RGB mode, and the single-color preset/custom color, so separate Red/Green/Blue/RGB/size palette variants are unnecessary. In RGB mode the three buses are **R**, **G**, and **B** with the same X × Y width. Corresponding bits light one pixel together: R+G is yellow, R+B is magenta, G+B is cyan, and all three are white. Each channel is on/off, yielding eight combinations including off; this is not an 8-bit-per-channel intensity display. Switching RGB to single color preserves the G/B wires as inactive connections, and switching back restores them.

## Editor controls

The canvas pans in either direction without fixed edges. Use the wheel to pan, Shift + wheel for horizontal movement, Ctrl + wheel to zoom around the pointer, or middle drag / Space + drag to pan. **Fit**, `F`, or Home frames the circuit. **Arrange** automatically lays out the current Root/custom scope from left to right using its connection graph, stacks parallel chips without overlap, and treats DFF/Register/counter state as feedback boundaries so CPU-style loops remain readable. Arrange is one normal undoable position edit. Palette drops, wire positions, box selection and group dragging all use the same transformed world coordinates. Dragging near the canvas edge pans it automatically.

Connect pins by dragging in either direction. Click a wire's wide hit area, then press Delete/Backspace or use the Delete button / × handle. Double-click or right-click a wire to remove it directly. Drag a connected input into empty canvas to unplug it, or to another input to rewire it. Escape, pointer cancellation and window focus loss cancel an in-progress drag without removing the original wire. Numeric/text editing does not trigger canvas deletion shortcuts.

Wires use horizontal and vertical segments with 90-degree corners, routing around component bounds. Self-feedback wires loop outside their own chip. Labels and wire-delete handles follow the routed path. Overlapping chips are separate stacking units: clicking a chip or focusing one of its controls raises its body and all its pins together. **Alt+click** cycles through chips under the pointer, including completely covered ones. Moving overlapping chips apart exposes any physically covered port.

Wires and chips share the same transformed stacking context. Focusing a chip brings its incident wires just below its own body/pins and above background chips; selecting a wire raises it for inspection. Select a wire and use **Wire** in the toolbar to choose any color, or **Auto** for normal signal colors. Custom-colored wires dim when LOW and brighten when HIGH. Invalid connections remain red regardless of their saved color, which returns when the connection becomes valid. Wire colors survive copy/paste and rerouting.

Custom-chip editing uses the **same canvas recursively** instead of a second editor. Double-click a custom instance to enter its scope: only that definition's nodes are shown and the breadcrumb becomes, for example, `Root / CPU / ALU`. Use the breadcrumb, the back control, **Esc**, or **Alt+↑** to return to a parent scope. Each scope remembers its own pan/zoom position. Interface Input/Output nodes stay in the semantic definition for compatibility and wiring, but are rendered as compact left/right rails rather than full-size I/O cards. Inside a scope you can add/delete components, move and rename them, change widths, disconnect/reconnect wires, and nest another custom chip. Actual internal signal values are shown when the breadcrumb follows a live root instance path; a standalone unused definition has no live root signal to project.

Use **+ New** to create a chip from scratch and enter a standalone `Root / NAME` scope with starter IN/OUT rails. A shared definition is edited once and used by every instance, so scoped edits participate in the normal document Undo/Redo and project Save/Open flow. Width edits still use the Zig width-group solver, and invalid structural/width edits are rejected without corrupting the saved definition. Alt+double-click a custom instance title renames that instance label instead of entering the scope.

Custom chips can also move between projects as small **modules** without moving the root circuit. Mark any number of palette chips with **Pack**, then press **Export** and give the module a name. For example, packing `cpu.x86` and `cpu.rv32I` as module `cpu` downloads `cpu.abc-chips.json`; both public chips are listed as module exports, while any shared nested ALU/decoder/helper definitions are embedded once as dependencies. **Import** beside `+ New` loads that module into the palette without creating root nodes or changing the current canvas. Definition ids are remapped safely, cyclic/malformed modules are rejected, and structurally equivalent chips/dependencies already in the palette are reused instead of duplicated. The older single-chip package form remains importable for compatibility, but new exports use the multi-chip module format.

Primitive bodies use conventional schematic shapes where they are well established. AND/OR/XOR and their inverted forms use gate outlines and inversion bubbles, NOT/Buffer use triangles, and MUX/DEMUX use directional trapezoids. DFF, decoder, counter and arithmetic/routing blocks keep compact block-style symbols. The same renderer is used at Root and in every recursive custom-chip scope.

**Ctrl+C / Ctrl+V** copies and pastes selected chips with their internal wires and colors, labels, widths, input values, LED settings, and the complete transitive set of custom definitions they depend on. Nested definition references and width parameters are remapped to fresh ids on paste, while equivalent dependency graphs reuse existing palette definitions. Connections from outside the selection are left disconnected. Each paste gets fresh document ids; repeated pastes offset near the pointer and select the new group. Pasted oscillators start paused and LOW; new counters and DFFs start with fresh runtime state. Native copy/paste remains available inside text and numeric fields. The toolbar buttons also use the system clipboard where permitted, with an in-tab fallback when clipboard permission is unavailable.

Box-select empty canvas, Shift-click nodes to toggle selection, or Ctrl+A to select all. Drag selected chips as a group and drop on the trash to delete. Escape restores original chip positions during a drag. LED outputs and labels update without recreating component controls each simulation frame. Topology edits also retain width/value editor elements, preserving focus when moving between fields and keeping unfinished input text during other edits. Starting a chip or wire drag commits the current editor before transferring focus to the canvas.

Topology rebuilds preserve existing scalar outputs, DFF state, counter values, and their clock history using the checkpoint API. Restoring combinational clock-path values as well prevents an unrelated editor change from generating a false clock edge. New bits/nodes start at zero; actual changes to clock wiring still follow the simulator's ordinary delta-round behavior. Input toggles wait for propagation to settle so successive clock changes are not collapsed into a single frame.

## Undo and project files

**Ctrl+Z** undoes a document edit; **Ctrl+Shift+Z** redoes it. Creating, deleting, moving, pasting, wiring, changing widths, colors, LED settings, input values, oscillator frequency, component names, and adding a custom definition are recorded as edits. One paste is one undo regardless of its number of components. Continuous color-picker changes are coalesced. Text fields retain native text undo while focused; click the canvas or use the toolbar for circuit undo. Selection, panning, automatic oscillator ticks, and ordinary counter increments do not create history entries.

History retains up to 100 edit frames with an estimated 16 MiB descriptor budget, always keeping at least the newest undo. Changed-node deltas share unchanged descriptors. Restoring a deleted counter/DFF can recover its retained runtime state; undoing a position or color edit does not rewind unrelated running counters. A fresh edit after Undo discards the redo branch. History belongs to the current page session and is not part of a project file.

**Ctrl+S / Save** downloads `circuit.abc.json`. **Ctrl+O / Open** reads a saved project, including all palette definitions (even unused ones), nested definition dependencies, component/internal layouts, wires and colors, bus parameters, LED dimensions and mode, exact input values and bases, oscillator frequency/phase, counter values, DFF state, RAM mappings/images, and the current sparse runtime RAM contents. Runtime state keys for nested sequential components and RAM are based on their structural path rather than palette definition ids, so definition-id remapping during load does not alias or discard unrelated instance state. Opened oscillators are paused at their saved level so the document can be inspected before resuming. Loading a project is one undoable edit. Invalid files—including malformed/cyclic nested definition graphs—are checked before replacing the current document; the editor accepts project files up to 32 MiB and validates their scalar-node expansion and runtime state keys. There is no automatic browser persistence: save before reloading the page.

## Verification

`zig build test` runs the native core tests. `zig build test-web` publishes the site, then uses Node.js 22+ and its built-in test runner against the **actual generated WASM** and the pure document helpers. Test files run sequentially. No npm packages are required. The suite covers every width 1–64, exact high bits and all four input bases, routing lanes and automatic layout, arithmetic carry, Register load-enable behavior, all four ALU operations, mapped sparse RAM with 64-bit addresses/words above `2^53`, first/last/outside-window behavior, held-HIGH rebuilds, direct cell editing, project/clipboard/module persistence, isolated custom RAM instances, split/join ordering, wire preservation, custom width constraints, DFF/counter state and manual values, oscillator scheduling and both directions of the manual Pulse edge, RGB buses and matrix resizing, nested custom 64-bit propagation, recursive-cycle rejection, state isolation/stability across nested instances, transitive clipboard/project definition roundtrips, multi-export chip modules with deduplicated shared dependencies, invalid payloads, edit history, runtime-only state, and orthogonal obstacle/self-loop routing. The editor limits one compiled document to 250,000 scalar nodes to bound accidental gate expansion. MUX/DEMUX/Decoder remain bounded by their 1–6-bit selector limit; RAM scalar cost is proportional to its data width while sparse cell storage grows only with non-zero written cells.

`abc_run` limits synchronous **delta rounds**, not wall-clock time or gate evaluations. A zero result means propagation remains; it does not claim the circuit is unstable. The caller may resume with another call. A single very wide round can still do substantial work, so a strict per-frame CPU budget would need a separate gate-work budget later. A combinational oscillator will simply keep returning pending while it oscillates.

Values read while `abc_run` is pending are intermediate delta-round state. A UI that only wants stable values should render simulation outputs after `abc_run` returns `1`.

Inputs are level state, not a queued event stream. Clocked simulation should call `abc_run` between clock transitions; multiple clock flips collapsed before the DFF is evaluated are observed as the final level transition rather than as every historical edge.

Node ids are session handles. `abc_reset` invalidates all of them, so the browser side must discard queued events or callbacks that still contain ids from the previous circuit. Deleted slots are intentionally not reused before reset; this keeps stale handles harmless without a generational handle table. A very long edit session with extreme create/delete churn can compact by rebuilding the document after `abc_reset`.

const std = @import("std");
const Circuit = @import("Circuit.zig");
const Semantics = @import("Semantics.zig");
const CustomDefinition = @import("CustomDefinition.zig");
const DocumentCompiler = @import("DocumentCompiler.zig");

const invalid_id = std.math.maxInt(u32);

var global_circuit: ?Circuit = null;
var width_groups: std.ArrayListUnmanaged(Semantics.WidthGroup) = .empty;
var width_relations: std.ArrayListUnmanaged(Semantics.Relation) = .empty;
var width_result: std.ArrayListUnmanaged(u8) = .empty;
var definition_builder: ?CustomDefinition.Builder = null;
var document_builder: ?DocumentCompiler.Builder = null;

fn circuit() *Circuit {
    if (global_circuit == null) {
        global_circuit = Circuit.init(std.heap.wasm_allocator);
    }
    return &global_circuit.?;
}

fn definitionBuilder() *CustomDefinition.Builder {
    if (definition_builder == null) definition_builder = CustomDefinition.Builder.init(std.heap.wasm_allocator);
    return &definition_builder.?;
}

fn documentBuilder() *DocumentCompiler.Builder {
    if (document_builder == null) document_builder = DocumentCompiler.Builder.init(std.heap.wasm_allocator);
    return &document_builder.?;
}

fn resetCircuit() *Circuit {
    if (global_circuit) |*value| value.deinit();
    global_circuit = Circuit.init(std.heap.wasm_allocator);
    return &global_circuit.?;
}

fn nodeId(raw: u32) Circuit.NodeId {
    return @enumFromInt(raw);
}

fn kind(raw: u32) ?Circuit.Kind {
    return switch (raw) {
        0 => .input,
        1 => .output,
        2 => .not,
        3 => .and2,
        4 => .or2,
        5 => .xor2,
        6 => .dff,
        7 => .buffer,
        8 => .nand2,
        9 => .nor2,
        10 => .xnor2,
        11 => .counter,
        else => null,
    };
}

/// Discards the current graph and invalidates every previously returned node id.
export fn abc_reset() void {
    if (global_circuit) |*value| value.deinit();
    global_circuit = null;
}

fn semanticKind(raw: u32) ?Semantics.Kind {
    return Semantics.kind(raw);
}

export fn abc_sem_valid_shape(kind_raw: u32, width: u32, address_width: u32, split_width: u32) u32 {
    const k = semanticKind(kind_raw) orelse return 0;
    return @intFromBool(Semantics.validShape(k, width, address_width, split_width));
}

export fn abc_sem_input_count(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32) u32 {
    _ = width;
    _ = split_width;
    const k = semanticKind(kind_raw) orelse return invalid_id;
    if (address_width == 0 or address_width > Semantics.max_address_width) return invalid_id;
    return Semantics.inputCount(k, @intCast(address_width), rgb != 0);
}

export fn abc_sem_output_count(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32) u32 {
    _ = width;
    _ = split_width;
    _ = rgb;
    const k = semanticKind(kind_raw) orelse return invalid_id;
    if (address_width == 0 or address_width > Semantics.max_address_width) return invalid_id;
    return Semantics.outputCount(k, @intCast(address_width));
}

export fn abc_sem_input_width(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32, pin: u32) u32 {
    const k = semanticKind(kind_raw) orelse return 0;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width) return 0;
    if ((k == .split or k == .join) and (split_width == 0 or split_width >= width)) return 0;
    return (Semantics.inputPort(k, @intCast(width), @intCast(address_width), @intCast(split_width), rgb != 0, pin) orelse return 0).width;
}

export fn abc_sem_output_width(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32, pin: u32) u32 {
    _ = rgb;
    const k = semanticKind(kind_raw) orelse return 0;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width) return 0;
    if ((k == .split or k == .join) and (split_width == 0 or split_width >= width)) return 0;
    return (Semantics.outputPort(k, @intCast(width), @intCast(address_width), @intCast(split_width), pin) orelse return 0).width;
}

export fn abc_sem_input_field(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32, pin: u32) u32 {
    const k = semanticKind(kind_raw) orelse return 0;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width) return 0;
    if ((k == .split or k == .join) and (split_width == 0 or split_width >= width)) return 0;
    return @intFromEnum((Semantics.inputPort(k, @intCast(width), @intCast(address_width), @intCast(split_width), rgb != 0, pin) orelse return 0).field);
}

export fn abc_sem_output_field(kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32, pin: u32) u32 {
    _ = rgb;
    const k = semanticKind(kind_raw) orelse return 0;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width) return 0;
    if ((k == .split or k == .join) and (split_width == 0 or split_width >= width)) return 0;
    return @intFromEnum((Semantics.outputPort(k, @intCast(width), @intCast(address_width), @intCast(split_width), pin) orelse return 0).field);
}

/// Status: 0 compatible, 1 missing source, 2 inactive output, 3 inactive input, 4 width mismatch.
export fn abc_sem_connection_status(source_present: u32, source_active: u32, source_width: u32, target_active: u32, target_width: u32) u32 {
    const source: ?Semantics.Port = if (source_active != 0 and source_width > 0 and source_width <= Semantics.max_width)
        .{ .width = @intCast(source_width), .field = .width }
    else
        null;
    const target: ?Semantics.Port = if (target_active != 0 and target_width > 0 and target_width <= Semantics.max_width)
        .{ .width = @intCast(target_width), .field = .width }
    else
        null;
    return @intFromEnum(Semantics.connectionStatus(source_present != 0, source, target));
}

export fn abc_width_reset() void {
    width_groups.clearRetainingCapacity();
    width_relations.clearRetainingCapacity();
    width_result.clearRetainingCapacity();
}

export fn abc_width_add_group(min: u32, max: u32, preferred: u32, dependent: u32, override_value: u32) u32 {
    if (min == 0 or max > Semantics.max_width or min > max or preferred < min or preferred > max or override_value > Semantics.max_width) return invalid_id;
    const index: u32 = @intCast(width_groups.items.len);
    width_groups.append(std.heap.wasm_allocator, .{
        .min = @intCast(min),
        .max = @intCast(max),
        .preferred = @intCast(preferred),
        .dependent = dependent != 0,
        .override = @intCast(override_value),
    }) catch return invalid_id;
    return index;
}

export fn abc_width_add_sum(total: u32, low: u32, high: u32) u32 {
    if (total >= width_groups.items.len or low >= width_groups.items.len or high >= width_groups.items.len or total > std.math.maxInt(u16) or low > std.math.maxInt(u16) or high > std.math.maxInt(u16)) return 1;
    width_relations.append(std.heap.wasm_allocator, .{ .sum = .{ .total = @intCast(total), .low = @intCast(low), .high = @intCast(high) } }) catch return 2;
    return 0;
}

export fn abc_width_add_pow(address: u32, out: u32) u32 {
    if (address >= width_groups.items.len or out >= width_groups.items.len or address > std.math.maxInt(u16) or out > std.math.maxInt(u16)) return 1;
    width_relations.append(std.heap.wasm_allocator, .{ .pow = .{ .address = @intCast(address), .out = @intCast(out) } }) catch return 2;
    return 0;
}

export fn abc_width_solve() u32 {
    width_result.resize(std.heap.wasm_allocator, width_groups.items.len) catch return 2;
    const solved = Semantics.solveWidths(std.heap.wasm_allocator, width_groups.items, width_relations.items, width_result.items) catch return 2;
    return if (solved) 0 else 1;
}

export fn abc_width_value(index: u32) u32 {
    if (index >= width_result.items.len) return 0;
    return width_result.items[index];
}

export fn abc_def_reset() void {
    definitionBuilder().reset();
}

export fn abc_def_add_node(kind_raw: u32, width: u32, address_width: u32, split_width: u32) u32 {
    const k = semanticKind(kind_raw) orelse return invalid_id;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width or split_width > Semantics.max_width) return invalid_id;
    return definitionBuilder().addNode(.{
        .kind = k,
        .width = @intCast(width),
        .address_width = @intCast(address_width),
        .split_width = @intCast(split_width),
    }) catch invalid_id;
}

/// Status: 0 ok, 1 invalid endpoint, 2 allocation failure.
export fn abc_def_add_wire(target: u32, pin: u32, source: u32, source_port: u32) u32 {
    definitionBuilder().addWire(.{
        .target = target,
        .pin = pin,
        .source = source,
        .source_port = source_port,
    }) catch |err| return switch (err) {
        error.InvalidWire => 1,
        else => 2,
    };
    return 0;
}

/// Status: 0 ok, 1 invalid shape/wire, 2 width mismatch, 3 inconsistent widths, 4 allocation failure.
export fn abc_def_compile() u32 {
    definitionBuilder().compile() catch |err| return switch (err) {
        error.InvalidNode, error.InvalidShape, error.InvalidWire => 1,
        error.WidthMismatch => 2,
        error.InconsistentWidths => 3,
        error.OutOfMemory => 4,
    };
    return 0;
}

export fn abc_def_group_count() u32 {
    return @intCast(definitionBuilder().groups.items.len);
}

export fn abc_def_group_value(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.groups.items.len) return 0;
    return builder.groups.items[index].value;
}

export fn abc_def_group_min(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.groups.items.len) return 0;
    return builder.groups.items[index].min;
}

export fn abc_def_group_max(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.groups.items.len) return 0;
    return builder.groups.items[index].max;
}

export fn abc_def_group_dependent(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.groups.items.len) return 0;
    return @intFromBool(builder.groups.items[index].dependent);
}

export fn abc_def_binding(node: u32, field_raw: u32) u32 {
    if (field_raw > @intFromEnum(Semantics.Field.two)) return invalid_id;
    const field: Semantics.Field = @enumFromInt(@as(u8, @intCast(field_raw)));
    return definitionBuilder().binding(node, field) orelse invalid_id;
}

export fn abc_def_relation_count() u32 {
    return @intCast(definitionBuilder().relations.items.len);
}

export fn abc_def_relation_kind(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.relations.items.len) return invalid_id;
    return switch (builder.relations.items[index]) {
        .sum => 0,
        .pow => 1,
    };
}

export fn abc_def_relation_a(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.relations.items.len) return invalid_id;
    return switch (builder.relations.items[index]) {
        .sum => |r| r.total,
        .pow => |r| r.address,
    };
}

export fn abc_def_relation_b(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.relations.items.len) return invalid_id;
    return switch (builder.relations.items[index]) {
        .sum => |r| r.low,
        .pow => |r| r.out,
    };
}

export fn abc_def_relation_c(index: u32) u32 {
    const builder = definitionBuilder();
    if (index >= builder.relations.items.len) return invalid_id;
    return switch (builder.relations.items[index]) {
        .sum => |r| r.high,
        .pow => invalid_id,
    };
}

export fn abc_doc_reset() void {
    documentBuilder().resetDocument();
}

export fn abc_doc_add_node(document_id: u32, kind_raw: u32, width: u32, address_width: u32, split_width: u32, rgb: u32) u32 {
    const k = DocumentCompiler.documentKind(kind_raw) orelse return invalid_id;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width or split_width > Semantics.max_width) return invalid_id;
    return documentBuilder().addNode(.{
        .document_id = document_id,
        .kind = k,
        .width = @intCast(width),
        .address_width = @intCast(address_width),
        .split_width = @intCast(split_width),
        .rgb = rgb != 0,
    }) catch invalid_id;
}

export fn abc_doc_add_wire(target: u32, pin: u32, source: u32, source_port: u32) u32 {
    documentBuilder().addWire(.{ .target = target, .pin = pin, .source = source, .source_port = source_port }) catch return 1;
    return 0;
}

export fn abc_doc_begin_custom(root_node: u32) u32 {
    return documentBuilder().beginCustom(root_node) catch invalid_id;
}

export fn abc_doc_add_custom_child(custom: u32, local_id: u32, kind_raw: u32, width: u32, address_width: u32, split_width: u32) u32 {
    const k = semanticKind(kind_raw) orelse return invalid_id;
    if (width == 0 or width > Semantics.max_width or address_width == 0 or address_width > Semantics.max_address_width or split_width > Semantics.max_width) return invalid_id;
    return documentBuilder().addCustomChild(custom, .{
        .local_id = local_id,
        .kind = k,
        .width = @intCast(width),
        .address_width = @intCast(address_width),
        .split_width = @intCast(split_width),
    }) catch invalid_id;
}

export fn abc_doc_add_custom_wire(custom: u32, target: u32, pin: u32, source: u32, source_port: u32) u32 {
    documentBuilder().addCustomWire(custom, .{ .target = target, .pin = pin, .source = source, .source_port = source_port }) catch return 1;
    return 0;
}

export fn abc_doc_add_custom_input(custom: u32, child: u32) u32 {
    documentBuilder().addCustomInput(custom, child) catch return 1;
    return 0;
}

export fn abc_doc_add_custom_output(custom: u32, child: u32) u32 {
    documentBuilder().addCustomOutput(custom, child) catch return 1;
    return 0;
}

export fn abc_doc_finish_custom(custom: u32) u32 {
    documentBuilder().finishCustom(custom) catch return 1;
    return 0;
}

fn documentStatus(err: anyerror) u32 {
    return switch (err) {
        error.BudgetExceeded => 3,
        error.OutOfMemory => 4,
        error.CircuitFailure => 5,
        else => 1,
    };
}

export fn abc_doc_analyze() u32 {
    documentBuilder().analyze() catch |err| return documentStatus(err);
    return 0;
}

export fn abc_doc_compile() u32 {
    const builder = documentBuilder();
    builder.compile(resetCircuit()) catch |err| return documentStatus(err);
    return 0;
}

export fn abc_doc_scalar_count() u32 {
    return std.math.cast(u32, documentBuilder().scalar_nodes) orelse invalid_id;
}

export fn abc_doc_state_count() u32 {
    return @intCast(documentBuilder().states.items.len);
}

fn documentState(index: u32) ?DocumentCompiler.StateRecord {
    const builder = documentBuilder();
    if (index >= builder.states.items.len) return null;
    return builder.states.items[index];
}

export fn abc_doc_state_root(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return state.root_document_id;
}
export fn abc_doc_state_local(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return state.local_id;
}
export fn abc_doc_state_has_local(index: u32) u32 {
    const state = documentState(index) orelse return 0;
    return @intFromBool(state.has_local);
}
export fn abc_doc_state_style(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return @intFromEnum(state.style);
}
export fn abc_doc_state_index(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return state.index;
}
export fn abc_doc_state_kind(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return @intFromEnum(state.kind);
}
export fn abc_doc_state_restore(index: u32) u32 {
    const state = documentState(index) orelse return 0;
    return @intFromBool(state.restore);
}
export fn abc_doc_state_node(index: u32) u32 {
    const state = documentState(index) orelse return invalid_id;
    return if (state.node) |node| @intFromEnum(node) else invalid_id;
}

export fn abc_doc_diagnostic_count() u32 {
    return @intCast(documentBuilder().diagnostics.items.len);
}

fn documentDiagnostic(index: u32) ?DocumentCompiler.Diagnostic {
    const builder = documentBuilder();
    if (index >= builder.diagnostics.items.len) return null;
    return builder.diagnostics.items[index];
}

export fn abc_doc_diagnostic_root(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return invalid_id;
    return diagnostic.root_document_id;
}
export fn abc_doc_diagnostic_target(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return invalid_id;
    return diagnostic.target_id;
}
export fn abc_doc_diagnostic_pin(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return invalid_id;
    return diagnostic.pin;
}
export fn abc_doc_diagnostic_internal(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return 0;
    return @intFromBool(diagnostic.internal);
}
export fn abc_doc_diagnostic_status(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return invalid_id;
    return @intFromEnum(diagnostic.status);
}
export fn abc_doc_diagnostic_source_width(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return 0;
    return diagnostic.source_width;
}
export fn abc_doc_diagnostic_target_width(index: u32) u32 {
    const diagnostic = documentDiagnostic(index) orelse return 0;
    return diagnostic.target_width;
}

export fn abc_doc_top_handle(node: u32) u32 {
    return documentBuilder().topHandle(node) orelse invalid_id;
}

export fn abc_doc_custom_child_handle(custom: u32, child: u32) u32 {
    return documentBuilder().customChildHandle(custom, child) orelse invalid_id;
}

export fn abc_doc_handle_input_count(handle: u32) u32 {
    return documentBuilder().handleInputCount(handle);
}
export fn abc_doc_handle_input_width(handle: u32, pin: u32) u32 {
    return documentBuilder().handleInputWidth(handle, pin);
}
export fn abc_doc_handle_input_connected(handle: u32, pin: u32) u32 {
    return @intFromBool(documentBuilder().handleInputBus(handle, pin) != null);
}
export fn abc_doc_handle_input_node(handle: u32, pin: u32, bit: u32) u32 {
    const bus = documentBuilder().handleInputBus(handle, pin) orelse return invalid_id;
    if (bit >= bus.len) return invalid_id;
    return @intFromEnum(bus[bit]);
}
export fn abc_doc_handle_output_count(handle: u32) u32 {
    return documentBuilder().handleOutputCount(handle);
}
export fn abc_doc_handle_output_width(handle: u32, pin: u32) u32 {
    const bus = documentBuilder().handleOutputBus(handle, pin) orelse return 0;
    return @intCast(bus.len);
}
export fn abc_doc_handle_output_node(handle: u32, pin: u32, bit: u32) u32 {
    const bus = documentBuilder().handleOutputBus(handle, pin) orelse return invalid_id;
    if (bit >= bus.len) return invalid_id;
    return @intFromEnum(bus[bit]);
}

/// Build one primitive/editor component. Status: 0 ok, 1 invalid kind/shape, 2 failure, 3 budget.
/// Returns 0xffffffff on invalid kind or allocation failure.
export fn abc_add_node(kind_raw: u32) u32 {
    const node_kind = kind(kind_raw) orelse return invalid_id;
    const id = circuit().addNode(node_kind) catch return invalid_id;
    return @intFromEnum(id);
}

/// Returns the first of `width` contiguous scalar outputs, or 0xffffffff.
export fn abc_add_counter(width: u32) u32 {
    const id = circuit().addCounter(@intCast(width)) catch return invalid_id;
    return @intFromEnum(id);
}

export fn abc_remove_node(id: u32) u32 {
    return @intFromBool(circuit().removeNode(nodeId(id)));
}

/// Counter pins: 0 shared CLK, 1 shared LOAD, 2 this output lane's DATA bit.
/// Status: 0 = ok, 1 = invalid node, 2 = invalid pin.
export fn abc_connect(source: u32, target: u32, pin: u32) u32 {
    circuit().connect(nodeId(source), nodeId(target), @intCast(pin)) catch |err| {
        return switch (err) {
            error.InvalidNode => 1,
            error.InvalidPin => 2,
        };
    };
    return 0;
}

export fn abc_disconnect(target: u32, pin: u32) u32 {
    return @intFromBool(circuit().disconnect(nodeId(target), @intCast(pin)));
}

/// Status: 0 = ok, 1 = invalid node, 2 = node is not an input.
export fn abc_set_input(id: u32, value: u32) u32 {
    circuit().setInput(nodeId(id), value != 0) catch |err| {
        return switch (err) {
            error.InvalidNode => 1,
            error.NotInput => 2,
        };
    };
    return 0;
}

/// Set the full counter using exact low/high halves. Keeps prior CLK state.
/// Status: 0 = ok, 1 = invalid node, 2 = not a counter, 3 = out of range.
export fn abc_set_counter(id: u32, low: u32, high: u32) u32 {
    const value = @as(u64, low) | (@as(u64, high) << 32);
    circuit().setCounter(nodeId(id), value) catch |err| {
        return switch (err) {
            error.InvalidNode => 1,
            error.NotCounter => 2,
            error.ValueOutOfRange => 3,
        };
    };
    return 0;
}

/// Returns 1 when settled, 0 when work remains, 2 on allocation/size failure.
export fn abc_run(max_rounds: u32) u32 {
    const result = circuit().run(@intCast(max_rounds)) catch return 2;
    return switch (result) {
        .settled => 1,
        .pending => 0,
    };
}

/// Returns 0/1 for a valid node and 2 for an invalid or deleted node.
export fn abc_value(id: u32) u32 {
    const result = circuit().value(nodeId(id)) catch return 2;
    return @intFromBool(result);
}

/// Returns a two-bit editor checkpoint, or 4 for an invalid node.
export fn abc_state(id: u32) u32 {
    return circuit().state(nodeId(id)) catch return 4;
}

/// Status: 0 = restored, 1 = invalid node, 2 = invalid checkpoint.
export fn abc_restore_state(id: u32, saved: u32) u32 {
    if (saved > 3) return 2;
    circuit().restoreState(nodeId(id), @intCast(saved)) catch return 1;
    return 0;
}

const std = @import("std");
const Circuit = @import("Circuit.zig");
const Semantics = @import("Semantics.zig");
const ComponentCompiler = @import("ComponentCompiler.zig");
const PrimitiveCompiler = @import("PrimitiveCompiler.zig");

pub const invalid_index = std.math.maxInt(u32);
pub const max_scalar_nodes: usize = 250_000;

pub const DocumentKind = enum(u8) {
    input,
    output,
    not,
    and2,
    or2,
    xor2,
    dff,
    buffer,
    nand2,
    nor2,
    xnor2,
    oscillator,
    clock,
    mux,
    demux,
    decoder,
    adder,
    split,
    join,
    display,
    register,
    alu,
    ram,
    custom,

    pub fn semantic(self: DocumentKind) ?Semantics.Kind {
        if (self == .custom) return null;
        return @enumFromInt(@intFromEnum(self));
    }
};

pub fn documentKind(raw: u32) ?DocumentKind {
    if (raw > @intFromEnum(DocumentKind.custom)) return null;
    return @enumFromInt(@as(u8, @intCast(raw)));
}

pub const NodeSpec = struct {
    document_id: u32,
    kind: DocumentKind,
    width: u8,
    address_width: u8,
    split_width: u8,
    rgb: bool,
    custom_instance: u32 = invalid_index,
};

pub const ChildSpec = struct {
    local_id: u32,
    kind: Semantics.Kind,
    width: u8,
    address_width: u8,
    split_width: u8,
};

pub const Wire = struct {
    target: u32,
    pin: u32,
    source: u32,
    source_port: u32,
};

pub const CustomInstance = struct {
    root_node: u32,
    child_start: u32,
    child_count: u32 = 0,
    wire_start: u32,
    wire_count: u32 = 0,
    input_start: u32,
    input_count: u32 = 0,
    output_start: u32,
    output_count: u32 = 0,
    finished: bool = false,
};

pub const DiagnosticStatus = enum(u8) {
    missing_source = 1,
    inactive_output = 2,
    inactive_input = 3,
    width_mismatch = 4,
};

pub const Diagnostic = struct {
    root_document_id: u32,
    target_id: u32,
    pin: u32,
    internal: bool,
    status: DiagnosticStatus,
    source_width: u8 = 0,
    target_width: u8 = 0,
};

pub const StateStyle = enum(u8) {
    bit = 0,
    count = 1,
    oscillator = 2,
    native = 3,
};

pub const StateRecord = struct {
    root_document_id: u32,
    local_id: u32 = 0,
    has_local: bool = false,
    style: StateStyle,
    index: u32,
    kind: Semantics.Kind,
    restore: bool,
    node: ?Circuit.NodeId = null,
};

const BusRef = struct {
    start: u32 = invalid_index,
    len: u8 = 0,

    fn valid(self: BusRef) bool {
        return self.start != invalid_index;
    }
};

const RuntimeTarget = struct {
    node: Circuit.NodeId,
    pin: u8,
    source_bit: u8,
};

const InputPort = struct {
    width: u8,
    target_start: u32,
    target_count: u32,
    connected: BusRef = .{},
};

const OutputPort = struct {
    bus: BusRef,
};

const Handle = struct {
    input_ref_start: u32,
    input_ref_count: u32,
    output_ref_start: u32,
    output_ref_count: u32,
};

pub const Error = error{
    InvalidDocument,
    InvalidShape,
    InvalidCustomInstance,
    BudgetExceeded,
    OutOfMemory,
    CircuitFailure,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(NodeSpec) = .empty,
    wires: std.ArrayListUnmanaged(Wire) = .empty,
    customs: std.ArrayListUnmanaged(CustomInstance) = .empty,
    children: std.ArrayListUnmanaged(ChildSpec) = .empty,
    child_wires: std.ArrayListUnmanaged(Wire) = .empty,
    custom_inputs: std.ArrayListUnmanaged(u32) = .empty,
    custom_outputs: std.ArrayListUnmanaged(u32) = .empty,

    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    states: std.ArrayListUnmanaged(StateRecord) = .empty,
    scalar_nodes: usize = 0,

    handles: std.ArrayListUnmanaged(Handle) = .empty,
    input_refs: std.ArrayListUnmanaged(u32) = .empty,
    output_refs: std.ArrayListUnmanaged(u32) = .empty,
    input_ports: std.ArrayListUnmanaged(InputPort) = .empty,
    output_ports: std.ArrayListUnmanaged(OutputPort) = .empty,
    targets: std.ArrayListUnmanaged(RuntimeTarget) = .empty,
    bus_nodes: std.ArrayListUnmanaged(Circuit.NodeId) = .empty,
    top_handles: std.ArrayListUnmanaged(u32) = .empty,
    child_handles: std.ArrayListUnmanaged(u32) = .empty,

    primitive_scratch: PrimitiveCompiler.Scratch,
    component_scratch: ComponentCompiler.Scratch,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .primitive_scratch = PrimitiveCompiler.Scratch.init(allocator),
            .component_scratch = ComponentCompiler.Scratch.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.component_scratch.deinit();
        self.primitive_scratch.deinit();
        self.child_handles.deinit(self.allocator);
        self.top_handles.deinit(self.allocator);
        self.bus_nodes.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.output_ports.deinit(self.allocator);
        self.input_ports.deinit(self.allocator);
        self.output_refs.deinit(self.allocator);
        self.input_refs.deinit(self.allocator);
        self.handles.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.custom_outputs.deinit(self.allocator);
        self.custom_inputs.deinit(self.allocator);
        self.child_wires.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.customs.deinit(self.allocator);
        self.wires.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resetDocument(self: *Builder) void {
        self.nodes.clearRetainingCapacity();
        self.wires.clearRetainingCapacity();
        self.customs.clearRetainingCapacity();
        self.children.clearRetainingCapacity();
        self.child_wires.clearRetainingCapacity();
        self.custom_inputs.clearRetainingCapacity();
        self.custom_outputs.clearRetainingCapacity();
        self.clearResults();
    }

    fn clearResults(self: *Builder) void {
        self.diagnostics.clearRetainingCapacity();
        self.states.clearRetainingCapacity();
        self.scalar_nodes = 0;
        self.handles.clearRetainingCapacity();
        self.input_refs.clearRetainingCapacity();
        self.output_refs.clearRetainingCapacity();
        self.input_ports.clearRetainingCapacity();
        self.output_ports.clearRetainingCapacity();
        self.targets.clearRetainingCapacity();
        self.bus_nodes.clearRetainingCapacity();
        self.top_handles.clearRetainingCapacity();
        self.child_handles.clearRetainingCapacity();
    }

    pub fn addNode(self: *Builder, spec: NodeSpec) !u32 {
        if (!validNode(spec)) return error.InvalidShape;
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, spec);
        return index;
    }

    pub fn addWire(self: *Builder, wire: Wire) !void {
        if (wire.target >= self.nodes.items.len) return error.InvalidDocument;
        try self.wires.append(self.allocator, wire);
    }

    pub fn beginCustom(self: *Builder, root_node: u32) !u32 {
        if (root_node >= self.nodes.items.len or self.nodes.items[root_node].kind != .custom) return error.InvalidCustomInstance;
        if (self.nodes.items[root_node].custom_instance != invalid_index) return error.InvalidCustomInstance;
        const index: u32 = @intCast(self.customs.items.len);
        try self.customs.append(self.allocator, .{
            .root_node = root_node,
            .child_start = @intCast(self.children.items.len),
            .wire_start = @intCast(self.child_wires.items.len),
            .input_start = @intCast(self.custom_inputs.items.len),
            .output_start = @intCast(self.custom_outputs.items.len),
        });
        self.nodes.items[root_node].custom_instance = index;
        return index;
    }

    fn openCustom(self: *Builder, custom: u32) !*CustomInstance {
        if (custom >= self.customs.items.len) return error.InvalidCustomInstance;
        const instance = &self.customs.items[custom];
        if (instance.finished) return error.InvalidCustomInstance;
        return instance;
    }

    pub fn addCustomChild(self: *Builder, custom: u32, child: ChildSpec) !u32 {
        const instance = try self.openCustom(custom);
        if (!validChild(child)) return error.InvalidShape;
        const expected: u32 = instance.child_start + instance.child_count;
        if (expected != self.children.items.len) return error.InvalidCustomInstance;
        try self.children.append(self.allocator, child);
        const local_index = instance.child_count;
        instance.child_count += 1;
        return local_index;
    }

    pub fn addCustomWire(self: *Builder, custom: u32, wire: Wire) !void {
        const instance = try self.openCustom(custom);
        if (wire.target >= instance.child_count) return error.InvalidDocument;
        if (instance.wire_start + instance.wire_count != self.child_wires.items.len) return error.InvalidCustomInstance;
        try self.child_wires.append(self.allocator, wire);
        instance.wire_count += 1;
    }

    pub fn addCustomInput(self: *Builder, custom: u32, child_index: u32) !void {
        const instance = try self.openCustom(custom);
        if (child_index >= instance.child_count) return error.InvalidDocument;
        if (instance.input_start + instance.input_count != self.custom_inputs.items.len) return error.InvalidCustomInstance;
        try self.custom_inputs.append(self.allocator, child_index);
        instance.input_count += 1;
    }

    pub fn addCustomOutput(self: *Builder, custom: u32, child_index: u32) !void {
        const instance = try self.openCustom(custom);
        if (child_index >= instance.child_count) return error.InvalidDocument;
        if (instance.output_start + instance.output_count != self.custom_outputs.items.len) return error.InvalidCustomInstance;
        try self.custom_outputs.append(self.allocator, child_index);
        instance.output_count += 1;
    }

    pub fn finishCustom(self: *Builder, custom: u32) !void {
        const instance = try self.openCustom(custom);
        if (instance.child_count == 0 or instance.input_count == 0 or instance.output_count == 0) return error.InvalidCustomInstance;
        const children = self.customChildren(instance.*);
        for (self.customInputRefs(instance.*)) |child_index| {
            if (children[child_index].kind != .input) return error.InvalidCustomInstance;
        }
        for (self.customOutputRefs(instance.*)) |child_index| {
            if (children[child_index].kind != .output) return error.InvalidCustomInstance;
        }
        instance.finished = true;
    }

    fn customChildren(self: *const Builder, instance: CustomInstance) []const ChildSpec {
        const start: usize = @intCast(instance.child_start);
        return self.children.items[start .. start + instance.child_count];
    }

    fn customWires(self: *const Builder, instance: CustomInstance) []const Wire {
        const start: usize = @intCast(instance.wire_start);
        return self.child_wires.items[start .. start + instance.wire_count];
    }

    fn customInputRefs(self: *const Builder, instance: CustomInstance) []const u32 {
        const start: usize = @intCast(instance.input_start);
        return self.custom_inputs.items[start .. start + instance.input_count];
    }

    fn customOutputRefs(self: *const Builder, instance: CustomInstance) []const u32 {
        const start: usize = @intCast(instance.output_start);
        return self.custom_outputs.items[start .. start + instance.output_count];
    }

    fn validateComplete(self: *const Builder) !void {
        for (self.nodes.items, 0..) |node, index| {
            if (!validNode(node)) return error.InvalidShape;
            if (node.kind == .custom) {
                if (node.custom_instance >= self.customs.items.len) return error.InvalidCustomInstance;
                const custom = self.customs.items[node.custom_instance];
                if (!custom.finished or custom.root_node != index) return error.InvalidCustomInstance;
            } else if (node.custom_instance != invalid_index) return error.InvalidCustomInstance;
        }
    }

    pub fn analyze(self: *Builder) Error!void {
        try self.validateComplete();
        self.clearResults();
        for (self.nodes.items) |node| {
            if (node.kind == .custom) {
                const custom = self.customs.items[node.custom_instance];
                const children = self.customChildren(custom);
                const interfaces = self.customInputRefs(custom);
                for (children, 0..) |child, child_index| {
                    const interface_input = containsIndex(interfaces, @intCast(child_index));
                    try self.planSemantic(node.document_id, child.local_id, true, child.kind, child.width, child.address_width, interface_input);
                }
                try self.validateCustomConnections(node.document_id, custom);
            } else if (node.kind != .display) {
                const k = node.kind.semantic() orelse return error.InvalidDocument;
                try self.planSemantic(node.document_id, 0, false, k, node.width, node.address_width, false);
            }
        }
        try self.validateTopConnections();
    }

    fn planSemantic(
        self: *Builder,
        root_document_id: u32,
        local_id: u32,
        has_local: bool,
        kind: Semantics.Kind,
        width: u8,
        address_width: u8,
        interface_input: bool,
    ) Error!void {
        const count: usize = if (isComposite(kind))
            ComponentCompiler.scalarCount(kind, width, address_width) orelse return error.InvalidShape
        else switch (kind) {
            .display => 0,
            .oscillator => 1,
            else => width,
        };
        try self.reserveScalar(count);
        if (kind == .display) return;
        const style: StateStyle = if (isComposite(kind)) .native else if (kind == .clock) .count else if (kind == .oscillator) .oscillator else .bit;
        const state_kind: Semantics.Kind = if (interface_input and kind == .input) .buffer else kind;
        const restore = !(kind == .oscillator or (!has_local and kind == .input and !interface_input));
        for (0..count) |index| try self.states.append(self.allocator, .{
            .root_document_id = root_document_id,
            .local_id = local_id,
            .has_local = has_local,
            .style = style,
            .index = @intCast(index),
            .kind = state_kind,
            .restore = restore,
        });
    }

    fn reserveScalar(self: *Builder, count: usize) Error!void {
        if (count > max_scalar_nodes - self.scalar_nodes) return error.BudgetExceeded;
        self.scalar_nodes += count;
    }

    pub fn compile(self: *Builder, circuit: *Circuit) Error!void {
        try self.validateComplete();
        self.clearResults();
        try self.top_handles.resize(self.allocator, self.nodes.items.len);
        @memset(self.top_handles.items, invalid_index);

        var child_total: usize = 0;
        for (self.customs.items) |custom| child_total += custom.child_count;
        try self.child_handles.resize(self.allocator, child_total);
        @memset(self.child_handles.items, invalid_index);

        var child_handle_cursor: usize = 0;
        for (self.nodes.items, 0..) |node, node_index| {
            if (node.kind == .custom) {
                const custom = self.customs.items[node.custom_instance];
                const children = self.customChildren(custom);
                const input_refs = self.customInputRefs(custom);
                const child_base = child_handle_cursor;
                for (children, 0..) |child, child_index| {
                    const interface_input = containsIndex(input_refs, @intCast(child_index));
                    const handle = try self.instantiateSemantic(
                        circuit,
                        node.document_id,
                        child.local_id,
                        true,
                        child.kind,
                        child.width,
                        child.address_width,
                        child.split_width,
                        interface_input,
                    );
                    self.child_handles.items[child_handle_cursor] = handle;
                    child_handle_cursor += 1;
                }
                try self.wireCustom(circuit, node.document_id, custom, child_base);
                const top_handle = try self.aliasCustomHandle(custom, child_base);
                self.top_handles.items[node_index] = top_handle;
            } else if (node.kind == .display) {
                self.top_handles.items[node_index] = try self.createDisplayHandle(node);
            } else {
                const semantic = node.kind.semantic() orelse return error.InvalidDocument;
                self.top_handles.items[node_index] = try self.instantiateSemantic(
                    circuit,
                    node.document_id,
                    0,
                    false,
                    semantic,
                    node.width,
                    node.address_width,
                    node.split_width,
                    false,
                );
            }
        }
        try self.wireTop(circuit);
    }

    fn instantiateSemantic(
        self: *Builder,
        circuit: *Circuit,
        root_document_id: u32,
        local_id: u32,
        has_local: bool,
        kind: Semantics.Kind,
        width: u8,
        address_width: u8,
        split_width: u8,
        interface_input: bool,
    ) Error!u32 {
        if (isComposite(kind)) {
            const expected = ComponentCompiler.scalarCount(kind, width, address_width) orelse return error.InvalidShape;
            try self.reserveScalar(expected);
            ComponentCompiler.compile(
                circuit,
                &self.component_scratch,
                kind,
                width,
                address_width,
                split_width,
                max_scalar_nodes - (self.scalar_nodes - expected),
            ) catch |err| return mapCompilerError(err);
            if (self.component_scratch.created.items.len != expected) return error.CircuitFailure;
            try self.appendStates(root_document_id, local_id, has_local, .native, kind, true, self.component_scratch.created.items);
            return self.createComponentHandle();
        }

        const expected: usize = switch (kind) {
            .display => 0,
            .oscillator => 1,
            else => width,
        };
        try self.reserveScalar(expected);
        PrimitiveCompiler.compile(
            circuit,
            &self.primitive_scratch,
            kind,
            width,
            address_width,
            split_width,
            interface_input,
            max_scalar_nodes - (self.scalar_nodes - expected),
        ) catch |err| return mapCompilerError(err);
        if (self.primitive_scratch.created.items.len != expected) return error.CircuitFailure;
        const style: StateStyle = if (kind == .clock) .count else if (kind == .oscillator) .oscillator else .bit;
        const state_kind: Semantics.Kind = if (interface_input and kind == .input) .buffer else kind;
        const restore = !(kind == .oscillator or (!has_local and kind == .input and !interface_input));
        try self.appendStates(root_document_id, local_id, has_local, style, state_kind, restore, self.primitive_scratch.created.items);
        return self.createPrimitiveHandle();
    }

    fn appendStates(
        self: *Builder,
        root_document_id: u32,
        local_id: u32,
        has_local: bool,
        style: StateStyle,
        kind: Semantics.Kind,
        restore: bool,
        nodes: []const Circuit.NodeId,
    ) Error!void {
        for (nodes, 0..) |node, index| try self.states.append(self.allocator, .{
            .root_document_id = root_document_id,
            .local_id = local_id,
            .has_local = has_local,
            .style = style,
            .index = @intCast(index),
            .kind = kind,
            .restore = restore,
            .node = node,
        });
    }

    fn createPrimitiveHandle(self: *Builder) Error!u32 {
        const input_ref_start: u32 = @intCast(self.input_refs.items.len);
        for (0..self.primitive_scratch.inputCount()) |pin| {
            const targets = self.primitive_scratch.inputTargets(pin) orelse return error.CircuitFailure;
            const target_start: u32 = @intCast(self.targets.items.len);
            for (targets) |target| try self.targets.append(self.allocator, .{
                .node = target.node,
                .pin = target.pin,
                .source_bit = target.source_bit,
            });
            const port_index: u32 = @intCast(self.input_ports.items.len);
            try self.input_ports.append(self.allocator, .{
                .width = self.primitive_scratch.input_widths.items[pin],
                .target_start = target_start,
                .target_count = @intCast(targets.len),
            });
            try self.input_refs.append(self.allocator, port_index);
        }
        const output_ref_start: u32 = @intCast(self.output_refs.items.len);
        for (0..self.primitive_scratch.outputCount()) |pin| {
            const bus = self.primitive_scratch.outputBus(pin) orelse return error.CircuitFailure;
            try self.output_refs.append(self.allocator, try self.appendOutputPort(bus));
        }
        return self.appendHandle(input_ref_start, @intCast(self.primitive_scratch.inputCount()), output_ref_start, @intCast(self.primitive_scratch.outputCount()));
    }

    fn createComponentHandle(self: *Builder) Error!u32 {
        const input_ref_start: u32 = @intCast(self.input_refs.items.len);
        for (0..self.component_scratch.inputCount()) |pin| {
            const bus = self.component_scratch.inputBus(pin) orelse return error.CircuitFailure;
            const target_start: u32 = @intCast(self.targets.items.len);
            for (bus, 0..) |node, bit| try self.targets.append(self.allocator, .{
                .node = node,
                .pin = 0,
                .source_bit = @intCast(bit),
            });
            const port_index: u32 = @intCast(self.input_ports.items.len);
            try self.input_ports.append(self.allocator, .{
                .width = @intCast(bus.len),
                .target_start = target_start,
                .target_count = @intCast(bus.len),
            });
            try self.input_refs.append(self.allocator, port_index);
        }
        const output_ref_start: u32 = @intCast(self.output_refs.items.len);
        for (0..self.component_scratch.outputCount()) |pin| {
            const bus = self.component_scratch.outputBus(pin) orelse return error.CircuitFailure;
            try self.output_refs.append(self.allocator, try self.appendOutputPort(bus));
        }
        return self.appendHandle(input_ref_start, @intCast(self.component_scratch.inputCount()), output_ref_start, @intCast(self.component_scratch.outputCount()));
    }

    fn createDisplayHandle(self: *Builder, node: NodeSpec) Error!u32 {
        const input_ref_start: u32 = @intCast(self.input_refs.items.len);
        const k = Semantics.Kind.display;
        const count = Semantics.inputCount(k, node.address_width, node.rgb);
        for (0..count) |pin| {
            const port = Semantics.inputPort(k, node.width, node.address_width, node.split_width, node.rgb, @intCast(pin)) orelse return error.InvalidShape;
            const port_index: u32 = @intCast(self.input_ports.items.len);
            try self.input_ports.append(self.allocator, .{
                .width = port.width,
                .target_start = @intCast(self.targets.items.len),
                .target_count = 0,
            });
            try self.input_refs.append(self.allocator, port_index);
        }
        return self.appendHandle(input_ref_start, count, @intCast(self.output_refs.items.len), 0);
    }

    fn aliasCustomHandle(self: *Builder, custom: CustomInstance, child_base: usize) Error!u32 {
        const input_ref_start: u32 = @intCast(self.input_refs.items.len);
        for (self.customInputRefs(custom)) |child_index| {
            const handle = self.handles.items[self.child_handles.items[child_base + child_index]];
            if (handle.input_ref_count == 0) return error.InvalidCustomInstance;
            try self.input_refs.append(self.allocator, self.input_refs.items[handle.input_ref_start]);
        }
        const output_ref_start: u32 = @intCast(self.output_refs.items.len);
        for (self.customOutputRefs(custom)) |child_index| {
            const handle = self.handles.items[self.child_handles.items[child_base + child_index]];
            if (handle.output_ref_count == 0) return error.InvalidCustomInstance;
            try self.output_refs.append(self.allocator, self.output_refs.items[handle.output_ref_start]);
        }
        return self.appendHandle(input_ref_start, custom.input_count, output_ref_start, custom.output_count);
    }

    fn appendHandle(self: *Builder, input_start: u32, input_count: u32, output_start: u32, output_count: u32) Error!u32 {
        const index: u32 = @intCast(self.handles.items.len);
        try self.handles.append(self.allocator, .{
            .input_ref_start = input_start,
            .input_ref_count = input_count,
            .output_ref_start = output_start,
            .output_ref_count = output_count,
        });
        return index;
    }

    fn appendOutputPort(self: *Builder, nodes: []const Circuit.NodeId) Error!u32 {
        if (nodes.len > Semantics.max_width) return error.CircuitFailure;
        const start: u32 = @intCast(self.bus_nodes.items.len);
        try self.bus_nodes.appendSlice(self.allocator, nodes);
        const index: u32 = @intCast(self.output_ports.items.len);
        try self.output_ports.append(self.allocator, .{ .bus = .{ .start = start, .len = @intCast(nodes.len) } });
        return index;
    }

    fn wireTop(self: *Builder, circuit: *Circuit) Error!void {
        for (self.wires.items) |wire| {
            const target_id = self.nodes.items[wire.target].document_id;
            try self.connectWire(circuit, wire, self.top_handles.items, target_id, 0, false);
        }
    }

    fn wireCustom(self: *Builder, circuit: *Circuit, root_document_id: u32, custom: CustomInstance, child_base: usize) Error!void {
        const children = self.customChildren(custom);
        const handles = self.child_handles.items[child_base .. child_base + custom.child_count];
        for (self.customWires(custom)) |wire| {
            if (wire.target >= children.len) return error.InvalidDocument;
            try self.connectWire(circuit, wire, handles, children[wire.target].local_id, root_document_id, true);
        }
    }

    fn connectWire(
        self: *Builder,
        circuit: *Circuit,
        wire: Wire,
        handle_map: []const u32,
        target_id: u32,
        root_document_id: u32,
        internal: bool,
    ) Error!void {
        if (wire.target >= handle_map.len) return error.InvalidDocument;
        if (wire.source == invalid_index or wire.source >= handle_map.len) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .missing_source, 0, 0);
        }
        const target_handle = self.handles.items[handle_map[wire.target]];
        const source_handle = self.handles.items[handle_map[wire.source]];
        if (wire.source_port >= source_handle.output_ref_count) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .inactive_output, 0, 0);
        }
        if (wire.pin >= target_handle.input_ref_count) {
            const source_bus = self.outputBusFromHandle(source_handle, wire.source_port) orelse return error.CircuitFailure;
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .inactive_input, @intCast(source_bus.len), 0);
        }
        const source_output_index = self.output_refs.items[source_handle.output_ref_start + wire.source_port];
        const source_bus_ref = self.output_ports.items[source_output_index].bus;
        const source_bus = self.busSlice(source_bus_ref);
        const input_index = self.input_refs.items[target_handle.input_ref_start + wire.pin];
        const input = &self.input_ports.items[input_index];
        if (source_bus.len != input.width) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .width_mismatch, @intCast(source_bus.len), input.width);
        }
        const target_start: usize = @intCast(input.target_start);
        for (self.targets.items[target_start .. target_start + input.target_count]) |target| {
            if (target.source_bit >= source_bus.len) return error.CircuitFailure;
            circuit.connect(source_bus[target.source_bit], target.node, target.pin) catch return error.CircuitFailure;
        }
        input.connected = source_bus_ref;
    }

    fn appendDiagnostic(
        self: *Builder,
        root_document_id: u32,
        target_id: u32,
        pin: u32,
        internal: bool,
        status: DiagnosticStatus,
        source_width: u8,
        target_width: u8,
    ) Error!void {
        try self.diagnostics.append(self.allocator, .{
            .root_document_id = root_document_id,
            .target_id = target_id,
            .pin = pin,
            .internal = internal,
            .status = status,
            .source_width = source_width,
            .target_width = target_width,
        });
    }

    fn validateTopConnections(self: *Builder) Error!void {
        for (self.wires.items) |wire| {
            const target = self.nodes.items[wire.target];
            try self.validateWireShape(wire, target.document_id, 0, false, null);
        }
    }

    fn validateCustomConnections(self: *Builder, root_document_id: u32, custom: CustomInstance) Error!void {
        const children = self.customChildren(custom);
        for (self.customWires(custom)) |wire| {
            if (wire.target >= children.len) return error.InvalidDocument;
            try self.validateWireShape(wire, children[wire.target].local_id, root_document_id, true, custom);
        }
    }

    fn validateWireShape(
        self: *Builder,
        wire: Wire,
        target_id: u32,
        root_document_id: u32,
        internal: bool,
        custom: ?CustomInstance,
    ) Error!void {
        const source_count: usize = if (custom) |instance| instance.child_count else self.nodes.items.len;
        if (wire.source == invalid_index or wire.source >= source_count) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .missing_source, 0, 0);
        }
        const source_port = if (custom) |instance|
            childOutputPort(self.customChildren(instance)[wire.source], wire.source_port)
        else
            self.topOutputPort(self.nodes.items[wire.source], wire.source_port);
        if (source_port == null) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .inactive_output, 0, 0);
        }
        const target_port = if (custom) |instance|
            childInputPort(self.customChildren(instance)[wire.target], wire.pin)
        else
            self.topInputPort(self.nodes.items[wire.target], wire.pin);
        if (target_port == null) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .inactive_input, source_port.?.width, 0);
        }
        if (source_port.?.width != target_port.?.width) {
            return self.appendDiagnostic(root_document_id, target_id, wire.pin, internal, .width_mismatch, source_port.?.width, target_port.?.width);
        }
    }

    fn topInputPort(self: *const Builder, node: NodeSpec, pin: u32) ?Semantics.Port {
        if (node.kind == .custom) {
            if (node.custom_instance >= self.customs.items.len) return null;
            const custom = self.customs.items[node.custom_instance];
            if (pin >= custom.input_count) return null;
            const child_index = self.customInputRefs(custom)[pin];
            const child = self.customChildren(custom)[child_index];
            return .{ .width = child.width, .field = .width };
        }
        const kind = node.kind.semantic() orelse return null;
        return Semantics.inputPort(kind, node.width, node.address_width, node.split_width, node.rgb, pin);
    }

    fn topOutputPort(self: *const Builder, node: NodeSpec, pin: u32) ?Semantics.Port {
        if (node.kind == .custom) {
            if (node.custom_instance >= self.customs.items.len) return null;
            const custom = self.customs.items[node.custom_instance];
            if (pin >= custom.output_count) return null;
            const child_index = self.customOutputRefs(custom)[pin];
            const child = self.customChildren(custom)[child_index];
            return .{ .width = child.width, .field = .width };
        }
        const kind = node.kind.semantic() orelse return null;
        return Semantics.outputPort(kind, node.width, node.address_width, node.split_width, pin);
    }

    fn handleInputPortIndex(self: *const Builder, handle_index: u32, pin: u32) ?u32 {
        if (handle_index >= self.handles.items.len) return null;
        const handle = self.handles.items[handle_index];
        if (pin >= handle.input_ref_count) return null;
        return self.input_refs.items[handle.input_ref_start + pin];
    }

    fn handleOutputPortIndex(self: *const Builder, handle_index: u32, pin: u32) ?u32 {
        if (handle_index >= self.handles.items.len) return null;
        const handle = self.handles.items[handle_index];
        if (pin >= handle.output_ref_count) return null;
        return self.output_refs.items[handle.output_ref_start + pin];
    }

    fn outputBusFromHandle(self: *const Builder, handle: Handle, pin: u32) ?[]const Circuit.NodeId {
        if (pin >= handle.output_ref_count) return null;
        const output_index = self.output_refs.items[handle.output_ref_start + pin];
        return self.busSlice(self.output_ports.items[output_index].bus);
    }

    fn busSlice(self: *const Builder, bus: BusRef) []const Circuit.NodeId {
        if (!bus.valid()) return &.{};
        const start: usize = @intCast(bus.start);
        return self.bus_nodes.items[start .. start + bus.len];
    }

    pub fn topHandle(self: *const Builder, node: u32) ?u32 {
        if (node >= self.top_handles.items.len) return null;
        const handle = self.top_handles.items[node];
        return if (handle == invalid_index) null else handle;
    }

    pub fn customChildHandle(self: *const Builder, custom_index: u32, child_index: u32) ?u32 {
        if (custom_index >= self.customs.items.len) return null;
        var base: usize = 0;
        for (self.customs.items[0..custom_index]) |custom| base += custom.child_count;
        const custom = self.customs.items[custom_index];
        if (child_index >= custom.child_count or base + child_index >= self.child_handles.items.len) return null;
        const handle = self.child_handles.items[base + child_index];
        return if (handle == invalid_index) null else handle;
    }

    pub fn handleInputCount(self: *const Builder, handle: u32) u32 {
        if (handle >= self.handles.items.len) return 0;
        return self.handles.items[handle].input_ref_count;
    }

    pub fn handleInputWidth(self: *const Builder, handle: u32, pin: u32) u32 {
        const port_index = self.handleInputPortIndex(handle, pin) orelse return 0;
        return self.input_ports.items[port_index].width;
    }

    pub fn handleInputBus(self: *const Builder, handle: u32, pin: u32) ?[]const Circuit.NodeId {
        const port_index = self.handleInputPortIndex(handle, pin) orelse return null;
        const bus = self.input_ports.items[port_index].connected;
        return if (bus.valid()) self.busSlice(bus) else null;
    }

    pub fn handleOutputCount(self: *const Builder, handle: u32) u32 {
        if (handle >= self.handles.items.len) return 0;
        return self.handles.items[handle].output_ref_count;
    }

    pub fn handleOutputBus(self: *const Builder, handle: u32, pin: u32) ?[]const Circuit.NodeId {
        const port_index = self.handleOutputPortIndex(handle, pin) orelse return null;
        return self.busSlice(self.output_ports.items[port_index].bus);
    }
};

fn validNode(spec: NodeSpec) bool {
    if (spec.width == 0 or spec.width > Semantics.max_width) return false;
    if (spec.address_width == 0 or spec.address_width > Semantics.max_address_width) return false;
    if ((spec.kind == .split or spec.kind == .join) and (spec.split_width == 0 or spec.split_width >= spec.width)) return false;
    if (spec.kind == .oscillator and spec.width != 1) return false;
    return true;
}

fn validChild(spec: ChildSpec) bool {
    if (spec.kind == .display or spec.kind == .oscillator) return false;
    return validNode(.{
        .document_id = 0,
        .kind = @enumFromInt(@intFromEnum(spec.kind)),
        .width = spec.width,
        .address_width = spec.address_width,
        .split_width = spec.split_width,
        .rgb = false,
    });
}

fn isComposite(kind: Semantics.Kind) bool {
    return switch (kind) {
        .adder, .register, .alu, .ram, .mux, .demux, .decoder, .split, .join => true,
        else => false,
    };
}

fn containsIndex(values: []const u32, needle: u32) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn childInputPort(child: ChildSpec, pin: u32) ?Semantics.Port {
    return Semantics.inputPort(child.kind, child.width, child.address_width, child.split_width, false, pin);
}

fn childOutputPort(child: ChildSpec, pin: u32) ?Semantics.Port {
    return Semantics.outputPort(child.kind, child.width, child.address_width, child.split_width, pin);
}

fn mapCompilerError(err: anyerror) Error {
    return switch (err) {
        error.BudgetExceeded => error.BudgetExceeded,
        error.InvalidKind, error.InvalidShape, error.InvalidPort => error.InvalidShape,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CircuitFailure,
    };
}

test "analysis owns scalar budget and state-key shape metadata" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addNode(.{ .document_id = 10, .kind = .input, .width = 64, .address_width = 1, .split_width = 1, .rgb = false });
    _ = try builder.addNode(.{ .document_id = 11, .kind = .mux, .width = 8, .address_width = 4, .split_width = 1, .rgb = false });
    try builder.analyze();
    const mux_nodes = ComponentCompiler.scalarCount(.mux, 8, 4).?;
    try std.testing.expectEqual(@as(usize, 64) + mux_nodes, builder.scalar_nodes);
    try std.testing.expectEqual(builder.scalar_nodes, builder.states.items.len);
    try std.testing.expect(!builder.states.items[0].restore);
    try std.testing.expectEqual(StateStyle.native, builder.states.items[64].style);
}

test "compile wires primitive buses and keeps display source bus" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addNode(.{ .document_id = 1, .kind = .input, .width = 8, .address_width = 1, .split_width = 1, .rgb = false });
    _ = try builder.addNode(.{ .document_id = 2, .kind = .not, .width = 8, .address_width = 1, .split_width = 1, .rgb = false });
    _ = try builder.addNode(.{ .document_id = 3, .kind = .display, .width = 8, .address_width = 1, .split_width = 1, .rgb = false });
    try builder.addWire(.{ .source = 0, .source_port = 0, .target = 1, .pin = 0 });
    try builder.addWire(.{ .source = 1, .source_port = 0, .target = 2, .pin = 0 });
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    try builder.compile(&circuit);
    const input_handle = builder.topHandle(0).?;
    const not_handle = builder.topHandle(1).?;
    const display_handle = builder.topHandle(2).?;
    const input_bus = builder.handleOutputBus(input_handle, 0).?;
    for (input_bus) |id| try circuit.setInput(id, true);
    _ = try circuit.run(16);
    for (builder.handleOutputBus(not_handle, 0).?) |id| try std.testing.expect(!(try circuit.value(id)));
    try std.testing.expectEqualSlices(Circuit.NodeId, builder.handleOutputBus(not_handle, 0).?, builder.handleInputBus(display_handle, 0).?);
}

test "custom instance aliases interface ports and reports internal mismatch" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    const root = try builder.addNode(.{ .document_id = 50, .kind = .custom, .width = 1, .address_width = 1, .split_width = 1, .rgb = false });
    const custom = try builder.beginCustom(root);
    _ = try builder.addCustomChild(custom, .{ .local_id = 1, .kind = .input, .width = 8, .address_width = 1, .split_width = 1 });
    _ = try builder.addCustomChild(custom, .{ .local_id = 2, .kind = .output, .width = 8, .address_width = 1, .split_width = 1 });
    try builder.addCustomWire(custom, .{ .source = 0, .source_port = 0, .target = 1, .pin = 0 });
    try builder.addCustomInput(custom, 0);
    try builder.addCustomOutput(custom, 1);
    try builder.finishCustom(custom);
    var circuit = Circuit.init(std.testing.allocator);
    defer circuit.deinit();
    try builder.compile(&circuit);
    const handle = builder.topHandle(root).?;
    try std.testing.expectEqual(@as(u32, 1), builder.handleInputCount(handle));
    try std.testing.expectEqual(@as(u32, 8), builder.handleInputWidth(handle, 0));
    try std.testing.expectEqual(@as(u32, 1), builder.handleOutputCount(handle));
    try std.testing.expectEqual(@as(usize, 8), builder.handleOutputBus(handle, 0).?.len);
}

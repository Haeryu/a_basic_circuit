import { META, MAX_WIDTH, MAX_ADDRESS_WIDTH, MAX_RAM_ADDRESS_WIDTH, validWidth, maskValue, bitValue, busValue,
  makeNode, inputDefs, outputDefs, ensureInputSlots, connectionProblem, createDefinition, inferDefinitionSelection,
  resolveCustom, changeCustomWidth, compileCircuit, readBus, setRuntimeInput, setRuntimeCounter, resizeDisplay,
  parseInputValue, formatBusValue, ramAddressLimit, cloneRamCells, setRamRange, setRamImageCell,
  readRuntimeRamCell, setRuntimeRamCell, snapshotRuntimeRamStates, setSemanticWasm } from "./circuit.js";
import { ClockScheduler, validClockHz, toggleClockLevel, MIN_CLOCK_HZ, MAX_CLOCK_HZ } from "./clock.js";
import { serializeSelection, deserializeSelection, serializeChipBundle, deserializeChipBundle } from "./clipboard.js";
import { autoLayout, routeWire } from "./routing.js";
import { createPrimitiveSymbol } from "./symbols.js";
import { DocumentHistory } from "./history.js";
import { serializeProject, deserializeProject } from "./project.js";

const $ = (selector) => document.querySelector(selector);
const dom = {
  canvas: $("#canvas"), nodeLayer: $("#nodeLayer"), wireLayer: $("#wireLayer"),
  selectionBox: $("#selectionBox"), trashDrop: $("#trashDrop"), status: $("#simStatus"),
  statusText: $("#simStatus .status-text"), nodeCount: $("#nodeCount"), emptyHint: $("#emptyHint"),
  chipButton: $("#chipButton"), customSection: $("#customSection"), customPalette: $("#customPalette"),
  newChipButton: $("#newChipButton"), importChipButton: $("#importChipButton"), exportChipButton: $("#exportChipButton"),
  chipFile: $("#chipFile"),
  scopeBar: $("#scopeBar"), scopeBack: $("#scopeBack"),
  scopeBreadcrumbs: $("#scopeBreadcrumbs"),
  demoButton: $("#demoButton"), clearButton: $("#clearButton"), deleteButton: $("#deleteButton"),
  arrangeButton: $("#arrangeButton"), fitButton: $("#fitButton"), zoomIn: $("#zoomIn"), zoomOut: $("#zoomOut"), zoomLabel: $("#zoomLabel"),
  warningList: $("#warningList"), footerTip: $("#footerTip"),
  copyButton: $("#copyButton"), pasteButton: $("#pasteButton"),
  wireColorTools: $("#wireColorTools"), wireColorInput: $("#wireColorInput"), wireColorReset: $("#wireColorReset"),
  wireDeleteQuick: $("#wireDeleteQuick"),
  undoButton: $("#undoButton"), redoButton: $("#redoButton"), saveButton: $("#saveButton"),
  openButton: $("#openButton"), projectFile: $("#projectFile"),
};
let wasm = null;
let rootNodes = [];
let nodes = rootNodes;
let nodeIndex = new Map();
let rootNodeIndex = new Map();
let nodeElements = new Map();
const nodeRenderState = new WeakMap();
let nextDocumentId = 1;
let selectedIds = new Set();
let selectedWire = null;
let lastWirePress = null;
let lastNodePress = null;
let wireToolAnchor = null;
let simulationToken = 0;
let simulationRunning = false;
let runtime = null;
let wireDrag = null;
let customDefinitions = [];
let nextDefinitionId = 1;
let gesture = null;
let gestureFrame = 0;
let spaceHeld = false;
let activeNodeId = null;
let clipboardText = "";
let pasteCount = 0;
let pasteAnchorKey = "";
let pointerPosition = null;
let documentEpoch = 0;
const clocks = new ClockScheduler();
let clockTimer = null;
const pendingInputValues = new Map();
const editHistory = new DocumentHistory();
let historyReady = false;
let applyingHistory = false;
const retainedStates = new Map();
const retainedRamStates = new Map();
const retainedOscillators = new Map();
let projectFileName = "circuit.abc.json";
const view = { x: 0, y: 0, zoom: 1 };
const scopeViews = new Map();
let scopePath = [];
const moduleExportIds = new Set();
const nodeById = (id) => nodeIndex.get(id) ?? null;
const definitionById = (id) => customDefinitions.find((d) => d.id === id) ?? null;
const nodeInputDefs = (node) => inputDefs(node, definitionById);
const nodeOutputDefs = (node) => outputDefs(node, definitionById);
const connection = (sourceId, sourcePort = 0) => ({ sourceId, sourcePort });
const isEditable = (target) => Boolean(target?.closest?.("input,select,textarea,[contenteditable=true]"));

function scopeKey(path = scopePath) {
  return path.length ? `definition:${path.at(-1).definitionId}` : "root";
}
function inDefinitionScope() { return scopePath.length !== 0; }
function activeDefinition() { return inDefinitionScope() ? definitionById(scopePath.at(-1).definitionId) : null; }
function setActiveNodes(next) {
  nodes = next;
  if (!inDefinitionScope()) rootNodes = next;
  nodeIndex = new Map(nodes.map((node) => [node.documentId, node]));
}
function saveScopeView() { scopeViews.set(scopeKey(), { ...view }); }
function materializeDefinition(definition) {
  return definition.nodes.map((spec) => {
    const node = makeNode(spec.localId, spec.kind, spec.x ?? 0, spec.y ?? 0, spec.width, spec.definitionId ?? null);
    Object.assign(node, spec, { documentId: spec.localId, inputs: (spec.inputs ?? []).map((c) => c && { ...c }),
      widthParameters: { ...(spec.widthParameters ?? {}) }, inputValue: spec.inputValue ?? 0n });
    if (node.kind === "ram") node.ramCells = cloneRamCells(spec.ramCells);
    ensureInputSlots(node, definitionById);
    return node;
  });
}
function renderScopeBar() {
  dom.scopeBack.disabled = !scopePath.length;
  dom.scopeBreadcrumbs.replaceChildren();
  const root = document.createElement("button"); root.type = "button"; root.className = `scope-crumb${scopePath.length ? "" : " current"}`;
  root.textContent = "Root"; root.addEventListener("click", () => navigateScope(-1)); dom.scopeBreadcrumbs.append(root);
  scopePath.forEach((scope, index) => {
    const separator = document.createElement("span"); separator.className = "scope-separator"; separator.textContent = "/";
    const button = document.createElement("button"); button.type = "button";
    button.className = `scope-crumb${index === scopePath.length - 1 ? " current" : ""}`;
    button.textContent = definitionById(scope.definitionId)?.name ?? `Chip ${scope.definitionId}`;
    if (index !== scopePath.length - 1) button.addEventListener("click", () => navigateScope(index));
    dom.scopeBreadcrumbs.append(separator, button);
  });
}
function reloadActiveScope() {
  if (!scopePath.length) setActiveNodes(rootNodes);
  else {
    const definition = activeDefinition();
    if (!definition) { scopePath = []; setActiveNodes(rootNodes); }
    else setActiveNodes(materializeDefinition(definition));
  }
  selectedIds.clear(); selectedWire = null; activeNodeId = null; wireToolAnchor = null;
  Object.assign(view, scopeViews.get(scopeKey()) ?? { x: 0, y: 0, zoom: 1 });
  renderScopeBar();
}
function enterCustomScope(node) {
  if (!node || node.kind !== "custom" || !definitionById(node.definitionId)) return false;
  return enterDefinitionScope(node.definitionId, node.documentId);
}
function enterDefinitionScope(definitionId, instanceId = null, { fromRoot = false } = {}) {
  if (!definitionById(definitionId)) return false;
  saveScopeView();
  if (fromRoot) scopePath = [];
  scopePath.push({ definitionId, instanceId });
  const restoreView = scopeViews.has(scopeKey());
  reloadActiveScope();
  if (runtime) readValues();
  render();
  if (!restoreView) fitView();
  else applyView();
  return true;
}
function navigateScope(index) {
  if (index >= scopePath.length - 1) return;
  saveScopeView();
  scopePath = index < 0 ? [] : scopePath.slice(0, index + 1);
  reloadActiveScope();
  if (runtime) readValues();
  render(); applyView();
}
function parentScope() {
  if (!scopePath.length) return false;
  navigateScope(scopePath.length - 2); return true;
}

function setStatus(kind, text) {
  dom.status.className = `status ${kind}`;
  dom.statusText.textContent = text;
}
async function loadWasm() {
  const response = await fetch("wasm/a_basic_circuit.wasm");
  if (!response.ok) throw new Error(`WASM request failed: ${response.status}`);
  const fallback = response.clone();
  const module = await WebAssembly.instantiateStreaming(response, {}).catch(async () =>
    WebAssembly.instantiate(await fallback.arrayBuffer(), {}));
  wasm = module.instance.exports;
  setSemanticWasm(wasm);
}
function liveStates() {
  const states = new Map();
  if (runtime) for (const [key, id] of runtime.stateKeys) {
    const value = wasm.abc_state(id);
    if (value <= 3) states.set(key, value);
  }
  return states;
}
function liveRamStates() {
  return runtime ? snapshotRuntimeRamStates(wasm, runtime) : new Map();
}
function rememberRuntime() {
  for (const [key, value] of liveStates()) retainedStates.set(key, value);
  for (const [key, cells] of liveRamStates()) retainedRamStates.set(key, cells);
  for (const node of rootNodes) if (node.kind === "oscillator") {
    retainedOscillators.set(node.documentId, { inputValue: node.inputValue, clockRunning: node.clockRunning });
  }
}
function updateHistoryControls() {
  dom.undoButton.disabled = !editHistory.canUndo;
  dom.redoButton.disabled = !editHistory.canRedo;
}
function recordEdit(options = {}) {
  if (!historyReady || applyingHistory) return;
  const historyOptions = { ...options };
  const commitScope = historyOptions.commitScope !== false;
  delete historyOptions.commitScope;
  if (commitScope && inDefinitionScope()) commitActiveScopeDefinition();
  if (editHistory.record(rootNodes, customDefinitions, historyOptions)) documentEpoch += 1;
  const ids = editHistory.referencedIds();
  for (const key of retainedStates.keys()) if (!ids.has(Number(key.slice(0, key.indexOf("/"))))) retainedStates.delete(key);
  for (const key of retainedRamStates.keys()) if (!ids.has(Number(key.slice(0, key.indexOf("/"))))) retainedRamStates.delete(key);
  for (const id of retainedOscillators.keys()) if (!ids.has(id)) retainedOscillators.delete(id);
  updateHistoryControls();
}

function updateCustomDefinition(definitionId, editedNodes, { rebuild = true } = {}) {
  const index = customDefinitions.findIndex((definition) => definition.id === definitionId);
  if (index < 0) throw new Error("Missing custom chip definition");
  const previous = customDefinitions[index];
  const oldLookup = (id) => id === definitionId ? previous : definitionById(id);
  const instanceWidths = new Map();
  for (const node of rootNodes) {
    if (node.kind !== "custom" || node.definitionId !== definitionId) continue;
    const resolved = resolveCustom(node, oldLookup);
    const explicit = new Map();
    for (const parameter of previous.parameters) {
      if (Object.hasOwn(node.widthParameters ?? {}, parameter.id)) {
        explicit.set(parameter.label, resolved.widths[parameter.index]);
      }
    }
    instanceWidths.set(node.documentId, explicit);
  }

  const rebuilt = createDefinition(editedNodes, previous.name, previous.id, definitionById);
  // Counter radix is presentation metadata rather than width semantics. Keep it
  // when the edited node still occupies the same template slot.
  for (let i = 0; i < rebuilt.nodes.length; i += 1) {
    if (rebuilt.nodes[i].kind === "clock" && editedNodes[i]?.inputRadix != null) {
      rebuilt.nodes[i].inputRadix = editedNodes[i].inputRadix;
    }
  }
  customDefinitions = customDefinitions.map((definition, i) => i === index ? rebuilt : definition);
  const newLookup = (id) => id === definitionId ? rebuilt : definitionById(id);

  for (const node of rootNodes) {
    if (node.kind !== "custom" || node.definitionId !== definitionId) continue;
    const desired = instanceWidths.get(node.documentId) ?? new Map();
    let parameters = {};
    for (const parameter of rebuilt.parameters) {
      const value = desired.get(parameter.label);
      if (value == null || value < parameter.min || value > parameter.max) continue;
      const trial = { ...node, widthParameters: { ...parameters, [parameter.id]: value } };
      try {
        resolveCustom(trial, newLookup);
        parameters = trial.widthParameters;
      } catch {
        // A structural edit may make a formerly independent parameter derived.
        // Keep the rest of the compatible instance overrides.
      }
    }
    node.widthParameters = parameters;
  }
  if (rebuild) rebuildRuntime({ commitScope: false });
  setStatus("settled", `updated ${rebuilt.name}`);
  return rebuilt;
}
function commitActiveScopeDefinition() {
  const definition = activeDefinition();
  if (!definition) return null;
  if (!nodes.length) return definition;
  const oldNodes = nodes;
  const oldIds = new Set(oldNodes.map((node) => node.documentId));
  const oldSelection = new Set(selectedIds);
  const oldActive = activeNodeId;
  const oldWire = selectedWire && { ...selectedWire };
  let edited = nodes;
  if (!nodes.some((node) => node.kind === "input") || !nodes.some((node) => node.kind === "output")) {
    edited = inferDefinitionSelection(nodes, new Set(nodes.map((node) => node.documentId)), definitionById);
  }
  const rebuilt = updateCustomDefinition(definition.id, edited, { rebuild: false });
  const idMap = new Map();
  edited.forEach((node, index) => {
    if (oldIds.has(node.documentId)) idMap.set(node.documentId, rebuilt.nodes[index].localId);
  });
  setActiveNodes(materializeDefinition(rebuilt));
  selectedIds = new Set([...oldSelection].flatMap((id) => idMap.has(id) ? [idMap.get(id)] : []));
  activeNodeId = oldActive != null ? idMap.get(oldActive) ?? null : null;
  selectedWire = oldWire && idMap.has(oldWire.targetId)
    ? { targetId: idMap.get(oldWire.targetId), pin: oldWire.pin }
    : null;
  lastNodePress = null;
  return rebuilt;
}
function applyEditHistory(redo = false) {
  if (!wasm || !historyReady) return false;
  if (gesture) { cancelGesture(); return false; }
  document.activeElement?.blur();
  const result = redo ? editHistory.redo() : editHistory.undo();
  if (!result) return false;
  rememberRuntime(); stopClockTimer(); documentEpoch += 1;
  applyingHistory = true;
  try {
    const previous = rootNodeIndex;
    rootNodes = result.nodes.map((saved) => {
      const current = previous.get(saved.documentId);
      if (current && !result.changedIds.has(saved.documentId)) return current;
      const node = Object.assign(makeNode(saved.documentId, saved.kind, saved.x, saved.y, saved.width, saved.definitionId), saved,
        { inputs: saved.inputs.map((c) => c && { ...c }), widthParameters: { ...saved.widthParameters } });
      if (node.kind === "ram") node.ramCells = cloneRamCells(saved.ramCells);
      if (node.kind === "oscillator") Object.assign(node, retainedOscillators.get(node.documentId) ?? {});
      return node;
    });
    customDefinitions = [...result.definitions];
    if (scopePath.some((scope) => !definitionById(scope.definitionId))) scopePath = [];
    reloadActiveScope();
    selectedIds = !scopePath.length ? new Set(rootNodes.filter((node) => result.changedIds.has(node.documentId)).map((node) => node.documentId)) : new Set();
    selectedWire = null; activeNodeId = [...selectedIds].at(-1) ?? null;
    rebuildRuntime({ commitScope: false, record: false });
    if (result.effect) {
      const node = rootNodeIndex.get(result.effect.documentId), handle = runtime?.handles.get(result.effect.documentId);
      if (node?.kind === "clock" && handle) {
        node.inputRadix = result.effect.radix;
        setRuntimeCounter(wasm, handle, maskValue(result.effect.value, node.width)); runSimulation();
      }
    }
  } finally { applyingHistory = false; updateHistoryControls(); }
  dom.canvas.focus({ preventScroll: true });
  return true;
}
function saveProjectFile() {
  if (!wasm) return;
  cancelGesture(); document.activeElement?.blur();
  try {
    const text = serializeProject(rootNodes, customDefinitions, {
      view: { ...(scopeViews.get("root") ?? view) },
      states: liveStates(),
      ramStates: liveRamStates(),
    });
    const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
    const link = document.createElement("a"); link.href = url; link.download = projectFileName;
    document.body.append(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (error) { setStatus("error", error.message); }
}
function safeDownloadName(value, fallback) {
  const stem = value.trim().replace(/[<>:"/\\|?*\x00-\x1f]+/g, "_").replace(/[. ]+$/g, "").slice(0, 80);
  return stem || fallback;
}
function downloadText(text, fileName) {
  const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
  const link = document.createElement("a"); link.href = url; link.download = fileName;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function suggestedModuleName(definitions) {
  if (!definitions.length) return "chips";
  const namespaces = definitions.map((definition) => definition.name.includes(".") ? definition.name.split(".", 1)[0] : null);
  if (namespaces[0] && namespaces.every((value) => value === namespaces[0])) return namespaces[0];
  return definitions.length === 1 ? definitions[0].name : "chips";
}
function updateModuleExportControl() {
  for (const id of [...moduleExportIds]) if (!definitionById(id)) moduleExportIds.delete(id);
  dom.exportChipButton.disabled = moduleExportIds.size === 0;
  dom.exportChipButton.title = moduleExportIds.size ? `Export ${moduleExportIds.size} selected chip${moduleExportIds.size === 1 ? "" : "s"} as a module` : "Mark palette chips with Pack first";
}
function exportChipModule() {
  if (!wasm) return;
  cancelGesture(); document.activeElement?.blur();
  try {
    if (inDefinitionScope()) commitActiveScopeDefinition();
    const definitions = [...moduleExportIds].map((id) => definitionById(id)).filter(Boolean);
    if (!definitions.length) throw new Error("Mark at least one palette chip with Pack");
    const suggested = suggestedModuleName(definitions);
    const moduleName = window.prompt("Chip module name", suggested)?.trim().slice(0, 80);
    if (!moduleName) return;
    const text = serializeChipBundle(definitions.map((definition) => definition.id), customDefinitions, { moduleName });
    downloadText(text, `${safeDownloadName(moduleName, "chips")}.abc-chips.json`);
    setStatus("settled", `exported ${moduleName} · ${definitions.length} chip${definitions.length === 1 ? "" : "s"}`);
  } catch (error) { setStatus("error", error.message); }
}
async function importChipFile(file) {
  if (!wasm || !file) return;
  const epoch = documentEpoch;
  try {
    if (file.size > 4 * 1024 * 1024) throw new Error("Chip file exceeds 4 MiB");
    const text = await file.text();
    if (epoch !== documentEpoch) return;
    const loaded = deserializeChipBundle(text, { definitions: customDefinitions, nextDefinitionId });
    const added = loaded.definitions.length;
    if (added) {
      customDefinitions.push(...loaded.definitions);
      nextDefinitionId = loaded.nextDefinitionId;
      renderCustomPalette();
      recordEdit({ commitScope: false });
    }
    const roots = loaded.rootDefinitionIds.map((id) => definitionById(id));
    if (roots.some((root) => !root)) throw new Error("Imported module export is missing");
    setStatus("settled", added ? `loaded ${loaded.moduleName} · ${roots.length} export${roots.length === 1 ? "" : "s"} · ${added} definition${added === 1 ? "" : "s"} added`
      : `${loaded.moduleName} module already available`);
  } catch (error) { setStatus("error", error.message); }
}
async function openProjectFile(file) {
  if (!wasm || !file) return;
  const epoch = documentEpoch;
  try {
    if (file.size > 32 * 1024 * 1024) throw new Error("Project file exceeds 32 MiB");
    const text = await file.text();
    if (epoch !== documentEpoch) return;
    const loaded = deserializeProject(text, { nextDocumentId, nextDefinitionId });
    cancelGesture(); rememberRuntime(); stopClockTimer();
    pendingInputValues.clear(); simulationToken += 1; simulationRunning = false;
    rootNodes = loaded.nodes; customDefinitions = loaded.definitions;
    nextDocumentId = loaded.nextDocumentId; nextDefinitionId = loaded.nextDefinitionId;
    scopePath = []; setActiveNodes(rootNodes); selectedIds.clear(); selectedWire = null; activeNodeId = null; runtime = null;
    retainedStates.clear(); retainedRamStates.clear(); retainedOscillators.clear();
    for (const [key, value] of loaded.states) retainedStates.set(key, value);
    for (const [key, cells] of loaded.ramStates) retainedRamStates.set(key, cells);
    scopeViews.set("root", { ...loaded.view }); Object.assign(view, loaded.view); projectFileName = file.name;
    documentEpoch += 1; clocks.sync([], performance.now());
    rebuildRuntime({ commitScope: false });
  } catch (error) { setStatus("error", error.message); }
}
function worldPoint(clientX, clientY) {
  const rect = dom.canvas.getBoundingClientRect();
  return { x: (clientX - rect.left - view.x) / view.zoom, y: (clientY - rect.top - view.y) / view.zoom };
}
function applyView() {
  dom.nodeLayer.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.zoom})`;
  const major = 80 * view.zoom, minor = 16 * view.zoom;
  dom.canvas.style.backgroundSize = `${major}px ${major}px, ${major}px ${major}px, ${minor}px ${minor}px, ${minor}px ${minor}px`;
  dom.canvas.style.backgroundPosition = `${view.x}px ${view.y}px`;
  dom.zoomLabel.textContent = `${Math.round(view.zoom * 100)}%`;
  positionWireTools();
}
function zoomAt(zoom, clientX, clientY) {
  const before = worldPoint(clientX, clientY);
  const rect = dom.canvas.getBoundingClientRect();
  view.zoom = Math.max(0.1, Math.min(3, zoom));
  view.x = clientX - rect.left - before.x * view.zoom;
  view.y = clientY - rect.top - before.y * view.zoom;
  applyView();
  if (gesture) gesture.move(gesture.last);
}
function zoomCenter(factor) {
  const rect = dom.canvas.getBoundingClientRect();
  zoomAt(view.zoom * factor, rect.left + rect.width / 2, rect.top + rect.height / 2);
}
function fitView() {
  cancelGesture();
  if (!nodes.length) { Object.assign(view, { x: 0, y: 0, zoom: 1 }); applyView(); return; }
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const node of nodes) {
    const el = nodeElements.get(node.documentId);
    left = Math.min(left, node.x); top = Math.min(top, node.y);
    right = Math.max(right, node.x + (el?.offsetWidth ?? 200));
    bottom = Math.max(bottom, node.y + (el?.offsetHeight ?? 120));
  }
  const width = dom.canvas.clientWidth, height = dom.canvas.clientHeight;
  view.zoom = Math.max(0.1, Math.min(1, (width - 90) / (right - left), (height - 90) / (bottom - top)));
  view.x = width / 2 - (left + right) / 2 * view.zoom;
  view.y = height / 2 - (top + bottom) / 2 * view.zoom;
  applyView();
}
function arrangeCurrentScope() {
  if (nodes.length < 2) return;
  cancelGesture(); document.activeElement?.blur();
  const sizes = new Map([...nodeElements].map(([id, el]) => [id, {
    width: el.offsetWidth || 200,
    height: el.offsetHeight || 150,
  }]));
  const positions = autoLayout(nodes, sizes);
  let changed = false;
  for (const node of nodes) {
    const position = positions.get(node.documentId);
    if (!position || (node.x === position.x && node.y === position.y)) continue;
    node.x = position.x; node.y = position.y; changed = true;
  }
  if (!changed) return;
  recordEdit();
  render(); fitView();
  setStatus("settled", `arranged ${nodes.length} chips`);
}
function newDocumentNode(kind, x, y, width = 1, definitionId = null) {
  const node = makeNode(nextDocumentId++, kind, x, y, width, definitionId);
  ensureInputSlots(node, definitionById);
  nodes.push(node); nodeIndex.set(node.documentId, node);
  return node;
}
function newNode(kind, x, y, width = 1, definitionId = null, appearance = {}) {
  const node = newDocumentNode(kind, x, y, width, definitionId);
  if (kind === "display") {
    node.ledMode = appearance.ledMode ?? node.ledMode;
    node.ledColor = appearance.ledColor ?? node.ledColor;
  }
  selectedIds = new Set([node.documentId]); selectedWire = null;
  activeNodeId = node.documentId;
  rebuildRuntime();
}
function removeNodes(ids) {
  if (!ids.size) return;
  rememberRuntime();
  const next = nodes.filter((node) => !ids.has(node.documentId));
  for (const node of next) node.inputs = node.inputs.map((c) => c && ids.has(c.sourceId) ? null : c);
  setActiveNodes(next);
  for (const id of ids) selectedIds.delete(id);
  rebuildRuntime();
}
function removeWire(targetId, pin) {
  const target = nodeById(targetId);
  if (!target?.inputs[pin]) return;
  target.inputs[pin] = null; selectedWire = null;
  rebuildRuntime();
}
function deleteSelection() {
  if (selectedWire) removeWire(selectedWire.targetId, selectedWire.pin);
  else removeNodes(new Set(selectedIds));
}
function focusNode(id) {
  activeNodeId = id;
  for (const [nodeId, el] of nodeElements) {
    el.style.zIndex = String(nodeDepth(nodeId) + 2);
    el.classList.toggle("foreground", nodeId === id);
  }
  updateWireDepth();
}
function nodeDepth(id) { return id === activeNodeId ? 40 : selectedIds.has(id) ? 20 : 0; }
function updateWireDepth() {
  for (const svg of dom.wireLayer.querySelectorAll(".wire-svg[data-target-id]")) {
    const targetId = Number(svg.dataset.targetId), pin = Number(svg.dataset.pin);
    const c = nodeById(targetId)?.inputs[pin];
    const selected = selectedWire?.targetId === targetId && selectedWire.pin === pin;
    svg.style.zIndex = String(selected ? 110 : 1 + Math.max(nodeDepth(targetId), c ? nodeDepth(c.sourceId) : 0));
  }
}
function positionWireTools() {
  if (dom.wireColorTools.hidden || !wireToolAnchor) return;
  const x = wireToolAnchor.x * view.zoom + view.x;
  const y = wireToolAnchor.y * view.zoom + view.y;
  const marginX = 86;
  dom.wireColorTools.style.left = `${Math.max(marginX, Math.min(dom.canvas.clientWidth - marginX, x))}px`;
  dom.wireColorTools.style.top = `${Math.max(48, Math.min(dom.canvas.clientHeight - 12, y))}px`;
}
function setSelectedWireColor(color) {
  const c = selectedWire && nodeById(selectedWire.targetId)?.inputs[selectedWire.pin];
  if (!c || (color != null && !/^#[0-9a-fA-F]{6}$/.test(color))) return;
  if (color == null) delete c.color;
  else c.color = color;
  renderWires(); updateSelection(); recordEdit({ mergeKey: color == null ? null : `wire:${selectedWire.targetId}/${selectedWire.pin}` });
}
function copySelection() {
  const text = serializeSelection(nodes, selectedIds, customDefinitions);
  clipboardText = text; pasteCount = 0; pasteAnchorKey = "";
  return text;
}
function pasteSelection(text) {
  if (!wasm || !text) return;
  cancelGesture();
  const rect = dom.canvas.getBoundingClientRect();
  const cursor = pointerPosition && pointInside(dom.canvas, pointerPosition.x, pointerPosition.y)
    ? pointerPosition : { x: rect.left + rect.width / 2 - 100, y: rect.top + rect.height / 2 - 40 };
  const anchor = worldPoint(cursor.x, cursor.y);
  const key = `${Math.round(anchor.x)},${Math.round(anchor.y)}`;
  const count = text === clipboardText && key === pasteAnchorKey ? pasteCount + 1 : 1;
  const pasted = deserializeSelection(text, { nextDocumentId, nextDefinitionId, definitions: customDefinitions,
    x: anchor.x + count * 24 / view.zoom, y: anchor.y + count * 24 / view.zoom });
  customDefinitions.push(...pasted.definitions);
  nodes.push(...pasted.nodes);
  nextDocumentId = pasted.nextDocumentId; nextDefinitionId = pasted.nextDefinitionId;
  clipboardText = text; pasteCount = count; pasteAnchorKey = key;
  selectedIds = new Set(pasted.nodes.map((node) => node.documentId)); selectedWire = null;
  activeNodeId = pasted.nodes.at(-1)?.documentId ?? null;
  rebuildRuntime();
  dom.canvas.focus({ preventScroll: true });
}
window.addEventListener("copy", (event) => {
  if (isEditable(event.target) || isEditable(document.activeElement) || !selectedIds.size || gesture) return;
  try {
    const text = copySelection();
    event.clipboardData.setData("text/plain", text); event.preventDefault();
  } catch (error) { setStatus("error", error.message); }
});
window.addEventListener("paste", (event) => {
  if (isEditable(event.target) || isEditable(document.activeElement)) return;
  const text = event.clipboardData?.getData("text/plain");
  if (!text) return;
  event.preventDefault();
  try { pasteSelection(text); } catch (error) { setStatus("error", error.message); }
});
function stopClockTimer() {
  if (clockTimer != null) clearTimeout(clockTimer);
  clockTimer = null;
}
function scheduleClocks() {
  stopClockTimer();
  clocks.sync(rootNodes, performance.now());
  if (!runtime || simulationRunning || document.hidden) return;
  const delay = clocks.delay(performance.now());
  if (delay == null) return;
  clockTimer = setTimeout(() => {
    clockTimer = null;
    if (!runtime || simulationRunning || document.hidden) return;
    const due = clocks.due(performance.now());
    for (const node of due) {
      const previous = node.inputValue;
      node.inputValue = toggleClockLevel(node.inputValue);
      setRuntimeInput(wasm, runtime.handles.get(node.documentId), node.inputValue, previous);
    }
    if (due.length) runSimulation(); else scheduleClocks();
  }, delay);
}
function setClockRunning(node, running) {
  node.clockRunning = running;
  scheduleClocks(); updateSignals();
}
function pulseClock(node) {
  if (!runtime || simulationRunning || node.clockRunning) return;
  stopClockTimer();
  const previous = node.inputValue;
  node.inputValue = toggleClockLevel(node.inputValue);
  setRuntimeInput(wasm, runtime.handles.get(node.documentId), node.inputValue, previous);
  runSimulation();
}
function flushPendingInputs() {
  if (!pendingInputValues.size) return false;
  for (const [id, value] of pendingInputValues) {
    const node = rootNodeIndex.get(id), handle = runtime.handles.get(id);
    if (node?.kind === "input" && handle) setRuntimeInput(wasm, handle, maskValue(value, node.width));
  }
  pendingInputValues.clear(); runSimulation(); return true;
}
function runtimeHandleForNode(nodeId) {
  if (!runtime) return null;
  if (!scopePath.length) return runtime.handles.get(nodeId) ?? null;
  let handle = runtime.handles.get(scopePath[0].instanceId) ?? null;
  for (let depth = 0; depth < scopePath.length; depth += 1) {
    if (!handle?.children) return null;
    if (depth === scopePath.length - 1) return handle.children.get(nodeId) ?? null;
    handle = handle.children.get(scopePath[depth + 1].instanceId) ?? null;
  }
  return null;
}
function rebuildRuntime({ commitScope = true, record = true } = {}) {
  if (!wasm) return;
  if (commitScope && inDefinitionScope()) {
    try {
      commitActiveScopeDefinition();
    } catch (error) {
      // Scoped edits are optimistic UI mutations. If semantic validation rejects
      // one (for example a recursive custom dependency), restore the last
      // canonical definition immediately instead of leaving an invalid draft on
      // the live canvas.
      const currentView = { ...view };
      reloadActiveScope();
      Object.assign(view, currentView);
      if (runtime) readValues();
      render(); applyView();
      setStatus("error", error instanceof Error ? error.message : String(error));
      return false;
    }
  }
  rememberRuntime();
  stopClockTimer();
  pendingInputValues.clear();
  cancelGesture(); simulationToken += 1; simulationRunning = false;
  lastWirePress = null;
  rootNodeIndex = new Map(rootNodes.map((n) => [n.documentId, n]));
  nodeIndex = new Map(nodes.map((n) => [n.documentId, n]));
  if (selectedWire && !nodeById(selectedWire.targetId)?.inputs[selectedWire.pin]) selectedWire = null;
  try {
    for (const node of rootNodes) ensureInputSlots(node, definitionById);
    runtime = compileCircuit(wasm, rootNodes, customDefinitions, runtime, retainedStates, retainedRamStates);
    render(); runSimulation();
  } catch (error) {
    runtime = null;
    for (const node of nodes) { node.values = []; node.outputValues = []; }
    render(); console.error(error); setStatus("error", error.message);
  }
  if (record) recordEdit({ commitScope: false });
  return Boolean(runtime);
}
function readValues() {
  for (const node of rootNodes) {
    const handle = runtime?.handles.get(node.documentId);
    if (!handle) continue;
    node.outputValues = handle.outputs.map((bus) => readBus(wasm, bus));
    if (node.kind === "display") {
      node.channelValues = handle.inputs.map((input) => readBus(wasm, input.bus));
      node.values = Array.from({ length: node.width }, (_, bit) => node.channelValues.some((channel) => channel[bit]));
    } else node.values = readBus(wasm, handle.probe);
  }
  if (scopePath.length) for (const node of nodes) {
    const handle = runtimeHandleForNode(node.documentId);
    if (!handle) { node.values = []; node.outputValues = []; continue; }
    node.outputValues = handle.outputs.map((bus) => readBus(wasm, bus));
    node.values = handle.probe ? readBus(wasm, handle.probe) : [];
  }
}
function updateContacts() {
  const outgoing = new Map();
  const contact = (port, c, problem) => {
    if (!port) return;
    port.classList.toggle("connected", Boolean(c));
    if (!c) { port.style.removeProperty("--pin-color"); return; }
    const on = nodeById(c.sourceId)?.outputValues?.[c.sourcePort]?.some(Boolean);
    port.style.setProperty("--pin-color", problem ? "var(--danger)" : c.color ?? (on ? "var(--signal-on)" : "var(--signal-off)"));
  };
  for (const target of nodes) target.inputs.forEach((c, pin) => {
    const problem = c && connectionProblem(target, pin, nodeById(c.sourceId), c.sourcePort, definitionById);
    contact(nodeElements.get(target.documentId)?.querySelector(`.input-port[data-pin="${pin}"]`), c, problem);
    if (c) {
      const key = `${c.sourceId}/${c.sourcePort}`;
      if (!outgoing.has(key) || (selectedWire?.targetId === target.documentId && selectedWire.pin === pin)) outgoing.set(key, { c, problem });
    }
  });
  for (const [id, el] of nodeElements) for (const port of el.querySelectorAll(".output-port")) {
    const attached = outgoing.get(`${id}/${port.dataset.port}`);
    contact(port, attached?.c, attached?.problem);
  }
}
function updateSignals() {
  for (const node of nodes) {
    const el = nodeElements.get(node.documentId);
    if (!el) continue;
    for (const led of el.querySelectorAll(".square-led")) {
      const bit = Number(led.dataset.bit);
      const on = node.kind === "input" ? bitValue(node.inputValue, bit) === 1 : Boolean(node.values[bit]);
      led.classList.toggle("on", on);
      const xy = node.kind === "display" ? `(${(node.width - 1 - bit) % node.ledColumns}, ${Math.floor((node.width - 1 - bit) / node.ledColumns)}) · ` : "";
      led.title = `${xy}bit ${bit}: ${on ? 1 : 0}`;
      if (node.kind === "display") {
        const color = node.ledMode === "rgb" ? `rgb(${[0,1,2].map((c) => node.channelValues?.[c]?.[bit] ? 255 : 0).join(",")})` : node.ledColor;
        led.style.setProperty("--led-color", color);
      }
      if (led.tagName === "BUTTON") { led.disabled = simulationRunning; led.setAttribute("aria-pressed", String(on)); }
    }
    const value = el.querySelector(".node-value");
    if (value) {
      const formatted = formatBusValue(node.kind === "input" ? node.inputValue : busValue(node.values), node.width,
        node.inputRadix ?? 16);
      if (value.tagName === "INPUT") {
        if (document.activeElement !== value) { value.value = formatted; value.classList.remove("invalid"); }
        value.disabled = !runtime || (inDefinitionScope() && node.kind === "clock");
      } else value.textContent = formatted;
    }
    if (node.kind === "oscillator") {
      const toggle = el.querySelector(".clock-toggle"), pulse = el.querySelector(".clock-pulse");
      if (toggle) { toggle.textContent = node.clockRunning ? "Pause" : "Start"; toggle.setAttribute("aria-pressed", String(node.clockRunning)); }
      if (pulse) {
        pulse.disabled = !runtime || simulationRunning || node.clockRunning;
      }
      const level = el.querySelector(".clock-level");
      if (level) {
        level.textContent = `${node.inputValue ? "HIGH" : "LOW"} · ${node.inputValue}`;
        level.classList.toggle("on", Boolean(node.inputValue));
      }
    }
    if (node.kind === "ram") {
      for (const input of el.querySelectorAll(".ram-cell-value")) {
        const address = BigInt(input.dataset.address);
        if (document.activeElement !== input) {
          input.value = formatBusValue(displayedRamCell(node, address), node.width, 16);
          input.classList.remove("invalid");
        }
        input.disabled = simulationRunning;
      }
    }
  }
  for (const group of dom.wireLayer.querySelectorAll(".wire-group")) {
    const c = nodeById(Number(group.dataset.targetId))?.inputs[Number(group.dataset.pin)];
    const source = c && nodeById(c.sourceId);
    group.classList.toggle("on", !group.classList.contains("invalid") && Boolean(source?.outputValues?.[c.sourcePort]?.some(Boolean)));
  }
  updateContacts();
}
function runSimulation() {
  if (!wasm || !runtime) return;
  stopClockTimer();
  const token = ++simulationToken;
  simulationRunning = true; setStatus("pending", "propagating"); updateSignals();
  const step = () => {
    if (token !== simulationToken) return;
    try {
      const result = wasm.abc_run(32);
      if (result === 2) throw new Error("WASM simulation failed");
      readValues();
      if (result === 1) {
        simulationRunning = false;
        const count = runtime.diagnostics.length;
        setStatus(count ? "warning" : "settled", count ? `${count} wire warning${count === 1 ? "" : "s"}` : "settled");
      }
      updateSignals();
      if (result === 0) requestAnimationFrame(step);
      else if (!flushPendingInputs()) scheduleClocks();
    } catch (error) {
      for (const node of rootNodes) if (node.kind === "oscillator") node.clockRunning = false;
      stopClockTimer();
      simulationRunning = false; setStatus("error", error.message); console.error(error); updateSignals();
    }
  };
  step();
}
function clearCircuit() {
  rememberRuntime();
  stopClockTimer(); pendingInputValues.clear(); documentEpoch += 1; activeNodeId = null;
  clocks.sync([], performance.now());
  cancelGesture(); simulationToken += 1; simulationRunning = false; wasm.abc_reset();
  scopePath = []; rootNodes = []; setActiveNodes(rootNodes); rootNodeIndex.clear(); selectedIds.clear(); selectedWire = null; lastWirePress = null;
  runtime = null;
  renderScopeBar(); render(); fitView(); setStatus("settled", "empty"); recordEdit();
}
function loadDemo() {
  rememberRuntime();
  stopClockTimer(); pendingInputValues.clear(); documentEpoch += 1; activeNodeId = null;
  clocks.sync([], performance.now());
  cancelGesture(); scopePath = []; rootNodes = []; setActiveNodes(rootNodes); selectedIds.clear(); selectedWire = null;
  runtime = null;
  const a = newDocumentNode("input", 50, 90, 8);
  const b = newDocumentNode("input", 50, 290, 8);
  const and = newDocumentNode("and2", 360, 190, 8);
  const out = newDocumentNode("output", 670, 120, 8);
  const display = newDocumentNode("display", 670, 320, 8);
  a.inputValue = 0x55n; b.inputValue = 0x0fn;
  and.inputs[0] = connection(a.documentId); and.inputs[1] = connection(b.documentId);
  out.inputs[0] = connection(and.documentId); display.inputs[0] = connection(and.documentId);
  renderScopeBar(); rebuildRuntime({ commitScope: false }); fitView();
}
function changeWidth(node, field, value) {
  const split = node.kind === "split" || node.kind === "join";
  const min = field === "width" && split ? 2 : 1;
  const max = field === "addressWidth"
    ? node.kind === "ram" ? MAX_RAM_ADDRESS_WIDTH : MAX_ADDRESS_WIDTH
    : field === "splitWidth" ? node.width - 1 : MAX_WIDTH;
  if (!validWidth(value, min, max)) throw new Error(`Width must be an integer from ${min} to ${max}`);
  if (node.kind === "ram" && field === "addressWidth") {
    const oldLimit = ramAddressLimit(node.addressWidth);
    const newLimit = ramAddressLimit(value);
    const base = node.ramBase ?? 0n, end = node.ramEnd ?? oldLimit;
    if (!(base === 0n && end === oldLimit) && end > newLimit) {
      throw new Error(`Mapped range does not fit a ${value}-bit RAM address bus`);
    }
    node.addressWidth = value;
    setRamRange(node, base === 0n && end === oldLimit ? 0n : base,
      base === 0n && end === oldLimit ? newLimit : end);
    rebuildRuntime();
    return;
  }
  node[field] = value;
  if (field === "width") {
    node.inputValue = maskValue(node.inputValue, value);
    if (split) node.splitWidth = Math.min(node.splitWidth, value - 1);
    if (node.kind === "ram") {
      const cells = new Map();
      for (const [address, word] of cloneRamCells(node.ramCells)) {
        const masked = maskValue(word, value);
        if (masked !== 0n) cells.set(address, masked);
      }
      node.ramCells = cells;
    }
  }
  rebuildRuntime();
}
function toggleInputBit(node, bit) {
  if (inDefinitionScope() || simulationRunning || !runtime || node.kind !== "input") return;
  node.inputValue ^= 1n << BigInt(bit);
  setRuntimeInput(wasm, runtime.handles.get(node.documentId), node.inputValue); runSimulation(); recordEdit();
}
function setInputValue(node, text) {
  if (inDefinitionScope()) throw new Error("Custom chip interface inputs are driven by the parent circuit");
  if (!runtime) throw new Error("Fix the circuit before changing inputs");
  const { value, radix } = parseInputValue(text, node.width);
  const previous = node.inputValue;
  node.inputValue = value; node.inputRadix = radix;
  if (simulationRunning) { pendingInputValues.set(node.documentId, value); recordEdit(); return; }
  setRuntimeInput(wasm, runtime.handles.get(node.documentId), value, previous); runSimulation(); recordEdit();
}
function setCounterValue(node, text) {
  if (inDefinitionScope()) throw new Error("Counter state is read-only while editing a custom-chip scope");
  const handle = runtimeHandleForNode(node.documentId);
  if (!handle) throw new Error("Fix the circuit before changing the counter");
  const { value, radix } = parseInputValue(text, node.width);
  const before = { documentId: node.documentId, value: busValue(readBus(wasm, handle.outputs[0])), radix: node.inputRadix ?? 16 };
  setRuntimeCounter(wasm, handle, value); node.inputRadix = radix;
  recordEdit({ effect: { before, after: { documentId: node.documentId, value, radix } } });
  runSimulation();
}
function widthControl(node, label, field, value, min, max, callback, step = 1, unit = "bits") {
  const container = document.createElement("label"); container.className = "width-control";
  container.addEventListener("pointerdown", (event) => event.stopPropagation());
  const caption = document.createElement("span"); caption.textContent = label; caption.title = label;
  const input = document.createElement("input"); input.className = "width-input";
  input.type = "number"; input.min = String(min); input.max = String(max); input.step = String(step);
  input.defaultValue = String(value); input.dataset.field = field;
  input.setAttribute("aria-label", `${label}${unit === "bits" ? " width" : ""} #${node.documentId}`);
  if (unit === "bits") input.setAttribute("list", "widthChoices");
  input.title = `${label}: ${min}–${max} ${unit} (Enter to apply)`;
  input.addEventListener("pointerdown", (event) => event.stopPropagation());
  input.addEventListener("keydown", (event) => { if (event.key === "Enter") input.blur(); });
  input.addEventListener("change", () => {
    try { callback(Number(input.value)); }
    catch (error) { input.value = input.defaultValue; setStatus("error", error.message); }
  });
  container.append(caption, input); return container;
}
function widthFields(node) {
  if (node.kind === "oscillator") return [{ label: "Frequency", field: "clockHz", value: node.clockHz,
    min: MIN_CLOCK_HZ, max: MAX_CLOCK_HZ, step: 0.1, unit: "Hz", apply(value) {
      if (!validClockHz(value)) throw new Error(`Frequency must be ${MIN_CLOCK_HZ}–${MAX_CLOCK_HZ} Hz`);
      node.clockHz = value; scheduleClocks(); updateWidthControls(nodeElements.get(node.documentId).querySelector(".node-settings"), node); recordEdit();
    } }];
  if (node.kind === "display") return [
    { label: "X", field: "ledColumns", value: node.ledColumns, min: 1, max: 64, unit: "pixels", apply(value) {
      resizeDisplay(node, value, node.ledRows); rebuildRuntime();
    } },
    { label: "Y", field: "ledRows", value: node.ledRows, min: 1, max: 64, unit: "pixels", apply(value) {
      resizeDisplay(node, node.ledColumns, value); rebuildRuntime();
    } },
  ];
  if (node.kind === "custom") {
    const resolved = resolveCustom(node, definitionById);
    return resolved.definition.parameters.map((p) => ({ label: p.label, field: p.id,
      value: resolved.widths[p.index], min: p.min, max: p.max, apply(value) {
        changeCustomWidth(node, p.id, value, definitionById); rebuildRuntime();
      } }));
  }
  const fields = [], split = ["split", "join"].includes(node.kind);
  const add = (label, field, min, max) => fields.push({ label, field, value: node[field], min, max,
    apply: (value) => changeWidth(node, field, value) });
  if (node.kind !== "decoder") add(split ? "Total" : "Data", "width", split ? 2 : 1, MAX_WIDTH);
  if (["mux", "demux", "decoder", "ram"].includes(node.kind)) {
    add("Address", "addressWidth", 1, node.kind === "ram" ? MAX_RAM_ADDRESS_WIDTH : MAX_ADDRESS_WIDTH);
  }
  if (split) add("Low bits", "splitWidth", 1, node.width - 1);
  return fields;
}
function updateWidthControls(settings, node) {
  const fields = widthFields(node);
  if (!fields.length) { settings.textContent = "Fixed-width ports"; return; }
  const existing = new Map([...settings.querySelectorAll(".width-input")].map((input) => [input.dataset.field, input]));
  for (const { label, field, value, min, max, apply, step = 1, unit = "bits" } of fields) {
    const input = existing.get(field);
    if (!input) { settings.append(widthControl(node, label, field, value, min, max, apply, step, unit)); continue; }
    existing.delete(field);
    const changed = input.defaultValue !== String(value);
    input.defaultValue = String(value);
    if (changed || document.activeElement !== input) input.value = String(value);
    input.min = String(min); input.max = String(max);
    input.title = `${label}: ${min}–${max} ${unit} (Enter to apply)`;
    const caption = input.previousElementSibling;
    caption.textContent = label; caption.title = label;
  }
  for (const input of existing.values()) input.closest(".width-control").remove();
  if (node.kind === "display") updateLedControls(settings, node);
  if (node.kind === "ram") updateRamMapControls(settings, node);
}
function updateLedControls(settings, node) {
  let controls = settings.querySelector(".led-controls");
  if (!controls) {
    controls = document.createElement("div"); controls.className = "led-controls";
    controls.addEventListener("pointerdown", (event) => event.stopPropagation());
    const mode = document.createElement("select"); mode.className = "led-mode";
    mode.setAttribute("aria-label", `LED mode #${node.documentId}`);
    for (const [value, label] of [["mono", "Single color"], ["rgb", "RGB · R + G + B"]]) {
      const option = document.createElement("option"); option.value = value; option.textContent = label; mode.append(option);
    }
    mode.addEventListener("change", () => { node.ledMode = mode.value; rebuildRuntime(); });
    const colors = document.createElement("div"); colors.className = "led-colors";
    for (const [name, color] of [["Red", "#ff0000"], ["Green", "#00ff00"], ["Blue", "#0000ff"], ["Amber", "#ffd36f"], ["Cyan", "#00ffff"], ["Magenta", "#ff00ff"], ["White", "#ffffff"]]) {
      const button = document.createElement("button"); button.type = "button"; button.className = "color-swatch";
      button.style.setProperty("--swatch", color); button.dataset.color = color;
      button.title = name; button.setAttribute("aria-label", `${name} LED #${node.documentId}`);
      button.addEventListener("click", () => { node.ledColor = color; updateLedControls(settings, node); updateSignals(); recordEdit(); });
      colors.append(button);
    }
    const custom = document.createElement("input"); custom.type = "color"; custom.className = "led-color";
    custom.setAttribute("aria-label", `Custom LED color #${node.documentId}`); custom.title = "Custom LED color";
    custom.addEventListener("input", () => { node.ledColor = custom.value; updateLedControls(settings, node); updateSignals(); recordEdit({ mergeKey: `led:${node.documentId}` }); });
    colors.append(custom); controls.append(mode, colors); settings.append(controls);
  }
  controls.querySelector(".led-mode").value = node.ledMode;
  controls.querySelector(".led-colors").hidden = node.ledMode === "rgb";
  controls.querySelector(".led-color").value = node.ledColor;
  for (const button of controls.querySelectorAll(".color-swatch")) button.setAttribute("aria-pressed", String(button.dataset.color === node.ledColor));
}

function updateRamMapControls(settings, node) {
  let controls = settings.querySelector(".ram-map-controls");
  if (!controls) {
    controls = document.createElement("div"); controls.className = "ram-map-controls";
    controls.addEventListener("pointerdown", (event) => event.stopPropagation());
    const make = (label, field) => {
      const wrapper = document.createElement("label"); wrapper.className = "ram-map-control";
      const caption = document.createElement("span"); caption.textContent = label;
      const input = document.createElement("input"); input.type = "text"; input.spellcheck = false;
      input.className = "ram-map-input"; input.dataset.ramMap = field;
      input.setAttribute("aria-label", `RAM ${label.toLowerCase()} #${node.documentId}`);
      input.title = "Decimal, 0x hexadecimal, 0b binary or 0o octal; Enter to apply";
      input.addEventListener("keydown", (event) => { if (event.key === "Enter") input.blur(); });
      input.addEventListener("change", () => {
        const start = controls.querySelector('[data-ram-map="start"]');
        const end = controls.querySelector('[data-ram-map="end"]');
        try {
          const base = parseInputValue(start.value, node.addressWidth).value;
          const last = parseInputValue(end.value, node.addressWidth).value;
          setRamRange(node, base, last);
          node.ramPageAddress = base;
          rebuildRuntime();
        } catch (error) {
          start.value = formatBusValue(node.ramBase, node.addressWidth, 16);
          end.value = formatBusValue(node.ramEnd, node.addressWidth, 16);
          setStatus("error", error.message);
        }
      });
      wrapper.append(caption, input); controls.append(wrapper);
    };
    make("Range start", "start"); make("Range end", "end"); settings.append(controls);
  }
  const start = controls.querySelector('[data-ram-map="start"]');
  const end = controls.querySelector('[data-ram-map="end"]');
  if (document.activeElement !== start) start.value = formatBusValue(node.ramBase, node.addressWidth, 16);
  if (document.activeElement !== end) end.value = formatBusValue(node.ramEnd, node.addressWidth, 16);
}

const RAM_PAGE_ROWS = 8n;
function ramPageStart(node) {
  const base = node.ramBase ?? 0n, end = node.ramEnd ?? ramAddressLimit(node.addressWidth);
  let start = typeof node.ramPageAddress === "bigint" ? node.ramPageAddress : base;
  if (start < base) start = base;
  if (start > end) start = end;
  node.ramPageAddress = start;
  return start;
}
function displayedRamCell(node, address) {
  const handle = !inDefinitionScope() ? runtimeHandleForNode(node.documentId) : null;
  if (handle && runtime) return readRuntimeRamCell(wasm, handle, address);
  if (node.ramCells instanceof Map) return node.ramCells.get(address) ?? 0n;
  return cloneRamCells(node.ramCells).get(address) ?? 0n;
}
function editRamCell(node, address, text) {
  const { value } = parseInputValue(text, node.width);
  const handle = !inDefinitionScope() ? runtimeHandleForNode(node.documentId) : null;
  if (handle && runtime) {
    setRuntimeRamCell(wasm, handle, node, address, value);
    recordEdit(); runSimulation();
  } else {
    setRamImageCell(node, address, value);
    rebuildRuntime();
  }
}
function createRamEditor(node) {
  const editor = document.createElement("div"); editor.className = "ram-editor";
  editor.addEventListener("pointerdown", (event) => event.stopPropagation());
  const base = node.ramBase ?? 0n, end = node.ramEnd ?? ramAddressLimit(node.addressWidth);
  const start = ramPageStart(node);
  const controls = document.createElement("div"); controls.className = "ram-page-controls";
  const previous = document.createElement("button"); previous.type = "button"; previous.className = "ram-page-button"; previous.textContent = "‹";
  previous.title = "Previous memory page"; previous.disabled = start <= base;
  previous.addEventListener("click", () => { node.ramPageAddress = start - RAM_PAGE_ROWS < base ? base : start - RAM_PAGE_ROWS; render(); });
  const jump = document.createElement("input"); jump.type = "text"; jump.spellcheck = false; jump.className = "ram-page-address";
  jump.value = formatBusValue(start, node.addressWidth, 16); jump.setAttribute("aria-label", `RAM page address #${node.documentId}`);
  jump.title = "Jump to mapped address";
  jump.addEventListener("keydown", (event) => { if (event.key === "Enter") jump.blur(); });
  jump.addEventListener("change", () => {
    try {
      const address = parseInputValue(jump.value, node.addressWidth).value;
      if (address < base || address > end) throw new Error("Page address is outside the RAM mapped range");
      node.ramPageAddress = address; render();
    } catch (error) {
      jump.value = formatBusValue(start, node.addressWidth, 16); setStatus("error", error.message);
    }
  });
  const next = document.createElement("button"); next.type = "button"; next.className = "ram-page-button"; next.textContent = "›";
  next.title = "Next memory page"; next.disabled = start + RAM_PAGE_ROWS > end;
  next.addEventListener("click", () => { node.ramPageAddress = start + RAM_PAGE_ROWS > end ? end : start + RAM_PAGE_ROWS; render(); });
  controls.append(previous, jump, next); editor.append(controls);

  const cells = document.createElement("div"); cells.className = "ram-cells";
  const remaining = end - start + 1n;
  const rowCount = Number(remaining < RAM_PAGE_ROWS ? remaining : RAM_PAGE_ROWS);
  for (let offset = 0; offset < rowCount; offset += 1) {
    const address = start + BigInt(offset);
    const row = document.createElement("label"); row.className = "ram-cell-row";
    const addressLabel = document.createElement("span"); addressLabel.className = "ram-cell-address";
    addressLabel.textContent = formatBusValue(address, node.addressWidth, 16);
    const value = document.createElement("input"); value.type = "text"; value.spellcheck = false; value.className = "ram-cell-value";
    value.dataset.address = address.toString(10); value.value = formatBusValue(displayedRamCell(node, address), node.width, 16);
    value.setAttribute("aria-label", `RAM ${addressLabel.textContent} value #${node.documentId}`);
    value.title = "Memory word: decimal, 0x hexadecimal, 0b binary or 0o octal";
    value.addEventListener("keydown", (event) => { if (event.key === "Enter") value.blur(); });
    value.addEventListener("change", () => {
      try { editRamCell(node, address, value.value); value.classList.remove("invalid"); }
      catch (error) { value.classList.add("invalid"); setStatus("error", error.message); }
    });
    row.append(addressLabel, value); cells.append(row);
  }
  const note = document.createElement("div"); note.className = "ram-map-note";
  note.textContent = "Outside map: read 0 · simulated writes ignored";
  editor.append(cells, note); return editor;
}
function bitGrid(node, interactive) {
  const grid = document.createElement("div"); grid.className = "led-grid";
  grid.style.setProperty("--led-cols", String(node.kind === "display" ? node.ledColumns : node.width <= 2 ? node.width : node.width === 4 ? 2 : node.width <= 8 ? 4 : 8));
  for (let bit = node.width - 1; bit >= 0; bit -= 1) {
    const led = document.createElement(interactive ? "button" : "span");
    led.className = "square-led"; led.dataset.bit = String(bit);
    if (interactive && !inDefinitionScope()) {
      led.type = "button";
      led.setAttribute("aria-label", `Toggle bit ${bit} of input #${node.documentId}`);
      led.addEventListener("pointerdown", (event) => event.stopPropagation());
      led.addEventListener("click", (event) => { event.stopPropagation(); toggleInputBit(node, bit); });
    }
    grid.append(led);
  }
  return grid;
}
function visibleInputDefs(node) {
  const defs = nodeInputDefs(node);
  for (let pin = defs.length; pin < node.inputs.length; pin += 1) defs.push({
    label: `${node.kind === "display" ? ["R", "G", "B"][pin] : `D${pin - 1}`} (inactive)`, width: 0, inactive: true });
  while (defs.at(-1)?.inactive && !node.inputs[defs.length - 1]) defs.pop();
  return defs;
}
function visibleOutputDefs(node) {
  const defs = nodeOutputDefs(node);
  let last = defs.length - 1;
  for (const target of nodes) for (const c of target.inputs) if (c?.sourceId === node.documentId) last = Math.max(last, c.sourcePort);
  while (defs.length <= last) defs.push({ label: `Q${defs.length} (inactive)`, width: 0, inactive: true });
  return defs;
}
function nodeTitle(node) {
  return node.label || (node.kind === "custom" ? definitionById(node.definitionId)?.name : META[node.kind]?.title) || node.kind;
}
function nodeTitleHint(node) {
  return `${nodeTitle(node)} · ${node.kind === "custom" ? "double-click to enter chip scope; Alt+double-click to rename" : "double-click to rename"}`;
}
function activateNodeDoublePress(node, altKey = false) {
  if (node.kind === "custom" && !altKey) return enterCustomScope(node);
  const label = window.prompt("Component / chip port name", node.label || "");
  if (label == null) return false;
  node.label = label.trim().slice(0, 80); render(); recordEdit();
  return true;
}
function createNodeElement(node, layout) {
  const el = document.createElement("article"); el.className = "node";
  if (inDefinitionScope() && (node.kind === "input" || node.kind === "output")) {
    el.classList.add("scope-interface", `scope-interface-${node.kind}`);
  }
  el.tabIndex = -1;
  el.addEventListener("pointerdown", () => focusNode(node.documentId), { capture: true });
  el.addEventListener("focusin", () => focusNode(node.documentId));
  el.dataset.documentId = String(node.documentId); el.dataset.kind = node.kind;
  el.style.left = `${node.x}px`; el.style.top = `${node.y}px`;
  const head = document.createElement("div"); head.className = "node-head";
  const title = document.createElement("span"); title.className = "node-title";
  title.textContent = nodeTitle(node); title.title = nodeTitleHint(node);
  title.addEventListener("dblclick", (event) => {
    event.stopPropagation();
    activateNodeDoublePress(node, event.altKey);
  });
  const idLabel = document.createElement("span"); idLabel.className = "node-id"; idLabel.textContent = `#${node.documentId}`;
  head.append(title, idLabel); el.append(head);
  const settings = document.createElement("div"); settings.className = "node-settings";
  updateWidthControls(settings, node); el.append(settings, createNodeBody(node, layout));
  el.addEventListener("pointerdown", (event) => beginNodeDrag(event, node));
  el.addEventListener("dblclick", (event) => {
    if (node.kind === "custom" && !event.target.closest("button,input,select,label")) {
      event.stopPropagation(); activateNodeDoublePress(node, event.altKey);
    }
  });
  return el;
}
function createNodeBody(node, { ins, outs }) {
  const body = document.createElement("div"); body.className = "node-body";
  const portHeight = node.kind === "ram" ? Math.max(286, (Math.max(ins.length, outs.length) + 1) * 28)
    : Math.max(74, (Math.max(ins.length, outs.length) + 1) * 28);
  const counterHeader = node.kind === "clock" ? 44 : 0;
  const portTop = (index, count) => counterHeader ? `${counterHeader + (index + 1) / (count + 1) * portHeight}px` : `${(index + 1) / (count + 1) * 100}%`;
  body.style.minHeight = `${counterHeader + portHeight}px`;
  if (node.kind === "clock") {
    body.classList.add("clock-body", "counter-body");
    const level = document.createElement("input"); level.className = "node-value counter-value";
    level.type = "text"; level.spellcheck = false;
    level.setAttribute("aria-label", `Counter value #${node.documentId}`);
    level.title = "Set current count: decimal, 0x hex, 0b binary or 0o octal; Enter to apply";
    level.addEventListener("pointerdown", (event) => event.stopPropagation());
    level.addEventListener("keydown", (event) => { if (event.key === "Enter") level.blur(); });
    level.addEventListener("change", () => {
      try { setCounterValue(node, level.value); level.classList.remove("invalid"); }
      catch (error) { level.classList.add("invalid"); setStatus("error", error.message); }
    });
    const caption = document.createElement("span"); caption.className = "logic-caption";
    caption.textContent = "CLK ↑ · LOAD 1: DATA · 0: +1";
    caption.title = "On a rising CLK edge: LOAD = 1 stores DATA; LOAD = 0 increments the count";
    body.append(level, caption);
  } else if (node.kind === "oscillator") {
    body.classList.add("clock-body");
    const level = document.createElement("span"); level.className = "clock-level";
    const actions = document.createElement("div"); actions.className = "clock-actions";
    const toggle = document.createElement("button"); toggle.type = "button"; toggle.className = "button clock-toggle";
    toggle.title = "Start / pause the oscillator; pausing holds its output level";
    toggle.setAttribute("aria-label", `Start or pause oscillator #${node.documentId}`);
    toggle.addEventListener("click", () => setClockRunning(node, !node.clockRunning));
    const pulse = document.createElement("button"); pulse.type = "button"; pulse.className = "button clock-pulse"; pulse.textContent = "Pulse";
    pulse.title = "Toggle one manual clock edge; press again for the opposite edge";
    pulse.setAttribute("aria-label", `Pulse oscillator #${node.documentId}`); pulse.addEventListener("click", () => pulseClock(node));
    for (const button of [toggle, pulse]) button.addEventListener("pointerdown", (event) => event.stopPropagation());
    actions.append(toggle, pulse); body.append(level, actions);
  } else if (node.kind === "ram") {
    body.classList.add("ram-body"); body.append(createRamEditor(node));
  } else if (["input", "output", "display"].includes(node.kind)) {
    body.classList.add("io-body"); body.append(bitGrid(node, node.kind === "input"));
    const value = document.createElement(node.kind === "input" ? "input" : "span"); value.className = "node-value";
    if (node.kind === "input") {
      value.type = "text"; value.spellcheck = false;
      value.setAttribute("aria-label", `Value of input #${node.documentId}`);
      value.title = "Decimal, 0x hexadecimal, 0b binary or 0o octal; Enter to apply";
      value.addEventListener("pointerdown", (event) => event.stopPropagation());
      value.addEventListener("keydown", (event) => { if (event.key === "Enter") value.blur(); });
      value.addEventListener("change", () => {
        try { setInputValue(node, value.value); value.classList.remove("invalid"); }
        catch (error) { value.classList.add("invalid"); setStatus("error", error.message); }
      });
    }
    body.append(value);
    if (node.kind === "display") {
      body.classList.add("display-body");
      const caption = document.createElement("span"); caption.className = "display-caption";
      caption.textContent = `${node.ledColumns} × ${node.ledRows} · ${node.width} bits${node.ledMode === "rgb" ? " / color" : ""}`;
      body.append(caption);
    }
  } else {
    const symbol = node.kind === "custom" ? document.createElement("span") : createPrimitiveSymbol(node.kind);
    if (!symbol) {
      const fallback = document.createElement("span"); fallback.className = "logic-symbol";
      fallback.textContent = META[node.kind]?.symbol ?? node.kind.toUpperCase();
      body.append(fallback);
    } else if (node.kind === "custom") {
      symbol.className = "logic-symbol"; symbol.textContent = "▣"; body.append(symbol);
    } else body.append(symbol);
    const caption = document.createElement("span"); caption.className = "logic-caption";
    caption.textContent = node.kind === "custom" ? "CUSTOM CHIP" : node.kind === "dff" ? "RISING EDGE · CLK 1" :
      node.kind === "register" ? `${node.width}-BIT · LOAD · CLK ↑` :
      node.kind === "alu" ? `${node.width}-BIT · OP 00 + · 01 & · 10 OR · 11 XOR` :
      node.kind === "decoder" ? `${2 ** node.addressWidth} OUTPUT BITS` : `${node.width}-BIT`;
    body.append(caption);
  }
  ins.forEach((def, pin) => {
    const port = document.createElement("button");
    port.type = "button"; port.className = "port input-port"; port.dataset.pin = String(pin);
    port.style.top = portTop(pin, ins.length);
    const c = node.inputs[pin];
    const problem = c && connectionProblem(node, pin, nodeById(c.sourceId), c.sourcePort, definitionById);
    port.classList.toggle("connected", Boolean(c)); port.classList.toggle("invalid", Boolean(problem || def.inactive));
    port.title = `${def.label} · ${def.width || "inactive"} bit${problem ? ` · ${problem}` : ""}`;
    if (node.kind === "clock") port.title += [" · Rising edge: load DATA or increment", " · HIGH: load DATA on rising CLK; LOW: increment", " · Value to store on rising CLK when LOAD is HIGH"][pin] ?? "";
    port.setAttribute("aria-label", `${def.label} ${def.width} bit input of #${node.documentId}`);
    port.addEventListener("pointerdown", (event) => {
      event.stopPropagation();
      const attached = node.inputs[pin];
      if (attached) startWireDrag(event, { sourceId: attached.sourceId, sourcePort: attached.sourcePort, color: attached.color, detached: { targetId: node.documentId, pin } });
      else if (!def.inactive) startWireDrag(event, { targetId: node.documentId, targetPin: pin, reverse: true });
    });
    const label = document.createElement("span"); label.className = `pin-label input-label${def.inactive ? " invalid" : ""}`;
    label.style.top = port.style.top; label.textContent = `${def.label}${def.width ? `:${def.width}` : ""}`;
    body.append(port, label);
  });
  outs.forEach((def, portIndex) => {
    const port = document.createElement("button");
    port.type = "button"; port.className = "port output-port"; port.dataset.port = String(portIndex);
    port.style.top = portTop(portIndex, outs.length);
    port.classList.toggle("invalid", Boolean(def.inactive)); port.title = `${def.label} · ${def.width || "inactive"} bit`;
    port.setAttribute("aria-label", `${def.label} ${def.width} bit output of #${node.documentId}`);
    port.addEventListener("pointerdown", (event) => {
      event.stopPropagation();
      if (!def.inactive) startWireDrag(event, { sourceId: node.documentId, sourcePort: portIndex });
    });
    const label = document.createElement("span"); label.className = `pin-label output-label${def.inactive ? " invalid" : ""}`;
    label.style.top = port.style.top; label.textContent = `${def.label}${def.width ? `:${def.width}` : ""}`;
    body.append(port, label);
  });
  return body;
}
function nodeLayout(node) {
  const ins = visibleInputDefs(node), outs = visibleOutputDefs(node);
  const wires = node.inputs.map((c, pin) => c && [c.sourceId, c.sourcePort,
    connectionProblem(node, pin, nodeById(c.sourceId), c.sourcePort, definitionById)]);
  const ramLayout = node.kind === "ram"
    ? [String(node.ramBase), String(node.ramEnd), String(ramPageStart(node))]
    : [];
  return { ins, outs, key: JSON.stringify([node.width, node.addressWidth, node.splitWidth, node.ledColumns,
    node.ledRows, node.ledMode, ...ramLayout, ins, outs, wires]) };
}
function updateNodeBody(el, node, layout) {
  const old = el.querySelector(".node-body"), fresh = createNodeBody(node, layout);
  // A width may commit while focus moves to this value field. Keep that exact
  // element attached, including its pending text, instead of losing the click.
  const value = old.querySelector(".node-value");
  const children = [...fresh.children].map((child) => child.classList.contains("node-value") && value ? value : child);
  const keep = new Set(children);
  for (const child of [...old.children]) if (!keep.has(child)) child.remove();
  let anchor = old.firstChild;
  for (const child of children) {
    if (child === anchor) anchor = anchor.nextSibling;
    else old.insertBefore(child, anchor);
  }
  old.className = fresh.className; old.style.cssText = fresh.style.cssText;
}
function renderNodes() {
  const next = new Map();
  for (const node of nodes) {
    const layout = nodeLayout(node);
    let el = nodeElements.get(node.documentId);
    const previous = el && nodeRenderState.get(el);
    if (previous?.node !== node) el = createNodeElement(node, layout);
    else {
      const title = el.querySelector(".node-title");
      title.textContent = nodeTitle(node); title.title = nodeTitleHint(node);
      updateWidthControls(el.querySelector(".node-settings"), node);
      if (previous.key !== layout.key) updateNodeBody(el, node, layout);
    }
    el.style.left = `${node.x}px`; el.style.top = `${node.y}px`;
    el.style.width = node.kind === "display" ? `${Math.max(220, node.ledColumns * 18 + 76)}px`
      : node.kind === "ram" ? "390px" : "";
    nodeRenderState.set(el, { node, key: layout.key }); next.set(node.documentId, el);
  }
  for (const [id, el] of nodeElements) if (next.get(id) !== el) el.remove();
  let anchor = dom.nodeLayer.firstChild;
  for (const el of next.values()) {
    if (el === anchor) anchor = anchor.nextSibling;
    else dom.nodeLayer.insertBefore(el, anchor);
  }
  nodeElements = next; focusNode(activeNodeId); applyView();
}
function updateSelection() {
  for (const [id, el] of nodeElements) el.classList.toggle("selected", selectedIds.has(id));
  dom.chipButton.disabled = !canMakeChip();
  dom.deleteButton.disabled = !selectedWire && !selectedIds.size;
  dom.deleteButton.textContent = selectedWire ? "Delete wire" : selectedIds.size ? `Delete (${selectedIds.size})` : "Delete";
  dom.copyButton.disabled = !selectedIds.size;
  dom.arrangeButton.disabled = nodes.length < 2;
  const c = selectedWire && nodeById(selectedWire.targetId)?.inputs[selectedWire.pin];
  dom.wireColorTools.hidden = !c;
  if (c) {
    if (document.activeElement !== dom.wireColorInput) dom.wireColorInput.value = c.color ?? "#ffd36f";
    dom.wireColorReset.disabled = !c.color;
  }
  focusNode(activeNodeId);
  updateHistoryControls();
}
function renderWarnings() {
  const warnings = runtime?.diagnostics ?? [];
  dom.warningList.replaceChildren(); dom.warningList.hidden = !warnings.length;
  dom.status.title = warnings.map((w) => w.message).join("\n");
  if (warnings.length) {
    const title = document.createElement("strong"); title.textContent = `${warnings.length} disconnected wire${warnings.length === 1 ? "" : "s"}`;
    dom.warningList.append(title);
    for (const warning of warnings.slice(0, 12)) {
      const row = document.createElement("div"); row.textContent = warning.message; dom.warningList.append(row);
    }
    if (warnings.length > 12) dom.warningList.append(document.createTextNode(`… ${warnings.length - 12} more`));
  }
  for (const [id, el] of nodeElements) el.classList.toggle("invalid-chip", warnings.some((w) => w.internal && w.message.startsWith(`chip #${id}:`)));
  dom.footerTip.textContent = warnings.length ? "Red wires are preserved but do not carry a signal. Match widths to reconnect." : "Wheel: pan · Ctrl + wheel: zoom · Space + drag: pan · F: fit";
}
function render() {
  renderNodes(); updateSelection(); renderCustomPalette(); renderWarnings(); updateSignals(); renderWires();
  dom.nodeCount.textContent = `${nodes.length} chips · ${runtime?.scalarNodes ?? 0} bit nodes`;
  dom.emptyHint.hidden = nodes.length !== 0;
}
function portCenters() {
  const positions = new Map();
  const rect = dom.canvas.getBoundingClientRect();
  for (const [id, el] of nodeElements) for (const port of el.querySelectorAll(".port")) {
    const r = port.getBoundingClientRect();
    const key = port.classList.contains("input-port") ? `${id}/in${port.dataset.pin}` : `${id}/out${port.dataset.port}`;
    positions.set(key, { x: (r.left + r.width / 2 - rect.left - view.x) / view.zoom,
      y: (r.top + r.height / 2 - rect.top - view.y) / view.zoom, radiusX: r.width / (2 * view.zoom) });
  }
  return positions;
}
function connectionPath(a, b) {
  const x = (a.x + b.x) / 2;
  return `M ${a.x} ${a.y} L ${x} ${a.y} L ${x} ${b.y} L ${b.x} ${b.y}`;
}
function renderWires() {
  const centers = portCenters(), parts = [];
  wireToolAnchor = null;
  const obstacles = nodes.map((node) => {
    const el = nodeElements.get(node.documentId);
    return { id: node.documentId, left: node.x, top: node.y, right: node.x + el.offsetWidth, bottom: node.y + el.offsetHeight };
  });
  for (const target of nodes) target.inputs.forEach((c, pin) => {
    if (!c || (wireDrag?.detached?.targetId === target.documentId && wireDrag.detached.pin === pin)) return;
    const source = nodeById(c.sourceId);
    const output = centers.get(`${c.sourceId}/out${c.sourcePort}`), input = centers.get(`${target.documentId}/in${pin}`);
    if (!output || !input || !source) return;
    const a = { x: output.x + output.radiusX, y: output.y }, b = { x: input.x - input.radiusX, y: input.y };
    const width = nodeOutputDefs(source)[c.sourcePort]?.width ?? 0;
    const problem = connectionProblem(target, pin, source, c.sourcePort, definitionById);
    const selected = selectedWire?.targetId === target.documentId && selectedWire.pin === pin;
    const on = !problem && source.outputValues?.[c.sourcePort]?.some(Boolean);
    const stroke = 2.2 + Math.log2(Math.max(1, width)) * 0.55;
    const route = routeWire(a, b, obstacles, c.sourceId, target.documentId);
    const path = route.d, { x, y } = route.midpoint;
    if (selected) wireToolAnchor = { x, y };
    const color = /^#[0-9a-fA-F]{6}$/.test(c.color) ? c.color : null;
    parts.push(`<svg class="wire-svg" data-target-id="${target.documentId}" data-pin="${pin}" xmlns="http://www.w3.org/2000/svg"><g class="wire-group${problem ? " invalid" : ""}${selected ? " selected" : ""}${on ? " on" : ""}" data-target-id="${target.documentId}" data-pin="${pin}"${color ? ` style="--wire-color:${color}"` : ""}>
      <title>#${source.documentId} → #${target.documentId}: ${problem || `${width} bit`}. Click to select; double-click or right-click to delete.</title>
      <path class="wire-hit" role="button" tabindex="0" aria-label="Wire into #${target.documentId} pin ${pin}${problem ? `: ${problem}` : ""}" d="${path}"/>
      <path class="wire" style="stroke-width:${stroke}px" d="${path}"/>
      <text class="bus-label" x="${x}" y="${y - 9}">${problem || (width > 1 ? width : "")}</text></g></svg>`);
  });
  if (wireDrag) {
    const fixed = centers.get(wireDrag.reverse ? `${wireDrag.targetId}/in${wireDrag.targetPin}` : `${wireDrag.sourceId}/out${wireDrag.sourcePort}`);
    if (fixed) {
      fixed.x += wireDrag.reverse ? -fixed.radiusX : fixed.radiusX;
      const free = { x: wireDrag.x, y: wireDrag.y };
      parts.push(`<svg class="wire-svg draft-svg" xmlns="http://www.w3.org/2000/svg"><path class="wire draft" d="${wireDrag.reverse ? connectionPath(free, fixed) : connectionPath(fixed, free)}"/></svg>`);
    }
  }
  dom.wireLayer.innerHTML = parts.join("");
  if (selectedWire && !wireToolAnchor) dom.wireColorTools.hidden = true;
  positionWireTools(); updateWireDepth(); updateContacts();
}
function pointInside(element, x, y) {
  const rect = element.getBoundingClientRect();
  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
}
function canvasDropTarget(x, y, emptyOnly = false) {
  const hit = document.elementFromPoint(x, y);
  return hit && dom.canvas.contains(hit) && (!emptyOnly || !hit.closest(".node,.wire-group"));
}
function showTrash(show, hot = false) {
  dom.trashDrop.classList.toggle("visible", show);
  dom.trashDrop.classList.toggle("hot", show && hot);
}
function cancelGesture() {
  if (!gesture) return;
  const current = gesture; gesture = null; releaseGesture(current); current.cancel?.();
}
function releaseGesture(current) {
  cancelAnimationFrame(gestureFrame);
  if (dom.canvas.hasPointerCapture(current.pointerId)) dom.canvas.releasePointerCapture(current.pointerId);
}
function beginGesture(event, handlers) {
  cancelGesture(); gesture = { ...handlers, pointerId: event.pointerId, last: event };
  if (event.isTrusted) dom.canvas.setPointerCapture(event.pointerId);
  if (handlers.edgePan) {
    let previousTime = performance.now();
    const tick = (time) => {
      if (!gesture?.edgePan) return;
      const elapsed = Math.min(32, time - previousTime); previousTime = time;
      const rect = dom.canvas.getBoundingClientRect();
      const { clientX: x, clientY: y } = gesture.last;
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        const velocity = (p, start, end) => p < start + 36 ? -(start + 36 - p) / 36 : p > end - 36 ? (p - end + 36) / 36 : 0;
        const dx = velocity(x, rect.left, rect.right) * elapsed * 0.65;
        const dy = velocity(y, rect.top, rect.bottom) * elapsed * 0.65;
        if (dx || dy) { view.x -= dx; view.y -= dy; applyView(); gesture.move(gesture.last); }
      }
      gestureFrame = requestAnimationFrame(tick);
    };
    gestureFrame = requestAnimationFrame(tick);
  }
}
window.addEventListener("pointermove", (event) => {
  if (!gesture || event.pointerId !== gesture.pointerId) return;
  gesture.last = event; gesture.move(event);
});
window.addEventListener("pointerup", (event) => {
  if (!gesture || event.pointerId !== gesture.pointerId) return;
  const current = gesture; gesture = null; releaseGesture(current); current.end(event);
});
window.addEventListener("pointercancel", (event) => { if (gesture?.pointerId === event.pointerId) cancelGesture(); });
dom.canvas.addEventListener("lostpointercapture", (event) => {
  if (gesture?.pointerId === event.pointerId && !dom.canvas.hasPointerCapture(event.pointerId)) cancelGesture();
});

function startWireDrag(event, spec) {
  if (event.button !== 0 || spaceHeld) return;
  event.preventDefault(); dom.canvas.focus({ preventScroll: true }); cancelGesture();
  const start = worldPoint(event.clientX, event.clientY);
  wireDrag = { ...spec, x: start.x, y: start.y };
  let moved = false;
  const clear = () => {
    wireDrag = null; showTrash(false);
    dom.nodeLayer.querySelectorAll(".drop-target,.drop-invalid").forEach((p) => p.classList.remove("drop-target", "drop-invalid"));
  };
  beginGesture(event, {
    edgePan: true,
    move(moveEvent) {
      if (!wireDrag) return;
      const point = worldPoint(moveEvent.clientX, moveEvent.clientY);
      wireDrag.x = point.x; wireDrag.y = point.y;
      moved ||= Math.abs(moveEvent.clientX - event.clientX) + Math.abs(moveEvent.clientY - event.clientY) > 4;
      if (spec.detached) showTrash(moved, pointInside(dom.trashDrop, moveEvent.clientX, moveEvent.clientY));
      dom.nodeLayer.querySelectorAll(".drop-target,.drop-invalid").forEach((p) => p.classList.remove("drop-target", "drop-invalid"));
      const hit = document.elementFromPoint(moveEvent.clientX, moveEvent.clientY)?.closest(spec.reverse ? ".output-port" : ".input-port");
      if (hit) {
        const hitNode = nodeById(Number(hit.closest(".node").dataset.documentId));
        const target = spec.reverse ? nodeById(spec.targetId) : hitNode;
        const pin = spec.reverse ? spec.targetPin : Number(hit.dataset.pin);
        const source = spec.reverse ? hitNode : nodeById(spec.sourceId);
        const sourcePort = spec.reverse ? Number(hit.dataset.port) : spec.sourcePort;
        const problem = connectionProblem(target, pin, source, sourcePort, definitionById);
        hit.classList.add(problem ? "drop-invalid" : "drop-target");
      }
      renderWires();
    },
    end(endEvent) {
      const hit = document.elementFromPoint(endEvent.clientX, endEvent.clientY)?.closest(spec.reverse ? ".output-port" : ".input-port");
      let changed = false;
      if (hit) {
        const hitNode = nodeById(Number(hit.closest(".node").dataset.documentId));
        const target = spec.reverse ? nodeById(spec.targetId) : hitNode;
        const pin = spec.reverse ? spec.targetPin : Number(hit.dataset.pin);
        const sourceId = spec.reverse ? hitNode?.documentId : spec.sourceId;
        const sourcePort = spec.reverse ? Number(hit.dataset.port) : spec.sourcePort;
        if (target && nodeById(sourceId)) {
          target.inputs[pin] = connection(sourceId, sourcePort);
          if (spec.color) target.inputs[pin].color = spec.color;
          if (spec.detached && (target.documentId !== spec.detached.targetId || pin !== spec.detached.pin)) {
            const old = nodeById(spec.detached.targetId);
            if (old) old.inputs[spec.detached.pin] = null;
          }
          changed = true;
        }
      } else if (moved && spec.detached && (canvasDropTarget(endEvent.clientX, endEvent.clientY, true) || pointInside(dom.trashDrop, endEvent.clientX, endEvent.clientY))) {
        const old = nodeById(spec.detached.targetId);
        if (old) { old.inputs[spec.detached.pin] = null; changed = true; }
      }
      clear();
      if (changed) rebuildRuntime(); else renderWires();
    },
    cancel() { clear(); renderWires(); },
  });
  renderWires();
}
function beginNodeDrag(event, node) {
  if (event.button !== 0 || spaceHeld || event.target.closest("button,input,select")) return;
  const now = performance.now();
  const doublePress = node.kind === "custom" && lastNodePress?.documentId === node.documentId &&
    now - lastNodePress.time < 350 &&
    Math.hypot(event.clientX - lastNodePress.x, event.clientY - lastNodePress.y) < 8;
  if (doublePress) {
    event.preventDefault();
    lastNodePress = null;
    cancelGesture();
    activateNodeDoublePress(node, event.altKey);
    return;
  }
  dom.canvas.focus({ preventScroll: true });
  const wasSelected = selectedIds.has(node.documentId);
  if (event.shiftKey) selectedIds.add(node.documentId);
  else if (!wasSelected) selectedIds = new Set([node.documentId]);
  selectedWire = null; updateSelection(); renderWires();
  const start = worldPoint(event.clientX, event.clientY);
  const origins = new Map([...selectedIds].map((id) => [id, { x: nodeById(id).x, y: nodeById(id).y }]));
  let moved = false;
  for (const id of selectedIds) nodeElements.get(id)?.classList.add("dragging");
  const finish = () => {
    showTrash(false);
    for (const el of nodeElements.values()) el.classList.remove("dragging");
    updateSelection(); renderWires();
  };
  beginGesture(event, {
    edgePan: true,
    move(moveEvent) {
      const point = worldPoint(moveEvent.clientX, moveEvent.clientY);
      const dx = point.x - start.x, dy = point.y - start.y;
      moved ||= Math.abs(dx) + Math.abs(dy) > 3 / view.zoom;
      if (moved) showTrash(true, pointInside(dom.trashDrop, moveEvent.clientX, moveEvent.clientY));
      for (const [id, origin] of origins) {
        const n = nodeById(id), el = nodeElements.get(id);
        if (!n || !el) continue;
        n.x = origin.x + dx; n.y = origin.y + dy;
        el.style.left = `${n.x}px`; el.style.top = `${n.y}px`;
      }
      renderWires();
    },
    end(endEvent) {
      const trash = moved && pointInside(dom.trashDrop, endEvent.clientX, endEvent.clientY);
      if (!moved && event.shiftKey && wasSelected) selectedIds.delete(node.documentId);
      lastNodePress = !moved && !trash ? {
        documentId: node.documentId, time: performance.now(), x: endEvent.clientX, y: endEvent.clientY,
      } : null;
      finish();
      if (trash) removeNodes(new Set(selectedIds));
      else if (moved) recordEdit();
    },
    cancel() {
      for (const [id, origin] of origins) {
        const n = nodeById(id), el = nodeElements.get(id);
        if (n && el) { Object.assign(n, origin); el.style.left = `${n.x}px`; el.style.top = `${n.y}px`; }
      }
      lastNodePress = null;
      finish();
    },
  });
}
function beginMarquee(event) {
  if (event.button !== 0) return;
  event.preventDefault(); dom.canvas.focus({ preventScroll: true });
  const start = worldPoint(event.clientX, event.clientY);
  const base = event.shiftKey ? new Set(selectedIds) : new Set();
  const original = new Set(selectedIds);
  selectedWire = null;
  let moved = false;
  const hide = () => { dom.selectionBox.hidden = true; updateSelection(); renderWires(); };
  beginGesture(event, {
    edgePan: true,
    move(moveEvent) {
      const point = worldPoint(moveEvent.clientX, moveEvent.clientY);
      const left = Math.min(start.x, point.x), top = Math.min(start.y, point.y);
      const right = Math.max(start.x, point.x), bottom = Math.max(start.y, point.y);
      moved ||= Math.abs(point.x - start.x) + Math.abs(point.y - start.y) > 3 / view.zoom;
      dom.selectionBox.hidden = false;
      Object.assign(dom.selectionBox.style, { left: `${left * view.zoom + view.x}px`, top: `${top * view.zoom + view.y}px`,
        width: `${(right - left) * view.zoom}px`, height: `${(bottom - top) * view.zoom}px` });
      selectedIds = new Set(base);
      for (const node of nodes) {
        const el = nodeElements.get(node.documentId);
        if (node.x <= right && node.x + el.offsetWidth >= left && node.y <= bottom && node.y + el.offsetHeight >= top) {
          if (event.shiftKey && selectedIds.has(node.documentId)) selectedIds.delete(node.documentId);
          else selectedIds.add(node.documentId);
        }
      }
      updateSelection();
    },
    end() { if (!moved && !event.shiftKey) selectedIds.clear(); hide(); },
    cancel() { selectedIds = original; hide(); },
  });
}
function beginPan(event) {
  event.preventDefault();
  const origin = { x: view.x, y: view.y };
  dom.canvas.classList.add("panning");
  beginGesture(event, {
    move(moveEvent) {
      view.x = origin.x + moveEvent.clientX - event.clientX;
      view.y = origin.y + moveEvent.clientY - event.clientY; applyView();
    },
    end() { dom.canvas.classList.remove("panning"); },
    cancel() { view.x = origin.x; view.y = origin.y; applyView(); dom.canvas.classList.remove("panning"); },
  });
}
function startPaletteDrag(event, spec) {
  if (event.button !== 0 || !wasm) return;
  event.preventDefault(); dom.canvas.focus({ preventScroll: true });
  const ghost = document.createElement("div"); ghost.className = "palette-ghost"; ghost.textContent = spec.label;
  document.body.append(ghost);
  const moveGhost = (e) => {
    ghost.style.left = `${e.clientX + 12}px`; ghost.style.top = `${e.clientY + 12}px`;
    dom.canvas.classList.toggle("palette-over", Boolean(canvasDropTarget(e.clientX, e.clientY)));
  };
  const clear = () => { ghost.remove(); dom.canvas.classList.remove("palette-over"); };
  moveGhost(event);
  beginGesture(event, {
    edgePan: true,
    move: moveGhost,
    end(endEvent) {
      clear();
      if (!canvasDropTarget(endEvent.clientX, endEvent.clientY)) return;
      const point = worldPoint(endEvent.clientX, endEvent.clientY);
      newNode(spec.kind, point.x - 100, point.y - 40, spec.width ?? 1, spec.definitionId ?? null, spec);
    },
    cancel: clear,
  });
}
function renderPrimitivePaletteSymbols() {
  for (const button of document.querySelectorAll(".palette-item[data-kind]")) {
    const symbol = createPrimitiveSymbol(button.dataset.kind);
    const icon = button.querySelector(".gate-icon");
    if (!symbol || !icon) continue;
    symbol.classList.add("palette-primitive-symbol");
    icon.replaceChildren(symbol);
  }
}
function canMakeChip() {
  const selected = nodes.filter((node) => selectedIds.has(node.documentId));
  return selected.length > 0 && !selected.some((node) => ["display", "oscillator"].includes(node.kind));
}
function newChip() {
  if (!wasm) return;
  const name = window.prompt("Custom chip name", `CHIP ${nextDefinitionId}`)?.trim().slice(0, 80);
  if (!name) return;
  try {
    const input = makeNode(nextDocumentId++, "input", 40, 120, 1); input.label = "IN";
    const output = makeNode(nextDocumentId++, "output", 520, 120, 1); output.label = "OUT";
    const definition = createDefinition([input, output], name, nextDefinitionId++);
    customDefinitions.push(definition); recordEdit(); renderCustomPalette();
    enterDefinitionScope(definition.id, null, { fromRoot: true }); setStatus("settled", `editing ${name}`);
  } catch (error) { setStatus("error", error.message); }
}
function makeChip() {
  if (!canMakeChip()) return;
  const name = window.prompt("Custom chip name", `CHIP ${nextDefinitionId}`)?.trim().slice(0, 80);
  if (!name) return;
  try {
    const selected = new Set(selectedIds);
    const candidates = inferDefinitionSelection(nodes, selectedIds, definitionById);
    const definition = createDefinition(candidates, name, nextDefinitionId, definitionById);
    const inputCandidates = candidates.filter((node) => node.kind === "input");
    const outputCandidates = candidates.filter((node) => node.kind === "output");
    const bounds = nodes.filter((node) => selected.has(node.documentId));
    const x = bounds.reduce((sum, node) => sum + node.x, 0) / Math.max(1, bounds.length);
    const y = bounds.reduce((sum, node) => sum + node.y, 0) / Math.max(1, bounds.length);
    const instance = makeNode(nextDocumentId++, "custom", x, y, 1, definition.id);
    instance.inputs = inputCandidates.map((node) => node._externalConnection ? { ...node._externalConnection } : null);
    ensureInputSlots(instance, (id) => id === definition.id ? definition : definitionById(id));
    const outputPort = new Map();
    outputCandidates.forEach((node, port) => {
      const source = node._exposedSource ?? node.inputs?.[0];
      if (source) outputPort.set(`${source.sourceId}/${source.sourcePort}`, port);
    });
    const next = nodes.filter((node) => !selected.has(node.documentId));
    for (const target of next) target.inputs = target.inputs.map((wire) => {
      if (!wire || !selected.has(wire.sourceId)) return wire;
      const port = outputPort.get(`${wire.sourceId}/${wire.sourcePort}`);
      return port == null ? null : { ...wire, sourceId: instance.documentId, sourcePort: port };
    });
    next.push(instance); setActiveNodes(next);
    customDefinitions.push(definition); nextDefinitionId += 1;
    selectedIds = new Set([instance.documentId]); selectedWire = null; activeNodeId = instance.documentId;
    rebuildRuntime(); renderCustomPalette(); setStatus("settled", `made ${name}`);
    const liveInstance = nodes.find((node) => node.kind === "custom" && node.definitionId === definition.id);
    if (liveInstance) enterCustomScope(liveInstance);
  } catch (error) { setStatus("error", error.message); }
}
function renderCustomPalette() {
  dom.customPalette.replaceChildren();
  updateModuleExportControl();
  for (const definition of customDefinitions) {
    const entry = document.createElement("div"); entry.className = "custom-palette-entry";
    const button = document.createElement("button"); button.type = "button"; button.className = "palette-item wide";
    const icon = document.createElement("span"); icon.className = "gate-icon"; icon.textContent = "▣";
    const title = document.createElement("span"); title.textContent = definition.name;
    button.append(icon, title);
    button.addEventListener("pointerdown", (event) => startPaletteDrag(event, { kind: "custom", definitionId: definition.id, label: definition.name }));
    const packButton = document.createElement("button"); packButton.type = "button"; packButton.className = "chip-pack-button";
    packButton.textContent = "Pack"; packButton.title = `Include ${definition.name} as an exported module chip`;
    packButton.setAttribute("aria-pressed", String(moduleExportIds.has(definition.id)));
    packButton.addEventListener("pointerdown", (event) => event.stopPropagation());
    packButton.addEventListener("click", (event) => {
      event.stopPropagation();
      if (moduleExportIds.has(definition.id)) moduleExportIds.delete(definition.id); else moduleExportIds.add(definition.id);
      packButton.setAttribute("aria-pressed", String(moduleExportIds.has(definition.id)));
      updateModuleExportControl();
    });
    entry.append(button, packButton); dom.customPalette.append(entry);
  }
}
for (const button of document.querySelectorAll(".palette-item[data-kind]")) button.addEventListener("pointerdown", (event) =>
  startPaletteDrag(event, { kind: button.dataset.kind, label: button.lastElementChild.textContent.trim() }));
for (const button of document.querySelectorAll(".palette-item[data-display-bits]")) button.addEventListener("pointerdown", (event) =>
  startPaletteDrag(event, { kind: "display", width: Number(button.dataset.displayBits), label: button.lastElementChild.textContent.trim(),
    ledMode: button.dataset.ledMode, ledColor: button.dataset.ledColor }));

dom.canvas.addEventListener("pointerdown", (event) => {
  if (event.button === 0 && event.altKey && !spaceHeld) {
    const overlapping = nodes.filter((node) => pointInside(nodeElements.get(node.documentId), event.clientX, event.clientY));
    if (overlapping.length > 1) {
      event.preventDefault(); event.stopImmediatePropagation(); cancelGesture();
      const current = overlapping.findIndex((node) => node.documentId === activeNodeId);
      const next = overlapping[(current + 1) % overlapping.length];
      selectedIds = new Set([next.documentId]); selectedWire = null;
      focusNode(next.documentId); nodeElements.get(next.documentId).focus({ preventScroll: true });
      updateSelection(); renderWires(); return;
    }
  }
  if (event.button === 1 || (event.button === 0 && spaceHeld && !isEditable(event.target))) {
    event.stopPropagation(); beginPan(event);
  }
}, { capture: true });
dom.canvas.addEventListener("pointermove", (event) => { pointerPosition = { x: event.clientX, y: event.clientY }; });
dom.canvas.addEventListener("pointerdown", (event) => {
  if (!event.target.closest(".node,.wire-group,.wire-color-tools")) beginMarquee(event);
});
dom.canvas.addEventListener("wheel", (event) => {
  if (isEditable(event.target) && event.target === document.activeElement && !event.target.matches(".width-input")) return;
  event.preventDefault();
  const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? dom.canvas.clientHeight : 1;
  if (event.ctrlKey || event.metaKey) zoomAt(view.zoom * Math.exp(-event.deltaY * unit * 0.002), event.clientX, event.clientY);
  else {
    view.x -= (event.shiftKey ? event.deltaY : event.deltaX) * unit;
    view.y -= (event.shiftKey ? event.deltaX : event.deltaY) * unit;
    applyView();
    if (gesture) gesture.move(gesture.last);
  }
}, { passive: false });
dom.canvas.addEventListener("contextmenu", (event) => { if (!isEditable(event.target)) event.preventDefault(); });
dom.wireLayer.addEventListener("pointerdown", (event) => {
  const group = event.target.closest(".wire-group");
  if (!group || event.button !== 0 || spaceHeld) return;
  event.stopPropagation(); event.preventDefault(); dom.canvas.focus({ preventScroll: true });
  const targetId = Number(group.dataset.targetId), pin = Number(group.dataset.pin);
  const now = performance.now();
  const doublePress = selectedWire?.targetId === targetId && selectedWire.pin === pin &&
    lastWirePress && lastWirePress.targetId === targetId && lastWirePress.pin === pin &&
    now - lastWirePress.time < 350 && Math.hypot(event.clientX - lastWirePress.x, event.clientY - lastWirePress.y) < 6;
  lastWirePress = { targetId, pin, time: now, x: event.clientX, y: event.clientY };
  if (doublePress) { lastWirePress = null; removeWire(targetId, pin); return; }
  selectedWire = { targetId, pin }; selectedIds.clear(); updateSelection(); renderWires();
});
dom.wireLayer.addEventListener("contextmenu", (event) => {
  const group = event.target.closest(".wire-group");
  if (!group) return;
  event.preventDefault(); event.stopPropagation(); removeWire(Number(group.dataset.targetId), Number(group.dataset.pin));
});
dom.wireLayer.addEventListener("focusin", (event) => {
  const group = event.target.closest(".wire-group");
  if (!group) return;
  selectedWire = { targetId: Number(group.dataset.targetId), pin: Number(group.dataset.pin) };
  selectedIds.clear(); updateSelection(); renderWires();
});
dom.chipButton.addEventListener("click", makeChip);
dom.newChipButton.addEventListener("click", newChip);
dom.importChipButton.addEventListener("click", () => { document.activeElement?.blur(); dom.chipFile.click(); });
dom.exportChipButton.addEventListener("click", exportChipModule);
dom.chipFile.addEventListener("change", () => {
  const file = dom.chipFile.files?.[0]; dom.chipFile.value = "";
  void importChipFile(file);
});
dom.scopeBack.addEventListener("click", parentScope);
dom.demoButton.addEventListener("click", () => wasm && loadDemo());
dom.clearButton.addEventListener("click", () => wasm && clearCircuit());
dom.undoButton.addEventListener("click", () => applyEditHistory());
dom.redoButton.addEventListener("click", () => applyEditHistory(true));
dom.saveButton.addEventListener("click", saveProjectFile);
dom.openButton.addEventListener("click", () => { document.activeElement?.blur(); dom.projectFile.click(); });
dom.projectFile.addEventListener("change", () => {
  const file = dom.projectFile.files?.[0]; dom.projectFile.value = "";
  void openProjectFile(file);
});
dom.deleteButton.addEventListener("click", deleteSelection);
dom.wireColorInput.addEventListener("input", () => setSelectedWireColor(dom.wireColorInput.value));
dom.wireColorReset.addEventListener("click", () => setSelectedWireColor(null));
dom.wireColorTools.addEventListener("pointerdown", (event) => event.stopPropagation());
dom.wireDeleteQuick.addEventListener("click", () => {
  if (selectedWire) removeWire(selectedWire.targetId, selectedWire.pin);
});
dom.arrangeButton.addEventListener("click", arrangeCurrentScope);
dom.fitButton.addEventListener("click", fitView);
dom.zoomIn.addEventListener("click", () => zoomCenter(1.25));
dom.zoomOut.addEventListener("click", () => zoomCenter(0.8));
dom.copyButton.addEventListener("click", async () => {
  try {
    const text = copySelection();
    try { await navigator.clipboard.writeText(text); }
    catch { setStatus("warning", "Copied in this tab; Ctrl+C copies to the system clipboard"); }
  } catch (error) { setStatus("error", error.message); }
});
dom.pasteButton.addEventListener("click", async () => {
  const epoch = documentEpoch;
  let text;
  try { text = await navigator.clipboard.readText(); }
  catch { text = clipboardText; }
  if (epoch !== documentEpoch) return;
  try {
    if (!text) throw new Error("Copy chips first, or use Ctrl+V to paste from the clipboard");
    pasteSelection(text);
  } catch (error) { setStatus("error", error.message); }
});
document.addEventListener("visibilitychange", () => {
  stopClockTimer();
  if (!document.hidden) { clocks.reset(performance.now()); scheduleClocks(); }
});
window.addEventListener("pagehide", stopClockTimer);
window.addEventListener("pageshow", () => { clocks.reset(performance.now()); scheduleClocks(); });

window.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && !event.altKey) {
    const key = event.key.toLowerCase();
    if (key === "s") { event.preventDefault(); saveProjectFile(); return; }
    if (key === "o") { event.preventDefault(); document.activeElement?.blur(); dom.projectFile.click(); return; }
    if (key === "z" && !isEditable(event.target)) { event.preventDefault(); applyEditHistory(event.shiftKey); return; }
  }
  if (event.key === "Escape") {
    if (gesture) cancelGesture();
    else if (parentScope()) event.preventDefault();
    return;
  }
  if (event.altKey && !event.ctrlKey && !event.metaKey && event.key === "ArrowUp" && !isEditable(event.target)) {
    if (parentScope()) event.preventDefault();
    return;
  }
  if (isEditable(event.target)) return;
  if (event.code === "Space" && !event.target.closest?.("button")) { event.preventDefault(); spaceHeld = true; dom.canvas.classList.add("pan-ready"); }
  else if (event.key === "Delete" || event.key === "Backspace") {
    if (selectedWire || selectedIds.size) { event.preventDefault(); deleteSelection(); }
  } else if (!event.ctrlKey && !event.metaKey && (event.key.toLowerCase() === "f" || event.key === "Home")) {
    event.preventDefault(); fitView();
  } else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "a") {
    event.preventDefault(); selectedIds = new Set(nodes.map((n) => n.documentId)); selectedWire = null; updateSelection(); renderWires();
  }
});
window.addEventListener("keyup", (event) => { if (event.code === "Space") { spaceHeld = false; dom.canvas.classList.remove("pan-ready"); } });
window.addEventListener("blur", () => { spaceHeld = false; dom.canvas.classList.remove("pan-ready"); cancelGesture(); });
new ResizeObserver(() => { applyView(); renderWires(); }).observe(dom.canvas);

renderPrimitivePaletteSymbols(); renderScopeBar();
try { await loadWasm(); loadDemo(); editHistory.reset(rootNodes, customDefinitions); historyReady = true; updateHistoryControls(); }
catch (error) { console.error(error); setStatus("error", `load failed: ${error.message}`); }

export const GAP = 0.02;
export const PRESETS = [1 / 3, 1 / 2, 2 / 3];

export function create(columns) {
  return { columns, col: 0, win: 0, offset: 0, nextId: 100 };
}

export function width(column) {
  const p = column.full ? 1 : column.width;
  return p * (1 - GAP) - GAP;
}

export function layout(state) {
  let x = GAP;
  const xs = state.columns.map((c) => {
    const at = x;
    x += width(c) + GAP;
    return at;
  });
  return { xs, extent: x };
}

export function maxOffset(state) {
  return Math.max(0, layout(state).extent - 1);
}

export function clampOffset(state, offset) {
  return Math.min(Math.max(offset, 0), maxOffset(state));
}

function reveal(state) {
  if (!state.columns.length) return { ...state, col: 0, win: 0, offset: 0 };
  const col = Math.min(Math.max(state.col, 0), state.columns.length - 1);
  const win = Math.min(Math.max(state.win, 0), state.columns[col].windows.length - 1);
  const s = { ...state, col, win };
  const left = layout(s).xs[col] - GAP;
  const right = left + width(s.columns[col]) + 2 * GAP;
  let offset = s.offset;
  if (right > offset + 1) offset = right - 1;
  if (left < offset) offset = left;
  return { ...s, offset: clampOffset(s, offset) };
}

function clone(state) {
  return { ...state, columns: state.columns.map((c) => ({ ...c, windows: [...c.windows] })) };
}

export function focusCol(state, dir) {
  return reveal({ ...state, col: state.col + dir, win: 0 });
}

export function focusWin(state, dir) {
  return reveal({ ...state, win: state.win + dir });
}

export function focusAt(state, col, win) {
  return reveal({ ...state, col, win });
}

export function moveWindow(state, dir) {
  const s = clone(state);
  const column = s.columns[s.col];
  if (!column) return state;
  if (column.windows.length > 1) {
    const [id] = column.windows.splice(s.win, 1);
    const at = dir > 0 ? s.col + 1 : s.col;
    s.columns.splice(at, 0, { windows: [id], width: 0.5 });
    return reveal({ ...s, col: at, win: 0 });
  }
  const target = s.col + dir;
  if (target < 0 || target >= s.columns.length) return state;
  s.columns[target].windows.push(column.windows[0]);
  s.columns.splice(s.col, 1);
  const col = dir > 0 ? target - 1 : target;
  return reveal({ ...s, col, win: s.columns[col].windows.length - 1 });
}

export function swapWindow(state, dir) {
  const s = clone(state);
  const windows = s.columns[s.col]?.windows;
  const to = s.win + dir;
  if (!windows || to < 0 || to >= windows.length) return state;
  [windows[s.win], windows[to]] = [windows[to], windows[s.win]];
  return reveal({ ...s, win: to });
}

export function moveColumn(state, dir) {
  const s = clone(state);
  const to = s.col + dir;
  if (to < 0 || to >= s.columns.length) return state;
  [s.columns[s.col], s.columns[to]] = [s.columns[to], s.columns[s.col]];
  return reveal({ ...s, col: to });
}

export function cycleWidth(state, dir = 1) {
  const s = clone(state);
  const column = s.columns[s.col];
  if (!column) return state;
  const next =
    dir > 0
      ? (PRESETS.find((p) => p > column.width + 1e-6) ?? PRESETS[0])
      : (PRESETS.findLast((p) => p < column.width - 1e-6) ?? PRESETS.at(-1));
  s.columns[s.col] = { ...column, width: next, full: false };
  return reveal(s);
}

export function toggleFull(state) {
  const s = clone(state);
  const column = s.columns[s.col];
  if (!column) return state;
  s.columns[s.col] = { ...column, full: !column.full };
  return reveal(s);
}

export function toggleTabbed(state) {
  const s = clone(state);
  const column = s.columns[s.col];
  if (!column) return state;
  s.columns[s.col] = { ...column, tabbed: !column.tabbed };
  return reveal(s);
}

export function open(state, kind) {
  const s = clone(state);
  const at = s.columns.length ? s.col + 1 : 0;
  s.columns.splice(at, 0, { windows: [`${kind}-${s.nextId}`], width: 0.5 });
  return reveal({ ...s, col: at, win: 0, nextId: s.nextId + 1 });
}

export function close(state) {
  const s = clone(state);
  const column = s.columns[s.col];
  if (!column) return state;
  column.windows.splice(s.win, 1);
  if (column.windows.length) return reveal({ ...s, win: Math.min(s.win, column.windows.length - 1) });
  s.columns.splice(s.col, 1);
  return reveal({ ...s, col: Math.min(s.col, s.columns.length - 1), win: 0 });
}

export function pan(state, offset) {
  return { ...state, offset: clampOffset(state, offset) };
}

export function settle(state) {
  if (!state.columns.length) return state;
  const { xs } = layout(state);
  const stops = [...xs.map((x) => x - GAP), ...xs.map((x, i) => x + width(state.columns[i]) + GAP - 1)].map((o) =>
    clampOffset(state, o)
  );
  const offset = stops.reduce((a, b) => (Math.abs(b - state.offset) < Math.abs(a - state.offset) ? b : a));
  const visible = (i) => xs[i] - GAP >= offset - 1e-6 && xs[i] + width(state.columns[i]) + GAP <= offset + 1 + 1e-6;
  if (visible(state.col)) return { ...state, offset };
  const col = state.columns.findIndex((_, i) => visible(i));
  return col < 0 ? { ...state, offset } : { ...state, offset, col, win: 0 };
}

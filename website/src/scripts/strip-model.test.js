import assert from 'node:assert/strict';
import test from 'node:test';
import * as m from './strip-model.js';

const strip = () =>
  m.create([
    { windows: ['a', 'b'], width: 0.5 },
    { windows: ['c'], width: 1 / 3 },
    { windows: ['d'], width: 0.5 },
  ]);

const ids = (s) => s.columns.map((c) => c.windows.join(''));

test('presets tile the viewport exactly', () => {
  const s = m.create([
    { windows: ['a'], width: 0.5 },
    { windows: ['b'], width: 0.5 },
  ]);
  assert.ok(Math.abs(m.layout(s).extent - 1) < 1e-9);
  assert.equal(m.maxOffset(s), 0);
});

test('focus clamps at both edges', () => {
  assert.equal(m.focusCol(strip(), -1).col, 0);
  assert.equal(m.focusCol(m.focusCol(m.focusCol(strip(), 1), 1), 1).col, 2);
  assert.equal(m.focusWin(strip(), 5).win, 1);
});

test('focus reveals the column with minimal scroll', () => {
  const s = m.focusCol(m.focusCol(strip(), 1), 1);
  const { xs } = m.layout(s);
  assert.ok(Math.abs(s.offset - (xs[2] + m.width(s.columns[2]) + m.GAP - 1)) < 1e-9);
  assert.equal(m.focusCol(s, -1).offset, s.offset);
});

test('moving out of a stack expels into a new column on that side', () => {
  const right = m.moveWindow(strip(), 1);
  assert.deepEqual(ids(right), ['b', 'a', 'c', 'd']);
  assert.equal(right.col, 1);
  assert.deepEqual(ids(m.moveWindow(strip(), -1)), ['a', 'b', 'c', 'd']);
});

test('moving a lone window consumes it into the neighbour', () => {
  const s = m.moveWindow(m.focusCol(strip(), 1), -1);
  assert.deepEqual(ids(s), ['abc', 'd']);
  assert.deepEqual([s.col, s.win], [0, 2]);
  const last = m.focusCol(m.focusCol(strip(), 1), 1);
  assert.equal(m.moveWindow(last, 1), last);
});

test('column swap and window swap stay in bounds', () => {
  assert.deepEqual(ids(m.moveColumn(strip(), 1)), ['c', 'ab', 'd']);
  assert.equal(m.moveColumn(strip(), -1).col, 0);
  assert.deepEqual(ids(m.swapWindow(strip(), 1)), ['ba', 'c', 'd']);
  assert.deepEqual(ids(m.swapWindow(strip(), -1)), ['ab', 'c', 'd']);
});

test('cycle width walks the presets and wraps', () => {
  const widths = [];
  let s = strip();
  for (let i = 0; i < 3; i++) widths.push((s = m.cycleWidth(s)).columns[0].width);
  assert.deepEqual(widths, [2 / 3, 1 / 3, 1 / 2]);
  assert.deepEqual([m.cycleWidth(s, -1).columns[0].width, m.cycleWidth(m.cycleWidth(s, -1), -1).columns[0].width], [1 / 3, 2 / 3]);
  assert.equal(m.cycleWidth(m.toggleFull(strip())).columns[0].full, false);
});

test('close drops empty columns and open lands right of focus', () => {
  let s = m.close(m.focusCol(strip(), 1));
  assert.deepEqual(ids(s), ['ab', 'd']);
  assert.equal(s.col, 1);
  s = m.open(m.focusCol(s, -1), 'notes');
  assert.equal(s.columns[1].windows[0], 'notes-100');
  for (let i = 0; i < 9; i++) s = m.close(s);
  assert.deepEqual([s.columns.length, s.offset], [0, 0]);
});

test('settle snaps to a column edge and refocuses a hidden column', () => {
  const s = m.settle(m.pan(strip(), 0.3));
  const { xs } = m.layout(s);
  assert.ok(xs.some((x, i) => Math.abs(s.offset - (x - m.GAP)) < 1e-9 || Math.abs(s.offset - (x + m.width(s.columns[i]) + m.GAP - 1)) < 1e-9));
  assert.ok(s.offset > 0);
  assert.notEqual(s.col, 0);
  assert.equal(m.settle(m.pan(strip(), 0.01)).offset, 0);
});

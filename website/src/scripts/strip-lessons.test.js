import assert from 'node:assert/strict';
import test from 'node:test';
import * as m from './strip-model.js';
import { lessons, start } from './strip-lessons.js';

const solutions = [
  [['focusCol', 1], ['focusCol', 1], ['focusCol', 1]],
  [['focusWin', 1]],
  [['moveWindow', 1]],
  [['moveWindow', -1]],
  [['swapWindow', 1]],
  [['moveColumn', 1]],
  [['cycleWidth', 1], ['cycleWidth', 1]],
  [['toggleFull']],
  [['toggleTabbed'], ['focusWin', 1]],
];

test('every lesson starts unsolved and the keys it shows solve it', () => {
  lessons.forEach((lesson, i) => {
    if (!lesson.done) return;
    let s = start(lesson);
    assert.equal(lesson.done(s), false, lesson.title);
    for (const [fn, arg] of solutions[i]) {
      assert.ok(lesson.keys.includes(`${fn}:${arg ?? ''}`), `${lesson.title} hides ${fn}`);
      s = m[fn](s, arg);
    }
    assert.equal(lesson.done(s), true, lesson.title);
  });
  assert.equal(solutions.length, lessons.filter((l) => l.done).length);
});

test('the wrong direction does not pass a lesson', () => {
  assert.equal(lessons[2].done(m.moveWindow(start(lessons[2]), -1)), false);
  assert.equal(lessons[5].done(m.moveColumn(start(lessons[5]), -1)), false);
  assert.equal(lessons[4].done(m.swapWindow(start(lessons[4]), -1)), false);
});

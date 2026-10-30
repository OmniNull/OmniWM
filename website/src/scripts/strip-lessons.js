import { create, focusAt } from './strip-model.js';

const stacked = () => [
  { windows: ['editor-1', 'notes-2'], width: 1 / 2 },
  { windows: ['terminal-3'], width: 1 / 3 },
  { windows: ['browser-4'], width: 1 / 2 },
  { windows: ['plain-5'], width: 1 / 3 },
];

const loose = () => [
  { windows: ['editor-1'], width: 1 / 2 },
  { windows: ['notes-2'], width: 1 / 3 },
  { windows: ['terminal-3'], width: 1 / 2 },
  { windows: ['browser-4'], width: 1 / 3 },
];

const focused = (s) => s.columns[s.col]?.windows[s.win];
const columnOf = (s, id) => s.columns.find((c) => c.windows.includes(id));
const indexOf = (s, id) => s.columns.findIndex((c) => c.windows.includes(id));

export const start = (lesson) => focusAt(create(lesson.columns()), lesson.col ?? 0, lesson.win ?? 0);

export const lessons = [
  {
    title: 'Move the focus',
    text: '⌥ plus an arrow moves the focus. The strip only scrolls as far as it has to, so the focused column stays on screen. Press ⌥→ until Messages, at the far right, has the focus.',
    keys: ['focusCol:-1', 'focusCol:1'],
    columns: stacked,
    done: (s) => focused(s) === 'plain-5',
  },
  {
    title: 'Up and down a column',
    text: 'A column can hold a stack of windows. ⌥↑ and ⌥↓ move the focus up and down the stack. Focus Notes, under Zed.',
    keys: ['focusWin:-1', 'focusWin:1'],
    columns: stacked,
    done: (s) => focused(s) === 'notes-2',
  },
  {
    title: 'Add ⇧ to move the window',
    text: 'Hold ⇧ as well and the same arrows move the focused window instead of the focus. Notes is stacked under Zed: press ⌥⇧→ to pull it out into a column of its own.',
    keys: ['moveWindow:-1', 'moveWindow:1'],
    columns: stacked,
    win: 1,
    done: (s) => indexOf(s, 'notes-2') > 0 && columnOf(s, 'notes-2')?.windows.length === 1,
  },
  {
    title: 'Join a column',
    text: 'When a window is already alone in its column, ⌥⇧← and ⌥⇧→ stack it into the column next to it. Press ⌥⇧← to put Notes back under Zed.',
    keys: ['moveWindow:-1', 'moveWindow:1'],
    columns: loose,
    col: 1,
    done: (s) => columnOf(s, 'notes-2') === columnOf(s, 'editor-1'),
  },
  {
    title: 'Reorder a stack',
    text: '⌥⇧↑ and ⌥⇧↓ swap the focused window with the one above or below it. Move Zed under Notes.',
    keys: ['swapWindow:-1', 'swapWindow:1'],
    columns: stacked,
    done: (s) => columnOf(s, 'editor-1')?.windows.join() === 'notes-2,editor-1',
  },
  {
    title: 'Add ⌃ to move the column',
    text: 'Hold ⌃ on top of ⌥⇧ and the arrows carry the whole column, stack and all. Press ⌃⌥⇧→ to slide the Zed and Notes column to the right.',
    keys: ['moveColumn:-1', 'moveColumn:1'],
    columns: stacked,
    done: (s) => indexOf(s, 'editor-1') > 0 && columnOf(s, 'editor-1')?.windows.join() === 'editor-1,notes-2',
  },
  {
    title: 'Cycle the width',
    text: 'Columns snap to a third, a half or two thirds of the screen. ⌥. steps up through those sizes and ⌥, steps down, wrapping at either end. Make Ghostty two thirds wide.',
    keys: ['cycleWidth:-1', 'cycleWidth:1'],
    columns: stacked,
    col: 1,
    done: (s) => {
      const c = columnOf(s, 'terminal-3');
      return !!c && !c.full && Math.abs(c.width - 2 / 3) < 1e-6;
    },
  },
  {
    title: 'Full width',
    text: '⌥⇧F stretches the focused column across the whole screen. Press it again to put it back. Give Safari the full width.',
    keys: ['toggleFull:'],
    columns: stacked,
    col: 2,
    done: (s) => !!columnOf(s, 'browser-4')?.full,
  },
  {
    title: 'Tabs',
    text: '⌥T turns a column into tabs: one window shows at a time, and ⌥↑ and ⌥↓ flip between them. Tab the Zed column, then bring Notes to the front.',
    keys: ['toggleTabbed:', 'focusWin:-1', 'focusWin:1'],
    columns: stacked,
    done: (s) => !!columnOf(s, 'notes-2')?.tabbed && focused(s) === 'notes-2',
  },
  {
    title: 'Free play',
    text: 'That covers the everyday keys. Every one of them is a default binding, and Settings › Keyboard Shortcuts can change any of them. ⌥1 to ⌥9 switch workspaces the same way, and a sideways two finger swipe on a trackpad scrolls the strip.',
    keys: null,
    columns: stacked,
    done: null,
  },
];

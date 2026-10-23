import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const sourceURL = new URL('../../Sources/OmniWM/Resources/omniwm.d.luau', import.meta.url);
const outputURL = new URL('../src/data/omnishell-api.json', import.meta.url);
const assignments = {
  'ui-elements': ['Element', 'TextStyle', 'Font', 'Weight', 'TextProps', 'TextInputProps', 'SymbolProps', 'IconProps', 'ImageProps', 'ProgressProps', 'SliderProps', 'PathProps', 'ui', 'ui.row', 'ui.column', 'ui.stack', 'ui.box', 'ui.text', 'ui.input', 'ui.symbol', 'ui.icon', 'ui.image', 'ui.progress', 'ui.path', 'ui.slider'],
  'layout-styling': ['Color', 'Material', 'Align', 'Props'],
  'context-data': ['BarWindow', 'BarItem', 'BarWorkspace', 'BarScratchpad', 'BarStyle', 'HiddenBarItem', 'HiddenBarMenuRow', 'HiddenBarMenu', 'HiddenBar', 'BarDrag', 'Bar', 'Workspace', 'AudioOutput', 'AudioApp', 'AudioApps', 'Media', 'CalendarEvent', 'CalendarMonth', 'Calendar', 'NotificationAction', 'NotificationAttachment', 'NotificationItem', 'Notifications', 'Reminder', 'Reminders', 'WeatherHour', 'WeatherDay', 'Weather', 'SystemDisplay', 'System', 'Power', 'InputSourceEntry', 'InputSource', 'WiFi', 'BluetoothDevice', 'Bluetooth', 'IslandNavigation', 'Island', 'Data', 'Format', 'Context', 'TriggerEvent', 'omniwm.run', 'omniwm.log', 'omniwm.l10n', 'ui.popout'],
  'input-motion': ['Motion', 'Curve', 'Animate', 'Presence', 'GestureRange', 'Enter', 'Event', 'InputHandler', 'Click', 'Gesture'],
  'components-configuration': ['ComponentInfo', 'ComponentValue', 'ComponentOption', 'ComponentCatalogEntry', 'ConfigResult', 'ConfigCallback', 'ComponentInstance', 'ComponentActivity', 'ComponentProps', 'ui.component', 'omniwm.components', 'omniwm.components.activity', 'omniwm.components.add', 'omniwm.components.remove', 'omniwm.components.move', 'omniwm.components.enable', 'omniwm.components.set', 'omniwm.config', 'omniwm.config.set'],
  'services': ['ServiceHandle', 'HTTPRequest', 'HTTPResult', 'StoreStatus', 'omniwm', 'omniwm.http', 'omniwm.after', 'omniwm.store', 'omniwm.store.get', 'omniwm.store.set', 'omniwm.store.status', 'json', 'json.null', 'json.encode', 'json.decode'],
  'resources-desktop': ['Asset', 'ResourceKind', 'Resource', 'DesktopResult', 'DesktopCallback', 'DropEvent', 'DropHoverEvent', 'DragOutEvent', 'omniwm.asset', 'omniwm.resources', 'omniwm.resources.persist', 'omniwm.resources.restore', 'omniwm.pick', 'omniwm.open', 'omniwm.reveal', 'omniwm.quicklook', 'omniwm.share', 'omniwm.clipboard', 'omniwm.clipboard.copy', 'omniwm.clipboard.read'],
  'providers': ['ProviderState', 'ProviderResult', 'ProviderEvent', 'omniwm.provider', 'omniwm.provider.send'],
  'effects-shaders': ['ShaderProps', 'ui.shader'],
};
const topics = Object.fromEntries(Object.entries(assignments).flatMap(([topic, names]) => names.map(name => [name, topic])));
if (Object.values(assignments).flat().length !== Object.keys(topics).length) throw new Error('Duplicate topic assignment');

function braces(line) {
  return line.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, '').split('').reduce((depth, char) => depth + (char === '{' ? 1 : char === '}' ? -1 : 0), 0);
}

function members(declaration) {
  const lines = declaration.split('\n');
  const result = [];
  let depth = braces(lines[0]);
  let pending;
  for (let index = 1; index < lines.length; index++) {
    const match = depth === 1 && lines[index].match(/^\s+([A-Za-z]\w*):/);
    if (match || (depth === 1 && /^\s*}/.test(lines[index]))) {
      if (pending) result.push({ name: pending.name, declaration: lines.slice(pending.start, index).join('\n').trimEnd() });
      pending = match ? { name: match[1], start: index } : undefined;
    }
    depth += braces(lines[index]);
  }
  return result;
}

function fields(declaration) {
  const result = [];
  let depth = 0;
  let parentheses = 0;
  let brackets = 0;
  for (let index = 0; index < declaration.length; index++) {
    const char = declaration[index];
    if (char === '"' || char === "'") {
      const end = new RegExp(`${char}(?:\\\\.|[^${char}\\\\])*${char}`, 'y');
      end.lastIndex = index;
      const match = end.exec(declaration);
      if (!match) throw new Error('Unterminated declaration string');
      if (depth === 1 && parentheses === 0 && brackets === 1 && declaration[index - 1] === '[' && declaration.slice(end.lastIndex).match(/^\]\s*:/)) result.push(match[0].slice(1, -1));
      index = end.lastIndex - 1;
    } else if (char === '{') depth++;
    else if (char === '}') depth--;
    else if (char === '(') parentheses++;
    else if (char === ')') parentheses--;
    else if (char === '[') brackets++;
    else if (char === ']') brackets--;
    else if (depth === 1 && parentheses === 0 && brackets === 0 && /[A-Za-z_]/.test(char) && !/[A-Za-z0-9_]/.test(declaration[index - 1] ?? '')) {
      const match = declaration.slice(index).match(/^([A-Za-z_]\w*)\s*:/);
      if (match) result.push(match[1]);
      const word = declaration.slice(index).match(/^\w+/)[0];
      index += word.length - 1;
    }
  }
  return [...new Set(result)];
}

const source = await readFile(sourceURL, 'utf8');
const starts = [...source.matchAll(/^(export type|declare) (\w+)[^\n]*/gm)];
if (!starts.length || /^(?!export type|declare)(?:export|declare)\b/m.test(source)) throw new Error('Unsupported top-level declaration');
const symbols = [];
function add(name, declaration, kind) {
  if (!topics[name]) throw new Error(`Missing topic assignment: ${name}`);
  const anchor = `api-${name.toLowerCase().replaceAll('.', '-')}`;
  symbols.push({ name, kind, topic: topics[name], anchor, declaration, fields: kind === 'type' ? fields(declaration) : [] });
  if (kind === 'namespace') {
    for (const member of members(declaration)) add(`${name}.${member.name}`, member.declaration, /^\s*\w+: \{\s*\n/.test(member.declaration) ? 'namespace' : 'member');
  }
}
for (let index = 0; index < starts.length; index++) {
  const start = starts[index];
  add(start[2], source.slice(start.index, starts[index + 1]?.index ?? source.length).trimEnd(), start[1] === 'declare' ? 'namespace' : 'type');
}
for (const name of Object.keys(topics)) if (!symbols.some(symbol => symbol.name === name)) throw new Error(`Assigned symbol missing from declarations: ${name}`);
for (const namespace of ['ui', 'omniwm', 'json']) if (!symbols.some(symbol => symbol.name === namespace)) throw new Error(`Missing namespace ${namespace}`);
if (new Set(symbols.map(symbol => symbol.anchor)).size !== symbols.length) throw new Error('Duplicate symbol anchor');
const exported = new Set(symbols.filter(symbol => symbol.kind === 'type').map(symbol => symbol.name));
for (const symbol of symbols) symbol.related = [...new Set(symbol.declaration.match(/\b[A-Z]\w*\b/g) ?? [])].filter(name => name !== symbol.name && exported.has(name));
const data = `${JSON.stringify({ source: 'Sources/OmniWM/Resources/omniwm.d.luau', symbols }, null, 2)}\n`;
if (process.argv.length !== 3 || !['--write', '--check'].includes(process.argv[2])) throw new Error('Usage: node scripts/omnishell-api.mjs --write|--check');
if (process.argv[2] === '--write') await writeFile(outputURL, data);
else if (await readFile(outputURL, 'utf8') !== data) throw new Error(`Luau reference is stale. Run npm run reference:generate to update ${fileURLToPath(outputURL)}`);
const declarations = await Promise.all(Object.keys(assignments).map(topic => readFile(new URL(`../src/content/docs/omnishell/reference/${topic}.mdx`, import.meta.url), 'utf8')));
for (const symbol of symbols) {
  const page = declarations[Object.keys(assignments).indexOf(symbol.topic)];
  if (!page.includes(`name="${symbol.name}"`)) throw new Error(`Reference page ${symbol.topic} does not render ${symbol.name}`);
}
console.log(`Luau reference ${process.argv[2] === '--write' ? 'generated' : 'current'}: ${exported.size} types, ${symbols.length - exported.size} namespace declarations/members; all assigned and rendered.`);

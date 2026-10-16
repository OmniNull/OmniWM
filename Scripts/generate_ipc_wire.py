import argparse
import json
import tempfile
from ipc_wire_models import read_models
import pathlib
import re
import subprocess
root = pathlib.Path(__file__).resolve().parents[1]
models = root / 'Sources/OmniWMIPC'
schemas = read_models(models)
header = '// SPDX-License-Identifier: GPL-2.0-only\n// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM\n\nimport Foundation\n\n'
seen = set()
output = []
primitive = {'String', 'Int', 'Int32', 'Int64', 'UInt', 'UInt32', 'UInt64', 'Bool', 'Double'}

def camel(value):
    words = value.split('-')
    return words[0] + ''.join((x.title() for x in words[1:]))

def field(value, typ):
    return (value, typ)

def object_lines(fields, indent='        ', first='first'):
    lines = [indent + 'begin(123)']
    if fields:
        lines.append(indent + f'var {first} = true')
    for (key, value) in sorted(fields.items()):
        if isinstance(value, dict):
            lines.append(indent + f'self.key("{key}", &{first})')
            lines += object_lines(value, indent, first + 'Nested')
            continue
        (expression, typ) = value
        generate(typ)
        if typ.endswith('?'):
            if re.fullmatch('[a-zA-Z_]\\w*', expression):
                lines += [indent + f'switch {expression} {{', indent + 'case let fieldValue?:', indent + f'    self.key("{key}", &{first})', indent + '    try self.value(fieldValue)', indent + 'case nil:', indent + '    break', indent + '}']
            else:
                lines += [indent + f'if let fieldValue = {expression} {{', indent + f'    self.key("{key}", &{first})', indent + '    try self.value(fieldValue)', indent + '}']
        else:
            lines += [indent + f'self.key("{key}", &{first})', indent + f'try self.value({expression})']
    return lines + [indent + 'end(125)']

def overload(typ, body):
    output.append(f'    mutating func value(_ value: borrowing {typ}) throws {{\n' + '\n'.join(body) + '\n    }')

def enum_object(typ, cases):
    total = sum((len(object_lines(fields)) for (_, fields) in cases)) + len(cases) + 2
    if total > 48:
        body = ['        switch value {']
        for (pattern, fields) in cases:
            name = typ.removeprefix('IPC') + pattern.split('.')[1].split('(')[0].title()
            name = name[0].lower() + name[1:]
            parameters = {}

            def collect(values):
                for entry in values.values():
                    if isinstance(entry, dict):
                        collect(entry)
                    elif re.fullmatch('[a-zA-Z_]\\w*', entry[0]):
                        parameters[entry[0]] = entry[1]
            collect(fields)
            arguments = ', '.join(parameters)
            signature = ', '.join((f'_ {key}: borrowing {ft}' for (key, ft) in parameters.items()))
            output.append(f'    mutating func {name}({signature}) throws {{\n' + '\n'.join(object_lines(fields)) + '\n    }')
            body += ['        case ' + pattern + ':', f'            try {name}({arguments})']
        overload(typ, body + ['        }'])
        return
    body = ['        switch value {']
    for (pattern, fields) in cases:
        body.append('        case ' + pattern + ':')
        body += object_lines(fields, '            ')
    body.append('        }')
    overload(typ, body)

def generate(typ):
    if typ in seen:
        return
    seen.add(typ)
    if typ.endswith('?'):
        return generate(typ[:-1])
    if typ.startswith('['):
        inner = typ[1:-1]
        generate(inner)
        overload(typ, ['        begin(91)', '        var first = true', '        let span = value.span', '        var index = 0', '        while index < span.count {', '            item(&first)', '            try self.value(span[index])', '            index += 1', '        }', '        end(93)'])
        return
    if typ in primitive:
        return
    if typ in custom:
        custom[typ]()
        return
    schema = schemas[typ]
    if 'enum' in schema:
        overload(typ, ['        try self.value(value.rawValue)'])
        return
    assert 'fields' in schema or 'empty' in schema, typ
    fields = {k: field('value.' + k, t) for (k, t) in sorted(schema.get('fields', {}).items())}
    if len(object_lines(fields)) > 47 or sum((ft.endswith('?') for (_, ft) in fields.values())) > 8:
        body = ['        begin(123)', '        var first = true']
        entries = list(fields.items())
        for (index, start) in enumerate(range(0, len(entries), 6)):
            chunk = dict(entries[start:start + 6])
            lines = object_lines(chunk)[2:-1]
            output.append(f'    mutating func fields{index}(_ value: borrowing {typ}, _ first: inout Bool) throws {{\n' + '\n'.join(lines) + '\n    }')
            body.append(f'        try fields{index}(value, &first)')
        overload(typ, body + ['        end(125)'])
    else:
        overload(typ, object_lines(fields))

def payload_root(typ):
    if typ == 'IPCResult':
        fields = {'kind': field('value.kind', 'IPCResultKind')}
        payloads = [(camel(k), v) for (k, v) in schemas[typ]['tagged'].items()]
    else:
        fields = {'authorizationToken': field('value.authorizationToken', 'String?'), 'id': field('value.id', 'String'), 'kind': field('value.kind', 'IPCRequestKind'), 'version': field('value.version', 'Int')}
        payloads = re.findall('^        case (\\w+)\\((\\w+)\\)$', (models / 'IPCRequest.swift').read_text(), re.M)
    body = ['        begin(123)', '        var first = true']
    for key in sorted(list(fields) + ['payload']):
        if key == 'payload':
            body += ['        self.key("payload", &first)', '        switch value.payload {']
            for (case, pt) in payloads:
                generate(pt)
                body += [f'        case let .{case}(payload):', '            try self.value(payload)']
            body.append('        }')
        else:
            (expression, ft) = fields[key]
            generate(ft)
            if ft.endswith('?'):
                body += [f'        if let fieldValue = {expression} {{', f'            self.key("{key}", &first)', '            try self.value(fieldValue)', '        }']
            else:
                body += [f'        self.key("{key}", &first)', f'        try self.value({expression})']
    overload(typ, body + ['        end(125)'])

def variants(typ, mappings):
    cases = []
    schema = schemas[typ]
    disc = schema['discriminator']
    for (raw, variant) in schema['variants'].items():
        (pattern, bindings) = mappings[raw]
        fields = {}
        for (key, ft) in variant['fields'].items():
            if key in variant.get('absent', []):
                continue
            if key == disc:
                fields[key] = field(json.dumps(raw), 'String')
            elif key == 'arguments':
                fields[key] = {k: field(bindings[k], t) for (k, t) in schemas[ft]['fields'].items()}
            else:
                fields[key] = field(bindings[key], ft)
        cases.append((pattern, fields))
    enum_object(typ, cases)

def command():
    argument_types = set()
    generate('IPCCommandName')
    body = ['        begin(123)', '        var first = true', '        switch value {']
    nested = {'focus': 'IPCFocusCommand', 'windowMovement': 'IPCWindowMovementCommand', 'workspace': 'IPCWorkspaceCommand', 'column': 'IPCColumnCommand', 'sizing': 'IPCSizingCommand', 'dwindle': 'IPCDwindleCommand', 'workspaceLayout': 'IPCWorkspaceLayoutCommand', 'scratchpad': 'IPCScratchpadCommand'}
    for (case, typ) in nested.items():
        body += [f'        case let .{case}(command):', '            try arguments(command, &first)']
        source = (root / 'Sources/OmniWMIPC' / f'{typ}.swift').read_text()
        start = source.index('    func encodeArguments(')
        lines = source[start:].split('        switch self {', 1)[1].rsplit('        }', 1)[0]
        lines = lines.strip('\n').splitlines()
        transformed = []
        for line in lines:
            found = re.search('try writer.encode\\((.*)\\)', line)
            if not found:
                transformed.append(line)
                continue
            parameters = dict((part.strip().split(': ', 1) for part in found.group(1).split(',')))
            types = {'direction': 'IPCDirection', 'layout': 'IPCWorkspaceLayout', 'paletteMode': 'IPCCommandPaletteMode', 'sizeChange': 'IPCSizeChange', 'resizeOperation': 'IPCResizeOperation', 'axis': 'IPCResizeAxis', 'operation': 'IPCResizeOperation', 'workspaceNumber': 'Int'}
            names = {'paletteMode': 'mode', 'sizeChange': 'change', 'resizeOperation': 'operation'}
            if 'integer' in parameters:
                fields = {parameters['field'].removeprefix('.'): field(parameters['integer'], 'Int')}
            else:
                fields = {names.get(k, k): field(v, types[k]) for (k, v) in parameters.items()}
            if len(fields) == 1:
                (key, (expression, ft)) = next(iter(fields.items()))
                if ft not in argument_types:
                    argument_types.add(ft)
                    generate(ft)
                    output.append(f'    mutating func argument(_ name: StaticString, _ value: borrowing {ft}, _ first: inout Bool) throws {{\n        self.key("arguments", &first)\n        begin(123)\n        var argumentFirst = true\n        self.key(name, &argumentFirst)\n        try self.value(value)\n        end(125)\n    }}')
                transformed.append(f'            try argument("{key}", {expression}, &first)')
            else:
                transformed += ['            self.key("arguments", &first)'] + object_lines(fields, '            ', 'argumentFirst')
        output.append(f'    mutating func arguments(_ value: borrowing {typ}, _ first: inout Bool) throws {{\n        switch value {{\n' + '\n'.join(transformed) + '\n        }\n    }')
    for (case, ft, key) in [('swapWorkspaceWithMonitor', 'IPCDirection', 'direction'), ('openCommandPaletteMode', 'IPCCommandPaletteMode', 'mode')]:
        body += [f'        case let .{case}(argument):', '            self.key("arguments", &first)'] + object_lines({key: field('argument', ft)}, '            ', 'argumentFirst')
    body += ['        case .monitorFocus, .openCommandPalette, .raiseAllFloatingWindows, .toggleFloatingFocus, .rescueOffscreenWindows, .fullscreen, .presentation, .media, .windowState, .openMenuAnywhere:', '            break', '        }', '        self.key("name", &first)', '        try self.value(value.name)', '        end(125)']
    overload('IPCCommandRequest', body)
custom = {'IPCResult': lambda : payload_root('IPCResult'), 'IPCRequest': lambda : payload_root('IPCRequest'), 'IPCCommandRequest': command, 'WorkspaceTarget': lambda : enum_object('WorkspaceTarget', [(f'let .{case}(text)', {'kind': field(json.dumps(raw), 'String'), 'value': field('text', 'String')}) for (case, raw) in [('rawID', 'raw-id'), ('displayName', 'display-name')]]), 'IPCWindowRequest': lambda : overload('IPCWindowRequest', object_lines({'name': field('value.name', 'IPCWindowActionName'), 'windowId': field('value.windowId', 'String'), 'workspaceTarget': field('value.workspaceTarget', 'WorkspaceTarget?'), 'columnIndex': field('value.columnIndex', 'Int?'), 'direction': field('value.direction', 'IPCDirection?'), 'change': field('value.change', 'IPCSizeChange?'), 'cycle': field('value.cycle', 'IPCCycleDirection?'), 'scratchpadIndex': field('value.scratchpadIndex', 'Int?')})), 'IPCCaptureRequest': lambda : variants('IPCCaptureRequest', {'start': ('let .start(profile)', {'profile': 'profile'}), 'stop': ('.stop', {}), 'status': ('.status', {})}), 'IPCRuleApplyTarget': lambda : variants('IPCRuleApplyTarget', {'focused': ('.focused', {}), 'window': ('let .window(id)', {'windowId': 'id'}), 'pid': ('let .pid(pid)', {'pid': 'pid'})}), 'IPCRuleRequest': lambda : variants('IPCRuleRequest', {k: (f'let .{k}(' + ', '.join(fields) + ')', {f: f for f in fields}) for (k, fields) in [('add', ['rule']), ('replace', ['id', 'rule']), ('remove', ['id']), ('move', ['id', 'position']), ('apply', ['target'])]}), 'IPCWorkspaceRequest': lambda : variants('IPCWorkspaceRequest', {'focus-name': ('let .focusName(target)', {'workspaceTarget': 'target'}), 'move-to-monitor': ('let .moveToMonitor(target, direction, force)', {'workspaceTarget': 'target', 'direction': 'direction', 'force': 'force'}), 'rename': ('let .rename(target, displayName)', {'workspaceTarget': 'target', 'displayName': 'displayName'})}), 'IPCWindowMarkRequest': lambda : variants('IPCWindowMarkRequest', {k: ('.list', {}) if k == 'list' else (f'let .{k}(mark)', {'mark': 'mark'}) for k in ['set', 'list', 'focus', 'summon', 'remove']}), 'IPCShellRequest': lambda : variants('IPCShellRequest', {'set': ('let .set(key, text)', {'key': 'key', 'value': 'text'}), 'unset': ('let .unset(key)', {'key': 'key'}), 'toggle': ('let .toggle(widget)', {'widget': 'widget'}), 'profile': ('let .profile(name)', {'key': 'name'}), 'theme': ('let .theme(name, scheme)', {'key': 'name', 'value': 'scheme'}), 'eject': ('let .eject(widget)', {'widget': 'widget'}), 'init': ('let .initialize(widget)', {'widget': 'widget'}), 'trigger': ('let .trigger(widget, name, text)', {'widget': 'widget', 'key': 'name', 'value': 'text'})})}
for typ in ['IPCResponse', 'IPCEventEnvelope', 'IPCRequest']:
    generate(typ)

def save_generated():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    options = parser.parse_args()
    groups = []
    current = []
    count = 0
    for function in output:
        size = len(function.splitlines()) + 1
        if current and count + size > 260:
            groups.append(current)
            current = []
            count = 0
        current.append(function)
        count += size
    if current:
        groups.append(current)
    expected = {}
    with tempfile.TemporaryDirectory(prefix='ipc-wire-') as directory:
        directory = pathlib.Path(directory)
        for (index, functions) in enumerate(groups, 1):
            name = f'IPCJSONWriter+Models{index:02}.swift'
            path = directory / name
            path.write_text(header + 'extension IPCJSONWriter {\n' + '\n\n'.join(functions) + '\n}\n')
        subprocess.run([str(root / '.cache/dev-tools/bin/swiftformat'), str(directory), '--config', str(root / '.swiftformat')], cwd=root, check=True, capture_output=True)
        expected = {path.name: path.read_text() for path in sorted(directory.glob('*.swift'))}
    existing = {path.name: path for path in models.glob('IPCJSONWriter+Models*.swift')}
    failures = []
    for (name, text) in expected.items():
        path = models / name
        previous = path.read_text() if path.exists() else ''
        if previous != text:
            if options.check:
                failures.append(name)
            else:
                path.write_text(text)
    for (name, path) in existing.items():
        if name not in expected:
            if options.check:
                failures.append(name)
            else:
                path.unlink()
    if failures:
        raise SystemExit('Generated IPC wire files are stale: ' + ', '.join(failures))
    print(f'{len(output)} concrete IPC encoders in {len(expected)} generated files' + (' checked' if options.check else ' generated'))
if __name__ == '__main__':
    save_generated()

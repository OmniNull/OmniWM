import json
import re

def read_models(models):
    schemas = {'IPCCommandName': {'enum': []}}
    for path in sorted(models.glob('*.swift')):
        source = path.read_text()
        for match in re.finditer('public (struct|enum) (\\w+): ([^{]+)\\{', source):
            (kind, name, conforms) = match.groups()
            if 'Codable' not in conforms:
                continue
            start = match.end()
            depth = 1
            end = start
            while depth:
                depth += (source[end] == '{') - (source[end] == '}')
                end += 1
            body = source[start:end - 1]
            if kind == 'enum' and 'String' in conforms:
                variants = re.findall('^    case (\\w+)(?: = "([^"]+)")?\\s*$', body, re.M)
                schemas[name] = {'enum': [raw or symbol for (symbol, raw) in variants]}
            if kind == 'struct':
                fields = re.findall('^    public (?:private\\(set\\) )?(?:let|var) (\\w+): ([\\w?\\[\\]: ]+)\\s*$', body, re.M)
                schemas[name] = {'fields': {k: v.strip() for (k, v) in fields}}
                defaults = re.findall('(\\w+) = try container.decodeIfPresent\\([^\\n]+\\) \\?\\? (\\[\\]|false|true|0)', body)
                if defaults:
                    schemas[name]['defaults'] = {k: json.loads(v) for (k, v) in defaults}
    result_source = (models / 'IPCResult.swift').read_text()
    symbols = dict(((symbol, raw or symbol) for (symbol, raw) in re.findall('^    case (\\w+)(?: = "([^"]+)")?\\s*$', result_source[:result_source.index('public struct IPCPingResult')], re.M)))
    schemas['IPCResult'] = {'tagged': dict(((symbols[symbol], typ) for (symbol, typ) in re.findall('^        case (\\w+)\\((IPC\\w+)\\)$', result_source, re.M)))}

    def object_schema(fields, defaults=None, absent=None):
        out = {'fields': fields}
        if defaults:
            out['defaults'] = defaults
        if absent:
            out['absent'] = absent
        return out

    def variants(name, discriminator, entries):
        schemas[name] = {'discriminator': discriminator, 'variants': entries}
    schemas['IPCNoPayload'] = {'empty': True}
    schemas['WorkspaceTargetKind'] = {'enum': ['raw-id', 'display-name']}
    schemas['WorkspaceTarget'] = object_schema({'kind': 'WorkspaceTargetKind', 'value': 'String'})
    schemas['IPCRuleApplyTargetKind'] = {'enum': ['focused', 'window', 'pid']}
    variants('IPCRuleApplyTarget', 'kind', {'focused': object_schema({'kind': 'IPCRuleApplyTargetKind'}), 'window': object_schema({'kind': 'IPCRuleApplyTargetKind', 'windowId': 'String'}), 'pid': object_schema({'kind': 'IPCRuleApplyTargetKind', 'pid': 'Int32'})})
    variants('IPCCaptureRequest', 'name', {name: object_schema({'name': 'IPCCaptureActionName', **({'profile': 'IPCCaptureProfile'} if name == 'start' else {})}) for name in ['start', 'stop', 'status']})
    variants('IPCWorkspaceRequest', 'name', {'focus-name': object_schema({'name': 'IPCWorkspaceActionName', 'workspaceTarget': 'WorkspaceTarget'}), 'move-to-monitor': object_schema({'name': 'IPCWorkspaceActionName', 'workspaceTarget': 'WorkspaceTarget', 'direction': 'IPCDirection', 'force': 'Bool'}, {'force': False}), 'rename': object_schema({'name': 'IPCWorkspaceActionName', 'workspaceTarget': 'WorkspaceTarget', 'displayName': 'String'})})
    variants('IPCWindowRequest', 'name', {name: object_schema({'name': 'IPCWindowActionName', 'windowId': 'String', 'workspaceTarget': 'WorkspaceTarget' if name == 'move-to-workspace' else 'WorkspaceTarget?'}, absent=None if name == 'move-to-workspace' else ['workspaceTarget']) for name in ['focus', 'navigate', 'summon-right', 'move-to-workspace', 'close']})
    variants('IPCWindowMarkRequest', 'name', {name: object_schema({'name': 'IPCWindowMarkActionName', 'mark': 'String?' if name == 'list' else 'String'}, absent=['mark'] if name == 'list' else None) for name in ['set', 'list', 'focus', 'summon', 'remove']})
    variants('IPCShellRequest', 'name', {'set': object_schema({'name': 'IPCShellActionName', 'key': 'String', 'value': 'String'}), 'unset': object_schema({'name': 'IPCShellActionName', 'key': 'String', 'value': 'String?'}, absent=['value']), 'toggle': object_schema({'name': 'IPCShellActionName', 'widget': 'String'}), 'profile': object_schema({'name': 'IPCShellActionName', 'key': 'String'}), 'theme': object_schema({'name': 'IPCShellActionName', 'key': 'String', 'value': 'String?'}), 'eject': object_schema({'name': 'IPCShellActionName', 'widget': 'String'}), 'init': object_schema({'name': 'IPCShellActionName', 'widget': 'String'}), 'trigger': object_schema({'name': 'IPCShellActionName', 'widget': 'String', 'key': 'String', 'value': 'String?'})})
    rule_fields = {'add': {'rule': 'IPCRuleDefinition'}, 'replace': {'id': 'String', 'rule': 'IPCRuleDefinition'}, 'remove': {'id': 'String'}, 'move': {'id': 'String', 'position': 'Int'}, 'apply': {'target': 'IPCRuleApplyTarget'}}
    for (name, fields) in rule_fields.items():
        schemas['IPCRuleArguments_' + name] = object_schema(fields)
    variants('IPCRuleRequest', 'name', {name: object_schema({'name': 'IPCRuleActionName', 'arguments': 'IPCRuleArguments_' + name}) for name in rule_fields})
    return schemas

import hashlib
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


def png():
    def chunk(name, body):
        value = name + body
        return struct.pack('>I', len(body)) + value + struct.pack('>I', zlib.crc32(value))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00\x00\xff\x00' * 2)) + chunk(b'IEND', b''))


def main():
    provider = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='OmniWM converter ') as temporary:
        root = pathlib.Path(temporary)
        source = root / 'input image.png'
        source.write_bytes(png())
        digest = hashlib.sha256(source.read_bytes()).digest()
        outputs = {name: root / name for name in ['png', 'jpeg', 'invalid', 'missing']}
        for path in outputs.values():
            path.mkdir()
        def action(request, form, directory, path=source):
            return ['action', request, 'convert', {'format': form},
                    {'files': [{'name': source.name, 'path': str(path)}], 'outputDirectory': str(directory)}]
        actions = [action('r1', 'png', outputs['png']), action('r2', 'jpeg', outputs['jpeg']),
                   action('r3', 'shell-command', outputs['invalid']),
                   action('r4', 'png', outputs['missing'], root / 'absent.png')]
        run = subprocess.run([str(provider)], input=''.join(json.dumps(action) + '\n' for action in actions),
                             text=True, capture_output=True, timeout=30, check=True)
        messages = [json.loads(line) for line in run.stdout.splitlines()]
        assert all(isinstance(message, list) and message[0] in ['state', 'result'] for message in messages)
        results = {message[1]: message for message in messages if message[0] == 'result'}
        assert len(results) == 4, results
        for request, kind, signature in [('r1', 'png', b'\x89PNG'), ('r2', 'jpeg', b'\xff\xd8')]:
            result = results[request]
            assert result[2] is True and result[3]['converted'] == 1, result
            files = result[4]['files']
            assert len(files) == 1 and set(files[0]) == {'name', 'path'}, files
            path = pathlib.Path(files[0]['path'])
            assert not path.is_absolute() and len(path.parts) == 1, path
            assert (outputs[kind] / path).read_bytes().startswith(signature), path
        assert results['r3'] == ['result', 'r3', False, 'invalid_format'], results['r3']
        assert results['r4'] == ['result', 'r4', False, 'invalid_input'], results['r4']
        assert not list(outputs['invalid'].iterdir()) and not list(outputs['missing'].iterdir())
        assert hashlib.sha256(source.read_bytes()).digest() == digest
        print('converter protocol: PNG/JPEG outputs, relative attachment paths, failures and unchanged input passed')


if __name__ == '__main__':
    main()

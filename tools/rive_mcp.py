#!/usr/bin/env python3
"""Calls tools on the Rive desktop editor's local MCP server (port 9791).

For payloads too large to pass by hand: generated scripts and image assets.

  rive_mcp.py script <rive/path> <file.luau>   create a Luau utility script
  rive_mcp.py image <asset-name> <file.png|jpg> upload an image asset
  rive_mcp.py sync <rive/path> <file.luau>     replace an existing script's
                                               source with the file, recompile
                                               and print diagnostics
"""

import base64
import difflib
import json
import mimetypes
import os
import sys
import urllib.parse
import urllib.request

URL = 'http://127.0.0.1:9791/mcp'
HEADERS = {'Content-Type': 'application/json',
           'Accept': 'application/json, text/event-stream'}


def post(body, session=None):
    headers = dict(HEADERS)
    if session:
        headers['mcp-session-id'] = session
    req = urllib.request.Request(URL, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read().decode()
        sid = resp.headers.get('mcp-session-id')
    lines = [l[5:].strip() for l in raw.splitlines() if l.startswith('data:')]
    return json.loads(lines[-1] if lines else raw), sid


def call(tool, arguments):
    _, sid = post({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                   'params': {'protocolVersion': '2025-11-25', 'capabilities': {},
                              'clientInfo': {'name': 'rive-vr', 'version': '1'}}})
    result, _ = post({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                      'params': {'name': tool, 'arguments': arguments}}, sid)
    if 'error' in result:
        sys.exit(json.dumps(result['error']))
    return result['result']['content'][0]['text']


def view_script(name):
    text = call('text_editor', {'command': 'view', 'path': name})
    text = json.loads(text)['content'] if text.startswith('{') else text
    # The view appends a newline the stored script does not have; matching
    # against it fails for any edit touching the end of the file.
    return text.rstrip('\n')


def sync_script(name, new):
    """Makes the editor's script match `new`, one changed hunk at a time.

    Replacing the whole file in one str_replace is not reliable in the editor,
    so each hunk is replaced with a few lines of unchanged context around it
    (enough to be unique), applied bottom-up so earlier offsets stay valid.
    """
    current = view_script(name)
    if current.rstrip('\n') == new.rstrip('\n'):
        call('recompile_all_scripts', {})
        return call('script_diagnostics', {'path': name})
    a = current.split('\n')
    b = new.rstrip('\n').split('\n')
    ops = [op for op in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
           if op[0] != 'equal']
    for tag, i1, i2, j1, j2 in reversed(ops):
        for ctx in (2, 4, 8, 16):
            s1, e1 = max(0, i1 - ctx), min(len(a), i2 + ctx)
            old_block = '\n'.join(a[s1:e1])
            if old_block and current.count(old_block) == 1:
                break
        new_block = '\n'.join(a[s1:i1] + b[j1:j2] + a[i2:e1])
        result = call('text_editor', {'command': 'str_replace', 'path': name,
                                      'old_string': old_block, 'new_string': new_block})
        if 'Error' in result:
            sys.exit(f'hunk at line {i1 + 1} failed: {result}')
        a[i1:i2] = b[j1:j2]
        current = '\n'.join(a)
    if view_script(name).rstrip('\n') != new.rstrip('\n'):
        sys.exit('sync finished but the editor text still differs')
    call('recompile_all_scripts', {})
    return call('script_diagnostics', {'path': name})


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    kind, name, path = sys.argv[1:]
    if kind == 'script':
        content = open(path).read()
        out = call('manage_scripts', {'command': 'create', 'data': {
            'create': [{'name': name, 'code_file_type': 'luau', 'content': content}]}})
    elif kind == 'image':
        mime = mimetypes.guess_type(path)[0] or 'image/png'
        data = base64.b64encode(open(path, 'rb').read()).decode()
        filename = urllib.parse.quote(os.path.basename(path))
        out = call('upload_asset', {'file': f'data:{mime};name={filename};base64,{data}',
                                    'name': name})
    elif kind == 'sync':
        new = open(path).read()
        out = sync_script(name, new)
    else:
        sys.exit(__doc__)
    print(out[:2000])


if __name__ == '__main__':
    main()

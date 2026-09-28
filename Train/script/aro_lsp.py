"""The action reference, taken from the ARO language server.

`Examples/list-of-actions.txt` — one canonical example line per action, which
NB08 trained the model's action vocabulary from — was deleted in #828, which
made `aro actions` the live source instead of a hand-maintained file. NB08 kept
reading the file and the stage died on a FileNotFoundError.

The replacement asks the language server, over stdio LSP, the same two questions
an editor asks:

* `textDocument/completion` at the start of a statement — every verb the running
  registry accepts, each with its role and description. This is the list of
  actions, and it cannot drift from the runtime because `AROCatalog` is what
  both the LSP and `aro actions` read.
* `textDocument/signatureHelp` after `<Verb> the ` — that action's canonical
  form, e.g. `Extract the <result: qualifier> from the <source: qualifier>.`

**A signature is not a program**, and that matters here because these lines
become training data. Seven of the ~50 signatures the server knows do not
compile: `Compute the <result: operation> from <input>.` names a qualifier that
does not exist (the qualifier namespace is closed, GitLab #486), `Close the
<connection>.` has no preposition, `Publish` is shown in angle brackets. They
are fine as editor hints and wrong as examples. So every line is put through
`aro check` before it is used, and a verb whose signature fails falls back to a
minimal statement built from its own prepositions — checked too. A verb no line
can be built for is dropped and counted, rather than teaching the model
something that does not parse.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aro_oracle  # noqa: E402
import extract_action_catalog  # noqa: E402

REPO = aro_oracle.REPO
COMPLETION_KIND_FUNCTION = 3        # LSP CompletionItemKind.Function — the verbs
DEFAULT_TIMEOUT = 30.0

# Tried in order when an action's own prepositions produce nothing that checks.
FALLBACK_PREPOSITIONS = ('from', 'to', 'with', 'for', 'on', 'into', 'at',
                         'against', 'via', 'by')


class LanguageServerError(RuntimeError):
    pass


class AROLanguageServer:
    """A minimal stdio LSP client for `aro lsp`. Use as a context manager.

    Replies are read on a background thread so a silent server times out
    instead of hanging the stage — the pipeline has been down that road.
    """

    def __init__(self, binary=None, root=None, timeout=DEFAULT_TIMEOUT):
        self.binary = binary or aro_oracle.require_aro_bin()
        self.root = Path(root or REPO).resolve()
        self.timeout = timeout
        self._proc = None
        self._replies: queue.Queue = queue.Queue()
        self._reader = None
        self._next_id = 0
        self._version = 0
        self._uri = f'file://{self.root}/__aro_lsp_probe__.aro'

    # ── lifecycle ───────────────────────────────────────────────────────────

    def __enter__(self):
        self._proc = subprocess.Popen(
            [self.binary, 'lsp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd=str(self.root))
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        self.request('initialize', {
            'processId': os.getpid(),
            'rootUri': f'file://{self.root}',
            'capabilities': {},
        })
        self.notify('initialized', {})
        return self

    def __exit__(self, *_exc):
        try:
            self.notify('exit', {})
        except Exception:
            pass
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        return False

    # ── framing ─────────────────────────────────────────────────────────────

    def _pump(self):
        """Read framed messages until the server closes. Runs on its own thread."""
        out = self._proc.stdout
        try:
            while True:
                length = None
                while True:
                    line = out.readline()
                    if not line:
                        return
                    line = line.strip()
                    if not line:
                        break
                    name, _, value = line.decode('utf-8', 'replace').partition(':')
                    if name.strip().lower() == 'content-length':
                        length = int(value.strip())
                if length is None:
                    continue
                body = out.read(length)
                self._replies.put(json.loads(body))
        except Exception as exc:                        # server died mid-message
            self._replies.put({'__error__': str(exc)})

    def notify(self, method, params):
        self._write({'jsonrpc': '2.0', 'method': method, 'params': params})

    def request(self, method, params):
        self._next_id += 1
        want = self._next_id
        self._write({'jsonrpc': '2.0', 'id': want, 'method': method,
                     'params': params})
        while True:
            try:
                msg = self._replies.get(timeout=self.timeout)
            except queue.Empty:
                raise LanguageServerError(
                    f'`{Path(self.binary).name} lsp` did not answer '
                    f'{method} within {self.timeout:.0f}s')
            if '__error__' in msg:
                raise LanguageServerError(
                    f'`aro lsp` closed the connection: {msg["__error__"]}')
            if msg.get('id') == want:
                if 'error' in msg:
                    raise LanguageServerError(f'{method}: {msg["error"]}')
                return msg.get('result')
            # Anything else is a diagnostic or log notification — not ours.

    def _write(self, message):
        raw = json.dumps(message).encode()
        self._proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(raw) + raw)
        self._proc.stdin.flush()

    # ── the two questions ───────────────────────────────────────────────────

    def open_document(self, text):
        self._version = 1
        self.notify('textDocument/didOpen', {'textDocument': {
            'uri': self._uri, 'languageId': 'aro', 'version': 1, 'text': text}})

    def change_document(self, text):
        self._version += 1
        self.notify('textDocument/didChange', {
            'textDocument': {'uri': self._uri, 'version': self._version},
            'contentChanges': [{'text': text}]})

    def completion(self, line, character):
        result = self.request('textDocument/completion', {
            'textDocument': {'uri': self._uri},
            'position': {'line': line, 'character': character}})
        if isinstance(result, dict):
            return result.get('items', [])
        return result or []

    def signature_help(self, line, character):
        result = self.request('textDocument/signatureHelp', {
            'textDocument': {'uri': self._uri},
            'position': {'line': line, 'character': character}})
        signatures = (result or {}).get('signatures') or []
        return signatures[0] if signatures else None


# ── Assembling the reference ────────────────────────────────────────────────

def _split_detail(detail):
    """`'[REQUEST] Pulls data in'` → `('request', 'Pulls data in')`."""
    detail = (detail or '').strip()
    role, description = '', detail
    if detail.startswith('['):
        role, _, description = detail[1:].partition(']')
    return role.strip().lower(), description.strip()


def verb_menu(server):
    """Every action verb the server offers at the start of a statement.

    Returns `{Verb: {'role': …, 'description': …}}` with the server's own
    capitalisation, which is also how the signature database is keyed.
    """
    server.open_document('(Application-Start: Probe) {\n    \n}\n')
    menu = {}
    for item in server.completion(line=1, character=4):
        if item.get('kind') != COMPLETION_KIND_FUNCTION:
            continue                        # keywords and snippets, not verbs
        role, description = _split_detail(item.get('detail'))
        menu[item['label']] = {'role': role, 'description': description}
    return menu


def signature_for(server, verb):
    """The server's canonical form for `verb`, or None.

    `signatureHelp` keys off a statement opener, so the probe line has to look
    like one: the handler matches `Verb the|a|an|<`, not a bare verb.
    """
    line = f'    {verb} the '
    server.change_document(f'(Application-Start: Probe) {{\n{line}\n}}\n')
    signature = server.signature_help(line=1, character=len(line))
    return signature.get('label') if signature else None


def _candidate_lines(verb, signature, prepositions):
    """Example lines to try for `verb`, best first."""
    candidates = []
    if signature:
        candidates.append(signature)
    for preposition in list(prepositions) + list(FALLBACK_PREPOSITIONS):
        line = f'{verb} the <result> {preposition} the <source>.'
        if line not in candidates:
            candidates.append(line)
    return candidates


def action_reference(binary=None, root=None, progress=None):
    """One validated example line per action, from the language server.

    Returns a list of `{verb, role, description, example_line, signature,
    from_signature}` — `verb` lowercased, the shape NB08 consumes — plus a
    `stats` dict as the second element, whose `all_verbs` is every verb the
    registry answers to (aliases included).
    """
    catalog = extract_action_catalog.load()
    canonical_of = {alias: canonical
                    for canonical, meta in catalog.items()
                    for alias in list(meta.get('aliases') or []) + [canonical]}

    with AROLanguageServer(binary=binary, root=root) as server:
        menu = verb_menu(server)
        signatures = {verb: signature_for(server, verb) for verb in menu}

    # One entry per action, not per verb: the catalog groups aliases, and the
    # old file listed each action once. Aliases get their own pair type in NB08.
    chosen = {}
    for verb, meta in menu.items():
        key = canonical_of.get(verb.lower(), verb.lower())
        # Prefer the verb whose signature the server knows, then the one that
        # is the action's canonical name.
        rank = (signatures.get(verb) is not None, verb.lower() == key)
        if key not in chosen or rank > chosen[key][0]:
            chosen[key] = (rank, verb, meta)

    actions, stats = [], {'verbs': len(menu), 'candidates': len(chosen),
                          'actions': 0,
                          # Every verb the registry answers to, aliases
                          # included — what "is this a real ARO verb?" should
                          # be asked of.
                          'all_verbs': sorted(v.lower() for v in menu),
                          'from_signature': 0, 'synthesised': 0, 'dropped': []}
    for key, (_rank, verb, meta) in sorted(chosen.items()):
        signature = signatures.get(verb)
        prepositions = catalog.get(key, {}).get('prepositions') or []
        example, from_signature = None, False
        for index, candidate in enumerate(_candidate_lines(
                verb, signature, prepositions)):
            valid, _output = aro_oracle.check_block(candidate)
            if valid:
                example, from_signature = candidate, (index == 0 and bool(signature))
                break
        if progress:
            progress(verb, example)
        if example is None:
            stats['dropped'].append(key)
            continue
        stats['from_signature' if from_signature else 'synthesised'] += 1
        actions.append({
            'verb': key,
            'role': meta['role'].upper(),
            'description': meta['description'],
            'example_line': example,
            'signature': signature,
            'from_signature': from_signature,
        })
    stats['actions'] = len(actions)
    return actions, stats


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true',
                        help='print the reference as JSON')
    args = parser.parse_args(argv)

    actions, stats = action_reference()
    if args.json:
        print(json.dumps(actions, indent=1, ensure_ascii=False))
    else:
        for action in actions:
            origin = 'sig' if action['from_signature'] else 'built'
            print(f'  [{action["role"]:8s}] {action["verb"]:16s} '
                  f'({origin}) {action["example_line"]}')
    print(f'\n{stats["actions"]} actions from {stats["verbs"]} verbs — '
          f'{stats["from_signature"]} from signatures, '
          f'{stats["synthesised"]} built from prepositions, '
          f'{len(stats["dropped"])} dropped', file=sys.stderr)
    if stats['dropped']:
        print(f'  dropped: {", ".join(stats["dropped"])}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())

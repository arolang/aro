"""What a released model has to say about the language it was trained for (GitLab #807).

`release/model_manifest.json` described the model and said nothing about ARO.
It carried a model id, a source label, a base model, a quantisation, a checksum,
a size, a build time, `cli_command: "aro ask"` — and `min_cli_version: "1.0.0"`,
for a CLI whose newest tag is 0.12.1 and which has never had a 1.x release. A
model that records no ARO version cannot be matched to the language it was
trained for: an action or a qualifier that changed between the training corpus
and the running toolchain produces confident, wrong ARO, and nothing in the
artefact lets anyone notice. And a `min_cli_version` that is simply invented is
worse than none, because the moment anything enforces it, it enforces a fiction.

This module produces the four facts the manifest was missing and one it got
wrong:

  * `aro_version` / `aro_commit` — the ARO-Lang tag and commit the model was
    built against. The corpus metadata already stamps `aro_lang_commit` on every
    artifact (`config.build_artifact_metadata`); it was never propagated to the
    released model.
  * `catalog_hash` — a digest of the action and qualifier catalogues the model
    was trained on. Two releases with the same base model and different
    catalogues are different models in the way that matters, and this is the
    key a CLI can compare against its own catalogue to tell a user that the
    model predates the verbs it is being asked about.
  * `corpus_hash` — a digest of the training corpus, so a release can be tied to
    the data that produced it.
  * `system_prompt_hash` — the prompt is part of the artefact (it ships inside
    the model directory and `aro ask` reads it back), so it is versioned with
    the same key rather than drifting silently against the weights.
  * `min_cli_version` — *derived*, not chosen. See `derive_min_cli_version`.

Everything here is pure except the two functions that shell out to git, and both
of those take an injectable runner so the derivation is testable without a
repository in a particular state.
"""

import hashlib
import json
import re
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TRAIN_ROOT = SCRIPT_DIR.parent
ARO_ROOT = (TRAIN_ROOT / '..').resolve()

# The tools `aro ask` registers, and therefore the vocabulary a model's replies
# may use. A CLI that does not have all of them cannot run this model's answers:
# a call to a tool it never registered is silently nothing. Mirrors
# Sources/AROAsk/Tools/* and Sources/AROAsk/Retrieval/SearchTool.swift.
ASK_TOOLS = (
    'read_file', 'write_file', 'edit_file', 'list_dir', 'grep', 'search_project',
    'aro_check', 'aro_run', 'aro_build', 'aro_test', 'parse_aro', 'list_actions',
    'list_proposals', 'read_proposal', 'create_plugin', 'write_openapi',
    'generate_docs', 'run_shell',
)

SEMVER_TAG = re.compile(r'^\d+\.\d+\.\d+$')


def _run(args, cwd=None):
    """Default git runner. Returns stdout, or '' on any failure — provenance
    degrades to 'unknown' rather than failing a release build."""
    try:
        r = subprocess.run(args, cwd=str(cwd) if cwd else None,
                           capture_output=True, text=True, timeout=30)
        return r.stdout if r.returncode == 0 else ''
    except Exception:
        return ''


# ── Version and commit ───────────────────────────────────────────────────────

def aro_commit(repo=ARO_ROOT, run=_run):
    """The ARO-Lang HEAD commit the model was built against."""
    return (run(['git', '-C', str(repo), 'rev-parse', 'HEAD']).strip() or None)


def aro_version(repo=ARO_ROOT, run=_run):
    """The ARO-Lang version, as `git describe` reports it.

    A tagged build gives the tag; anything else gives the tag plus the distance
    and commit, which is the honest answer for a model trained between releases
    and is exactly what the CLI's own version stamp does.
    """
    v = run(['git', '-C', str(repo), 'describe', '--tags', '--always']).strip()
    return v or None


def semver_tags(repo=ARO_ROOT, run=_run):
    """Released CLI versions, oldest first. Only bare `N.N.N` tags count — the
    repository also carries `v0.1.0-beta.4`-style pre-release tags and
    non-version tags like `intellij-v1.4.2`, and neither is a CLI release a user
    can be told to install."""
    tags = [t for t in run(['git', '-C', str(repo), 'tag', '--list']).split()
            if SEMVER_TAG.match(t)]
    return sorted(tags, key=lambda t: tuple(int(x) for x in t.split('.')))


def first_tag_containing(needle, path, repo=ARO_ROOT, run=_run, tags=None):
    """The earliest released version whose tree contains `needle` under `path`.

    Implemented as `git log -S` for the first commit that introduced the string,
    then the earliest semver tag that contains that commit. This is archaeology
    rather than judgement, which is the point: the answer is recomputable and
    does not depend on anyone remembering when a feature shipped.
    """
    tags = semver_tags(repo, run) if tags is None else tags
    out = run(['git', '-C', str(repo), 'log', '-S', needle, '--reverse',
               '--format=%H', '--', path])
    commits = out.split()
    if not commits:
        return None
    contains = set(run(['git', '-C', str(repo), 'tag', '--contains',
                        commits[0]]).split())
    for t in tags:
        if t in contains:
            return t
    return None


def derive_min_cli_version(model_id, repo=ARO_ROOT, run=_run, tools=ASK_TOOLS):
    """The oldest released CLI that can actually run this model.

    Two things have to be true of a CLI before this artefact works on it, and
    both are facts in the repository rather than opinions:

      1. it registers every tool the model was trained to call — a reply that
         invokes a tool the CLI never registered does nothing at all;
      2. it knows this model id, i.e. `aro ask` resolves it without the user
         having to pass `--model`.

    The answer is the later of the two. For `ARO-Lang/aro-coder-6bit` that is
    0.11.3: the whole tool vocabulary landed together in 0.10.0, and 0.11.3 is
    the release in which the default model became the 6-bit build. Note what
    this is *not*: a guess at which CLI is "modern enough". A model's minimum is
    a property of when its interface shipped.

    Returns (version, basis) so the manifest can record how it was derived; the
    version is None when the repository cannot answer, and callers must record
    that rather than substituting a plausible number.
    """
    tags = semver_tags(repo, run)
    basis = {}

    tool_tags = []
    for tool in tools:
        t = first_tag_containing(f'name: "{tool}"', 'Sources/AROAsk',
                                 repo=repo, run=run, tags=tags)
        if t:
            tool_tags.append(t)
    tool_floor = max(tool_tags, key=_key) if tool_tags else None
    basis['tool_vocabulary'] = tool_floor
    basis['tools_checked'] = len(tools)
    basis['tools_located'] = len(tool_tags)

    model_floor = first_tag_containing(model_id, 'Sources/AROAsk',
                                       repo=repo, run=run, tags=tags)
    basis['default_model_id'] = model_floor

    candidates = [t for t in (tool_floor, model_floor) if t]
    if not candidates:
        return None, basis
    version = max(candidates, key=_key)
    basis['derived'] = version
    return version, basis


def _key(tag):
    return tuple(int(x) for x in tag.split('.'))


# ── Hashes ───────────────────────────────────────────────────────────────────
# All three are SHA-256 over a canonical JSON rendering, truncated to 16 hex
# characters. Truncated because these are identity keys a human compares by eye
# in a warning message, not signatures; canonical because a hash that changes
# when a dict is reordered tells nobody anything.

def _digest(obj):
    blob = json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(blob.encode('utf-8')).hexdigest()[:16]


def catalog_hash(actions, qualifiers):
    """Identity of the action and qualifier catalogues the model was trained on.

    Only the parts a model's output depends on go in: the verbs, their roles and
    prepositions, and the qualifier names. Descriptions and examples move with
    documentation edits that change nothing about what compiles, and a hash that
    changes for those would cry wolf on every release.
    """
    acts = {}
    for name, entry in (actions or {}).items():
        if isinstance(entry, dict):
            acts[name] = {
                'role': entry.get('role'),
                'prepositions': sorted(entry.get('prepositions') or []),
                'verbs': sorted(entry.get('verbs') or []),
            }
        else:
            acts[name] = {}
    quals = sorted((qualifiers or {}).keys())
    return _digest({'actions': acts, 'qualifiers': quals})


def catalog_hash_from_files(action_path=None, qualifier_path=None):
    """catalog_hash for the catalogues on disk beside this module."""
    action_path = Path(action_path or SCRIPT_DIR / 'aro_action_catalog.json')
    qualifier_path = Path(qualifier_path or SCRIPT_DIR / 'aro_qualifier_catalog.json')
    actions = json.loads(action_path.read_text()) if action_path.exists() else {}
    quals = json.loads(qualifier_path.read_text()) if qualifier_path.exists() else {}
    return catalog_hash(actions, quals)


def corpus_hash(paths):
    """Identity of the training corpus: size and content digest per file.

    Files that do not exist are recorded as absent rather than skipped, so a
    corpus that lost a file hashes differently from one that never had it.
    """
    entries = {}
    for p in paths:
        p = Path(p)
        if not p.exists():
            entries[p.name] = None
            continue
        h = hashlib.sha256()
        with open(p, 'rb') as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b''):
                h.update(chunk)
        entries[p.name] = {'size': p.stat().st_size, 'sha256': h.hexdigest()[:32]}
    return _digest(entries)


def system_prompt_hash(prompt):
    """Identity of the system prompt shipped with the model."""
    return hashlib.sha256((prompt or '').encode('utf-8')).hexdigest()[:16]


# ── The manifest ─────────────────────────────────────────────────────────────

MANIFEST_SCHEMA = 2   # 1 was the nine-key manifest that recorded no ARO version


def build_manifest(*, model_id, source_label, base_model, quantization,
                   checksum, size_bytes, built_at, system_prompt,
                   repo=ARO_ROOT, run=_run, corpus_paths=(),
                   action_catalog=None, qualifier_catalog=None,
                   cli_command='aro ask'):
    """The manifest a released model ships with.

    `min_cli_version` is derived and accompanied by `min_cli_version_basis`, so
    a reader can see *why* it says what it says and recompute it. When the
    derivation cannot run, the field is null and `basis.reason` says so — an
    absent minimum is honest and a fabricated one is not.
    """
    version, basis = derive_min_cli_version(model_id, repo=repo, run=run)
    if version is None:
        basis['reason'] = ('could not be derived from the ARO-Lang repository; '
                           'recorded as null rather than guessed')
    manifest = {
        'manifest_schema': MANIFEST_SCHEMA,
        'model_id': model_id,
        'source_label': source_label,
        'base_model': str(base_model),
        'quantization': quantization,
        'checksum': checksum,
        'size_bytes': size_bytes,
        'built_at': built_at,
        'cli_command': cli_command,
        'min_cli_version': version,
        'min_cli_version_basis': basis,
        # ── What language this model speaks ──────────────────────────────────
        'aro_version': aro_version(repo, run),
        'aro_commit': aro_commit(repo, run),
        'catalog_hash': catalog_hash(action_catalog, qualifier_catalog)
        if action_catalog is not None or qualifier_catalog is not None
        else catalog_hash_from_files(),
        'corpus_hash': corpus_hash(corpus_paths),
        'system_prompt_hash': system_prompt_hash(system_prompt),
    }
    return manifest


def catalog_drift(manifest, running_catalog_hash):
    """Does the running toolchain's catalogue differ from the model's?

    Returns None when they agree or when either side is unknown, and a sentence
    otherwise — the text `aro ask` would print. The check lives here, in the
    pipeline that knows what a release means, so the CLI side is a one-line
    comparison whenever someone adds it.
    """
    theirs = (manifest or {}).get('catalog_hash')
    if not theirs or not running_catalog_hash:
        return None
    if theirs == running_catalog_hash:
        return None
    return (f'This model was trained against ARO action catalog {theirs}; this '
            f'CLI has {running_catalog_hash}. Actions or qualifiers have changed '
            'since the model was built, so it may write ARO that no longer '
            'compiles.')


def _main(argv=None):  # pragma: no cover - a convenience for humans
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--model-id', default='ARO-Lang/aro-coder-6bit')
    ap.add_argument('--repo', default=str(ARO_ROOT))
    args = ap.parse_args(argv)
    version, basis = derive_min_cli_version(args.model_id, repo=Path(args.repo))
    print(f'aro_version    {aro_version(Path(args.repo))}')
    print(f'aro_commit     {aro_commit(Path(args.repo))}')
    print(f'catalog_hash   {catalog_hash_from_files()}')
    print(f'min_cli_version {version}')
    print(json.dumps(basis, indent=2))
    return 0


if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(_main())

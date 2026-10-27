"""Plugin stratum: authoring and calling plugins (GitLab #785).

GitLab #797 calls plugin authoring thin. It is also split across two skills
that fail independently, so this stratum is split the same way:

  * 20 rows whose answer is **ARO** — the call site. Graded by `aro check`,
    which accepts a namespaced qualifier and a `Handle.Verb` action without
    loading any plugin, so the grade is exactly "did you write the call
    correctly" and not "is that plugin installed".
  * 15 rows whose answer is **not ARO** — a `plugin.yaml`, a Rust `extern "C"`
    surface, the C SDK macros, the Python decorators, a Swift `@AROExport`.
    There is nothing for `aro check` to judge, so these are graded by the same
    rubric the explain stratum uses: the phrases a correct answer must contain
    (`aro_plugin_info`, `#[no_mangle]`, `handle:`) and the ones a wrong answer
    reaches for.

The rubric is crude and it is the right crude: the recorded failure mode for
plugin questions is a confident answer in the wrong language's idiom — a Python
plugin described with Rust's macros, a manifest with `handler:` at the root —
and a `must_not_include` naming that idiom catches it without a judge model.

Each row: (id, domain, kind, prompt, reference, must_include, must_not_include)
where kind is 'aro' (graded by `aro check`) or 'rubric' (graded by phrases).
"""

ROWS = [
    # ── ARO-side: calling plugin qualifiers and actions ──────────────────────
    ('plugin-001', 'plugin', 'aro',
     'A Collections plugin provides a pick-random qualifier. Write the '
     'complete ARO application that picks one of three ferry ports at random '
     'and logs it.',
     '(Application-Start: Port Picker) {\n'
     '    Create the <ports> with ["dover", "calais", "ostend"].\n'
     '    Compute the <chosen: collections.pick-random> from the <ports>.\n'
     '    Log <chosen> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-002', 'plugin', 'aro',
     'The same Collections plugin provides shuffle. Write the application '
     'that shuffles the four curling sheet numbers and logs the shuffled '
     'list.',
     '(Application-Start: Sheet Shuffle) {\n'
     '    Create the <sheets> with [1, 2, 3, 4].\n'
     '    Compute the <order: collections.shuffle> from the <sheets>.\n'
     '    Log <order> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-003', 'plugin', 'aro',
     'A Stats plugin exposes a sort qualifier. Write the application that '
     'sorts the three glacier stake readings with it and logs them. Use the '
     "plugin's qualifier, not the built-in Sort action.",
     '(Application-Start: Stake Order) {\n'
     '    Create the <stakes> with [24, 12, 18].\n'
     '    Compute the <ordered: stats.sort> from the <stakes>.\n'
     '    Log <ordered> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-004', 'plugin', 'aro',
     'Log a reversed list inline, without binding it first: a Collections '
     'plugin provides reverse, and the three tram routes should come out '
     'backwards. Complete application.',
     '(Application-Start: Route Reverse) {\n'
     '    Create the <routes> with ["7", "3", "11"].\n'
     '    Log <routes: collections.reverse> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-005', 'plugin', 'aro',
     'A Markdown plugin whose handle is Markdown provides a ToHTML action. '
     'Write the application that renders a one-line heading through it and '
     'logs the HTML.',
     '(Application-Start: Rendering) {\n'
     '    Create the <source> with "# Lock Keeper Notes".\n'
     '    Markdown.ToHTML the <page> with <source>.\n'
     '    Log <page> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-006', 'plugin', 'aro',
     'A Hash plugin with handle Hash provides a Digest action taking an '
     'object with a `text` field. Write the application that digests a bell '
     'inscription and logs the result.',
     '(Application-Start: Inscription Digest) {\n'
     '    Create the <text> with "cast in 1742".\n'
     '    Hash.Digest the <digest> with { text: <text> }.\n'
     '    Log <digest> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-007', 'plugin', 'aro',
     'A Csv plugin provides a Parse action that takes { path } and binds the '
     'rows. Write the application that parses ./intake.csv through it and logs '
     'how many rows came back.',
     '(Application-Start: Intake Parse) {\n'
     '    Csv.Parse the <rows> with { path: "./intake.csv" }.\n'
     '    Compute the <count: length> from the <rows>.\n'
     '    Log <count> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-008', 'plugin', 'aro',
     'Chain a built-in qualifier into a plugin one: trim a ring code and then '
     'put it through a Stats plugin qualifier called normalise, in a single '
     'Compute. Complete application, logging the result.',
     '(Application-Start: Ring Normalise) {\n'
     '    Create the <raw> with "  GB-2291  ".\n'
     '    Compute the <ring: trim|stats.normalise> from <raw>.\n'
     '    Log <ring> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-009', 'plugin', 'aro',
     'A Sqlite plugin with handle Sqlite provides a Query action taking '
     '{ database, sql }. Write the application that queries the kiln database '
     'for firings and logs the row count.',
     '(Application-Start: Kiln Query) {\n'
     '    Sqlite.Query the <rows> with { database: "./kiln.db", '
     'sql: "SELECT * FROM firings" }.\n'
     '    Compute the <count: length> from the <rows>.\n'
     '    Log <count> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-010', 'plugin', 'aro',
     'A Zip plugin with handle Zip provides Compress, taking { source, '
     'target }. Write the application that compresses ./out into ./out.zip '
     'and logs that it is done.',
     '(Application-Start: Archiving) {\n'
     '    Zip.Compress the <archive> with { source: "./out", '
     'target: "./out.zip" }.\n'
     '    Log "archived" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-011', 'plugin', 'aro',
     'Use a plugin qualifier on a field of a record: a Geo plugin provides '
     'grid-ref, and a lighthouse record carries a `position`. Write the '
     'application that logs the gridded position.',
     '(Application-Start: Gridding) {\n'
     '    Create the <light> with { name: "beachy head", position: '
     '"50.73,0.24" }.\n'
     '    Extract the <position> from the <light: position>.\n'
     '    Compute the <grid: geo.grid-ref> from <position>.\n'
     '    Log <grid> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-012', 'plugin', 'aro',
     'Inside a route handler: GET /sheets/random picks a random sheet with a '
     "Collections plugin qualifier and returns it. operationId randomSheet. "
     'Write the contract and the application.',
     '(randomSheet: Curling API) {\n'
     '    Retrieve the <sheets> from the <sheet-repository>.\n'
     '    Compute the <chosen: collections.pick-random> from the <sheets>.\n'
     '    Return an <OK: status> with <chosen>.\n}\n\n'
     '(Application-Start: Curling API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-013', 'plugin', 'aro',
     'Inside an event handler: when a KilnFired event arrives, put its log '
     'text through a Markdown plugin action and store the HTML. Write both '
     'feature sets and the entry point.',
     '(Application-Start: Kiln Watch) {\n'
     '    Create the <firing> with { log: "# firing 104" }.\n'
     '    Emit a <KilnFired: event> with <firing>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Render Log: KilnFired Handler) {\n'
     '    Extract the <firing> from the <event: firing>.\n'
     '    Extract the <text> from the <firing: log>.\n'
     '    Markdown.ToHTML the <page> with <text>.\n'
     '    Store the <page> into the <page-repository>.\n'
     '    Return an <OK: status> for the <render>.\n}\n',
     None, None),

    ('plugin-014', 'plugin', 'aro',
     'A user-defined action that wraps a plugin qualifier so the rest of the '
     'application does not name the plugin: PickPort takes a list and returns '
     '{ port: <chosen> } using a Collections plugin qualifier. Write the '
     'action and a caller.',
     '(PickPort: Action takes <ports>) {\n'
     '    Extract the <list> from the <input: ports>.\n'
     '    Compute the <chosen: collections.pick-random> from the <list>.\n'
     '    Return an <OK: status> with { port: <chosen> }.\n}\n\n'
     '(Application-Start: Port Caller) {\n'
     '    Create the <ports> with ["dover", "calais"].\n'
     '    Application.PickPort the <out> from <ports>.\n'
     '    Extract the <port> from the <out: port>.\n'
     '    Log <port> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-015', 'plugin', 'aro',
     'Two plugins in one feature set: a Stats qualifier sums the takings and '
     'a Markdown action renders a one-line report. Write the complete '
     'application.',
     '(Application-Start: Takings Report) {\n'
     '    Create the <takings> with [240, 115, 90].\n'
     '    Compute the <total: stats.total> from the <takings>.\n'
     '    Create the <source> with "# Takings".\n'
     '    Markdown.ToHTML the <page> with <source>.\n'
     '    Log <total> to the <console>.\n'
     '    Log <page> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-016', 'plugin', 'aro',
     'A Pdf plugin provides a Render action taking { template, data, target }. '
     'Write a route handler for POST /invoices that renders an invoice to '
     './out/invoice.pdf and answers Created. operationId renderInvoice. '
     'Contract and application.',
     '(renderInvoice: Invoice API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Pdf.Render the <document> with { template: "./invoice.tpl", '
     'data: <data>, target: "./out/invoice.pdf" }.\n'
     '    Return a <Created: status> with { file: "invoice.pdf" }.\n}\n\n'
     '(Application-Start: Invoice API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-017', 'plugin', 'aro',
     'Guard a plugin call: only put the cave note through the Markdown plugin '
     'when the note is not empty, then log it. Complete application with the '
     'note set to a heading.',
     '(Application-Start: Note Render) {\n'
     '    Create the <note> with "# cave 3".\n'
     '    Compute the <size: length> from <note>.\n'
     '    Markdown.ToHTML the <page> with <note> when <size> > 0.\n'
     '    Log <page> to the <console> when <size> > 0.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-018', 'plugin', 'aro',
     'Per element: walk three cheese-cave notes and put each one through a '
     'Markdown plugin action inside the loop, logging each rendering. '
     'Complete application.',
     '(Application-Start: Note Loop) {\n'
     '    Create the <notes> with ["# one", "# two", "# three"].\n'
     '    for each <note> in <notes> {\n'
     '        Markdown.ToHTML the <page> with <note>.\n'
     '        Log <page> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-019', 'plugin', 'aro',
     'A Metrics plugin provides an Increment action taking { counter }. Write '
     'the route handler for POST /tickets that stores the ticket and bumps a '
     'tickets-created counter through the plugin. operationId createTicket. '
     'Contract and application.',
     '(createTicket: Weighbridge API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <ticket-repository>.\n'
     '    Metrics.Increment the <bumped> with '
     '{ counter: "tickets-created" }.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Application-Start: Weighbridge API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('plugin-020', 'plugin', 'aro',
     'Chain two plugin qualifiers from different plugins in one Compute: a '
     'Collections unique followed by a Stats rank, over the depot route list. '
     'Complete application, logging the result.',
     '(Application-Start: Route Ranking) {\n'
     '    Create the <routes> with ["7", "3", "7", "11"].\n'
     '    Compute the <ranked: collections.unique|stats.rank> from the '
     '<routes>.\n'
     '    Log <ranked> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    # ── manifests and host languages (rubric) ────────────────────────────────
    ('plugin-021', 'plugin', 'rubric',
     'Write the plugin.yaml for a Rust plugin called plugin-tides whose '
     'namespace handle is Tides and whose sources are in src/. Use the '
     'canonical way of declaring the namespace, not the deprecated one.',
     'name: plugin-tides\nversion: 1.0.0\nhandle: Tides\nprovides:\n'
     '  - type: rust-plugin\n    path: src/\n\n'
     'The root-level `handle:` is the canonical declaration. `handler:` inside '
     '`provides:` still works but emits a deprecation warning, and when the '
     'two disagree the root-level one wins.',
     ['handle: Tides', 'rust-plugin'],
     ['handler: tides', 'swift-plugin']),

    ('plugin-022', 'plugin', 'rubric',
     'Which directory does a plugin have to live in for the loader to find '
     'it, and what does the layout inside look like? Name the file that is '
     'required per plugin.',
     'Capital-P `Plugins/`, with one subdirectory per plugin and a '
     '`plugin.yaml` manifest in each: `Plugins/my-plugin/plugin.yaml` plus '
     'the sources beside it. A lowercase `plugins/` is still read, with a '
     'deprecation warning, and will stop being read.',
     ['Plugins/', 'plugin.yaml'],
     ['either spelling is fine', 'no manifest is needed']),

    ('plugin-023', 'plugin', 'rubric',
     'Write the Rust surface for a plugin that exposes one action. Give me '
     'the exported function signatures the host dispatches through — not the '
     "action's body.",
     '#[no_mangle]\npub extern "C" fn aro_plugin_info() -> *mut c_char { … }\n'
     '#[no_mangle]\npub extern "C" fn aro_plugin_execute(action: *const '
     'c_char, input: *const c_char) -> *mut c_char { … }\n'
     '#[no_mangle]\npub extern "C" fn aro_plugin_qualifier(name: *const '
     'c_char, input: *const c_char) -> *mut c_char { … }\n'
     '#[no_mangle]\npub extern "C" fn aro_plugin_free(ptr: *mut c_char) { … }\n'
     '\nFour exports: metadata, action dispatch, qualifier dispatch, and the '
     'free the host calls when it is done with a returned string.',
     ['no_mangle', 'aro_plugin_info', 'aro_plugin_execute',
      'aro_plugin_free'],
     ['@AROExport', 'aro_plugin_info()\n  return']),

    ('plugin-024', 'plugin', 'rubric',
     'Write the Python side of a plugin that provides one action and one '
     'qualifier, using the SDK decorators. Include whatever call makes the '
     'ABI exports exist.',
     'from aro_plugin_sdk import plugin, action, qualifier, export_abi\n\n'
     '@plugin(name="plugin-tides", version="1.0.0", handle="Tides")\n'
     'class Tides:\n'
     '    @action\n'
     '    def predict(self, args):\n'
     '        return {"high": args["port"]}\n\n'
     '    @qualifier\n'
     '    def normalise(self, value):\n'
     '        return value.strip().lower()\n\n'
     'export_abi(globals())\n\n'
     'The decorators register the action and the qualifier; '
     '`export_abi(globals())` is what creates the C entry points the host '
     'dispatches through.',
     ['@plugin', '@action', '@qualifier', 'export_abi'],
     ['no_mangle', 'ARO_PLUGIN(']),

    ('plugin-025', 'plugin', 'rubric',
     'Write the C side of a plugin providing one action and one qualifier '
     'using the SDK macros from aro_plugin_sdk.h.',
     '#include "aro_plugin_sdk.h"\n\n'
     'ARO_ACTION(predict) {\n'
     '    return aro_json_object("high", "06:12");\n'
     '}\n\n'
     'ARO_QUALIFIER(normalise) {\n'
     '    return aro_string(aro_trim(input));\n'
     '}\n\n'
     'ARO_PLUGIN("plugin-tides", "1.0.0")\n\n'
     'The macros generate the four C ABI exports, so the plugin does not '
     'write aro_plugin_info or the dispatchers by hand.',
     ['ARO_PLUGIN(', 'ARO_ACTION(', 'ARO_QUALIFIER('],
     ['no_mangle', '@AROExport']),

    ('plugin-026', 'plugin', 'rubric',
     'Write the Swift side of a plugin exposing one action. Say what the '
     'macro does for you.',
     '@AROExport\nlet plugin = AROPlugin(\n'
     '    name: "plugin-tides",\n'
     '    version: "1.0.0",\n'
     '    handle: "Tides",\n'
     '    actions: ["predict": { args in ["high": "06:12"] }]\n'
     ')\n\n'
     'The @AROExport macro generates every C ABI export — the metadata, the '
     'action and qualifier dispatchers, and the free — so the plugin writes '
     'none of them.',
     ['@AROExport', 'AROPlugin'],
     ['no_mangle', 'export_abi']),

    ('plugin-027', 'plugin', 'rubric',
     'A plugin.yaml declares `handle: Tides` at the root and '
     '`handler: harbour` inside provides. What namespace do its qualifiers '
     'end up under, and does anything complain?',
     'Under Tides. The root-level `handle:` wins, and the loader emits a '
     'deprecation warning for `handler:` — including when a root-level handle '
     'is also present, which it did not always do. The warning says which of '
     'the two won.',
     ['Tides', 'deprecation'],
     ['harbour wins', 'no warning']),

    ('plugin-028', 'plugin', 'rubric',
     'Should the qualifier names in a plugin\'s metadata JSON carry the '
     'namespace prefix? Say what the runtime does with them.',
     'No — they are declared plain, with no prefix. The runtime registers each '
     'one as `handle.qualifier` in the QualifierRegistry using the handle from '
     'the manifest, so ARO calls it as `Tides.normalise` while the plugin '
     'declares `normalise`.',
     ['no', 'handle.qualifier'],
     ['declare them with the prefix', 'tides.normalise in the json']),

    ('plugin-029', 'plugin', 'rubric',
     'A plugin\'s own source declares a handle that disagrees with its '
     'plugin.yaml. Which one is used, and why that one?',
     'The manifest. It is what the loader reads and what `aro add` writes, so '
     'it is the one the rest of the toolchain agrees with. It used to win '
     'silently, which let a plugin ship every qualifier under a namespace its '
     'own source never mentioned; now it warns.',
     ['manifest'],
     ['the code wins', 'the source declaration wins']),

    ('plugin-030', 'plugin', 'rubric',
     'I want `aro build --static` to produce one file, and my plugin is '
     'written in Python. What happens, and what are my options?',
     'The build refuses, naming the plugin and the exact Python installation '
     'it would have depended on — an interpreter, a libpython and a standard '
     'library resolved from the build machine are not a single file. Options: '
     'point ARO_STATIC_PYTHON at a CPython distribution with a real static '
     'libpython archive and its stdlib, which makes the build carry them; use '
     '--dynamic, which never promised one file and builds with a warning; or '
     'set ARO_ALLOW_EMBEDDED_PYTHON=1 if you run on the machine you build on. '
     'A plugin needing a native wheel cannot be embedded at all.',
     ['ARO_STATIC_PYTHON', '--dynamic'],
     ['it works fine', 'Python plugins are always embedded']),

    ('plugin-031', 'plugin', 'rubric',
     'What is the difference between what `aro build --static` and '
     '`aro build --dynamic` do with a Rust plugin?',
     '--static (the default) builds the crate as a staticlib and links the '
     'object files into the binary, with symbols renamed so several plugins '
     'can coexist; nothing is dlopened at run time. --dynamic ships the '
     'shared library beside the binary and loads it at startup the way the '
     'interpreter does, baking nothing in.',
     ['static', 'dynamic', 'dlopen'],
     ['there is no difference', 'both bake it in']),

    ('plugin-032', 'plugin', 'rubric',
     'Write the plugin.yaml for a Python plugin called plugin-markdown with '
     'the handle Markdown and its sources under src/, and say which directory '
     'the file belongs in.',
     'name: plugin-markdown\nversion: 1.0.0\nhandle: Markdown\nprovides:\n'
     '  - type: python-plugin\n    path: src/\n\n'
     'It goes in `Plugins/plugin-markdown/plugin.yaml`, one subdirectory per '
     'plugin under capital-P Plugins.',
     ['python-plugin', 'handle: Markdown', 'Plugins/'],
     ['rust-plugin', 'handler: markdown']),

    ('plugin-033', 'plugin', 'rubric',
     'Which command scaffolds a new plugin, and what does it insist on?',
     '`aro new plugin <name> --lang <language>`. The --lang flag is required — '
     'swift, rust, c, cpp, python or aro — because the scaffold differs per '
     'language; there is no default. It writes the Plugins/<name>/ layout with '
     'a plugin.yaml.',
     ['aro new plugin', '--lang'],
     ['--lang is optional', 'aro plugin new']),

    ('plugin-034', 'plugin', 'rubric',
     'How does a compiled binary decide whether it is allowed to dlopen a '
     'plugin at all?',
     'From what was recorded at link time: the generated `main` calls '
     '`aro_set_build_link_mode`, and the dynamic-loading code answers from '
     'that. It deliberately does not probe the loader, because probing '
     'answers a different question — whether dlopen exists, not whether this '
     'build was meant to use it.',
     ['link time', 'aro_set_build_link_mode'],
     ['it probes the loader', 'it tries dlopen and sees what happens']),

    ('plugin-035', 'plugin', 'rubric',
     'What does `aro add github:org/repo` do, and where does what it installs '
     'end up?',
     'It installs a plugin from that Git repository into `Plugins/`, one '
     'subdirectory with the plugin.yaml the loader reads — the same layout '
     '`aro new plugin` scaffolds. `aro plugins` then lists it and '
     '`aro actions` shows the actions it registers.',
     ['Plugins/', 'plugin.yaml'],
     ['site-packages', 'a global plugin directory']),
]


# The three plugin rows that are HTTP handlers get their contract, the same way
# the repair stratum does: ARO is contract-first, so a route handler with no
# openapi.yaml beside it is not the task that was set.
FILES = {
    'plugin-012': {'openapi.yaml':
                   'openapi: 3.0.3\ninfo:\n  title: Curling API\n'
                   '  version: 1.0.0\npaths:\n  /sheets/random:\n'
                   '    get:\n      operationId: randomSheet\n'},
    'plugin-016': {'openapi.yaml':
                   'openapi: 3.0.3\ninfo:\n  title: Invoice API\n'
                   '  version: 1.0.0\npaths:\n  /invoices:\n'
                   '    post:\n      operationId: renderInvoice\n'},
    'plugin-019': {'openapi.yaml':
                   'openapi: 3.0.3\ninfo:\n  title: Weighbridge API\n'
                   '  version: 1.0.0\npaths:\n  /tickets:\n'
                   '    post:\n      operationId: createTicket\n'},
}

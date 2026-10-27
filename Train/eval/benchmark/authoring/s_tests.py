"""Tests stratum: write the ARO-0015 tests (GitLab #785).

GitLab #797: "There are no Given/When/Then pairs at all." Not thin — zero. So
this stratum is the one with no corpus to be contaminated by, and it is also
the strongest grade in the benchmark, because `aro test` asserts the program's
*values* rather than its printing: an answer that computes a plausible wrong
number fails, where `aro check` and even a printed-output comparison can be
satisfied by the wrong arithmetic dressed correctly.

**The answer is the test file, not the application.** That is the opposite
arrangement from `functional_eval`'s `aro_test` grade, and it is forced:
ARO-0015 §2.2's `When the <result> from the <feature-set>.` does not execute in
this runtime — it fails with "Cannot when the … from the …" — and an
`Application.<Name>` call inside a test feature set binds the argument rather
than the call's result. Measured against the binary this benchmark was frozen
on, in both directions. So a checked-in test cannot reach a generated
application's code, and the only honest arrangement is the inverse: the
application is checked in (a bare entry point, since the test cannot call into
it anyway), the answer is the test, and `aro test` decides.

What that measures is still worth measuring, and arguably more than the other
direction: the model has to know the `Test` business-activity suffix, the
Given / Then / Assert vocabulary, that there is no setup or teardown hook, and
it has to get the asserted value *right* — the prompt states the setup and the
expected answer, and a test asserting anything else fails.

Each row: (id, domain, activity, prompt, reference_test).
"""

ROWS = [
    # ── arithmetic ───────────────────────────────────────────────────────────
    ('tests-001', 'tests', 'Pricing',
     'Write the ARO-0015 test feature sets for a pricing rule, business '
     'activity "Pricing Test". One case: given a subtotal of 200, a ten per '
     'cent discount is 20. Assert it.',
     '(ten-percent-discount: Pricing Test) {\n'
     '    Given the <subtotal> with 200.\n'
     '    Compute the <discount> from <subtotal> * 0.1.\n'
     '    Then the <discount> with 20.\n}\n'),

    ('tests-002', 'tests', 'Weighbridge',
     'Give me the tests for a weighbridge net-weight rule under the business '
     'activity "Weighbridge Test": gross 12_400 minus tare 3_100 is a net of '
     '9_300.',
     '(net-weight: Weighbridge Test) {\n'
     '    Given the <gross> with 12_400.\n'
     '    Given the <tare> with 3_100.\n'
     '    Compute the <net> from <gross> - <tare>.\n'
     '    Then the <net> with 9_300.\n}\n'),

    ('tests-003', 'tests', 'Kiln',
     'Tests for kiln firing cost, activity "Kiln Test": 11 hours at 4.25 an '
     'hour comes to 46.75.',
     '(firing-cost: Kiln Test) {\n'
     '    Given the <hours> with 11.\n'
     '    Given the <rate> with 4.25.\n'
     '    Compute the <cost> from <hours> * <rate>.\n'
     '    Then the <cost> with 46.75.\n}\n'),

    ('tests-004', 'tests', 'Locks',
     'Write the tests for a canal lock drop, activity "Locks Test": an upper '
     'pound of 34 metres over a lower pound of 21 gives a drop of 13.',
     '(lock-drop: Locks Test) {\n'
     '    Given the <upper> with 34.\n'
     '    Given the <lower> with 21.\n'
     '    Compute the <drop> from <upper> - <lower>.\n'
     '    Then the <drop> with 13.\n}\n'),

    ('tests-005', 'tests', 'Trailers',
     'Tests for trailer loading under "Trailers Test": 1_250 bales onto '
     'trailers of 48 leaves 2 over.',
     '(leftover-bales: Trailers Test) {\n'
     '    Given the <bales> with 1_250.\n'
     '    Given the <capacity> with 48.\n'
     '    Compute the <leftover> from <bales> % <capacity>.\n'
     '    Then the <leftover> with 2.\n}\n'),

    ('tests-006', 'tests', 'Billing',
     'Tests for turbine billing, activity "Billing Test": a raw reading of '
     '7.48812 kilowatt hours bills as 7.49 once rounded the way money is.',
     '(money-rounding: Billing Test) {\n'
     '    Given the <raw> with 7.48812.\n'
     '    Compute the <billed: fixed> from <raw>.\n'
     '    Then the <billed> with 7.49.\n}\n'),

    ('tests-007', 'tests', 'Fares',
     'Write two test cases under "Fares Test": a single tram fare of 3 '
     'doubles to 6, and a fare of 4 doubles to 8.',
     '(double-three: Fares Test) {\n'
     '    Given the <fare> with 3.\n'
     '    Compute the <doubled> from <fare> * 2.\n'
     '    Then the <doubled> with 6.\n}\n\n'
     '(double-four: Fares Test) {\n'
     '    Given the <fare> with 4.\n'
     '    Compute the <doubled> from <fare> * 2.\n'
     '    Then the <doubled> with 8.\n}\n'),

    ('tests-008', 'tests', 'Crossings',
     'Tests for ferry crossing arithmetic, activity "Crossings Test": 200 '
     'minutes divided into 40-minute crossings is 5.',
     '(crossings-per-shift: Crossings Test) {\n'
     '    Given the <minutes> with 200.\n'
     '    Given the <crossing> with 40.\n'
     '    Compute the <crossings> from <minutes> / <crossing>.\n'
     '    Then the <crossings> with 5.\n}\n'),

    # ── collections ──────────────────────────────────────────────────────────
    ('tests-009', 'tests', 'Apiary',
     'Tests under "Apiary Test": the hive weights 14, 22 and 19 total 55.',
     '(total-hive-weight: Apiary Test) {\n'
     '    Given the <weights> with [14, 22, 19].\n'
     '    Compute the <total: sum> from the <weights>.\n'
     '    Then the <total> with 55.\n}\n'),

    ('tests-010', 'tests', 'Stakes',
     'Tests under "Stakes Test": the glacier stake readings 12, 18 and 24 '
     'average 18.',
     '(mean-stake: Stakes Test) {\n'
     '    Given the <stakes> with [12, 18, 24].\n'
     '    Compute the <mean: avg> from the <stakes>.\n'
     '    Then the <mean> with 18.\n}\n'),

    ('tests-011', 'tests', 'Depths',
     'Tests under "Depths Test": the five depth readings 3, 9, 4, 9 and 7 are '
     'five readings.',
     '(reading-count: Depths Test) {\n'
     '    Given the <readings> with [3, 9, 4, 9, 7].\n'
     '    Compute the <count: length> from the <readings>.\n'
     '    Then the <count> with 5.\n}\n'),

    ('tests-012', 'tests', 'Routes',
     'Tests under "Routes Test": the depot route list 7, 3, 7, 11 has three '
     'distinct routes once the repeat is dropped.',
     '(distinct-routes: Routes Test) {\n'
     '    Given the <routes> with ["7", "3", "7", "11"].\n'
     '    Compute the <distinct: unique> from the <routes>.\n'
     '    Compute the <count: length> from the <distinct>.\n'
     '    Then the <count> with 3.\n}\n'),

    ('tests-013', 'tests', 'Plots',
     'Tests under "Plots Test": of three allotment plots with 12, 3 and 18 '
     'beds, two have more than ten.',
     '(large-plots: Plots Test) {\n'
     '    Given the <plots> with [{ plot: 4, beds: 12 }, '
     '{ plot: 9, beds: 3 }, { plot: 11, beds: 18 }].\n'
     '    Filter the <large> from the <plots> where <beds> > 10.\n'
     '    Compute the <count: length> from the <large>.\n'
     '    Then the <count> with 2.\n}\n'),

    ('tests-014', 'tests', 'Clamps',
     'Tests under "Clamps Test": four silage rows from clamps north, south, '
     'north and east group into three clamps.',
     '(distinct-clamps: Clamps Test) {\n'
     '    Given the <rows> with [{ clamp: "north", t: 20 }, '
     '{ clamp: "south", t: 14 }, { clamp: "north", t: 6 }, '
     '{ clamp: "east", t: 3 }].\n'
     '    Group the <by-clamp> from the <rows> by "clamp".\n'
     '    Compute the <count: length> from the <by-clamp>.\n'
     '    Then the <count> with 3.\n}\n'),

    ('tests-015', 'tests', 'Takings',
     'Tests under "Takings Test": the parking-meter takings 240, 115 and 90 '
     'reduce to 445.',
     '(days-takings: Takings Test) {\n'
     '    Given the <takings> with [240, 115, 90].\n'
     '    Reduce the <total: sum> from the <takings>.\n'
     '    Then the <total> with 445.\n}\n'),

    ('tests-016', 'tests', 'Tonnages',
     'Tests under "Tonnages Test": pulling the tonnage field off two '
     'weighbridge rows of 20 and 6 and sorting ascending gives 6 first.',
     '(lightest-first: Tonnages Test) {\n'
     '    Given the <loads> with [{ ticket: 1, t: 20 }, { ticket: 2, t: 6 }].\n'
     '    Map the <tonnages> from the <loads> with t.\n'
     '    Sort the <ordered> for the <tonnages>.\n'
     '    Extract the <lightest: first> from the <ordered>.\n'
     '    Then the <lightest> with 6.\n}\n'),

    ('tests-017', 'tests', 'Fields',
     'Tests under "Fields Test": splitting the cheese-cave row '
     '"gruyere;14;rind-washed" on semicolons yields three fields, and the '
     'middle one is "14".',
     '(three-fields: Fields Test) {\n'
     '    Given the <row> with "gruyere;14;rind-washed".\n'
     '    Split the <fields> from the <row> by ";".\n'
     '    Compute the <count: length> from the <fields>.\n'
     '    Then the <count> with 3.\n}\n\n'
     '(middle-field: Fields Test) {\n'
     '    Given the <row> with "gruyere;14;rind-washed".\n'
     '    Split the <fields> from the <row> by ";".\n'
     '    Extract the <middle: 1> from the <fields>.\n'
     '    Then the <middle> with "14".\n}\n'),

    ('tests-018', 'tests', 'Parts',
     'Tests under "Parts Test": joining the choir voice parts soprano, alto '
     'and tenor with " / " gives "soprano / alto / tenor".',
     '(joined-parts: Parts Test) {\n'
     '    Given the <parts> with ["soprano", "alto", "tenor"].\n'
     '    Compute the <line: join> from the <parts> '
     'with { separator: " / " }.\n'
     '    Then the <line> with "soprano / alto / tenor".\n}\n'),

    # ── text ─────────────────────────────────────────────────────────────────
    ('tests-019', 'tests', 'Labels',
     'Tests under "Labels Test": "beachy head" uppercases to "BEACHY HEAD".',
     '(shouted-name: Labels Test) {\n'
     '    Given the <light> with "beachy head".\n'
     '    Compute the <shouted: uppercase> from <light>.\n'
     '    Then the <shouted> with "BEACHY HEAD".\n}\n'),

    ('tests-020', 'tests', 'Rings',
     'Tests under "Rings Test": the ring code "  GB-2291  " trims to '
     '"GB-2291", and its length is then 7.',
     '(trimmed-ring: Rings Test) {\n'
     '    Given the <ring> with "  GB-2291  ".\n'
     '    Compute the <clean: trim> from <ring>.\n'
     '    Then the <clean> with "GB-2291".\n}\n\n'
     '(ring-length: Rings Test) {\n'
     '    Given the <ring> with "  GB-2291  ".\n'
     '    Compute the <clean: trim|length> from <ring>.\n'
     '    Then the <clean> with 7.\n}\n'),

    ('tests-021', 'tests', 'Codes',
     'Tests under "Codes Test": replacing hyphens with underscores in '
     '"bisque-01-east" gives "bisque_01_east".',
     '(slugged-code: Codes Test) {\n'
     '    Given the <code> with "bisque-01-east".\n'
     '    Compute the <slug: replace> from <code> '
     'with { find: "-", replace: "_" }.\n'
     '    Then the <slug> with "bisque_01_east".\n}\n'),

    ('tests-022', 'tests', 'Notes',
     'Tests under "Notes Test": the three-line note "mon\\ntue\\nwed" has '
     'three lines.',
     '(three-lines: Notes Test) {\n'
     '    Given the <note> with "mon\\ntue\\nwed".\n'
     '    Compute the <rows: lines> from <note>.\n'
     '    Compute the <count: length> from the <rows>.\n'
     '    Then the <count> with 3.\n}\n'),

    ('tests-023', 'tests', 'Credentials',
     'Tests under "Credentials Test": base64-encoding "depot:kestrel" gives '
     '"ZGVwb3Q6a2VzdHJlbA==".',
     '(encoded-credential: Credentials Test) {\n'
     '    Given the <credential> with "depot:kestrel".\n'
     '    Compute the <encoded: base64-encode> from <credential>.\n'
     '    Then the <encoded> with "ZGVwb3Q6a2VzdHJlbA==".\n}\n'),

    ('tests-024', 'tests', 'Escaping',
     'Tests under "Escaping Test": html-escaping "Block <C> & rows" gives '
     '"Block &lt;C&gt; &amp; rows".',
     '(escaped-note: Escaping Test) {\n'
     '    Given the <note> with "Block <C> & rows".\n'
     '    Compute the <safe: html-escape> from <note>.\n'
     '    Then the <safe> with "Block &lt;C&gt; &amp; rows".\n}\n'),

    ('tests-025', 'tests', 'Queries',
     'Tests under "Queries Test": percent-encoding "cheese cave" gives '
     '"cheese%20cave".',
     '(encoded-term: Queries Test) {\n'
     '    Given the <term> with "cheese cave".\n'
     '    Compute the <encoded: url-encode> from <term>.\n'
     '    Then the <encoded> with "cheese%20cave".\n}\n'),

    ('tests-026', 'tests', 'Captures',
     'Tests under "Captures Test": pulling named groups out of '
     '"turbine=hub-14" with a regex gives a value of "hub-14".',
     '(captured-value: Captures Test) {\n'
     '    Given the <line> with "turbine=hub-14".\n'
     '    Compute the <parts: captures> from <line> '
     'by /(?<key>[a-z]+)=(?<value>.+)/.\n'
     '    Extract the <value> from the <parts: value>.\n'
     '    Then the <value> with "hub-14".\n}\n'),

    # ── paths ────────────────────────────────────────────────────────────────
    ('tests-027', 'tests', 'Paths',
     'Tests under "Paths Test": the basename of '
     '"/var/spool/kiln/firing-104.csv" is "firing-104.csv" and its dirname is '
     '"/var/spool/kiln".',
     '(leaf-name: Paths Test) {\n'
     '    Given the <path> with "/var/spool/kiln/firing-104.csv".\n'
     '    Compute the <leaf: basename> from <path>.\n'
     '    Then the <leaf> with "firing-104.csv".\n}\n\n'
     '(folder-name: Paths Test) {\n'
     '    Given the <path> with "/var/spool/kiln/firing-104.csv".\n'
     '    Compute the <folder: dirname> from <path>.\n'
     '    Then the <folder> with "/var/spool/kiln".\n}\n'),

    ('tests-028', 'tests', 'Extensions',
     'Tests under "Extensions Test": the extension of "lock-gauge.tsv" is '
     '"tsv", with no dot.',
     '(bare-extension: Extensions Test) {\n'
     '    Given the <name> with "lock-gauge.tsv".\n'
     '    Compute the <kind: extension> from <name>.\n'
     '    Then the <kind> with "tsv".\n}\n'),

    ('tests-029', 'tests', 'Joining',
     'Tests under "Joining Test": joining "/srv/dropbox" to "roster.csv" '
     'gives "/srv/dropbox/roster.csv" with exactly one separator.',
     '(single-separator: Joining Test) {\n'
     '    Given the <dir> with "/srv/dropbox".\n'
     '    Given the <name> with "roster.csv".\n'
     '    Compute the <target: path-join> from <dir> with <name>.\n'
     '    Then the <target> with "/srv/dropbox/roster.csv".\n}\n'),

    ('tests-030', 'tests', 'Untrusted',
     'Tests under "Untrusted Test": path-join does not let an absolute '
     'right-hand side escape the trusted directory — "/uploads" joined to '
     '"/etc/passwd" is "/uploads/etc/passwd".',
     '(absolute-does-not-reset: Untrusted Test) {\n'
     '    Given the <dir> with "/uploads".\n'
     '    Given the <name> with "/etc/passwd".\n'
     '    Compute the <target: path-join> from <dir> with <name>.\n'
     '    Then the <target> with "/uploads/etc/passwd".\n}\n'),

    ('tests-031', 'tests', 'Stems',
     'Tests under "Stems Test": the stem of "firing-104.csv" is '
     '"firing-104".',
     '(stem-name: Stems Test) {\n'
     '    Given the <name> with "firing-104.csv".\n'
     '    Compute the <stem: stem> from <name>.\n'
     '    Then the <stem> with "firing-104".\n}\n'),

    # ── conditionals and comparison ──────────────────────────────────────────
    ('tests-032', 'conditionals', 'Tides',
     'Tests under "Tides Test": with a tide of 1.2 metres against a minimum '
     'of 1.5, the sailing decision is "cancelled".',
     '(cancelled-below-minimum: Tides Test) {\n'
     '    Given the <tide> with 1.2.\n'
     '    Given the <minimum> with 1.5.\n'
     '    Create the <decision> with "cancelled" when <tide> < <minimum>.\n'
     '    Then the <decision> with "cancelled".\n}\n'),

    ('tests-033', 'conditionals', 'Vents',
     'Tests under "Vents Test": at 31 degrees against a threshold of 28 the '
     'greenhouse vent is "open"; at 22 it is "shut". Two cases.',
     '(open-above-threshold: Vents Test) {\n'
     '    Given the <house-temp> with 31.\n'
     '    Create the <vent> with "open" when <house-temp> > 28.\n'
     '    Then the <vent> with "open".\n}\n\n'
     '(shut-below-threshold: Vents Test) {\n'
     '    Given the <house-temp> with 22.\n'
     '    Create the <vent> with "shut" when <house-temp> <= 28.\n'
     '    Then the <vent> with "shut".\n}\n'),

    ('tests-034', 'conditionals', 'Routing',
     'Tests under "Routing Test": the path "/depot/health" counts as internal '
     'because it begins with "/depot".',
     '(internal-path: Routing Test) {\n'
     '    Given the <route> with "/depot/health".\n'
     '    Create the <zone> with "internal" '
     'when <route> starts with "/depot".\n'
     '    Then the <zone> with "internal".\n}\n'),

    ('tests-035', 'conditionals', 'Permissions',
     'Tests under "Permissions Test": a ringer holding tower and method '
     'satisfies a requirement of tower alone, so the verdict is "allowed".',
     '(subset-is-allowed: Permissions Test) {\n'
     '    Given the <held> with ["tower", "method"].\n'
     '    Given the <needed> with ["tower"].\n'
     '    Create the <verdict> with "allowed" '
     'when <needed> subset of <held>.\n'
     '    Then the <verdict> with "allowed".\n}\n'),

    ('tests-036', 'conditionals', 'Moorings',
     'Tests under "Moorings Test": "lock-5" is not in the banned list '
     '"lock-3", "lock-8", so the mooring is "free".',
     '(not-banned: Moorings Test) {\n'
     '    Given the <banned> with ["lock-3", "lock-8"].\n'
     '    Given the <wanted> with "lock-5".\n'
     '    Create the <state> with "free" when <wanted> not in <banned>.\n'
     '    Then the <state> with "free".\n}\n'),

    ('tests-037', 'conditionals', 'Tallies',
     'Tests under "Tallies Test": comparing two bale counts of 48 and 48 with '
     'the Compare action binds a result that matches.',
     '(counts-agree: Tallies Test) {\n'
     '    Given the <field-count> with 48.\n'
     '    Given the <shed-count> with 48.\n'
     '    Compare the <tally> from the <field-count> against the '
     '<shed-count>.\n'
     '    Create the <verdict> with "agree" when <tally: matches>.\n'
     '    Then the <verdict> with "agree".\n}\n'),

    ('tests-038', 'conditionals', 'Archiving',
     'Tests under "Archiving Test": a kiln log named "firing-104.csv" is '
     'archived because the name ends with ".csv". The affix operator is '
     'literal, so do not reach for a regex.',
     '(archive-csv-logs: Archiving Test) {\n'
     '    Given the <log-name> with "firing-104.csv".\n'
     '    Create the <action> with "archive" '
     'when <log-name> ends with ".csv".\n'
     '    Then the <action> with "archive".\n}\n'),

    ('tests-039', 'conditionals', 'Sheets',
     'Tests under "Sheets Test": an ice booking at hour 6 is out of hours '
     '(the rink runs 7 to 22), so the verdict is "closed". Use Assert rather '
     'than Then.',
     '(before-opening: Sheets Test) {\n'
     '    Given the <hour> with 6.\n'
     '    Create the <verdict> with "closed" when <hour> < 7.\n'
     '    Assert the <verdict> with "closed".\n}\n'),

    # ── iteration ────────────────────────────────────────────────────────────
    ('tests-040', 'tests', 'Accumulating',
     'Tests under "Accumulating Test": adding the whole numbers 1 to 4 with a '
     'while loop and a running accumulator gives 10.',
     '(sum-to-four: Accumulating Test) {\n'
     '    Given the <limit> with 4.\n'
     '    Compute the <position> from 1.\n'
     '    Compute the <running> from 0.\n'
     '    while <position> <= <limit> {\n'
     '        Compute the <running> from <running> + <position>.\n'
     '        Compute the <position> from <position> + 1.\n'
     '    }\n'
     '    Then the <running> with 10.\n}\n'),

    ('tests-041', 'tests', 'Breaking',
     'Tests under "Breaking Test": a while loop that counts up from 1 and '
     'leaves as soon as the counter passes 3 ends with the counter at 4, even '
     'though the loop condition would have allowed it to reach 10.',
     '(leaves-early: Breaking Test) {\n'
     '    Given the <ceiling> with 10.\n'
     '    Compute the <position> from 1.\n'
     '    while <position> <= <ceiling> {\n'
     '        Compute the <position> from <position> + 1.\n'
     '        when <position> > 3 {\n'
     '            break.\n'
     '        }\n'
     '    }\n'
     '    Then the <position> with 4.\n}\n'),

    # ── repositories ─────────────────────────────────────────────────────────
    ('tests-042', 'repositories', 'Accessions',
     'Tests under "Accessions Test": storing two seed-bank accessions and '
     'fetching the one with id 2 gives the name "emmer".',
     '(fetch-by-id: Accessions Test) {\n'
     '    Given the <first> with { id: 1, name: "einkorn" }.\n'
     '    Given the <second> with { id: 2, name: "emmer" }.\n'
     '    Store the <first> into the <accession-repository>.\n'
     '    Store the <second> into the <accession-repository>.\n'
     '    Retrieve the <found> from the <accession-repository> '
     'where <id> is 2.\n'
     '    Extract the <name> from the <found: name>.\n'
     '    Then the <name> with "emmer".\n}\n'),

    ('tests-043', 'repositories', 'Empty',
     'Tests under "Empty Test": a Retrieve against a repository nothing has '
     'written binds an empty list rather than failing, so the count is 0.',
     '(empty-is-not-a-failure: Empty Test) {\n'
     '    Retrieve the <firings> from the <firing-repository>.\n'
     '    Compute the <count: length> from the <firings>.\n'
     '    Then the <count> with 0.\n}\n'),

    ('tests-044', 'repositories', 'Machines',
     'Tests under "Machines Test": storing one laundromat machine record and '
     'reading the repository back gives one row.',
     '(one-row-after-one-store: Machines Test) {\n'
     '    Given the <machine> with { id: 3, drum: 8 }.\n'
     '    Store the <machine> into the <machines-repository>.\n'
     '    Retrieve the <machines> from the <machines-repository>.\n'
     '    Compute the <count: length> from the <machines>.\n'
     '    Then the <count> with 1.\n}\n'),

    ('tests-045', 'repositories', 'Updating',
     'Tests under "Updating Test": retrieving a slot, updating its holder to '
     '"bess" and storing it back leaves the holder as "bess".',
     '(holder-after-update: Updating Test) {\n'
     '    Given the <row> with { id: 1, holder: "none" }.\n'
     '    Store the <row> into the <slot-repository>.\n'
     '    Retrieve the <slot> from the <slot-repository> where <id> is 1.\n'
     '    Update the <slot> with { holder: "bess" }.\n'
     '    Store the <slot> into the <slot-repository>.\n'
     '    Extract the <holder> from the <slot: holder>.\n'
     '    Then the <holder> with "bess".\n}\n'),
]


def entry_point(activity):
    """The checked-in application a test runs beside.

    Bare on purpose. A test feature set cannot call into the application in
    this runtime (see the module docstring), so an application with real
    feature sets here would be scenery — and scenery in a benchmark is a prompt
    the model has to read and cannot be graded on.
    """
    return (f'(Application-Start: {activity}) {{\n'
            '    Return an <OK: status> for the <startup>.\n}\n')

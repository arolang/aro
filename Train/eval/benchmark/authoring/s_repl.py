"""REPL stratum: a statement, or a few, with no feature set (GitLab #785).

What this measures that `nl_application` does not: whether the model can write
a *statement* correctly when there is no feature-set scaffolding to pattern-
match against. The corpus is thick with whole feature sets, and a model that
has memorised feature-set shapes can produce one while getting the statement
inside it wrong.

Every task here is graded twice: `aro check --syntax` on the statements as
written, and — because the harness wraps a bare run of statements in an entry
point, which is what the REPL itself does — `aro run` against an expected
output. "It parses" is the axis the 75.5 % figure measured, and it is the
weaker half.

Subject matter is deliberately away from the corpus's users/orders/products
(canal locks, kiln firings, bell towers, silage). Not for flavour: character
3-gram similarity against 23,931 corpus instructions is the gate these prompts
have to clear, and shared vocabulary is what drives it.

Each row: (id, domain, prompt, reference, expected_output).
"""

ROWS = [
    # ── arithmetic and numbers ───────────────────────────────────────────────
    ('repl-001', 'numbers',
     'Bind <lock-drop> to the difference between an upper pound level of 34 '
     'metres and a lower one of 21 metres, then print the drop.',
     'Compute the <lock-drop> from 34 - 21.\n'
     'Log <lock-drop> to the <console>.',
     '13'),
    ('repl-002', 'numbers',
     'Two ARO statements: bind <kiln-hours> to 11, then bind <firing-cost> to '
     'that many hours at 4.25 per hour. Print the cost.',
     'Create the <kiln-hours> with 11.\n'
     'Compute the <firing-cost> from <kiln-hours> * 4.25.\n'
     'Log <firing-cost> to the <console>.',
     '46.75'),
    ('repl-003', 'numbers',
     'One statement that works out how many whole 45-minute bell-ringing '
     'slots fit in 200 minutes, bound as <slots>.',
     'Compute the <slots> from 200 / 45.\nLog <slots> to the <console>.',
     '__NUMBER__'),
    ('repl-004', 'numbers',
     'Bind <leftover-bales> to what is left when 1_250 bales are loaded onto '
     'trailers that each take 48, and print it.',
     'Compute the <leftover-bales> from 1_250 % 48.\n'
     'Log <leftover-bales> to the <console>.',
     '2'),
    ('repl-005', 'numbers',
     'Round a raw turbine reading of 7.48812 kilowatt-hours to money-style '
     'two decimals, bound as <billed-kwh>, and print it.',
     'Create the <raw-kwh> with 7.48812.\n'
     'Compute the <billed-kwh: fixed> from <raw-kwh>.\n'
     'Log <billed-kwh> to the <console>.',
     '7.49'),

    # ── collections ──────────────────────────────────────────────────────────
    ('repl-006', 'collections',
     'Bind <depth-readings> to the list 3, 9, 4, 9, 7 and print how many '
     'readings there are.',
     'Create the <depth-readings> with [3, 9, 4, 9, 7].\n'
     'Compute the <reading-count: length> from the <depth-readings>.\n'
     'Log <reading-count> to the <console>.',
     '5'),
    ('repl-007', 'collections',
     'Total the hive weights 14, 22, 19 in one computation bound as '
     '<apiary-weight>, then print it.',
     'Create the <hive-weights> with [14, 22, 19].\n'
     'Compute the <apiary-weight: sum> from the <hive-weights>.\n'
     'Log <apiary-weight> to the <console>.',
     '55'),
    ('repl-008', 'collections',
     'Print the mean of the glacier stake measurements 12, 18, 24.',
     'Create the <stakes> with [12, 18, 24].\n'
     'Compute the <mean-stake: avg> from the <stakes>.\n'
     'Log <mean-stake> to the <console>.',
     '18'),
    ('repl-009', 'collections',
     'Strip the repeats out of the tram-depot route list "7", "3", "7", "11" '
     'and print what is left.',
     'Create the <routes> with ["7", "3", "7", "11"].\n'
     'Compute the <distinct-routes: unique> from the <routes>.\n'
     'Log <distinct-routes> to the <console>.',
     '[7, 3, 11]'),
    ('repl-010', 'collections',
     'Join the choir voice parts "soprano", "alto", "tenor" into one string '
     'separated by " / " and print it.',
     'Create the <parts> with ["soprano", "alto", "tenor"].\n'
     'Compute the <billing-line: join> from the <parts> '
     'with { separator: " / " }.\n'
     'Log <billing-line> to the <console>.',
     'soprano / alto / tenor'),
    ('repl-011', 'collections',
     'From a list of allotment records — plot 4 with 12 beds, plot 9 with 3 '
     'beds — keep only the plots with more than 10 beds and print the count.',
     'Create the <plots> with [{ plot: 4, beds: 12 }, { plot: 9, beds: 3 }].\n'
     'Filter the <large-plots> from the <plots> where <beds> > 10.\n'
     'Compute the <n: length> from the <large-plots>.\n'
     'Log <n> to the <console>.',
     '1'),
    ('repl-012', 'collections',
     'Pull just the wheel numbers out of these lock records — wheel 2 at '
     'Foxton, wheel 5 at Hatton — and print the list.',
     'Create the <locks> with [{ wheel: 2, place: "Foxton" }, '
     '{ wheel: 5, place: "Hatton" }].\n'
     'Map the <wheels> from the <locks> with wheel.\n'
     'Log <wheels> to the <console>.',
     '[2, 5]'),
    ('repl-013', 'collections',
     'Sort the ferry crossing times 55, 20, 40 into ascending order and print '
     'them.',
     'Create the <crossings> with [55, 20, 40].\n'
     'Sort the <ordered-crossings> for the <crossings>.\n'
     'Log <ordered-crossings> to the <console>.',
     '[20, 40, 55]'),
    ('repl-014', 'collections',
     'Group the silage bales — clamp "north" 20 tonnes, clamp "south" 14, '
     'clamp "north" 6 — by clamp and print the grouping.',
     'Create the <bales> with [{ clamp: "north", t: 20 }, '
     '{ clamp: "south", t: 14 }, { clamp: "north", t: 6 }].\n'
     'Group the <by-clamp> from the <bales> by "clamp".\n'
     'Compute the <clamp-count: length> from the <by-clamp>.\n'
     'Log <clamp-count> to the <console>.',
     '2'),
    ('repl-015', 'collections',
     'Reduce the parking-meter takings 240, 115, 90 to a single total using '
     'the Reduce action, and print it.',
     'Create the <takings> with [240, 115, 90].\n'
     'Reduce the <days-total: sum> from the <takings>.\n'
     'Log <days-total> to the <console>.',
     '445'),

    # ── text ─────────────────────────────────────────────────────────────────
    ('repl-016', 'text',
     'Shout a lighthouse name: take "beachy head" and print it in capitals.',
     'Create the <light> with "beachy head".\n'
     'Compute the <shouted: uppercase> from <light>.\n'
     'Log <shouted> to the <console>.',
     'BEACHY HEAD'),
    ('repl-017', 'text',
     'A falconry ring code arrives as "  GB-2291  ". Trim the surrounding '
     'blanks and print the result.',
     'Create the <ring> with "  GB-2291  ".\n'
     'Compute the <clean-ring: trim> from <ring>.\n'
     'Log <clean-ring> to the <console>.',
     'GB-2291'),
    ('repl-018', 'text',
     'Swap every hyphen for an underscore in the kiln code "bisque-01-east" '
     'and print it.',
     'Create the <code> with "bisque-01-east".\n'
     'Compute the <slug: replace> from <code> '
     'with { find: "-", replace: "_" }.\n'
     'Log <slug> to the <console>.',
     'bisque_01_east'),
    ('repl-019', 'text',
     'Split the cheese-cave row "gruyere;14;rind-washed" on semicolons and '
     'print how many fields came out.',
     'Create the <row> with "gruyere;14;rind-washed".\n'
     'Split the <fields> from the <row> by ";".\n'
     'Compute the <field-count: length> from the <fields>.\n'
     'Log <field-count> to the <console>.',
     '3'),
    ('repl-020', 'text',
     'Count the lines in the three-line bell-tower note "mon\\ntue\\nwed" and '
     'print the count.',
     'Create the <note> with "mon\\ntue\\nwed".\n'
     'Compute the <note-lines: lines> from <note>.\n'
     'Compute the <line-count: length> from the <note-lines>.\n'
     'Log <line-count> to the <console>.',
     '3'),
    ('repl-021', 'text',
     'Hash the ringer passphrase "tenor-bell" with SHA-256 and print the '
     'digest.',
     'Create the <passphrase> with "tenor-bell".\n'
     'Compute the <digest: sha256> from <passphrase>.\n'
     'Log <digest> to the <console>.',
     '__HASH__'),
    ('repl-022', 'text',
     'Base64-encode the depot credential "depot:kestrel" for a header and '
     'print it.',
     'Create the <credential> with "depot:kestrel".\n'
     'Compute the <encoded: base64-encode> from <credential>.\n'
     'Log <encoded> to the <console>.',
     'ZGVwb3Q6a2VzdHJlbA=='),
    ('repl-023', 'text',
     'Make the vineyard note "Block <C> & rows" safe to drop into an HTML '
     'page, and print the escaped text.',
     'Create the <note> with "Block <C> & rows".\n'
     'Compute the <safe-note: html-escape> from <note>.\n'
     'Log <safe-note> to the <console>.',
     'Block &lt;C&gt; &amp; rows'),
    ('repl-024', 'text',
     'Percent-encode the search term "cheese cave" so it can ride in a query '
     'string, and print it.',
     'Create the <term> with "cheese cave".\n'
     'Compute the <encoded-term: url-encode> from <term>.\n'
     'Log <encoded-term> to the <console>.',
     'cheese%20cave'),
    ('repl-025', 'text',
     'Pick the key and value out of "turbine=hub-14" with a named-group regex '
     'and print the value.',
     'Create the <line> with "turbine=hub-14".\n'
     'Compute the <parts: captures> from <line> '
     'by /(?<key>[a-z]+)=(?<value>.+)/.\n'
     'Log <parts: value> to the <console>.',
     'hub-14'),

    # ── paths and files ──────────────────────────────────────────────────────
    ('repl-026', 'paths',
     'Print just the file name of "/var/spool/kiln/firing-104.csv".',
     'Create the <path> with "/var/spool/kiln/firing-104.csv".\n'
     'Compute the <leaf: basename> from <path>.\n'
     'Log <leaf> to the <console>.',
     'firing-104.csv'),
    ('repl-027', 'paths',
     'Print the directory part of "/srv/apiary/weights/2026-05.yaml".',
     'Create the <path> with "/srv/apiary/weights/2026-05.yaml".\n'
     'Compute the <folder: dirname> from <path>.\n'
     'Log <folder> to the <console>.',
     '/srv/apiary/weights'),
    ('repl-028', 'paths',
     'Print the file type of "lock-gauge.tsv" without its dot.',
     'Create the <name> with "lock-gauge.tsv".\n'
     'Compute the <kind: extension> from <name>.\n'
     'Log <kind> to the <console>.',
     'tsv'),
    ('repl-029', 'paths',
     'Join the trusted upload directory "/srv/dropbox" to the untrusted file '
     'name "roster.csv" and print the single path that comes out.',
     'Create the <dir> with "/srv/dropbox".\n'
     'Create the <name> with "roster.csv".\n'
     'Compute the <target: path-join> from <dir> with <name>.\n'
     'Log <target> to the <console>.',
     '/srv/dropbox/roster.csv'),
    ('repl-030', 'files',
     'Write the single line "stake 12" into "glacier.txt", read it straight '
     'back, and print what came back.',
     'Write "stake 12" to the <file: "glacier.txt">.\n'
     'Read the <back> from the <file: "glacier.txt">.\n'
     'Log <back> to the <console>.',
     'stake 12'),
    ('repl-031', 'files',
     'Say whether "absent-ledger.txt" is on disk, printing the answer.',
     'Exists the <ledger-there> for the <file: "absent-ledger.txt">.\n'
     'Log <ledger-there> to the <console>.',
     'false'),

    # ── conditionals (weak domain) ───────────────────────────────────────────
    ('repl-032', 'conditionals',
     'A greenhouse vent should open above 28 degrees. With the reading at 31, '
     'print "vent open" only when that holds.',
     'Create the <house-temp> with 31.\n'
     'Log "vent open" to the <console> when <house-temp> > 28.',
     'vent open'),
    ('repl-033', 'conditionals',
     'With a tide height of 1.2 metres, print "ferry cancelled" when the '
     'height is below 1.5 and print "ferry sails" when it is not.',
     'Create the <tide> with 1.2.\n'
     'Log "ferry cancelled" to the <console> when <tide> < 1.5.\n'
     'Log "ferry sails" to the <console> when <tide> >= 1.5.',
     'ferry cancelled'),
    ('repl-034', 'conditionals',
     'The route "/depot/health" should be treated as internal. Print '
     '"internal" when the path begins with "/depot".',
     'Create the <route> with "/depot/health".\n'
     'Log "internal" to the <console> when <route> starts with "/depot".',
     'internal'),
    ('repl-035', 'conditionals',
     'A kiln log name is "firing-104.csv". Print "archive it" when the name '
     'ends with ".csv".',
     'Create the <log-name> with "firing-104.csv".\n'
     'Log "archive it" to the <console> when <log-name> ends with ".csv".',
     'archive it'),
    ('repl-036', 'conditionals',
     'Given the banned moorings "lock-3" and "lock-8", and a request for '
     '"lock-5", print "mooring free" when the request is not banned.',
     'Create the <banned> with ["lock-3", "lock-8"].\n'
     'Create the <wanted> with "lock-5".\n'
     'Log "mooring free" to the <console> when <wanted> not in <banned>.',
     'mooring free'),
    ('repl-037', 'conditionals',
     'A ringer holds "tower" and "method"; the peal needs "tower". Print '
     '"may ring" when every needed permission is held.',
     'Create the <held> with ["tower", "method"].\n'
     'Create the <needed> with ["tower"].\n'
     'Log "may ring" to the <console> when <needed> subset of <held>.',
     'may ring'),
    ('repl-038', 'conditionals',
     'Print "mentions kiln" when the note "load the kiln tonight" contains '
     'the word kiln.',
     'Create the <note> with "load the kiln tonight".\n'
     'Log "mentions kiln" to the <console> when <note> contains "kiln".',
     'mentions kiln'),
    ('repl-039', 'conditionals',
     'Compare two counted bale totals, 48 and 48, binding the comparison to a '
     'fresh name, and print "counts agree" when they match.',
     'Create the <field-count> with 48.\n'
     'Create the <shed-count> with 48.\n'
     'Compare the <tally> from the <field-count> against the <shed-count>.\n'
     'Log "counts agree" to the <console> when <tally: matches>.',
     'counts agree'),
    ('repl-040', 'conditionals',
     'Branch on the lock state "closed" with a match: print "waiting" for '
     '"closed", "going through" for "open", and "unknown state" otherwise.',
     'Create the <lock-state> with "closed".\n'
     'match <lock-state> {\n'
     '    case "closed" {\n'
     '        Log "waiting" to the <console>.\n'
     '    }\n'
     '    case "open" {\n'
     '        Log "going through" to the <console>.\n'
     '    }\n'
     '    otherwise {\n'
     '        Log "unknown state" to the <console>.\n'
     '    }\n'
     '}',
     'waiting'),

    # ── iteration ────────────────────────────────────────────────────────────
    ('repl-041', 'iteration',
     'Walk the three dental surgery names "chair-a", "chair-b", "chair-c" and '
     'print each one on its own line.',
     'Create the <chairs> with ["chair-a", "chair-b", "chair-c"].\n'
     'for each <chair> in <chairs> {\n'
     '    Log <chair> to the <console>.\n'
     '}',
     'chair-a\nchair-b\nchair-c'),
    ('repl-042', 'iteration',
     'Over the hive numbers 1, 2, 3, print each number doubled.',
     'Create the <hives> with [1, 2, 3].\n'
     'for each <hive> in <hives> {\n'
     '    Compute the <doubled> from <hive> * 2.\n'
     '    Log <doubled> to the <console>.\n'
     '}',
     '2\n4\n6'),
    ('repl-043', 'iteration',
     'Walk the moorings 1, 2, 3, 4 but stop as soon as a mooring number is '
     'above 2, printing the ones you reached.',
     'Create the <moorings> with [1, 2, 3, 4].\n'
     'for each <mooring> in <moorings> {\n'
     '    when <mooring> > 2 {\n'
     '        break.\n'
     '    }\n'
     '    Log <mooring> to the <console>.\n'
     '}',
     '1\n2'),
    ('repl-044', 'iteration',
     'Count up from 1 to 3 with a while loop, printing each step.',
     'Compute the <step> from 1.\n'
     'while <step> <= 3 {\n'
     '    Log <step> to the <console>.\n'
     '    Compute the <step> from <step> + 1.\n'
     '}',
     '1\n2\n3'),
    # A `for each` body may NOT rebind an accumulator declared outside it —
    # `aro check` rejects that as an immutability violation, where a `while`
    # body may. The distinction is worth a benchmark row of its own, because
    # "use a loop and an accumulator" is exactly where a model trained on
    # imperative languages reaches for the illegal form.
    ('repl-045', 'iteration',
     'Add the whole numbers from 1 up to 4 using a while loop and a running '
     'accumulator — not a sum qualifier — then print the total.',
     'Compute the <position> from 1.\n'
     'Compute the <running> from 0.\n'
     'while <position> <= 4 {\n'
     '    Compute the <running> from <running> + <position>.\n'
     '    Compute the <position> from <position> + 1.\n'
     '}\n'
     'Log <running> to the <console>.',
     '10'),

    # ── configuration (weak domain) ──────────────────────────────────────────
    ('repl-046', 'configuration',
     'Hold the whole application to four concurrent units of work, then print '
     '"ceiling set".',
     'Configure the <application: concurrency> with 4.\n'
     'Log "ceiling set" to the <console>.',
     'ceiling set'),
    ('repl-047', 'configuration',
     'Give the outbound HTTP client both a ceiling of 2 in flight and a rate '
     'of 5 per second in one statement, then print "client tuned".',
     'Configure the <http-client> with { concurrency: 2, rate: "5/s" }.\n'
     'Log "client tuned" to the <console>.',
     'client tuned'),
    ('repl-048', 'configuration',
     'Set the HTTP client timeout to eight seconds and print "timeout set".',
     'Configure the <http-client: timeout> with 8.\n'
     'Log "timeout set" to the <console>.',
     'timeout set'),
    ('repl-049', 'configuration',
     'Declare that the basket repository is partitioned per session, then '
     'print "basket scoped".',
     'Configure the <basket-repository: scope> with "session".\n'
     'Log "basket scoped" to the <console>.',
     'basket scoped'),
    ('repl-050', 'configuration',
     'Read the environment variable TURBINE_SITE, falling back to "orkney" '
     'when nobody set it, and print what you got.',
     'Extract the <site> from the <env: TURBINE_SITE> default "orkney".\n'
     'Log <site> to the <console>.',
     'orkney'),

    # ── repositories ─────────────────────────────────────────────────────────
    ('repl-051', 'repositories',
     'Put a single laundromat machine record — id 3, drum 8 kilos — into the '
     'machines repository, read the repository back, and print how many rows '
     'it holds.',
     'Create the <machine> with { id: 3, drum: 8 }.\n'
     'Store the <machine> into the <machines-repository>.\n'
     'Retrieve the <machines> from the <machines-repository>.\n'
     'Compute the <row-count: length> from the <machines>.\n'
     'Log <row-count> to the <console>.',
     '1'),
    ('repl-052', 'repositories',
     'Store two seed-bank accessions (id 1 "einkorn", id 2 "emmer"), fetch '
     'the one with id 2 and print its name.',
     'Create the <first> with { id: 1, name: "einkorn" }.\n'
     'Create the <second> with { id: 2, name: "emmer" }.\n'
     'Store the <first> into the <accession-repository>.\n'
     'Store the <second> into the <accession-repository>.\n'
     'Retrieve the <found> from the <accession-repository> where <id> is 2.\n'
     'Log <found: name> to the <console>.',
     'emmer'),
    ('repl-053', 'repositories',
     'Ask the empty kiln-firing repository for everything it has and print '
     'the number of rows, without assuming the query fails.',
     'Retrieve the <firings> from the <firing-repository>.\n'
     'Compute the <firing-count: length> from the <firings>.\n'
     'Log <firing-count> to the <console>.',
     '0'),

    # ── events ───────────────────────────────────────────────────────────────
    ('repl-054', 'events',
     'Announce that a canal lock has been emptied: build the payload with '
     'lock 3 and emit a LockEmptied event carrying it.',
     'Create the <lock> with { lock: 3 }.\n'
     'Emit a <LockEmptied: event> with <lock>.\n'
     'Log "announced" to the <console>.',
     'announced'),

    # ── publish (weak domain) ────────────────────────────────────────────────
    ('repl-055', 'publish',
     'Fix the roster size at 18, publish it under the name <roster-size> so '
     'other feature sets in the same business activity can see it, and print '
     'the published name.',
     'Create the <size> with 18.\n'
     'Publish as <roster-size> <size>.\n'
     'Log <roster-size> to the <console>.',
     '18'),
    ('repl-056', 'publish',
     'A tuning value of 3 should only be published when the mode is "fast". '
     'With the mode set to "slow", publish under a guard and then print '
     '"guard evaluated".',
     'Create the <mode> with "slow".\n'
     'Create the <tuning> with 3.\n'
     'Publish as <fast-tuning> <tuning> when <mode> == "fast".\n'
     'Log "guard evaluated" to the <console>.',
     'guard evaluated'),
]

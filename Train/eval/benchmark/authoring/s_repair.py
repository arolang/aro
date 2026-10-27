"""Repair stratum: a broken program, its real diagnostic, and the fix (#785).

What makes this different from `eval_derived/generators/errorfix.jsonl`, which
already holds 5,440 repair pairs: those prompts are "The following ARO code
fails `aro check`. Fix it:" followed by the program. The model is told that
something is wrong and has to find it. Here the prompt carries **the diagnostic
the toolchain actually printed**, which is the situation a developer is in and
the one `aro ask` is for — and it is a different skill, because the diagnostic
often names a fix that is wrong for the program (`aro check` suggests
`<running-updated>` for an illegal rebind, when the right repair is usually a
different loop).

The diagnostics are not written by hand. `build.py` runs each broken program
through the binary and pastes what came back, so a prompt cannot claim a
diagnostic the toolchain does not produce. That also means re-running the
builder against a different binary can change the prompts — which is why the
frozen artefact is the JSON and `MANIFEST.json` records the version it was
built with.

Error classes are spread across the ones that actually bite: a preposition the
action does not take (a *warning*, so `aro check` exits 0 and the program still
dies at run time), an immutable rebind, an invented verb, an invented Compute
qualifier, the two-operand `Compare`, `if/else` where the language has `when`,
`Map` with an expression, and the structural ones.

Each row: (id, domain, framing, broken, reference, expected_output|None,
           diagnostic_from) where diagnostic_from is 'check' or 'run'.
"""

ROWS = [
    # ── structural ───────────────────────────────────────────────────────────
    ('repair-001', 'syntax',
     'A colleague left this half-finished while tallying weighbridge tickets. '
     'Give me the whole file back, working.',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <gross> with 12_400\n'
     '    Log <gross> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <gross> with 12_400.\n'
     '    Log <gross> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '12400', 'check'),

    ('repair-002', 'syntax',
     'This lighthouse watch log will not load. Repair it and hand back the '
     'complete feature set.',
     '(Application-Start: Watch Log) {\n'
     '    Log "lamp lit" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n',
     '(Application-Start: Watch Log) {\n'
     '    Log "lamp lit" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'lamp lit', 'check'),

    ('repair-003', 'syntax',
     'The header on this kiln-schedule feature set is rejected. Fix the file.',
     '(Application-Start) {\n'
     '    Log "schedule loaded" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Kiln Schedule) {\n'
     '    Log "schedule loaded" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'schedule loaded', 'check'),

    ('repair-004', 'syntax',
     'Somebody typed the verb in lower case here. Correct the whole thing.',
     '(Application-Start: Tide Table) {\n'
     '    log "high water at 06:12" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Tide Table) {\n'
     '    Log "high water at 06:12" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'high water at 06:12', 'check'),

    ('repair-005', 'syntax',
     'The comment in this allotment roster was never closed. Give me the '
     'repaired file.',
     '(Application-Start: Allotment Roster) {\n'
     '    (* plots are numbered from the gate inward\n'
     '    Log "roster ready" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Allotment Roster) {\n'
     '    (* plots are numbered from the gate inward *)\n'
     '    Log "roster ready" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'roster ready', 'check'),

    ('repair-006', 'syntax',
     'A variable reference lost its brackets somewhere in this bale count. '
     'Put the file right.',
     '(Application-Start: Bale Count) {\n'
     '    Create the <bales> with 96.\n'
     '    Log bales to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Bale Count) {\n'
     '    Create the <bales> with 96.\n'
     '    Log <bales> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '96', 'check'),

    ('repair-007', 'syntax',
     'This feature set never says how it ends. Finish it so the checker is '
     'happy and it still prints the hive count.',
     '(Application-Start: Apiary) {\n'
     '    Create the <hives> with 9.\n'
     '    Log <hives> to the <console>.\n}\n',
     '(Application-Start: Apiary) {\n'
     '    Create the <hives> with 9.\n'
     '    Log <hives> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '9', 'check'),

    ('repair-008', 'architecture',
     'A copy-paste left two feature sets with the same name in this turbine '
     'file. Give me the file back with the duplicate gone; it should still '
     'print the output figure and nothing else.',
     '(Application-Start: Turbine) {\n'
     '    Create the <output-kwh> with 18_400.\n'
     '    Log <output-kwh> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Daily Report: Turbine) {\n'
     '    Log "report filed" to the <console>.\n'
     '    Return an <OK: status> for the <report>.\n}\n\n'
     '(Daily Report: Turbine) {\n'
     '    Log "report filed" to the <console>.\n'
     '    Return an <OK: status> for the <report>.\n}\n',
     '(Application-Start: Turbine) {\n'
     '    Create the <output-kwh> with 18_400.\n'
     '    Log <output-kwh> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Daily Report: Turbine) {\n'
     '    Log "report filed" to the <console>.\n'
     '    Return an <OK: status> for the <report>.\n}\n',
     '18400', 'check'),

    ('repair-009', 'architecture',
     'Two entry points crept into this ferry timetable when files were '
     'merged. Give me back one file with one entry point that logs both '
     'lines, the Dover line first.',
     '(Application-Start: Ferry Timetable) {\n'
     '    Log "dover 07:00" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Application-Start: Ferry Timetable) {\n'
     '    Log "calais 09:30" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Ferry Timetable) {\n'
     '    Log "dover 07:00" to the <console>.\n'
     '    Log "calais 09:30" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'dover 07:00\ncalais 09:30', 'check'),

    ('repair-010', 'architecture',
     'This parking-meter application has handlers but nothing to start it. '
     'Add what is missing so it runs and prints the takings, and return every '
     'feature set.',
     '(Takings Report: Meters) {\n'
     '    Create the <takings> with 445.\n'
     '    Log <takings> to the <console>.\n'
     '    Return an <OK: status> for the <report>.\n}\n',
     '(Application-Start: Meters) {\n'
     '    Create the <takings> with 445.\n'
     '    Log <takings> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '445', 'check'),

    # ── immutability ─────────────────────────────────────────────────────────
    ('repair-011', 'immutability',
     'The second measurement here tries to reuse the first name. Rework it so '
     'both cave readings survive and both are printed, humidity first.',
     '(Application-Start: Cheese Cave) {\n'
     '    Compute the <reading> from 84.\n'
     '    Compute the <reading> from 11.\n'
     '    Log <reading> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Cheese Cave) {\n'
     '    Compute the <humidity> from 84.\n'
     '    Compute the <temperature> from 11.\n'
     '    Log <humidity> to the <console>.\n'
     '    Log <temperature> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '84\n11', 'check'),

    ('repair-012', 'immutability',
     'Two lengths are wanted from two different labels, and this will not '
     'compile. Use the qualifier-as-name form and print both lengths, the '
     'short one first.',
     '(Application-Start: Labels) {\n'
     '    Create the <front> with "orkney".\n'
     '    Create the <back> with "north ronaldsay".\n'
     '    Compute the <length> from <front>.\n'
     '    Compute the <length> from <back>.\n'
     '    Log <length> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Labels) {\n'
     '    Create the <front> with "orkney".\n'
     '    Create the <back> with "north ronaldsay".\n'
     '    Compute the <front-length: length> from <front>.\n'
     '    Compute the <back-length: length> from <back>.\n'
     '    Log <front-length> to the <console>.\n'
     '    Log <back-length> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '6\n15', 'check'),

    ('repair-013', 'immutability',
     'This accumulator sits outside a for-each and the loop will not accept '
     'it. Rewrite the feature set so it still prints the total of the fares, '
     'and say nothing else.',
     '(Application-Start: Tram Fares) {\n'
     '    Create the <fares> with [3, 4, 5].\n'
     '    Compute the <running> from 0.\n'
     '    for each <fare> in <fares> {\n'
     '        Compute the <running> from <running> + <fare>.\n'
     '    }\n'
     '    Log <running> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Tram Fares) {\n'
     '    Create the <fares> with [3, 4, 5].\n'
     '    Compute the <total: sum> from the <fares>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '12', 'check'),

    # ── invented names ───────────────────────────────────────────────────────
    ('repair-014', 'actions',
     'Whoever wrote this invented a verb. Replace it with the real action and '
     'keep the printed result the same.',
     '(Application-Start: Seed Bank) {\n'
     '    Grab the <accessions> from the <accession-repository>.\n'
     '    Compute the <n: length> from the <accessions>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Seed Bank) {\n'
     '    Retrieve the <accessions> from the <accession-repository>.\n'
     '    Compute the <n: length> from the <accessions>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '0', 'check'),

    ('repair-015', 'actions',
     'There is no such Compute qualifier. Fix the statement so it prints the '
     'number of glacier stake readings.',
     '(Application-Start: Glacier) {\n'
     '    Create the <stakes> with [12, 18, 24].\n'
     '    Compute the <n: size> from the <stakes>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Glacier) {\n'
     '    Create the <stakes> with [12, 18, 24].\n'
     '    Compute the <n: length> from the <stakes>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '3', 'check'),

    ('repair-016', 'actions',
     'This calls a user-defined action that nobody wrote. Add the action it '
     'needs — it should triple its argument — and return both feature sets.',
     '(Application-Start: Falconry) {\n'
     '    Application.TripleWeight the <out> from 7.\n'
     '    Extract the <value> from the <out: tripled>.\n'
     '    Log <value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(TripleWeight: Action takes <grams>) {\n'
     '    Extract the <g> from the <input: grams>.\n'
     '    Compute the <tripled> from <g> * 3.\n'
     '    Return an <OK: status> with { tripled: <tripled> }.\n}\n\n'
     '(Application-Start: Falconry) {\n'
     '    Application.TripleWeight the <out> from 7.\n'
     '    Extract the <value> from the <out: tripled>.\n'
     '    Log <value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '21', 'check'),

    ('repair-017', 'actions',
     'The qualifier chain here has an invented link in it. Repair the '
     'statement so the trimmed, capitalised name is printed.',
     '(Application-Start: Ringers) {\n'
     '    Create the <raw> with "  bess  ".\n'
     '    Compute the <name: trim|capitalise-all> from <raw>.\n'
     '    Log <name> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Ringers) {\n'
     '    Create the <raw> with "  bess  ".\n'
     '    Compute the <name: trim|uppercase> from <raw>.\n'
     '    Log <name> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'BESS', 'check'),

    # ── prepositions: warnings that pass `aro check` and die at run time ─────
    ('repair-018', 'throw',
     'The checker only warned about this, and then it blew up when I ran it. '
     'Fix the Throw statement and hand back the file; with the gate at 15 it '
     'should refuse and print nothing else.',
     '(Application-Start: Gatehouse) {\n'
     '    Create the <age> with 15.\n'
     '    Throw a <BadRequest: status> with "under age" when <age> < 18.\n'
     '    Log "admitted" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Gatehouse) {\n'
     '    Create the <age> with 15.\n'
     '    Throw a <BadRequest: status> for "under age" when <age> < 18.\n'
     '    Log "admitted" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'run'),

    ('repair-019', 'actions',
     'Accept is being given a preposition it does not take. Correct it and '
     'return the file.',
     '(Application-Start: Lock Keeper) {\n'
     '    Create the <lock> with { id: 1, state: "closed" }.\n'
     '    Accept the <opened> for the <lock> with "open".\n'
     '    Log "transition attempted" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Lock Keeper) {\n'
     '    Create the <lock> with { id: 1, state: "closed" }.\n'
     '    Accept the <opened> on the <lock> with "open".\n'
     '    Log "transition attempted" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'run'),

    ('repair-020', 'files',
     'This Move statement is written the way a shell command would be. Give '
     'me the version the parser accepts, keeping the printed line.',
     '(Application-Start: Dropbox) {\n'
     '    Move the <roster> from the <file: "in/roster.csv"> '
     'to the <file: "done/roster.csv">.\n'
     '    Log "moved" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Dropbox) {\n'
     '    Make the <inbox> to the <path: "in">.\n'
     '    Make the <archive> to the <path: "done">.\n'
     '    Write "plot,holder" to the <file: "in/roster.csv">.\n'
     '    Create the <source> with "in/roster.csv".\n'
     '    Create the <target> with "done/roster.csv".\n'
     '    Move the <moved: source> to the <target>.\n'
     '    Log "moved" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'moved', 'check'),

    # ── wrong shapes the checker catches ─────────────────────────────────────
    ('repair-021', 'conditionals',
     'This was written by somebody who knows Python. Translate it into the '
     'conditional form ARO actually has; with the reading at 31 it should '
     'print the vent line only.',
     '(Application-Start: Greenhouse) {\n'
     '    Create the <house-temp> with 31.\n'
     '    if <house-temp> > 28 {\n'
     '        Log "vent open" to the <console>.\n'
     '    } else {\n'
     '        Log "vent shut" to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Greenhouse) {\n'
     '    Create the <house-temp> with 31.\n'
     '    Log "vent open" to the <console> when <house-temp> > 28.\n'
     '    Log "vent shut" to the <console> when <house-temp> <= 28.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'vent open', 'check'),

    ('repair-022', 'actions',
     'Map is being handed an expression. Rewrite the feature set so each '
     'discounted price is printed in order instead.',
     '(Application-Start: Vineyard) {\n'
     '    Create the <cases> with [{ price: 100 }, { price: 200 }].\n'
     '    Map the <discounted> from the <cases> with <price> * 0.9.\n'
     '    Log <discounted> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Vineyard) {\n'
     '    Create the <cases> with [{ price: 100 }, { price: 200 }].\n'
     '    for each <case> in <cases> {\n'
     '        Compute the <net> from <case: price> * 0.9.\n'
     '        Log <net> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '90\n180', 'check'),

    ('repair-023', 'actions',
     'The old two-operand Compare cannot run under immutability. Bring this '
     'up to date so it prints the agreement line when the counts match.',
     '(Application-Start: Silage) {\n'
     '    Create the <field-count> with 48.\n'
     '    Create the <shed-count> with 48.\n'
     '    Compare the <field-count> against the <shed-count>.\n'
     '    Log "counts agree" to the <console> when <field-count: matches>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Silage) {\n'
     '    Create the <field-count> with 48.\n'
     '    Create the <shed-count> with 48.\n'
     '    Compare the <tally> from the <field-count> against the '
     '<shed-count>.\n'
     '    Log "counts agree" to the <console> when <tally: matches>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'counts agree', 'check'),

    ('repair-024', 'collections',
     'Reduce is being given a bare qualifier name where it wants something '
     'else. Fix it so the total of the takings is printed.',
     '(Application-Start: Laundromat) {\n'
     '    Create the <takings> with [240, 115, 90].\n'
     '    Reduce the <total> from the <takings> with sum.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Laundromat) {\n'
     '    Create the <takings> with [240, 115, 90].\n'
     '    Reduce the <total: sum> from the <takings>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '445', 'check'),

    ('repair-025', 'collections',
     'The Group statement is using the wrong clause. Repair it so the number '
     'of distinct clamps is printed.',
     '(Application-Start: Clamps) {\n'
     '    Create the <bales> with [{ clamp: "north", t: 20 }, '
     '{ clamp: "south", t: 14 }, { clamp: "north", t: 6 }].\n'
     '    Group the <by-clamp> from the <bales> with clamp.\n'
     '    Compute the <n: length> from the <by-clamp>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Clamps) {\n'
     '    Create the <bales> with [{ clamp: "north", t: 20 }, '
     '{ clamp: "south", t: 14 }, { clamp: "north", t: 6 }].\n'
     '    Group the <by-clamp> from the <bales> by "clamp".\n'
     '    Compute the <n: length> from the <by-clamp>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '2', 'check'),

    ('repair-026', 'publish',
     'The Publish statement is missing the keyword that names the alias. Fix '
     'it and keep the printed value.',
     '(Application-Start: Choir) {\n'
     '    Create the <size> with 18.\n'
     '    Publish <roster-size> <size>.\n'
     '    Log <roster-size> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Choir) {\n'
     '    Create the <size> with 18.\n'
     '    Publish as <roster-size> <size>.\n'
     '    Log <roster-size> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '18', 'check'),

    ('repair-027', 'iteration',
     'The loop keyword here is wrong. Correct it so each chair name is '
     'printed on its own line.',
     '(Application-Start: Surgery) {\n'
     '    Create the <chairs> with ["chair-a", "chair-b"].\n'
     '    for each <chair> of <chairs> {\n'
     '        Log <chair> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Surgery) {\n'
     '    Create the <chairs> with ["chair-a", "chair-b"].\n'
     '    for each <chair> in <chairs> {\n'
     '        Log <chair> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'chair-a\nchair-b', 'check'),

    ('repair-028', 'iteration',
     'The early exit in this loop is missing something and the whole feature '
     'set stops parsing because of it. Fix it so the moorings up to and '
     'including 2 are printed and no more.',
     '(Application-Start: Moorings) {\n'
     '    Create the <moorings> with [1, 2, 3, 4].\n'
     '    for each <mooring> in <moorings> {\n'
     '        when <mooring> > 2 {\n'
     '            break\n'
     '        }\n'
     '        Log <mooring> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Moorings) {\n'
     '    Create the <moorings> with [1, 2, 3, 4].\n'
     '    for each <mooring> in <moorings> {\n'
     '        when <mooring> > 2 {\n'
     '            break.\n'
     '        }\n'
     '        Log <mooring> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '1\n2', 'check'),

    ('repair-029', 'conditionals',
     'A match case here has no block around its body. Repair the feature set '
     'so the waiting line is printed.',
     '(Application-Start: Canal) {\n'
     '    Create the <lock-state> with "closed".\n'
     '    match <lock-state> {\n'
     '        case "closed"\n'
     '            Log "waiting" to the <console>.\n'
     '        otherwise {\n'
     '            Log "unknown state" to the <console>.\n'
     '        }\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Canal) {\n'
     '    Create the <lock-state> with "closed".\n'
     '    match <lock-state> {\n'
     '        case "closed" {\n'
     '            Log "waiting" to the <console>.\n'
     '        }\n'
     '        otherwise {\n'
     '            Log "unknown state" to the <console>.\n'
     '        }\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'waiting', 'check'),

    ('repair-030', 'configuration',
     'Two Configure statements name the same category and the second one '
     'cannot bind. Collapse them properly and keep the printed line.',
     '(Application-Start: Depot) {\n'
     '    Configure the <http-client> with { concurrency: 2 }.\n'
     '    Configure the <http-client> with { rate: "5/s" }.\n'
     '    Log "client tuned" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Depot) {\n'
     '    Configure the <http-client> with { concurrency: 2, rate: "5/s" }.\n'
     '    Log "client tuned" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'client tuned', 'check'),

    ('repair-031', 'configuration',
     'This loader declares a per-caller basket store and then writes to it '
     'from the entry point, which the checker refuses. Fix the declaration so '
     'the write is legal, and keep the printed line.',
     '(Application-Start: Baskets) {\n'
     '    Configure the <basket-repository: scope> with "session".\n'
     '    Create the <item> with { id: 1 }.\n'
     '    Store the <item> into the <basket-repository>.\n'
     '    Log "basket scoped" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Baskets) {\n'
     '    Configure the <basket-repository: scope> with "application".\n'
     '    Create the <item> with { id: 1 }.\n'
     '    Store the <item> into the <basket-repository>.\n'
     '    Log "basket scoped" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'basket scoped', 'check'),

    ('repair-032', 'text',
     'String concatenation is being attempted with an operator ARO does not '
     'have there. Produce the joined call sign another way and print it.',
     '(Application-Start: Radio) {\n'
     '    Create the <prefix> with "GB".\n'
     '    Create the <serial> with "2291".\n'
     '    Compute the <callsign> from <prefix> + "-" + <serial>.\n'
     '    Log <callsign> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Radio) {\n'
     '    Create the <prefix> with "GB".\n'
     '    Create the <serial> with "2291".\n'
     '    Compute the <callsign> from <prefix> ++ "-" ++ <serial>.\n'
     '    Log <callsign> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'GB-2291', 'run'),

    ('repair-033', 'repositories',
     'The first Store in this seed-bank loader warned at check time and then '
     'killed the run. Repair it so the second accession name is printed.',
     '(Application-Start: Accessions) {\n'
     '    Create the <first> with { id: 1, name: "einkorn" }.\n'
     '    Create the <second> with { id: 2, name: "emmer" }.\n'
     '    Store the <first> from the <accession-repository>.\n'
     '    Store the <second> into the <accession-repository>.\n'
     '    Retrieve the <found> from the <accession-repository> '
     'where <id> is 2.\n'
     '    Log <found: name> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Accessions) {\n'
     '    Create the <first> with { id: 1, name: "einkorn" }.\n'
     '    Create the <second> with { id: 2, name: "emmer" }.\n'
     '    Store the <first> into the <accession-repository>.\n'
     '    Store the <second> into the <accession-repository>.\n'
     '    Retrieve the <found> from the <accession-repository> '
     'where <id> is 2.\n'
     '    Log <found: name> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'emmer', 'run'),

    ('repair-034', 'collections',
     'Sort is being pointed at records and fails at run time. Rewrite the '
     'feature set so it prints the tonnages in ascending order instead.',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <loads> with [{ ticket: 1, t: 20 }, { ticket: 2, t: 6 }].\n'
     '    Sort the <ordered> for the <loads>.\n'
     '    Log <ordered> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <loads> with [{ ticket: 1, t: 20 }, { ticket: 2, t: 6 }].\n'
     '    Map the <tonnages> from the <loads> with t.\n'
     '    Sort the <ordered> for the <tonnages>.\n'
     '    Log <ordered> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '[6, 20]', 'run'),

    ('repair-035', 'rest',
     'The status name in this handler is misspelled. Correct it and return '
     'the file; the contract is already in place.',
     '(getFiring: Kiln API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <firing> from the <firing-repository> where <id> is '
     '<id>.\n'
     '    Return a <NotFoundd: status> with <firing>.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(getFiring: Kiln API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <firing> from the <firing-repository> where <id> is '
     '<id>.\n'
     '    Return a <NotFound: status> with <firing>.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'check'),

    ('repair-036', 'events',
     'An event is emitted here and nothing handles it. Add the handler so the '
     'lock number is printed, and give me both feature sets.',
     '(Application-Start: Canal Watch) {\n'
     '    Create the <emptying> with { lock: 3 }.\n'
     '    Emit a <LockEmptied: event> with <emptying>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Canal Watch) {\n'
     '    Create the <emptying> with { lock: 3 }.\n'
     '    Emit a <LockEmptied: event> with <emptying>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Note Emptying: LockEmptied Handler) {\n'
     '    Extract the <body> from the <event: emptying>.\n'
     '    Log <body: lock> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n',
     '3', 'check'),

    ('repair-037', 'events',
     'The handler reads the event payload at the wrong level and dies at run '
     'time. Fix it so the ticket number is printed, returning both feature '
     'sets.',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <load> with { ticket: 814 }.\n'
     '    Emit a <LoadWeighed: event> with <load>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Note Load: LoadWeighed Handler) {\n'
     '    Extract the <ticket> from the <event: ticket>.\n'
     '    Log <ticket> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n',
     '(Application-Start: Weighbridge) {\n'
     '    Create the <load> with { ticket: 814 }.\n'
     '    Emit a <LoadWeighed: event> with <load>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Note Load: LoadWeighed Handler) {\n'
     '    Extract the <load> from the <event: load>.\n'
     '    Log <load: ticket> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n',
     '814', 'run'),

    ('repair-038', 'tests',
     'This test feature set is never collected by `aro test`. Make it a test '
     'and keep the assertion it already has.',
     '(sums-a-basket: Totals) {\n'
     '    Given the <prices> with [4, 6, 10].\n'
     '    Compute the <total: sum> from the <prices>.\n'
     '    Assert the <total> with 20.\n}\n\n'
     '(Application-Start: Totals) {\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(sums-a-basket: Totals Test) {\n'
     '    Given the <prices> with [4, 6, 10].\n'
     '    Compute the <total: sum> from the <prices>.\n'
     '    Assert the <total> with 20.\n}\n\n'
     '(Application-Start: Totals) {\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'check'),

    ('repair-039', 'publish',
     'A handler cannot see what the entry point published, and the run fails. '
     'Put it right so the published roster size is printed, and give me both '
     'feature sets.',
     '(Application-Start: Bell Tower) {\n'
     '    Create the <size> with 18.\n'
     '    Publish as <roster-size> <size>.\n'
     '    Emit a <PealCalled: event> with { ok: true }.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Report Size: PealCalled Handler) {\n'
     '    Require the <roster-size> from the <BellTower>.\n'
     '    Log <roster-size> to the <console>.\n'
     '    Return an <OK: status> for the <report>.\n}\n',
     '(Application-Start: Bell Tower) {\n'
     '    Create the <size> with 18.\n'
     '    Publish as <roster-size> <size>.\n'
     '    Log <roster-size> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '18', 'run'),

    ('repair-040', 'files',
     'The lines count here is off by one because of how the file ends. Fix '
     'the feature set so it prints the number of real lines.',
     '(Application-Start: Note Count) {\n'
     '    Write "mon\\ntue\\nwed\\n" to the <file: "notes.txt">.\n'
     '    Read the <content> from the <file: "notes.txt">.\n'
     '    Split the <rows> from the <content> by "\\n".\n'
     '    Compute the <n: length> from the <rows>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Note Count) {\n'
     '    Write "mon\\ntue\\nwed\\n" to the <file: "notes.txt">.\n'
     '    Read the <content> from the <file: "notes.txt">.\n'
     '    Compute the <rows: lines> from <content>.\n'
     '    Compute the <n: length> from the <rows>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '3', 'run'),

    ('repair-041', 'text',
     'This hand-escapes a value and then prints it into a template that '
     'escapes as well. Remove the double escaping so the vineyard note comes '
     'out once-escaped.',
     '(Application-Start: Notes) {\n'
     '    Create the <note> with "Block <C> & rows".\n'
     '    Compute the <once: html-escape> from <note>.\n'
     '    Compute the <twice: html-escape> from <once>.\n'
     '    Log <twice> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Notes) {\n'
     '    Create the <note> with "Block <C> & rows".\n'
     '    Compute the <safe: html-escape> from <note>.\n'
     '    Log <safe> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'Block &lt;C&gt; &amp; rows', 'run'),

    ('repair-042', 'paths',
     'Somebody expected the absolute right-hand side to win here and it did '
     'not. Rewrite it so the printed path is the trusted directory joined to '
     'the bare file name.',
     '(Application-Start: Uploads) {\n'
     '    Create the <dir> with "/srv/dropbox".\n'
     '    Create the <name> with "/etc/passwd".\n'
     '    Compute the <target: path-join> from <dir> with <name>.\n'
     '    Log <target> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Uploads) {\n'
     '    Create the <dir> with "/srv/dropbox".\n'
     '    Create the <raw> with "/etc/passwd".\n'
     '    Compute the <name: basename> from <raw>.\n'
     '    Compute the <target: path-join> from <dir> with <name>.\n'
     '    Log <target> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '/srv/dropbox/passwd', 'run'),

    ('repair-043', 'numbers',
     'The rounding here leaves more decimals than money should have. Fix it '
     'so the billed figure prints to two places.',
     '(Application-Start: Billing) {\n'
     '    Create the <raw-kwh> with 7.48812.\n'
     '    Compute the <billed: round> from <raw-kwh>.\n'
     '    Log <billed> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Billing) {\n'
     '    Create the <raw-kwh> with 7.48812.\n'
     '    Compute the <billed: fixed> from <raw-kwh>.\n'
     '    Log <billed> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '7.49', 'check'),

    ('repair-044', 'conditionals',
     'The guard on this statement uses a word that is not an ARO operator. '
     'Repair it so the internal line prints for the depot route.',
     '(Application-Start: Routing) {\n'
     '    Create the <route> with "/depot/health".\n'
     '    Log "internal" to the <console> when <route> beginswith "/depot".\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Routing) {\n'
     '    Create the <route> with "/depot/health".\n'
     '    Log "internal" to the <console> when <route> starts with "/depot".\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'internal', 'check'),

    ('repair-045', 'collections',
     'This filter uses the wrong clause for its predicate, which the checker '
     'only grumbled about. Fix it so the count of large plots prints.',
     '(Application-Start: Allotments) {\n'
     '    Create the <plots> with [{ plot: 4, beds: 12 }, '
     '{ plot: 9, beds: 3 }].\n'
     '    Filter the <large> from the <plots> with <beds> > 10.\n'
     '    Compute the <n: length> from the <large>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Allotments) {\n'
     '    Create the <plots> with [{ plot: 4, beds: 12 }, '
     '{ plot: 9, beds: 3 }].\n'
     '    Filter the <large> from the <plots> where <beds> > 10.\n'
     '    Compute the <n: length> from the <large>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '1', 'run'),

    ('repair-046', 'actions',
     'A plugin qualifier is being used without its namespace. Rewrite the '
     'statement to use a built-in that does the same job here, and print the '
     'count.',
     '(Application-Start: Depot) {\n'
     '    Create the <routes> with ["7", "3", "7"].\n'
     '    Compute the <n: size-of> from the <routes>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Depot) {\n'
     '    Create the <routes> with ["7", "3", "7"].\n'
     '    Compute the <n: length> from the <routes>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '3', 'check'),

    ('repair-047', 'rest',
     'This handler builds its own response envelope by hand. Replace that '
     'with the Return the language already has, and give me the handler plus '
     'the entry point.',
     '(listFirings: Kiln API) {\n'
     '    Retrieve the <firings> from the <firing-repository>.\n'
     '    Create the <envelope> with { status: 200, body: <firings> }.\n'
     '    Send the <envelope> to the <response>.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(listFirings: Kiln API) {\n'
     '    Retrieve the <firings> from the <firing-repository>.\n'
     '    Return an <OK: status> with <firings>.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'check'),

    ('repair-048', 'architecture',
     'This server application exits the moment it has started. Add the one '
     'statement that keeps it up, and return both feature sets.',
     '(listBerths: Marina API) {\n'
     '    Retrieve the <berths> from the <berth-repository>.\n'
     '    Return an <OK: status> with <berths>.\n}\n\n'
     '(Application-Start: Marina API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(listBerths: Marina API) {\n'
     '    Retrieve the <berths> from the <berth-repository>.\n'
     '    Return an <OK: status> with <berths>.\n}\n\n'
     '(Application-Start: Marina API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'symptom'),

    ('repair-049', 'actions',
     'The Validate statement is handed a preposition the action does not '
     'take. Correct it and keep the printed line.',
     '(Application-Start: Intake) {\n'
     '    Create the <form> with { holder: "bess" }.\n'
     '    Validate the <checked> from the <form>.\n'
     '    Log "validated" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Intake) {\n'
     '    Create the <form> with { holder: "bess" }.\n'
     '    Validate the <checked> for the <form>.\n'
     '    Log "validated" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'validated', 'run'),

    ('repair-050', 'text',
     'The regex here has no named groups, so nothing can be read off the '
     'match. Rewrite it so the turbine hub identifier is printed.',
     '(Application-Start: Turbines) {\n'
     '    Create the <line> with "turbine=hub-14".\n'
     '    Compute the <parts: captures> from <line> by /[a-z]+=.+/.\n'
     '    Log <parts: value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Turbines) {\n'
     '    Create the <line> with "turbine=hub-14".\n'
     '    Compute the <parts: captures> from <line> '
     'by /(?<key>[a-z]+)=(?<value>.+)/.\n'
     '    Log <parts: value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'hub-14', 'run'),

    ('repair-051', 'collections',
     'This tries to take the first element with a qualifier that is not one. '
     'Fix it so the first route is printed.',
     '(Application-Start: Routes) {\n'
     '    Create the <routes> with ["7", "3", "11"].\n'
     '    Compute the <head: head> from the <routes>.\n'
     '    Log <head> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Routes) {\n'
     '    Create the <routes> with ["7", "3", "11"].\n'
     '    Extract the <head: first> from the <routes>.\n'
     '    Log <head> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '7', 'check'),

    ('repair-052', 'conditionals',
     'The default clause on this Extract is written as an operator and will '
     'not parse. Repair it so the fallback site name prints.',
     '(Application-Start: Siting) {\n'
     '    Extract the <site> from the <env: TURBINE_SITE> || "orkney".\n'
     '    Log <site> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Siting) {\n'
     '    Extract the <site> from the <env: TURBINE_SITE> default "orkney".\n'
     '    Log <site> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'orkney', 'check'),

    ('repair-053', 'repositories',
     'This assumes a Retrieve that matches nothing will fail, and guards the '
     'wrong thing. Rewrite it so an empty kiln repository prints the empty '
     'line and nothing else.',
     '(Application-Start: Firings) {\n'
     '    Retrieve the <firings> from the <firing-repository>.\n'
     '    Throw a <NotFound: status> for "no firings" when <firings> == [].\n'
     '    Log "have firings" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Firings) {\n'
     '    Retrieve the <firings> from the <firing-repository>.\n'
     '    Compute the <n: length> from the <firings>.\n'
     '    Log "no firings yet" to the <console> when <n> == 0.\n'
     '    Log "have firings" to the <console> when <n> > 0.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'no firings yet', 'run'),

    ('repair-054', 'actions',
     'The entry point calls a user-defined action with the wrong clause for '
     'an action that declares no `takes`. Fix the call site and give me both '
     'feature sets.',
     '(SumPair: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Compute the <sum> from <a> + <b>.\n'
     '    Return an <OK: status> with { sum: <sum> }.\n}\n\n'
     '(Application-Start: Adder) {\n'
     '    Application.SumPair the <out> from { a: 3, b: 4 }.\n'
     '    Extract the <value> from the <out: sum>.\n'
     '    Log <value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(SumPair: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Compute the <sum> from <a> + <b>.\n'
     '    Return an <OK: status> with { sum: <sum> }.\n}\n\n'
     '(Application-Start: Adder) {\n'
     '    Application.SumPair the <out> with { a: 3, b: 4 }.\n'
     '    Extract the <value> from the <out: sum>.\n'
     '    Log <value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '7', 'check'),

    ('repair-055', 'syntax',
     'The string literal in this bell inscription was never closed. Repair '
     'the file.',
     '(Application-Start: Inscription) {\n'
     '    Create the <text> with "cast in 1742.\n'
     '    Log <text> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     '(Application-Start: Inscription) {\n'
     '    Create the <text> with "cast in 1742".\n'
     '    Log <text> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     'cast in 1742', 'check'),
]


# Contracts for the repair tasks that are HTTP handlers. ARO is contract-first,
# so a route handler with no `openapi.yaml` beside it is not the task that was
# set — the file is given to the grader, and the prompt says it is already in
# place.
FILES = {
    'repair-035': {'openapi.yaml':
                   'openapi: 3.0.3\n'
                   'info:\n'
                   '  title: Kiln API\n'
                   '  version: 1.0.0\n'
                   'paths:\n'
                   '  /firings/{id}:\n'
                   '    get:\n'
                   '      operationId: getFiring\n'
                   '      parameters:\n'
                   '        - name: id\n'
                   '          in: path\n'
                   '          required: true\n'
                   '          schema:\n'
                   '            type: string\n'},
    'repair-047': {'openapi.yaml':
                   'openapi: 3.0.3\n'
                   'info:\n'
                   '  title: Kiln API\n'
                   '  version: 1.0.0\n'
                   'paths:\n'
                   '  /firings:\n'
                   '    get:\n'
                   '      operationId: listFirings\n'},
    'repair-048': {'openapi.yaml':
                   'openapi: 3.0.3\n'
                   'info:\n'
                   '  title: Marina API\n'
                   '  version: 1.0.0\n'
                   'paths:\n'
                   '  /berths:\n'
                   '    get:\n'
                   '      operationId: listBerths\n'},
}

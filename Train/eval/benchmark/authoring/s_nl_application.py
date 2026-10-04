"""NL → application stratum (GitLab #785, weak domain REST from #797).

The stated product goal is turning natural language into a valid ARO
application, and GitLab #797 found that task essentially absent from the
corpus: `knowledge_pairs` has fourteen `multi_file_application` rows and zero
`full_application`, and `eval_derived/generators/openapi_apps.jsonl`'s 180 rows
are one templated CRUD shape. REST measured 19 % in the 4,000-prompt run.

Two shapes here, because "write an application" means two different things:

  * 38 **contract-first HTTP services**: the answer is an `openapi.yaml` *and*
    the handlers named after its operationIds. Graded by `aro check` over the
    directory, because a server has no completion to observe — a handler that
    parses beside a contract that parses is the whole of what can be checked
    without a client.
  * 17 **complete runnable applications**: batch jobs, watchers, pipelines with
    a definite end. Graded by `aro run` against an expected output, which is
    the only axis that catches "parses, runs, computes the wrong thing" — the
    dominant failure in the run this benchmark replaces, and one `aro check`
    cannot see at all.

Specs are written the way a colleague would write them: the behaviour, the
route, the status, and what comes back. They name the operationIds, because a
contract-first handler is wired by its *name* and a benchmark that left the
names to chance would be grading a guess.

Each row: (id, domain, prompt, reference, reference_files|None,
           expected_output|None).
"""

CONTRACT_HEAD = 'openapi: 3.0.3\ninfo:\n  title: %s\n  version: 1.0.0\npaths:\n'

ROWS = [
    # ── contract-first HTTP services ─────────────────────────────────────────
    ('nlapp-001', 'rest',
     'Write me the complete ARO application for a canal-lock passage service. '
     'One route: GET /locks returns every lock from the lock repository with '
     'an OK status, under the operationId listLocks. Give me the openapi.yaml '
     'and the .aro, entry point included, and keep the server up for events.',
     '(listLocks: Canal API) {\n'
     '    Retrieve the <locks> from the <lock-repository>.\n'
     '    Return an <OK: status> with <locks>.\n}\n\n'
     '(Application-Start: Canal API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Canal API' +
      '  /locks:\n    get:\n      operationId: listLocks\n'},
     None),

    ('nlapp-002', 'rest',
     'A beekeeping co-op needs a hive register. GET /hives lists them '
     '(listHives), POST /hives takes a body, creates a hive, announces a '
     'HiveRegistered event and answers Created (registerHive). Write the '
     'contract and every feature set, with the server kept alive.',
     '(listHives: Apiary API) {\n'
     '    Retrieve the <hives> from the <hive-repository>.\n'
     '    Return an <OK: status> with <hives>.\n}\n\n'
     '(registerHive: Apiary API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Create the <hive> with <data>.\n'
     '    Store the <hive> into the <hive-repository>.\n'
     '    Emit a <HiveRegistered: event> with <hive>.\n'
     '    Return a <Created: status> with <hive>.\n}\n\n'
     '(Note Registration: HiveRegistered Handler) {\n'
     '    Extract the <hive> from the <event: hive>.\n'
     '    Log <hive> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n\n'
     '(Application-Start: Apiary API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Apiary API' +
      '  /hives:\n'
      '    get:\n      operationId: listHives\n'
      '    post:\n      operationId: registerHive\n'},
     None),

    ('nlapp-003', 'rest',
     'Build the kiln-firing API. GET /firings/{id} reads the id out of the '
     'path, looks the firing up in the firing repository, and returns it with '
     'an OK status; the operationId is getFiring. Contract and application, '
     'please.',
     '(getFiring: Kiln API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <firing> from the <firing-repository> where <id> is '
     '<id>.\n'
     '    Return an <OK: status> with <firing>.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Kiln API' +
      '  /firings/{id}:\n    get:\n      operationId: getFiring\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-004', 'rest',
     'Ferry berths need a booking endpoint. POST /berths/{id}/bookings pulls '
     'the berth id from the path and the passenger count from the body, '
     'refuses with a BadRequest when the count is above 400, and otherwise '
     'stores the booking and answers Created. operationId bookBerth. Give me '
     'the whole application.',
     '(bookBerth: Marina API) {\n'
     '    Extract the <berth> from the <pathParameters: id>.\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <passengers> from the <data: passengers>.\n'
     '    Throw a <BadRequest: status> for "too many passengers" '
     'when <passengers> > 400.\n'
     '    Create the <booking> with { berth: <berth>, '
     'passengers: <passengers> }.\n'
     '    Store the <booking> into the <booking-repository>.\n'
     '    Return a <Created: status> with <booking>.\n}\n\n'
     '(Application-Start: Marina API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Marina API' +
      '  /berths/{id}/bookings:\n    post:\n      operationId: bookBerth\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-005', 'rest',
     'Write the laundromat machine service: GET /machines (listMachines), and '
     'DELETE /machines/{id} which takes the machine out of the repository and '
     'answers NoContent (retireMachine). Contract plus application.',
     '(listMachines: Laundry API) {\n'
     '    Retrieve the <machines> from the <machine-repository>.\n'
     '    Return an <OK: status> with <machines>.\n}\n\n'
     '(retireMachine: Laundry API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Delete the <removed> from the <machine-repository> where <id> is '
     '<id>.\n'
     '    Return a <NoContent: status> with <removed>.\n}\n\n'
     '(Application-Start: Laundry API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Laundry API' +
      '  /machines:\n    get:\n      operationId: listMachines\n'
      '  /machines/{id}:\n    delete:\n      operationId: retireMachine\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-006', 'rest',
     'A dental practice wants appointment slots. GET /slots lists them '
     '(listSlots); PUT /slots/{id} takes a body with a holder, updates the '
     'slot and returns OK (claimSlot). Write the contract and the handlers, '
     'and keep the server running.',
     '(listSlots: Surgery API) {\n'
     '    Retrieve the <slots> from the <slot-repository>.\n'
     '    Return an <OK: status> with <slots>.\n}\n\n'
     '(claimSlot: Surgery API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <holder> from the <data: holder>.\n'
     '    Retrieve the <slot> from the <slot-repository> where <id> is '
     '<id>.\n'
     '    Update the <slot> with { holder: <holder> }.\n'
     '    Store the <slot> into the <slot-repository>.\n'
     '    Return an <OK: status> with <slot>.\n}\n\n'
     '(Application-Start: Surgery API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Surgery API' +
      '  /slots:\n    get:\n      operationId: listSlots\n'
      '  /slots/{id}:\n    put:\n      operationId: claimSlot\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-007', 'rest',
     'Seed-bank accessions, read-only: GET /accessions lists everything '
     '(listAccessions) and GET /accessions/{id} returns one, answering '
     'NotFound when the lookup comes back empty (getAccession). Remember that '
     'a Retrieve matching nothing does not fail. Whole application, please.',
     '(listAccessions: Seedbank API) {\n'
     '    Retrieve the <accessions> from the <accession-repository>.\n'
     '    Return an <OK: status> with <accessions>.\n}\n\n'
     '(getAccession: Seedbank API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <accession> from the <accession-repository> '
     'where <id> is <id>.\n'
     '    Compute the <found: length> from the <accession>.\n'
     '    Return a <NotFound: status> with <id> when <found> == 0.\n'
     '    Return an <OK: status> with <accession> when <found> > 0.\n}\n\n'
     '(Application-Start: Seedbank API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Seedbank API' +
      '  /accessions:\n    get:\n      operationId: listAccessions\n'
      '  /accessions/{id}:\n    get:\n      operationId: getAccession\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-008', 'rest',
     'Tram depot roster API. POST /shifts takes { driver, route } in the '
     'body, refuses a shift whose route is not in the depot route list with a '
     'BadRequest, otherwise stores it and answers Created. operationId '
     'createShift. Give me the contract and the application.',
     '(createShift: Depot API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <route> from the <data: route>.\n'
     '    Create the <known-routes> with ["7", "3", "11"].\n'
     '    Throw a <BadRequest: status> for "unknown route" '
     'when <route> not in <known-routes>.\n'
     '    Store the <data> into the <shift-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Application-Start: Depot API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Depot API' +
      '  /shifts:\n    post:\n      operationId: createShift\n'},
     None),

    ('nlapp-009', 'rest',
     'A lighthouse keeper logs watches. POST /watches stores the body and '
     'answers Created (logWatch); GET /watches returns the count of watches '
     'rather than the watches themselves (countWatches). Contract and '
     'application.',
     '(logWatch: Lighthouse API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <watch-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(countWatches: Lighthouse API) {\n'
     '    Retrieve the <watches> from the <watch-repository>.\n'
     '    Compute the <total: length> from the <watches>.\n'
     '    Return an <OK: status> with { watches: <total> }.\n}\n\n'
     '(Application-Start: Lighthouse API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Lighthouse API' +
      '  /watches:\n'
      '    get:\n      operationId: countWatches\n'
      '    post:\n      operationId: logWatch\n'},
     None),

    ('nlapp-010', 'rest',
     'Falconry ring registrations. POST /rings validates the body, computes a '
     'SHA-256 of the ring code as a checksum, stores the registration with '
     'that checksum and answers Created. operationId registerRing. Write the '
     'contract and the application.',
     '(registerRing: Falconry API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Validate the <checked> for the <data>.\n'
     '    Extract the <code> from the <data: code>.\n'
     '    Compute the <checksum: sha256> from <code>.\n'
     '    Create the <registration> with { code: <code>, '
     'checksum: <checksum> }.\n'
     '    Store the <registration> into the <ring-repository>.\n'
     '    Return a <Created: status> with <registration>.\n}\n\n'
     '(Application-Start: Falconry API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Falconry API' +
      '  /rings:\n    post:\n      operationId: registerRing\n'},
     None),

    ('nlapp-011', 'rest',
     'Vineyard block yields. GET /blocks/{id}/yield reads the block id from '
     'the path, totals the tonnages recorded against that block in the yield '
     'repository, and returns the total with an OK status. operationId '
     'blockYield. Contract and application.',
     '(blockYield: Vineyard API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <rows> from the <yield-repository> where <block> is '
     '<id>.\n'
     '    Map the <tonnages> from the <rows> with tonnes.\n'
     '    Compute the <total: sum> from the <tonnages>.\n'
     '    Return an <OK: status> with { block: <id>, tonnes: <total> }.\n}\n\n'
     '(Application-Start: Vineyard API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Vineyard API' +
      '  /blocks/{id}/yield:\n    get:\n      operationId: blockYield\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-012', 'rest',
     'A choir roster service where the per-singer basket of parts is private '
     'to the caller. Declare the parts repository session-scoped, then POST '
     '/parts adds a part for whoever is calling (addPart) and GET /parts '
     'lists theirs (listParts). The scope declaration belongs in the entry '
     'point. Contract and application, please.',
     '(Application-Start: Choir API) {\n'
     '    Configure the <parts-repository: scope> with "session".\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(addPart: Choir API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <parts-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(listParts: Choir API) {\n'
     '    Retrieve the <parts> from the <parts-repository>.\n'
     '    Return an <OK: status> with <parts>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Choir API' +
      '  /parts:\n'
      '    get:\n      operationId: listParts\n'
      '    post:\n      operationId: addPart\n'},
     None),

    ('nlapp-013', 'rest',
     'Glacier stake readings, with an upload that must not be read into '
     'memory. POST /readings/raw takes the body and writes it straight to '
     './incoming/readings.csv, answering Created with the file name; declare '
     'a 64 MB body limit for that route. operationId uploadReadings. Give me '
     'the contract and the application.',
     '(uploadReadings: Glacier API) {\n'
     '    Extract the <upload> from the <request: body>.\n'
     '    Write the <upload> to the <file: "./incoming/readings.csv">.\n'
     '    Return a <Created: status> with { file: "readings.csv" }.\n}\n\n'
     '(Application-Start: Glacier API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Glacier API' +
      '  /readings/raw:\n    post:\n      operationId: uploadReadings\n'
      '      x-aro-max-body: 64MB\n'},
     None),

    ('nlapp-014', 'rest',
     'Parking meters report their takings. POST /meters/{id}/takings records '
     'the amount against the meter and emits a TakingsRecorded event; a '
     'handler logs the meter id. operationId recordTakings. Whole '
     'application plus contract.',
     '(recordTakings: Meters API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <amount> from the <data: amount>.\n'
     '    Create the <takings> with { meter: <id>, amount: <amount> }.\n'
     '    Store the <takings> into the <takings-repository>.\n'
     '    Emit a <TakingsRecorded: event> with <takings>.\n'
     '    Return a <Created: status> with <takings>.\n}\n\n'
     '(Note Takings: TakingsRecorded Handler) {\n'
     '    Extract the <takings> from the <event: takings>.\n'
     '    Log <takings: meter> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n\n'
     '(Application-Start: Meters API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Meters API' +
      '  /meters/{id}/takings:\n    post:\n      operationId: recordTakings\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-015', 'rest',
     'Radio-telescope observation slots, with an outbound client that must be '
     'polite: hold the HTTP client to three in flight and ten a second in one '
     'statement. GET /slots lists slots (listSlots) and POST /slots/{id}/hold '
     'marks one held (holdSlot). Contract and application.',
     '(Application-Start: Telescope API) {\n'
     '    Configure the <http-client> with { concurrency: 3, rate: "10/s" }.\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(listSlots: Telescope API) {\n'
     '    Retrieve the <slots> from the <slot-repository>.\n'
     '    Return an <OK: status> with <slots>.\n}\n\n'
     '(holdSlot: Telescope API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <slot> from the <slot-repository> where <id> is '
     '<id>.\n'
     '    Update the <slot> with { held: true }.\n'
     '    Store the <slot> into the <slot-repository>.\n'
     '    Return an <OK: status> with <slot>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Telescope API' +
      '  /slots:\n    get:\n      operationId: listSlots\n'
      '  /slots/{id}/hold:\n    post:\n      operationId: holdSlot\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-016', 'rest',
     'Cheese-cave ageing records split across two files: put the entry point '
     'and the contract in one .aro and the two handlers in another. GET '
     '/wheels lists wheels (listWheels), POST /wheels/{id}/turns records a '
     'turn (recordTurn). Show me both .aro files and the openapi.yaml.',
     '(Application-Start: Cave API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(listWheels: Cave API) {\n'
     '    Retrieve the <wheels> from the <wheel-repository>.\n'
     '    Return an <OK: status> with <wheels>.\n}\n\n'
     '(recordTurn: Cave API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Create the <turn> with { wheel: <id> }.\n'
     '    Store the <turn> into the <turn-repository>.\n'
     '    Return a <Created: status> with <turn>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Cave API' +
      '  /wheels:\n    get:\n      operationId: listWheels\n'
      '  /wheels/{id}/turns:\n    post:\n      operationId: recordTurn\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-017', 'rest',
     'Allotment plot applications with a waiting list. POST /applications '
     'stores the application and emails the applicant by sending to their '
     'address; GET /applications/count returns how many are waiting. '
     'operationIds applyForPlot and countApplications. Contract and '
     'application.',
     '(applyForPlot: Allotment API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <application-repository>.\n'
     '    Send the <acknowledgement> to the <data: email>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(countApplications: Allotment API) {\n'
     '    Retrieve the <applications> from the <application-repository>.\n'
     '    Compute the <waiting: length> from the <applications>.\n'
     '    Return an <OK: status> with { waiting: <waiting> }.\n}\n\n'
     '(Application-Start: Allotment API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Allotment API' +
      '  /applications:\n    post:\n      operationId: applyForPlot\n'
      '  /applications/count:\n    get:\n'
      '      operationId: countApplications\n'},
     None),

    ('nlapp-018', 'rest',
     'Bell-tower peal bookings where a ringer needs permissions. POST /peals '
     'takes { method, held } in the body and only books when the required '
     'permissions — tower and method — are a subset of what the ringer holds; '
     'otherwise Forbidden. operationId bookPeal. Whole application and '
     'contract.',
     '(bookPeal: Tower API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <held> from the <data: held>.\n'
     '    Create the <needed> with ["tower", "method"].\n'
     '    Return a <Forbidden: status> with <needed> '
     'when not <needed> subset of <held>.\n'
     '    Store the <data> into the <peal-repository>.\n'
     '    Return a <Created: status> with <data> when <needed> subset of '
     '<held>.\n}\n\n'
     '(Application-Start: Tower API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Tower API' +
      '  /peals:\n    post:\n      operationId: bookPeal\n'},
     None),

    ('nlapp-019', 'rest',
     'Silage clamp intake with a grouped report. GET /intake/by-clamp groups '
     'the intake rows by clamp and returns the grouping with an OK status. '
     'operationId intakeByClamp. Contract and application, server kept alive.',
     '(intakeByClamp: Silage API) {\n'
     '    Retrieve the <rows> from the <intake-repository>.\n'
     '    Group the <by-clamp> from the <rows> by "clamp".\n'
     '    Return an <OK: status> with <by-clamp>.\n}\n\n'
     '(Application-Start: Silage API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Silage API' +
      '  /intake/by-clamp:\n    get:\n      operationId: intakeByClamp\n'},
     None),

    ('nlapp-020', 'rest',
     'Weighbridge tickets with a repository observer. POST /tickets stores a '
     'ticket (createTicket), and a separate feature set watches the ticket '
     'repository and logs every change — nothing emits an event for it. '
     'Contract and application.',
     '(createTicket: Weighbridge API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <ticket-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Audit Tickets: ticket-repository Observer) {\n'
     '    Extract the <change> from the <event: change>.\n'
     '    Log <change> to the <console>.\n'
     '    Return an <OK: status> for the <audit>.\n}\n\n'
     '(Application-Start: Weighbridge API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Weighbridge API' +
      '  /tickets:\n    post:\n      operationId: createTicket\n'},
     None),

    ('nlapp-021', 'rest',
     'A curling club ice-sheet booking service. GET /sheets lists sheets '
     '(listSheets); POST /sheets/{id}/bookings books one, but only when the '
     'requested hour is between 7 and 22 — outside that, BadRequest. '
     'operationId bookSheet. Contract and application.',
     '(listSheets: Curling API) {\n'
     '    Retrieve the <sheets> from the <sheet-repository>.\n'
     '    Return an <OK: status> with <sheets>.\n}\n\n'
     '(bookSheet: Curling API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <hour> from the <data: hour>.\n'
     '    Throw a <BadRequest: status> for "ice is off" when <hour> < 7.\n'
     '    Throw a <BadRequest: status> for "ice is off" when <hour> > 22.\n'
     '    Create the <booking> with { sheet: <id>, hour: <hour> }.\n'
     '    Store the <booking> into the <booking-repository>.\n'
     '    Return a <Created: status> with <booking>.\n}\n\n'
     '(Application-Start: Curling API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Curling API' +
      '  /sheets:\n    get:\n      operationId: listSheets\n'
      '  /sheets/{id}/bookings:\n    post:\n      operationId: bookSheet\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-022', 'rest',
     'Greenhouse vent control over HTTP. POST /houses/{id}/vent reads the '
     'house id and a temperature from the body, opens the vent above 28 '
     'degrees and shuts it at or below, and returns which it did. operationId '
     'setVent. Give me the contract and the application.',
     '(setVent: Greenhouse API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <house-temp> from the <data: temperature>.\n'
     '    Create the <opened> with { house: <id>, vent: "open" }.\n'
     '    Create the <shut> with { house: <id>, vent: "shut" }.\n'
     '    Return an <OK: status> with <opened> when <house-temp> > 28.\n'
     '    Return an <OK: status> with <shut> when <house-temp> <= 28.\n}\n\n'
     '(Application-Start: Greenhouse API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Greenhouse API' +
      '  /houses/{id}/vent:\n    post:\n      operationId: setVent\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-023', 'rest',
     'Wind-turbine billing. GET /turbines/{id}/invoice totals the kilowatt '
     'hours recorded for that turbine, multiplies by 0.27, rounds the figure '
     'to two decimals the way money needs, and returns it. operationId '
     'turbineInvoice. Contract and application.',
     '(turbineInvoice: Turbine API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <rows> from the <reading-repository> where <turbine> is '
     '<id>.\n'
     '    Map the <units> from the <rows> with kwh.\n'
     '    Compute the <total: sum> from the <units>.\n'
     '    Compute the <raw> from <total> * 0.27.\n'
     '    Compute the <due: fixed> from <raw>.\n'
     '    Return an <OK: status> with { turbine: <id>, due: <due> }.\n}\n\n'
     '(Application-Start: Turbine API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Turbine API' +
      '  /turbines/{id}/invoice:\n    get:\n'
      '      operationId: turbineInvoice\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-024', 'rest',
     'A tide-table service that answers from a seeded store rather than an '
     'empty repository. GET /tides lists the tide rows (listTides); ship a '
     'tides.store seeding two rows. Contract, store file and application.',
     '(listTides: Tide API) {\n'
     '    Retrieve the <tides> from the <tides-repository>.\n'
     '    Return an <OK: status> with <tides>.\n}\n\n'
     '(Application-Start: Tide API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Tide API' +
      '  /tides:\n    get:\n      operationId: listTides\n',
      'tides.store': '- id: 1\n  port: dover\n  high: "06:12"\n'
                     '- id: 2\n  port: calais\n  high: "07:40"\n'},
     None),

    ('nlapp-025', 'rest',
     'Kiln firings again, but with the arithmetic in a reusable action: a '
     'user-defined action FiringCost that takes hours and returns hours times '
     '4.25, and a GET /firings/{id}/cost handler that calls it. operationId '
     'firingCost. Contract and application.',
     '(FiringCost: Action takes <hours>) {\n'
     '    Extract the <h> from the <input: hours>.\n'
     '    Compute the <cost> from <h> * 4.25.\n'
     '    Return an <OK: status> with { cost: <cost> }.\n}\n\n'
     '(firingCost: Kiln API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <firing> from the <firing-repository> where <id> is '
     '<id>.\n'
     '    Application.FiringCost the <out> from <firing: hours>.\n'
     '    Extract the <cost> from the <out: cost>.\n'
     '    Return an <OK: status> with { firing: <id>, cost: <cost> }.\n}\n\n'
     '(Application-Start: Kiln API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Kiln API' +
      '  /firings/{id}/cost:\n    get:\n      operationId: firingCost\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-026', 'rest',
     'Canal mooring permits where the permit number is read from a query '
     'parameter rather than the path. GET /permits looks up a permit by the '
     '`number` query parameter and returns it, or NotFound when nothing '
     'matches. operationId findPermit. Contract and application.',
     '(findPermit: Permit API) {\n'
     '    Extract the <number> from the <queryParameters: number>.\n'
     '    Retrieve the <permit> from the <permit-repository> where <number> is '
     '<number>.\n'
     '    Compute the <found: length> from the <permit>.\n'
     '    Return a <NotFound: status> with <number> when <found> == 0.\n'
     '    Return an <OK: status> with <permit> when <found> > 0.\n}\n\n'
     '(Application-Start: Permit API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Permit API' +
      '  /permits:\n    get:\n      operationId: findPermit\n'
      '      parameters:\n        - name: number\n          in: query\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-027', 'rest',
     'A shutdown-aware depot service: the usual listRoutes endpoint, plus '
     'both Application-End handlers — Success logs that it is stopping and '
     'stops the HTTP server, Error logs whatever the shutdown error was. '
     'Contract and every feature set.',
     '(listRoutes: Depot API) {\n'
     '    Retrieve the <routes> from the <route-repository>.\n'
     '    Return an <OK: status> with <routes>.\n}\n\n'
     '(Application-Start: Depot API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Application-End: Success) {\n'
     '    Log "depot closing" to the <console>.\n'
     '    Stop the <http-server> with <application>.\n'
     '    Return an <OK: status> for the <shutdown>.\n}\n\n'
     '(Application-End: Error) {\n'
     '    Extract the <error> from the <shutdown: error>.\n'
     '    Log <error> to the <console>.\n'
     '    Return an <OK: status> for the <error-handling>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Depot API' +
      '  /routes:\n    get:\n      operationId: listRoutes\n'},
     None),

    ('nlapp-028', 'rest',
     'Dental recall letters rendered from a template. POST /recalls stores '
     'the recall and writes a letter to ./out/recall.txt containing the '
     "patient's name, then answers Created. operationId createRecall. "
     'Contract and application.',
     '(createRecall: Recall API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Extract the <name> from the <data: name>.\n'
     '    Store the <data> into the <recall-repository>.\n'
     '    Write <name> to the <file: "./out/recall.txt">.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Application-Start: Recall API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Recall API' +
      '  /recalls:\n    post:\n      operationId: createRecall\n'},
     None),

    ('nlapp-029', 'rest',
     'A seed-bank service that publishes its page size once and reads it back '
     'in a second feature set with the same business activity. GET '
     '/accessions returns at most that many rows. operationId '
     'listAccessions; the publishing feature set is the entry point. Contract '
     'and application.',
     '(Application-Start: Seedbank API) {\n'
     '    Create the <limit> with 25.\n'
     '    Publish as <page-size> <limit>.\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(listAccessions: Seedbank API) {\n'
     '    Require the <page-size> from the <Seedbank>.\n'
     '    Retrieve the <accessions> from the <accession-repository>.\n'
     '    Return an <OK: status> with { page: <page-size>, '
     'rows: <accessions> }.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Seedbank API' +
      '  /accessions:\n    get:\n      operationId: listAccessions\n'},
     None),

    ('nlapp-030', 'rest',
     'Tram shift swaps as a state machine. POST /swaps/{id}/accept moves the '
     'swap from requested to accepted using the Accept action and returns the '
     'new state. operationId acceptSwap. Contract and application.',
     '(acceptSwap: Swap API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <swap> from the <swap-repository> where <id> is <id>.\n'
     '    Accept the <accepted> on the <swap> with "accepted".\n'
     '    Return an <OK: status> with <accepted>.\n}\n\n'
     '(Application-Start: Swap API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Swap API' +
      '  /swaps/{id}/accept:\n    post:\n      operationId: acceptSwap\n'
      '      parameters:\n        - name: id\n          in: path\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-031', 'rest',
     'Laundromat cycle events over WebSocket as well as HTTP: GET /cycles '
     'lists cycles, and a Socket Event Handler logs anything arriving on the '
     'socket. Start both the HTTP server and the socket server in the entry '
     'point. operationId listCycles. Contract and application.',
     '(listCycles: Laundry API) {\n'
     '    Retrieve the <cycles> from the <cycle-repository>.\n'
     '    Return an <OK: status> with <cycles>.\n}\n\n'
     '(Note Socket Traffic: Socket Event Handler) {\n'
     '    Extract the <message> from the <event: message>.\n'
     '    Log <message> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n\n'
     '(Application-Start: Laundry API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Start the <socket-server> with { port: 9100 }.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Laundry API' +
      '  /cycles:\n    get:\n      operationId: listCycles\n'},
     None),

    ('nlapp-032', 'rest',
     'Falconry weigh-ins with a 7-day window. GET /weighins returns the '
     'weigh-in rows whose bird matches the `bird` query parameter, with the '
     'count alongside them. operationId listWeighins. Contract and '
     'application.',
     '(listWeighins: Falconry API) {\n'
     '    Extract the <bird> from the <queryParameters: bird>.\n'
     '    Retrieve the <rows> from the <weighin-repository> where <bird> is '
     '<bird>.\n'
     '    Compute the <total: length> from the <rows>.\n'
     '    Return an <OK: status> with { bird: <bird>, count: <total>, '
     'rows: <rows> }.\n}\n\n'
     '(Application-Start: Falconry API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Falconry API' +
      '  /weighins:\n    get:\n      operationId: listWeighins\n'
      '      parameters:\n        - name: bird\n          in: query\n'
      '          required: true\n          schema:\n            type: string\n'},
     None),

    ('nlapp-033', 'rest',
     'A lock-keeper rota service whose per-connection draft rota is private '
     'to the TCP peer. Declare the draft repository connection-scoped in the '
     'entry point, start the socket server, and handle socket events by '
     'storing the message into that repository. Also serve GET /rota over '
     'HTTP (listRota). Contract and application.',
     '(Application-Start: Rota API) {\n'
     '    Configure the <draft-repository: scope> with "connection".\n'
     '    Start the <http-server> with <contract>.\n'
     '    Start the <socket-server> with { port: 9200 }.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Collect Draft: Socket Event Handler) {\n'
     '    Extract the <message> from the <event: message>.\n'
     '    Store the <message> into the <draft-repository>.\n'
     '    Return an <OK: status> for the <collection>.\n}\n\n'
     '(listRota: Rota API) {\n'
     '    Retrieve the <rota> from the <rota-repository>.\n'
     '    Return an <OK: status> with <rota>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Rota API' +
      '  /rota:\n    get:\n      operationId: listRota\n'},
     None),

    ('nlapp-034', 'rest',
     'Cheese wheels with a tiny audit trail: POST /wheels creates a wheel and '
     'emits WheelCreated; two separate handlers react to that one event, one '
     'logging it and one storing an audit row. operationId createWheel. '
     'Contract and application.',
     '(createWheel: Cave API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <wheel-repository>.\n'
     '    Emit a <WheelCreated: event> with <data>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Log Wheel: WheelCreated Handler) {\n'
     '    Extract the <wheel> from the <event: data>.\n'
     '    Log <wheel> to the <console>.\n'
     '    Return an <OK: status> for the <logging>.\n}\n\n'
     '(Audit Wheel: WheelCreated Handler) {\n'
     '    Extract the <wheel> from the <event: data>.\n'
     '    Store the <wheel> into the <audit-repository>.\n'
     '    Return an <OK: status> for the <audit>.\n}\n\n'
     '(Application-Start: Cave API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Cave API' +
      '  /wheels:\n    post:\n      operationId: createWheel\n'},
     None),

    ('nlapp-035', 'rest',
     'A glacier monitoring service with a bounded outbound client: hold the '
     'HTTP client to two requests in flight, serve GET /stakes (listStakes), '
     'and watch ./incoming for new files with a File Event Handler that logs '
     'each path. Contract and application.',
     '(Application-Start: Glacier API) {\n'
     '    Configure the <http-client> with { concurrency: 2 }.\n'
     '    Start the <http-server> with <contract>.\n'
     '    Start the <file-monitor> with "./incoming".\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(listStakes: Glacier API) {\n'
     '    Retrieve the <stakes> from the <stake-repository>.\n'
     '    Return an <OK: status> with <stakes>.\n}\n\n'
     '(Note Arrival: File Event Handler) {\n'
     '    Extract the <path> from the <event: path>.\n'
     '    Log <path> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Glacier API' +
      '  /stakes:\n    get:\n      operationId: listStakes\n'},
     None),

    ('nlapp-036', 'rest',
     'Vineyard harvest intake where the row is validated before it is kept. '
     'POST /intake validates the body, throws UnprocessableEntity when the '
     'tonnage is zero or less, otherwise stores and answers Created. '
     'operationId recordIntake. Contract and application.',
     '(recordIntake: Harvest API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Validate the <checked> for the <data>.\n'
     '    Extract the <tonnes> from the <data: tonnes>.\n'
     '    Throw an <UnprocessableEntity: status> for "no tonnage" '
     'when <tonnes> <= 0.\n'
     '    Store the <data> into the <intake-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(Application-Start: Harvest API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Harvest API' +
      '  /intake:\n    post:\n      operationId: recordIntake\n'},
     None),

    ('nlapp-037', 'rest',
     'Choir attendance with an environment-driven setting: read the venue '
     'name from CHOIR_VENUE, falling back to "parish hall", and include it in '
     'every GET /attendance response. operationId listAttendance. Contract '
     'and application.',
     '(listAttendance: Choir API) {\n'
     '    Extract the <venue> from the <env: CHOIR_VENUE> '
     'default "parish hall".\n'
     '    Retrieve the <rows> from the <attendance-repository>.\n'
     '    Return an <OK: status> with { venue: <venue>, rows: <rows> }.\n}\n\n'
     '(Application-Start: Choir API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Choir API' +
      '  /attendance:\n    get:\n      operationId: listAttendance\n'},
     None),

    ('nlapp-038', 'rest',
     'A marina berth service with a 256 KB cap declared on its one POST '
     'route in the contract. POST /berths stores the body and answers Created '
     '(createBerth); GET /berths lists them (listBerths). Contract and '
     'application.',
     '(Application-Start: Marina API) {\n'
     '    Start the <http-server> with <contract>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(createBerth: Marina API) {\n'
     '    Extract the <data> from the <request: body>.\n'
     '    Store the <data> into the <berth-repository>.\n'
     '    Return a <Created: status> with <data>.\n}\n\n'
     '(listBerths: Marina API) {\n'
     '    Retrieve the <berths> from the <berth-repository>.\n'
     '    Return an <OK: status> with <berths>.\n}\n',
     {'openapi.yaml': CONTRACT_HEAD % 'Marina API' +
      '  /berths:\n'
      '    get:\n      operationId: listBerths\n'
      '    post:\n      operationId: createBerth\n'
      '      x-aro-max-body: 256KB\n'},
     None),

    # ── complete runnable applications ───────────────────────────────────────
    ('nlapp-039', 'batch',
     'Write a complete ARO application that prints the total weight of three '
     'hives — 14, 22 and 19 kilos — and nothing else.',
     '(Application-Start: Apiary Total) {\n'
     '    Create the <weights> with [14, 22, 19].\n'
     '    Compute the <total: sum> from the <weights>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '55'),

    ('nlapp-040', 'batch',
     'A complete application that writes three kiln codes, one per line, into '
     './firings.txt, reads the file back and prints how many lines it found.',
     '(Application-Start: Kiln Log) {\n'
     '    Write "bisque-01\\nglaze-02\\nbisque-03" to the '
     '<file: "./firings.txt">.\n'
     '    Read the <content> from the <file: "./firings.txt">.\n'
     '    Compute the <rows: lines> from <content>.\n'
     '    Compute the <total: length> from the <rows>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '3'),

    ('nlapp-041', 'conditionals',
     'A complete application that decides a ferry sailing: with a tide of 1.2 '
     'metres and a minimum of 1.5, it should print exactly "ferry cancelled".',
     '(Application-Start: Ferry Decision) {\n'
     '    Create the <tide> with 1.2.\n'
     '    Create the <minimum> with 1.5.\n'
     '    Log "ferry cancelled" to the <console> when <tide> < <minimum>.\n'
     '    Log "ferry sails" to the <console> when <tide> >= <minimum>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'ferry cancelled'),

    ('nlapp-042', 'batch',
     'A complete application that stores three parking-meter readings in a '
     'repository, reads them back and prints the number of rows.',
     '(Application-Start: Meter Load) {\n'
     '    Create the <first> with { id: 1, amount: 240 }.\n'
     '    Create the <second> with { id: 2, amount: 115 }.\n'
     '    Create the <third> with { id: 3, amount: 90 }.\n'
     '    Store the <first> into the <takings-repository>.\n'
     '    Store the <second> into the <takings-repository>.\n'
     '    Store the <third> into the <takings-repository>.\n'
     '    Retrieve the <rows> from the <takings-repository>.\n'
     '    Compute the <total: length> from the <rows>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '3'),

    ('nlapp-043', 'events',
     'A complete application in which the entry point emits a BaleWeighed '
     'event carrying a bale number of 814, and a handler prints that number.',
     '(Application-Start: Bale Weigher) {\n'
     '    Create the <weighing> with { bale: 814 }.\n'
     '    Emit a <BaleWeighed: event> with <weighing>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n\n'
     '(Note Bale: BaleWeighed Handler) {\n'
     '    Extract the <body> from the <event: weighing>.\n'
     '    Log <body: bale> to the <console>.\n'
     '    Return an <OK: status> for the <note>.\n}\n',
     None, '814'),

    ('nlapp-044', 'batch',
     'A complete application that reads a CSV row "oslo,9,north" from a file '
     'it writes first, splits it on commas, and prints the middle field.',
     '(Application-Start: Row Reader) {\n'
     '    Write "oslo,9,north" to the <file: "./row.csv">.\n'
     '    Read the <content> from the <file: "./row.csv">.\n'
     '    Split the <fields> from the <content> by ",".\n'
     '    Extract the <middle: 1> from the <fields>.\n'
     '    Log <middle> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '9'),

    ('nlapp-045', 'batch',
     'A complete application that walks the three tram routes 7, 3 and 11 and '
     'prints each one on its own line, in that order.',
     '(Application-Start: Route Walk) {\n'
     '    Create the <routes> with ["7", "3", "11"].\n'
     '    for each <route> in <routes> {\n'
     '        Log <route> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '7\n3\n11'),

    ('nlapp-046', 'batch',
     'A regions.store file with two rows is already sitting beside the '
     'application. Write the complete application that reads the regions '
     'repository it seeds and prints how many rows came back.',
     '(Application-Start: Region Load) {\n'
     '    Retrieve the <regions> from the <regions-repository>.\n'
     '    Compute the <total: length> from the <regions>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     {'regions.store': '- id: 1\n  name: north\n- id: 2\n  name: south\n'},
     '2'),

    ('nlapp-047', 'throw',
     'A complete application that refuses to run: with an age of 15 and a '
     'minimum of 18 it must throw a BadRequest rather than print the '
     'admission line.',
     '(Application-Start: Gatehouse) {\n'
     '    Create the <age> with 15.\n'
     '    Create the <minimum> with 18.\n'
     '    Throw a <BadRequest: status> for "under age" '
     'when <age> < <minimum>.\n'
     '    Log "admitted" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, None),

    ('nlapp-048', 'batch',
     'A complete application with a user-defined action HalveWeight that '
     'takes a weight and returns half of it, called once from the entry point '
     'with 50 and printed.',
     '(HalveWeight: Action takes <weight>) {\n'
     '    Extract the <w> from the <input: weight>.\n'
     '    Compute the <half> from <w> / 2.\n'
     '    Return an <OK: status> with { half: <half> }.\n}\n\n'
     '(Application-Start: Halver) {\n'
     '    Application.HalveWeight the <out> from 50.\n'
     '    Extract the <half> from the <out: half>.\n'
     '    Log <half> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '25'),

    ('nlapp-049', 'batch',
     'A complete application that takes a site name as a positional '
     'command-line argument, defaulting to "orkney" when it is not given, and '
     'prints it.',
     '(Application-Start: Siting takes <site>) {\n'
     '    Extract the <name> from the <parameter: site> default "orkney".\n'
     '    Log <name> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'orkney'),

    ('nlapp-050', 'batch',
     'A complete application that filters three allotment plots — 12 beds, 3 '
     'beds, 18 beds — down to those with more than 10 beds, and prints how '
     'many survived.',
     '(Application-Start: Plot Filter) {\n'
     '    Create the <plots> with [{ plot: 4, beds: 12 }, '
     '{ plot: 9, beds: 3 }, { plot: 11, beds: 18 }].\n'
     '    Filter the <large> from the <plots> where <beds> > 10.\n'
     '    Compute the <total: length> from the <large>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '2'),

    ('nlapp-051', 'batch',
     'A complete application that groups four silage intake rows by clamp — '
     'north, south, north, east — and prints the number of distinct clamps.',
     '(Application-Start: Clamp Grouping) {\n'
     '    Create the <rows> with [{ clamp: "north", t: 20 }, '
     '{ clamp: "south", t: 14 }, { clamp: "north", t: 6 }, '
     '{ clamp: "east", t: 3 }].\n'
     '    Group the <by-clamp> from the <rows> by "clamp".\n'
     '    Compute the <total: length> from the <by-clamp>.\n'
     '    Log <total> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '3'),

    ('nlapp-052', 'publish',
     'A complete application whose entry point fixes a roster size of 18, '
     'publishes it under the name roster-size, and prints the published value '
     'back.',
     '(Application-Start: Roster) {\n'
     '    Create the <size> with 18.\n'
     '    Publish as <roster-size> <size>.\n'
     '    Log <roster-size> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '18'),

    ('nlapp-053', 'configuration',
     'A complete application that bounds itself to four concurrent units of '
     'work and caps the outbound HTTP client at two in flight and five a '
     'second, then prints "limits applied".',
     '(Application-Start: Bounded) {\n'
     '    Configure the <application: concurrency> with 4.\n'
     '    Configure the <http-client> with { concurrency: 2, rate: "5/s" }.\n'
     '    Log "limits applied" to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'limits applied'),

    ('nlapp-054', 'batch',
     'A complete application that parses "turbine=hub-14" with a named-group '
     'regex and prints the hub identifier on its own.',
     '(Application-Start: Hub Parser) {\n'
     '    Create the <line> with "turbine=hub-14".\n'
     '    Compute the <parts: captures> from <line> '
     'by /(?<key>[a-z]+)=(?<value>.+)/.\n'
     '    Log <parts: value> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, 'hub-14'),

    ('nlapp-055', 'batch',
     'A complete application that works out a lighthouse watch bill: 11 hours '
     'at 4.25 an hour, rounded the way money is, printed on its own.',
     '(Application-Start: Watch Bill) {\n'
     '    Create the <hours> with 11.\n'
     '    Compute the <raw> from <hours> * 4.25.\n'
     '    Compute the <due: fixed> from <raw>.\n'
     '    Log <due> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n}\n',
     None, '46.75'),
]

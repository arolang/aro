// ============================================================
// SolaroThemeTests.swift
// SOLARO — user-editable themes (GitLab #269)
// ============================================================
//
// The interesting cases here are the broken ones. A theme file is
// hand-typed JSON, so the question that decides whether the feature is
// usable is not "does a correct file work" but "what does a wrong file
// do" — and the answer has to be the same in every case: the palette
// is complete, the app is legible, and the user is told what is wrong.
//
// So: a full theme, a partial theme, a file that is not JSON, a file
// that is JSON but not a theme, a key that does not exist, a value
// that is not a colour, a hex string of the wrong shape, and a
// selected theme whose file has been deleted.

import Testing
import Foundation
import SwiftUI
@testable import SOLARO

// MARK: - Hex

@Suite("Theme colour parsing")
struct SolaroHexTests {

    @Test func readsEveryAcceptedDigitCount() throws {
        #expect(try SolaroRGBA.parse(hex: "#FFFFFF") == SolaroRGBA(1, 1, 1, 1))
        #expect(try SolaroRGBA.parse(hex: "#000000") == SolaroRGBA(0, 0, 0, 1))
        #expect(try SolaroRGBA.parse(hex: "#FFF") == SolaroRGBA(1, 1, 1, 1))
        // Eight digits carry alpha; 0x80 is 128/255, not 0.5 exactly.
        let half = try SolaroRGBA.parse(hex: "#00000080")
        #expect(abs(half.alpha - 128.0 / 255.0) < 1e-9)
        let short = try SolaroRGBA.parse(hex: "#0008")
        #expect(abs(short.alpha - 8.0 / 15.0) < 1e-9)
    }

    @Test func toleratesThePunctuationPeopleActuallyType() throws {
        let canonical = try SolaroRGBA.parse(hex: "#2E3440")
        #expect(try SolaroRGBA.parse(hex: "2e3440") == canonical)
        #expect(try SolaroRGBA.parse(hex: "  #2E3440  ") == canonical)
        #expect(try SolaroRGBA.parse(hex: "0x2E3440") == canonical)
    }

    /// There is no out-of-range *value* to reject — every hex pair is
    /// a byte. What goes wrong is the shape, and each shape error has
    /// to name itself, because "invalid colour" is not something a
    /// user can act on.
    @Test func rejectsEveryShapeThatIsNotAColour() {
        #expect(throws: SolaroHexError.empty) {
            try SolaroRGBA.parse(hex: "#")
        }
        #expect(throws: SolaroHexError.digitCount(5)) {
            try SolaroRGBA.parse(hex: "#12345")
        }
        #expect(throws: SolaroHexError.digitCount(9)) {
            try SolaroRGBA.parse(hex: "#123456789")
        }
        #expect(throws: SolaroHexError.notHexadecimal("#GGHHII")) {
            try SolaroRGBA.parse(hex: "#GGHHII")
        }
        #expect(throws: SolaroHexError.notHexadecimal("rgb(300, 0, 0)")) {
            try SolaroRGBA.parse(hex: "rgb(300, 0, 0)")
        }
    }

    @Test func hexStringOmitsAlphaOnlyWhenOpaque() {
        #expect(SolaroRGBA(1, 1, 1, 1).hexString == "#FFFFFF")
        #expect(SolaroRGBA(0, 0, 0, 0.5).hexString == "#00000080")
    }
}

// MARK: - The file format

@Suite("Theme file")
struct SolaroThemeFileTests {

    /// Every token must have a built-in value, because
    /// `SolaroThemeTokens.color(_:)` promises a colour for each and the
    /// merge-over-defaults guarantee rests on it. A token added to the
    /// enum without a default fails here rather than rendering grey.
    @Test func builtInCoversEveryToken() {
        let built = SolaroThemeTokens.builtIn
        #expect(built.statedTokens == Set(SolaroColorToken.allCases))
    }

    @Test func readsAFullyStatedTheme() throws {
        let json = Self.themeJSON(
            name: "All Red",
            colors: SolaroColorToken.allCases.map { ($0.rawValue, "\"#FF0000\"") })
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(theme.name == "All Red")
        #expect(theme.colors.count == SolaroColorToken.allCases.count)
        let merged = SolaroThemeTokens.builtIn.overriding(theme.colors)
        #expect(merged.color(.backdrop).dark == SolaroRGBA(1, 0, 0, 1))
        #expect(merged.color(.syntaxLiteral).light == SolaroRGBA(1, 0, 0, 1))
    }

    /// The central promise: what a theme does not say stays SOLARO's.
    @Test func aPartialThemeOverridesOnlyWhatItNames() throws {
        let json = Self.themeJSON(name: "Two Keys", colors: [
            ("backdrop", "\"#101010\""),
            ("accent", "\"#00FF00\""),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(theme.colors.count == 2)

        let merged = SolaroThemeTokens.builtIn.overriding(theme.colors)
        #expect(merged.color(.accent).light == SolaroRGBA(0, 1, 0, 1))
        // Untouched tokens are identical to the shipping palette —
        // not approximately, identically.
        for token in SolaroColorToken.allCases
        where token != .backdrop && token != .accent {
            #expect(merged.color(token) == SolaroThemeTokens.builtIn.color(token))
        }
    }

    @Test func aTokenMayGiveOneColourPerAppearance() throws {
        let json = Self.themeJSON(name: "Both", colors: [
            ("textPrimary", "{ \"light\": \"#111111\", \"dark\": \"#EEEEEE\" }"),
        ])
        let (theme, _) = try SolaroThemeFile.parse(Data(json.utf8))
        let color = try #require(theme.colors[.textPrimary])
        #expect(color.light == SolaroRGBA(17.0 / 255, 17.0 / 255, 17.0 / 255, 1))
        #expect(color.resolved(dark: true).red > 0.9)
        #expect(color.resolved(dark: false).red < 0.1)
    }

    /// A single hex string applies to both appearances — which is what
    /// a palette like Dracula wants, since it only exists in one.
    @Test func aBareHexStringAppliesToBothAppearances() throws {
        let json = Self.themeJSON(name: "Flat", colors: [("surface", "\"#282A36\"")])
        let (theme, _) = try SolaroThemeFile.parse(Data(json.utf8))
        let color = try #require(theme.colors[.surface])
        #expect(color.light == color.dark)
    }

    /// Half an appearance pair is legal: the other half stays SOLARO's,
    /// so someone retouching only dark mode writes only dark mode.
    @Test func aOneSidedPairKeepsTheBuiltInOtherSide() throws {
        let json = Self.themeJSON(name: "Dark only", colors: [
            ("backdrop", "{ \"dark\": \"#000000\" }"),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        let color = try #require(theme.colors[.backdrop])
        #expect(color.dark == SolaroRGBA(0, 0, 0, 1))
        #expect(color.light == SolaroThemeTokens.builtIn.color(.backdrop).light)
    }

    @Test func declaresTheAppearanceItBelongsTo() throws {
        let json = """
        { "name": "D", "appearance": "dark", "colors": { "accent": "#FFFFFF" } }
        """
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(theme.appearance == .dark)
    }

    @Test func anAppearanceItDoesNotRecogniseIsReportedNotGuessed() throws {
        let json = """
        { "appearance": "sepia", "colors": { "accent": "#FFFFFF" } }
        """
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(theme.appearance == nil)
        #expect(issues.contains { $0.key == "appearance" })
        // The colour it did get right is still applied.
        #expect(theme.colors[.accent] != nil)
    }

    /// People copy palettes out of blog posts as a flat object. Taking
    /// one is a one-line concession that saves a support question.
    @Test func acceptsColoursAtTheTopLevelWithNoWrapper() throws {
        let json = """
        { "name": "Flat file", "backdrop": "#101010", "accent": "#00FF00" }
        """
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(theme.name == "Flat file")
        #expect(theme.colors.count == 2)
    }

    @Test func matchesKeysTheWayPeopleWriteThem() throws {
        let json = Self.themeJSON(name: "Spellings", colors: [
            ("surface-raised", "\"#111111\""),
            ("text_primary", "\"#222222\""),
            ("StateOK", "\"#333333\""),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(issues.isEmpty)
        #expect(theme.colors[.surfaceRaised] != nil)
        #expect(theme.colors[.textPrimary] != nil)
        #expect(theme.colors[.stateOK] != nil)
    }

    // MARK: Failure modes

    @Test func aKeyThatIsNotAColourCostsThatKeyAndNothingElse() throws {
        let json = Self.themeJSON(name: "Typo", colors: [
            ("backgrop", "\"#101010\""),
            ("accent", "\"#00FF00\""),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(theme.colors[.accent] != nil)
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.key == "backgrop")
        #expect(issue.detail.contains("not a theme colour"))
    }

    @Test func anUnparseableColourCostsThatTokenAndNothingElse() throws {
        let json = Self.themeJSON(name: "Bad hex", colors: [
            ("backdrop", "\"#12345\""),
            ("accent", "\"#00FF00\""),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(theme.colors[.backdrop] == nil)
        #expect(theme.colors[.accent] != nil)
        #expect(issues.count == 1)
        #expect(try #require(issues.first).key == "backdrop")
        // And the merge then leaves the backdrop exactly as it shipped
        // — the file is wrong, the window is not.
        let merged = SolaroThemeTokens.builtIn.overriding(theme.colors)
        #expect(merged.color(.backdrop) == SolaroThemeTokens.builtIn.color(.backdrop))
    }

    @Test func aValueThatIsNotAColourAtAllIsReported() throws {
        let json = """
        { "colors": { "accent": 255, "backdrop": true, "surface": "#101010" } }
        """
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(theme.colors.count == 1)
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.detail.contains("hex string") })
    }

    @Test func halfAPairStillNamesWhichHalfIsWrong() throws {
        let json = Self.themeJSON(name: "Half bad", colors: [
            ("backdrop", "{ \"light\": \"#FFFFFF\", \"dark\": \"nope\" }"),
        ])
        let (theme, issues) = try SolaroThemeFile.parse(Data(json.utf8))
        #expect(theme.colors.isEmpty)
        #expect(issues.contains { $0.key == "backdrop.dark" })
    }

    /// Only bytes that are not a JSON object are fatal, because then
    /// there is genuinely nothing to apply.
    @Test func bytesThatAreNotJSONAreTheOnlyFatalCase() {
        #expect(throws: SolaroThemeFile.ParseError.self) {
            try SolaroThemeFile.parse(Data("{ \"colors\": ".utf8))
        }
        #expect(throws: SolaroThemeFile.ParseError.self) {
            try SolaroThemeFile.parse(Data("# not json at all".utf8))
        }
        #expect(throws: SolaroThemeFile.ParseError.self) {
            try SolaroThemeFile.parse(Data("[\"#FFFFFF\"]".utf8))
        }
        #expect(throws: SolaroThemeFile.ParseError.self) {
            try SolaroThemeFile.parse(Data())
        }
    }

    /// A file that parses but names no colour is a mistake worth a
    /// sentence: without one, selecting it looks like the app ignored
    /// the click.
    @Test func aThemeWithNoRecognisedColoursSaysSo() throws {
        let (theme, issues) = try SolaroThemeFile.parse(
            Data("{ \"name\": \"Empty\" }".utf8))
        #expect(theme.colors.isEmpty)
        #expect(issues.contains { $0.detail.contains("no recognised colour keys") })
    }

    // MARK: Shipped content

    /// The presets are compiled-in JSON and go through this same
    /// parser, so a typo in one is a test failure rather than a
    /// mystery colour in a release.
    @Test func everyCuratedPresetParsesCleanlyAndStatesEveryToken() throws {
        for preset in SolaroThemeCatalog.presets {
            let (theme, issues) = try SolaroThemeFile.parse(Data(preset.json.utf8))
            #expect(issues.isEmpty, "\(preset.id): \(issues.map(\.description))")
            #expect(theme.name?.isEmpty == false, "\(preset.id) has no name")
            #expect(theme.appearance != nil, "\(preset.id) declares no appearance")
            let missing = Set(SolaroColorToken.allCases)
                .subtracting(theme.colors.keys)
            #expect(Set(theme.colors.keys) == Set(SolaroColorToken.allCases),
                    "\(preset.id) is missing \(missing)")
        }
    }

    /// The worked example written into the user's folder has to be a
    /// legal theme, or the first thing anybody edits is already broken.
    @Test func theWorkedExampleIsALegalThemeEqualToTheBuiltIn() throws {
        let (theme, issues) = try SolaroThemeFile.parse(
            Data(SolaroThemeTokens.exampleJSON().utf8))
        #expect(issues.isEmpty)
        #expect(Set(theme.colors.keys) == Set(SolaroColorToken.allCases))
        // Hex is 8-bit, so the example round-trips to within a byte of
        // the full-precision built-ins rather than exactly.
        for token in SolaroColorToken.allCases {
            let stated = try #require(theme.colors[token])
            let built = SolaroThemeTokens.builtIn.color(token)
            #expect(abs(stated.light.red - built.light.red) <= 1.0 / 255)
            #expect(abs(stated.dark.blue - built.dark.blue) <= 1.0 / 255)
            #expect(abs(stated.dark.alpha - built.dark.alpha) <= 1.0 / 255)
        }
    }

    private static func themeJSON(name: String,
                                  colors: [(String, String)]) -> String {
        let body = colors.map { "    \"\($0.0)\": \($0.1)" }
            .joined(separator: ",\n")
        return "{\n  \"name\": \"\(name)\",\n  \"colors\": {\n\(body)\n  }\n}"
    }
}

// MARK: - The live palette

@Suite("Theme palette")
@MainActor
struct SolaroPaletteTests {

    /// `SyntaxHighlighter` asks "did this verb have a role?" by
    /// comparing the answer to `textSecondary`, so a token has to be
    /// equal to itself across reads and two tokens have to differ even
    /// when they carry the same value — `wireVia` and `wireFrom` do.
    @Test func aTokenIsEqualToItselfAndDistinctFromOthers() {
        let palette = SolaroPalette()
        #expect(palette.color(.textSecondary) == palette.color(.textSecondary))
        #expect(palette.color(.wireFrom) != palette.color(.wireTo))
        #expect(palette.color(.wireVia) != palette.color(.wireFrom))
    }

    @Test func installingATheneBumpsTheGenerationViewsObserve() {
        let palette = SolaroPalette()
        let before = palette.generation
        palette.install(SolaroThemeTokens.builtIn.overriding(
            [.accent: SolaroThemeColor(SolaroRGBA(1, 0, 0))]))
        #expect(palette.generation == before + 1)
        #expect(palette.current.color(.accent) == SolaroThemeColor(SolaroRGBA(1, 0, 0)))
    }

    /// A filesystem event that rewrote a theme without changing a
    /// colour must not repaint the app.
    @Test func reinstallingTheSamePaletteIsANoOp() {
        let palette = SolaroPalette()
        palette.install(.builtIn)
        #expect(palette.generation == 0)
    }
}

// MARK: - Discovery, selection and failure

@Suite("Theme discovery", .serialized)
@MainActor
struct SolaroThemeStoreTests {

    /// A store over a temporary folder and its own defaults and
    /// palette, so nothing here can reach the running user's themes,
    /// preferences or colours.
    private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let palette = SolaroPalette()
        private let suiteName: String

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("solaro.themes.\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            suiteName = "solaro.tests.themes.\(UUID().uuidString)"
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        @discardableResult
        func write(_ name: String, _ contents: String) -> URL {
            let url = directory.appendingPathComponent(name)
            try? Data(contents.utf8).write(to: url, options: [.atomic])
            return url
        }

        @MainActor
        func store(watching: Bool = false) -> SolaroThemeStore {
            SolaroThemeStore(directory: directory,
                             defaults: defaults,
                             palette: palette,
                             watching: watching)
        }
    }

    @Test func startsOnTheBuiltInPaletteWithNothingToComplainAbout() {
        let fixture = Fixture()
        let store = fixture.store()
        #expect(store.selectionID == SolaroThemeStore.builtInID)
        #expect(store.issues.isEmpty)
        #expect(fixture.palette.current == .builtIn)
    }

    @Test func listsTheBuiltInTheCuratedPresetsAndTheUsersOwn() {
        let fixture = Fixture()
        fixture.write("mine.json", "{ \"name\": \"Mine\", \"accent\": \"#FF0000\" }")
        let store = fixture.store()
        #expect(store.entries.first?.id == SolaroThemeStore.builtInID)
        #expect(store.entries.contains { $0.id == "dracula" })
        let mine = try? #require(store.entries.first { $0.id == "mine" })
        #expect(mine?.name == "Mine")
        if case .userFile = mine?.origin {} else {
            Issue.record("expected mine.json to list as a user file")
        }
        // Only .json; a stray file in the folder is not a theme.
        fixture.write("notes.txt", "hello")
        store.refresh()
        #expect(store.entries.contains { $0.id == "notes" } == false)
    }

    @Test func selectingAUserFileInstallsIt() {
        let fixture = Fixture()
        fixture.write("mine.json", """
        { "name": "Mine", "colors": { "accent": "#FF0000" } }
        """)
        let store = fixture.store()
        store.select("mine")
        #expect(store.issues.isEmpty)
        #expect(store.statedTokenCount == 1)
        #expect(fixture.palette.current.color(.accent)
                == SolaroThemeColor(SolaroRGBA(1, 0, 0)))
        // One colour changed; the other 25 did not.
        #expect(fixture.palette.current.color(.backdrop)
                == SolaroThemeTokens.builtIn.color(.backdrop))
        // And the choice is a preference, so it survives a relaunch.
        #expect(fixture.defaults.string(forKey: SolaroPrefs.themePreset.rawValue)
                == "mine")
        #expect(fixture.store().selectionID == "mine")
    }

    @Test func selectingACuratedPresetInstallsTheWholePalette() {
        let fixture = Fixture()
        let store = fixture.store()
        store.select("nord")
        #expect(store.issues.isEmpty)
        #expect(store.statedTokenCount == SolaroColorToken.allCases.count)
        #expect(fixture.palette.current != .builtIn)
    }

    /// A theme that says which appearance it belongs to pins it, so a
    /// dark palette does not land in a light window. Only an explicit
    /// pick does this — see the reload test below.
    @Test func aThemeThatDeclaresAnAppearancePinsIt() {
        let fixture = Fixture()
        let store = fixture.store()
        store.select("github-light")
        #expect(store.pinnedAppearance == .light)
        #expect(fixture.defaults.string(forKey: SolaroPrefs.theme.rawValue)
                == SolaroTheme.light.rawValue)
    }

    /// The headline failure mode. A file the user broke mid-edit must
    /// leave a complete palette and an explanation, never a monochrome
    /// window and silence.
    @Test func aMalformedFileLeavesTheBuiltInPaletteAndSaysWhy() {
        let fixture = Fixture()
        fixture.write("broken.json", "{ \"colors\": { \"accent\": ")
        let store = fixture.store()
        store.select("broken")
        #expect(fixture.palette.current == .builtIn)
        #expect(store.issues.isEmpty == false)
        let detail = store.issues.map(\.description).joined(separator: " ")
        #expect(detail.contains("broken.json"))
        #expect(detail.contains("SOLARO's own palette"))
        // It still lists, so the user can see what they selected
        // rather than finding the row gone.
        #expect(store.entries.contains { $0.id == "broken" })
    }

    @Test func aPartlyWrongFileAppliesTheRestAndNamesTheBadKeys() {
        let fixture = Fixture()
        fixture.write("partly.json", """
        {
          "name": "Partly",
          "colors": {
            "accent": "#00FF00",
            "backdrop": "#12345",
            "backgrop": "#000000"
          }
        }
        """)
        let store = fixture.store()
        store.select("partly")
        #expect(store.statedTokenCount == 1)
        #expect(fixture.palette.current.color(.accent)
                == SolaroThemeColor(SolaroRGBA(0, 1, 0)))
        #expect(fixture.palette.current.color(.backdrop)
                == SolaroThemeTokens.builtIn.color(.backdrop))
        let keys = Set(store.issues.compactMap(\.key))
        #expect(keys == ["backdrop", "backgrop"])
    }

    /// Selected, then deleted or renamed. The selection is kept so
    /// that putting the file back restores it, and the message names
    /// the theme and the folder it looked in.
    @Test func aSelectedThemeThatIsGoneFallsBackAndNamesIt() {
        let fixture = Fixture()
        let url = fixture.write("mine.json", "{ \"accent\": \"#FF0000\" }")
        let store = fixture.store()
        store.select("mine")
        #expect(fixture.palette.current != .builtIn)

        try? FileManager.default.removeItem(at: url)
        store.refresh()
        #expect(store.selectionID == "mine")
        #expect(fixture.palette.current == .builtIn)
        let detail = store.issues.map(\.description).joined(separator: " ")
        #expect(detail.contains("\"mine\" was not found"))
        #expect(detail.contains(fixture.directory.path))
    }

    /// A file wins over the preset of the same name, so dropping
    /// `nord.json` into the folder customises Nord instead of
    /// disappearing behind it.
    @Test func aUserFileShadowsACuratedPresetOfTheSameName() {
        let fixture = Fixture()
        fixture.write("nord.json", """
        { "name": "My Nord", "colors": { "accent": "#FF0000" } }
        """)
        let store = fixture.store()
        store.select("nord")
        #expect(store.statedTokenCount == 1)
        #expect(fixture.palette.current.color(.accent)
                == SolaroThemeColor(SolaroRGBA(1, 0, 0)))
        #expect(store.entries.filter { $0.id == "nord" }.count == 1)
        #expect(store.selectedEntry?.name == "My Nord")
    }

    /// Reload — the mechanism live reload uses — re-reads the selected
    /// file, but does not touch the appearance the user chose. A
    /// background file write yanking somebody out of light mode would
    /// be a worse surprise than a dark palette in a light window.
    @Test func reloadingPicksUpAnEditWithoutChangingTheAppearance() {
        let fixture = Fixture()
        fixture.write("mine.json", """
        { "appearance": "dark", "colors": { "accent": "#FF0000" } }
        """)
        let store = fixture.store()
        store.select("mine")
        #expect(fixture.defaults.string(forKey: SolaroPrefs.theme.rawValue)
                == SolaroTheme.dark.rawValue)

        fixture.defaults.set(SolaroTheme.light.rawValue,
                             forKey: SolaroPrefs.theme.rawValue)
        fixture.write("mine.json", """
        { "appearance": "dark", "colors": { "accent": "#0000FF" } }
        """)
        store.refresh()
        #expect(fixture.palette.current.color(.accent)
                == SolaroThemeColor(SolaroRGBA(0, 0, 1)))
        #expect(fixture.defaults.string(forKey: SolaroPrefs.theme.rawValue)
                == SolaroTheme.light.rawValue)
    }

    /// Live reload, end to end: edit the file on disk and the palette
    /// follows without anybody asking it to.
    @Test func anEditOnDiskReachesThePaletteOnItsOwn() async {
        let fixture = Fixture()
        fixture.write("mine.json", "{ \"colors\": { \"accent\": \"#FF0000\" } }")
        let store = fixture.store(watching: true)
        store.select("mine")
        #expect(store.watchedPathCount > 0)

        fixture.write("mine.json", "{ \"colors\": { \"accent\": \"#0000FF\" } }")
        let arrived = await eventually {
            fixture.palette.current.color(.accent)
                == SolaroThemeColor(SolaroRGBA(0, 0, 1))
        }
        #expect(arrived)
    }

    /// The Themes folder starts empty, so revealing it drops a worked
    /// example in — a complete, editable copy of the built-in palette,
    /// which is the documentation for the schema.
    @Test func revealingAnEmptyFolderSeedsAWorkedExample() throws {
        let fixture = Fixture()
        let store = fixture.store()
        let example = try #require(store.seedExampleIfFolderIsEmpty())
        #expect(example.lastPathComponent == "Example.json")
        #expect(store.entries.contains { $0.id == "Example" })
        // It is a theme, not a comment: selecting it works and changes
        // nothing, because it is the built-in palette written out.
        store.select("Example")
        #expect(store.issues.isEmpty)
        #expect(store.statedTokenCount == SolaroColorToken.allCases.count)

        // And a second reveal does not overwrite the user's edits.
        fixture.write("Example.json", "{ \"colors\": { \"accent\": \"#FF0000\" } }")
        #expect(store.seedExampleIfFolderIsEmpty() == nil)
    }
}

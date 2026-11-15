// BlackWhiteSettings.swift: the window that changes the settings of "Black & White.app".
//
// The game reads ~/Library/Application Support/Black & White/settings.conf once, when it starts
// (launcher.sh turns it into the game's registry size and BW_* switches). This app is the one place
// a player changes it, so nobody has to find a hidden file: it shows the choices, says plainly what
// each one does, writes the file, and when the game is running it can quit the game (the way
// Cmd-Q does, so the game saves as it ends) and open it again with the new settings.
//
//   swiftc -O -parse-as-library -target arm64-apple-macos13.0 BlackWhiteSettings.swift
//
// build-app.py does that and wraps the result in "Black & White Settings.app".
//
// Without a window, for tests and scripts:
//   --selftest                  checks the reading and writing of the file, prints one line per check
//   --print                     prints the settings as this app understands the file
//   --set NAME=value ...        changes settings and writes the file, as Save does
//       screen=window|desktop|exclusive  resolution=WIDTHxHEIGHT|native (the game's own picture
//       size; the window's Resolution list names each by what is drawn, size times sharpness)
//       sharpness=auto|1|1.5|2|3...  fps=30|60|120|0  sound=on|off  volume=0..100 (the master
//       volume the game's own Options screen also sets)
//   --window-size               prints the window size the settings give on this Mac
//   --list-resolutions          prints the Resolution list as the window shows it, with the
//                               resolution= value --set takes for each
//   --game-menu                 prints the Screen and Resolution choices as the game's own Options
//                               screen shows them (plain ASCII, one tab-separated line each, then
//                               the current choices); launcher.sh hands this to the game
//   --restart-game              after --set: quits the running game the way Cmd-Q does (it saves as it
//                               ends) and opens it again, which is what the game's Options screen
//                               asks for when a new Resolution is chosen (a Screen choice there is
//                               shown at once and only saved, with a plain --set screen=...)
//
// BW_APP_SUPPORT_DIR and BW_APP_LOGS_DIR move the two folders, as they do for launcher.sh;
// BW_SETTINGS_GAME_APP names the game app these settings are for (launcher.sh sets it to the app it
// belongs to; a test sets it to its stand-in).

import AppKit
import Combine
import SwiftUI

// MARK: - Where things are

enum Locations {
    static let environment = ProcessInfo.processInfo.environment

    static var support: URL {
        if let d = environment["BW_APP_SUPPORT_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Black & White", isDirectory: true)
    }

    static var logs: URL {
        if let d = environment["BW_APP_LOGS_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Black & White", isDirectory: true)
    }

    static var settingsFile: URL { support.appendingPathComponent("settings.conf") }

    /// The game app these settings are for: a test's stand-in, else the one beside this app, else
    /// the one in ~/Applications. (Not Launch Services' idea of it: that also knows every scratch
    /// copy ever built.)
    static var gameApp: URL? {
        let fm = FileManager.default
        if let p = environment["BW_SETTINGS_GAME_APP"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let beside = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Black & White.app")
        if fm.fileExists(atPath: beside.path) { return beside }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Black & White.app")
        return fm.fileExists(atPath: home.path) ? home : nil
    }
}

// MARK: - The file

/// A settings.conf as launcher.sh reads it: KEY=value lines, '#' starts a comment, a pair of double
/// quotes round a value is dropped, and when a key is given twice the last one counts.
struct ConfFile {
    struct Entry {
        var key: String
        var value: String
        var raw: String
    }

    private(set) var entries: [Entry] = []

    init(text: String) {
        for substring in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let raw = String(substring)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            entries.append(Entry(key: key, value: value, raw: raw.trimmingCharacters(in: .whitespaces)))
        }
    }

    func value(_ key: String) -> String? { entries.last(where: { $0.key == key })?.value }

    /// The lines of keys this app does not manage, as written (the game's folders, the pointer
    /// mode, the quit grace period), so saving does not lose them.
    func otherLines(managed: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        // The last of each key is the one that counts; keep that one, in file order.
        for entry in entries.reversed() where !managed.contains(entry.key) {
            if seen.insert(entry.key).inserted { result.append(entry.raw) }
        }
        return result.reversed()
    }
}

// MARK: - The settings

enum ScreenMode: String, CaseIterable, Identifiable {
    case window, desktop, exclusive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: return "Window"
        case .desktop: return "Full screen"
        case .exclusive: return "Full screen, switching the display's mode"
        }
    }
    /// The same choice as the game's own Options screen words it (its font has no dashes or quotes).
    var gameTitle: String {
        switch self {
        case .window: return "Window"
        case .desktop: return "Full screen"
        case .exclusive: return "Full screen, own display mode"
        }
    }
}

/// The game's own picture size: one of a few sizes, or whatever this Mac's display is.
enum Picture: Hashable {
    case size(Int, Int)
    case matchDisplay

    static let classic = Picture.size(1280, 800)
}

struct Settings: Equatable {
    var screen: ScreenMode = .window
    var picture: Picture = .classic
    /// How many times finer the world is drawn than the game's own picture (1 is the game's size),
    /// or nil for Automatic: the display's own pixel density, worked out each time the game starts.
    var sharpness: Double? = nil
    /// The most pictures a second (0: no limit).
    var frameCap: Int = 60
    var sound: Bool = true
    /// The master volume, 0 to 100, over everything the game plays.
    var volume: Int = 100

    static let managedKeys: Set<String> = ["SCREEN_MODE", "RESOLUTION", "PICTURE", "RENDER_SCALE", "FPS_CAP", "AUDIO", "VOLUME"]

    /// What the file says. An empty or missing RENDER_SCALE, or "auto", is Automatic. The older
    /// PICTURE presets are understood: 1440p and 4k are a size and a fixed scale of 2 (unless
    /// RENDER_SCALE says otherwise), native is this display at the automatic scale.
    init(file: ConfFile) {
        if let v = file.value("SCREEN_MODE"), let m = ScreenMode(rawValue: v) { screen = m }
        let raw = (file.value("RENDER_SCALE") ?? "").lowercased()
        var scale: Double? = Double(raw).flatMap { $0 > 0 ? $0 : nil }
        let automatic = raw == "auto"
        switch (file.value("PICTURE") ?? "classic").lowercased() {
        case "1440p":
            picture = .size(1280, 720)
            if !automatic { scale = scale ?? 2 }
        case "4k":
            picture = .size(1920, 1080)
            if !automatic { scale = scale ?? 2 }
        case "native":
            picture = .matchDisplay
        default:
            if let r = file.value("RESOLUTION"), let (w, h) = Settings.parseSize(r) { picture = .size(w, h) }
        }
        sharpness = scale
        if let v = file.value("FPS_CAP"), let n = Int(v), n >= 0 { frameCap = n }
        if let v = file.value("AUDIO") { sound = v != "off" }
        if let v = file.value("VOLUME"), let n = Int(v), n >= 0, n <= 100 { volume = n }
    }

    init() {}

    /// What suits the Mac this runs on: a window, the game's own picture size, drawn as finely as the
    /// display can show (Automatic), so the window has as many points as the picture has pixels
    /// (1280 × 800 points for the standard picture on a Retina display, where a sharpness of 1 would
    /// give 640 × 400).
    static func recommended() -> Settings { Settings() }

    /// "Automatic" sharpness: the display's own pixel density, so a picture of W × H is drawn at
    /// (W × density) × (H × density) pixels and the window is W × H points. The Resolution list is
    /// worked out with it, and launcher.sh works it out the same way at each start.
    static func automaticSharpness(for display: Display) -> Double {
        display.density >= 2 ? 2 : 1
    }

    /// The sharpness the game will draw at on this display.
    func scale(on display: Display) -> Double {
        sharpness ?? Settings.automaticSharpness(for: display)
    }

    static func parseSize(_ text: String) -> (Int, Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w >= 320, h >= 200,
              w <= 16384, h <= 16384 else { return nil }
        return (w, h)
    }

    /// The text of a settings.conf for these settings, with the lines of other keys kept.
    func fileText(keeping others: [String]) -> String {
        let resolution: String
        let pictureWord: String
        switch picture {
        case .size(let w, let h):
            resolution = "\(w)x\(h)"
            pictureWord = "classic"
        case .matchDisplay:
            // launcher.sh works the size out at each start; RESOLUTION is its fallback.
            resolution = "1280x800"
            pictureWord = "native"
        }
        // Automatic is left empty, which every build of the launcher accepts; a number is written as it is.
        let scale = sharpness.map { Settings.number($0) } ?? ""
        var text = """
        # Black & White settings.
        #
        # The "Black & White Settings" app writes this file; it can be edited by hand as well. The game
        # reads it once, when it starts, so a change is used the next time the game is opened.
        #
        # SCREEN_MODE: window (a window you can move; the default), desktop (borderless, over the whole
        #   screen) or exclusive (a real display mode switch).
        SCREEN_MODE=\(screen.rawValue)
        #
        # RESOLUTION: the game's own picture size, WIDTHxHEIGHT. A larger one shows more of the world
        #   at once and makes the buttons smaller. It is shown in the window or on the screen with its
        #   shape kept.
        RESOLUTION=\(resolution)
        #
        # PICTURE: classic (the size above; the default) or native (this Mac's main display in points,
        #   as even numbers, which then replaces RESOLUTION). 1440p and 4k, the older presets, set both
        #   RESOLUTION and RENDER_SCALE and are still understood.
        PICTURE=\(pictureWord)
        #
        # RENDER_SCALE: how many times finer the world is drawn than the picture size, 0.5 to 4. Empty
        #   (or auto) is automatic: 2 on a Retina display, 1 on other displays, worked out at each start.
        #   In a window the window grows by the same factor, so 2 gives a 1280x800 picture a 1280x800-point
        #   window on a Retina display. The buttons and the hand are not redrawn finer.
        RENDER_SCALE=\(scale)
        #
        # FPS_CAP: the most pictures a second the game shows (0: no limit). The game's turns run at
        #   about 10 a second whatever this says.
        FPS_CAP=\(frameCap)
        #
        # AUDIO: device (play the sound) or off.
        AUDIO=\(sound ? "device" : "off")
        #
        # VOLUME: the master volume, 0 to 100, over everything the game plays. The game's own
        # Options screen sets it too, and it takes effect there at once.
        VOLUME=\(volume)
        #
        # Set by hand, if wanted (the Settings app leaves them as they are):
        #   QUIT_GRACE_MS=15000   closing the window asks the game to quit; at some moments (the opening
        #                         films, loading) it ignores that, so the app ends it this many
        #                         milliseconds after the first request (0: never)
        #   POINTER=absolute      absolute (the hand follows the pointer exactly) or virtual (the hand is
        #                         steered by the pointer's motion); empty lets the game decide
        #   GAME_DIR=/path/to/the/installed/Black & White
        #   DISC_DIR=/path/to/the/disc/copy       (the folder next to its .volume file)
        #   EXE=/path/to/the/unprotected/runblack.exe

        """
        if !others.isEmpty {
            text += "#\n# Set by hand earlier, kept as they were:\n"
            for line in others { text += line + "\n" }
        }
        return text
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    // MARK: choices shown in the window

    /// The sizes of the game's own picture that the Resolution list offers, smallest first. The list
    /// names each one by what is drawn (the size times the sharpness), not by this number.
    static let pictureSizes: [(Int, Int)] = [
        (1024, 768), (1280, 720), (1280, 800), (1440, 900), (1680, 1050), (1920, 1080), (1920, 1200),
    ]

    /// The name people know a drawn size by, if it has one.
    static func outputName(_ w: Int, _ h: Int) -> String? {
        switch (w, h) {
        case (1280, 720): return "720p"
        case (1920, 1080): return "1080p"
        case (2560, 1440): return "1440p"
        case (3840, 2160): return "4K"
        default: return nil
        }
    }

    /// "3840 × 2160" and, for the sizes people know by a name, "4K (3840 × 2160)".
    static func drawnText(_ w: Int, _ h: Int) -> String {
        let size = "\(w) × \(h)"
        return outputName(w, h).map { "\($0) (\(size))" } ?? size
    }

    /// The other sharpnesses the Advanced section offers besides Automatic.
    static let sharpnessChoices: [Double] = [1, 1.5, 2, 3]
    static let frameCaps: [(Int, String)] = [(30, "30"), (60, "60"), (120, "120"), (0, "No limit")]
}

// MARK: - What this Mac's display gives

struct Display {
    var pointsWide: Int
    var pointsHigh: Int
    var usableWide: Int
    var usableHigh: Int
    var density: Double

    @MainActor static func main() -> Display {
        guard let s = NSScreen.main ?? NSScreen.screens.first else {
            return Display(pointsWide: 1440, pointsHigh: 900, usableWide: 1440, usableHigh: 875, density: 2)
        }
        return Display(pointsWide: Int(s.frame.width.rounded()), pointsHigh: Int(s.frame.height.rounded()),
                       usableWide: Int(s.visibleFrame.width.rounded()),
                       usableHigh: Int(s.visibleFrame.height.rounded()), density: Double(s.backingScaleFactor))
    }

    /// The game's picture size for "match this display": the display's size in points, as even
    /// numbers (launcher.sh does the same at each start).
    var matchedSize: (Int, Int) { (pointsWide / 2 * 2, pointsHigh / 2 * 2) }
}

extension Settings {
    /// The game's own picture size in pixels, with "match this display" worked out.
    func logicalSize(on display: Display) -> (Int, Int) {
        switch picture {
        case .size(let w, let h): return (w, h)
        case .matchDisplay: return display.matchedSize
        }
    }

    /// The size, in pixels, that the game's picture is drawn at: its own size times the sharpness.
    /// This is what the Resolution list shows, whatever the sharpness is.
    func drawnSize(on display: Display) -> (Int, Int) {
        let (w, h) = logicalSize(on: display)
        let k = scale(on: display)
        return (Int((Double(w) * k).rounded()), Int((Double(h) * k).rounded()))
    }

    /// What one choice of the Resolution list is called: the size it is drawn at with these
    /// settings' sharpness (and the name people know it by), "recommended" on the one that suits
    /// this Mac, "set in the file" on one the list does not offer.
    func resolutionTitle(_ p: Picture, on display: Display) -> String {
        var s = self
        s.picture = p
        let (w, h) = s.drawnSize(on: display)
        switch p {
        case .matchDisplay:
            return "Match this display (\(w) × \(h))"
        case .size(let lw, let lh):
            var title = Settings.drawnText(w, h)
            if !Settings.pictureSizes.contains(where: { $0.0 == lw && $0.1 == lh }) {
                title += " – set in the file"
            } else if p == Settings.recommended().picture, sharpness == nil {
                title += " – recommended"
            }
            return title
        }
    }

    /// The size, in points, of the window the game gets: the picture times the scale, over the
    /// display's pixel density, shrunk with its shape kept to fit the usable area (less room for the
    /// title bar). The same sum as the game's own (user32_window.cpp, WindowPoints).
    func windowPoints(on display: Display) -> (Int, Int) {
        let (w, h) = logicalSize(on: display)
        let k = scale(on: display)
        var pw = (Double(w) * k / display.density).rounded()
        var ph = (Double(h) * k / display.density).rounded()
        if k != 1 {
            let maxW = Double(display.usableWide)
            let maxH = Double(max(display.usableHigh - 40, 1))
            if pw > maxW || ph > maxH {
                let f = min(maxW / pw, maxH / ph)
                pw = (pw * f).rounded()
                ph = (ph * f).rounded()
            }
        }
        return (max(Int(pw), 1), max(Int(ph), 1))
    }
}

// MARK: - The game

@MainActor
enum Game {
    static func runningCopies() -> [NSRunningApplication] {
        guard let app = Locations.gameApp?.resolvingSymlinksInPath().path else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == app
        }
    }

    static var isRunning: Bool { !runningCopies().isEmpty }

    /// Asks the game to quit the way Cmd-Q does (the game saves as it ends), and waits for it.
    static func quit(timeout: TimeInterval) async -> Bool {
        let copies = runningCopies()
        copies.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if copies.allSatisfy({ $0.isTerminated }) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return copies.allSatisfy { $0.isTerminated }
    }

    /// What launcher.sh works out from the settings file and hands to the game. A game opened from
    /// here, possibly by the game that asked for the restart (its Options screen), must work these
    /// out again from the file it has just been given, not inherit the old ones.
    static let launcherExports: Set<String> = [
        "BW_CD_DIR", "BW_FULLSCREEN", "BW_AUDIO", "BW_POINTER", "BW_FPS_CAP", "BW_QUIT_GRACE_MS",
        "BW_RENDER_SCALE", "BW_SETTINGS_TOOL", "BW_SETTINGS_GAME_APP", "BW_DISPLAY_MENU",
    ]

    static func open() async -> Bool {
        guard let app = Locations.gameApp else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        // LaunchServices gives the game it opens this program's own environment as well as the one
        // set below, so the launcher's values are taken out of it here (a game that asked for this
        // restart handed them on, and they describe the settings it started with).
        for name in launcherExports { unsetenv(name) }
        // A test that runs this app with BW_* switches (a scratch settings folder, background mode)
        // wants the game it opens to get them too; a player's own run has none.
        let passed = Locations.environment.filter { $0.key.hasPrefix("BW_") && !launcherExports.contains($0.key) }
        if !passed.isEmpty { configuration.environment = passed }
        return await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                cont.resume(returning: error == nil)
            }
        }
    }
}

// MARK: - The window's model

@MainActor
final class SettingsModel: ObservableObject {
    /// What the window shows. Changing it clears the last message, which was about what was saved before.
    @Published var settings: Settings {
        didSet { if settings != oldValue, !busy { message = "" } }
    }
    @Published private(set) var saved: Settings
    @Published private(set) var others: [String]
    @Published var gameRunning = Game.isRunning
    @Published var busy = false
    @Published var message = ""
    let display = Display.main()

    init() {
        let file = SettingsModel.readFile()
        let loaded = Settings(file: file)
        settings = loaded
        saved = loaded
        others = file.otherLines(managed: Settings.managedKeys)
    }

    static func readFile() -> ConfFile {
        let data = try? Data(contentsOf: Locations.settingsFile)
        return ConfFile(text: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    var changed: Bool { settings != saved }

    func refreshGame() { gameRunning = Game.isRunning }

    func recommend() {
        settings = Settings.recommended()
        message = "The recommended settings for this Mac are in the window. Save to use them."
    }

    /// Writes the file. The one it replaces is kept beside it as settings.conf.previous.
    @discardableResult
    func save() -> Bool {
        do {
            let url = Locations.settingsFile
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let old = try? Data(contentsOf: url) {
                try old.write(to: url.appendingPathExtension("previous"), options: .atomic)
            }
            // Other keys are read again from the file as it is now, in case it was edited meanwhile.
            let file = SettingsModel.readFile()
            let keep = file.otherLines(managed: Settings.managedKeys)
            try settings.fileText(keeping: keep).write(to: url, atomically: true, encoding: .utf8)
            others = keep
            saved = settings
            return true
        } catch {
            message = "The settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func saveOnly() {
        if save() {
            message = gameRunning
                ? "Saved. The running game keeps its old settings until it is opened again."
                : "Saved. The game uses these the next time it is opened."
        }
    }

    /// Saves, quits the game if it is running (it saves as it ends), and opens it again.
    func saveAndOpen() {
        guard save() else { return }
        busy = true
        Task {
            if Game.isRunning {
                message = "Waiting for the game to save and quit…"
                let ended = await Game.quit(timeout: 25)
                if !ended {
                    message = "Saved, but the game is still running. It ignores a quit at some moments (the opening film, loading); try again in a moment."
                    busy = false
                    refreshGame()
                    return
                }
            }
            message = "Opening the game…"
            let opened = await Game.open()
            message = opened ? "Saved. The game is opening." : "Saved, but the game could not be opened. Open it from the Applications folder."
            busy = false
            refreshGame()
        }
    }

    // MARK: notes

    var automaticSharpness: Double { Settings.automaticSharpness(for: display) }

    var sharpnessIsAutomatic: Bool { settings.sharpness == nil }

    /// The name of a choice in the Resolution list.
    func resolutionTitle(_ p: Picture) -> String { settings.resolutionTitle(p, on: display) }

    /// The name of a choice in the Sharpness list (Advanced): nil is Automatic.
    func sharpnessTitle(_ v: Double?) -> String {
        guard let v else { return "Automatic (\(Settings.number(automaticSharpness))× on this display)" }
        return Settings.sharpnessChoices.contains(v) ? "\(Settings.number(v))×" : "\(Settings.number(v))× – set in the file"
    }

    /// The sharpnesses Advanced lists: Automatic first, the others after it, and a value the file
    /// holds that is none of them.
    var sharpnessOptions: [Double?] {
        var options: [Double?] = [nil]
        options += Settings.sharpnessChoices.map { Optional($0) }
        if !options.contains(settings.sharpness) { options.append(settings.sharpness) }
        return options
    }

    /// What the choices give, in the words of the list: one sentence for the Resolution list.
    var resolutionNote: String {
        switch settings.picture {
        case .matchDisplay:
            return "Uses every pixel of this display. Everything is small at this size."
        case .size:
            return "A higher resolution shows more of the world at once and makes the buttons smaller."
        }
    }

    /// What the Screen and Resolution choices give together, in plain terms.
    var sizeNote: String {
        let (dw, dh) = settings.drawnSize(on: display)
        let drawn = "\(dw) × \(dh) pixels" + (Settings.outputName(dw, dh).map { " (\($0))" } ?? "")
        // The largest pictures tried here ran at about 55 to 60 pictures a second on a Mac with this
        // display, so they may not hold the frame limit on a busier or older one.
        let heavy = dw * dh > 8_000_000
            ? " That is a great many pixels: if the game stutters, choose a smaller resolution." : ""
        let sharpness = settings.sharpness.map { " Sharpness is set to \(Settings.number($0))× (Advanced)." } ?? ""
        switch settings.screen {
        case .window:
            let (pw, ph) = settings.windowPoints(on: display)
            let wantW = Int((Double(settings.logicalSize(on: display).0) * settings.scale(on: display) / display.density).rounded())
            let fit = pw < wantW ? " The window is made smaller to fit this display." : ""
            return "A \(pw) × \(ph) window on this display. The game draws \(drawn) into it.\(fit)\(sharpness)\(heavy)"
        case .desktop:
            return "Fills the screen, with its shape kept (bars where the shapes differ). The game draws \(drawn).\(sharpness)\(heavy)"
        case .exclusive:
            return "The display is asked for the smallest mode that holds it; if the Mac does not like that, use Full screen. The game draws \(drawn).\(sharpness)\(heavy)"
        }
    }

    /// The tool tip of the Recommended button.
    var recommendedHelp: String {
        let (w, h) = Settings.recommended().drawnSize(on: display)
        return "Window, \(Settings.drawnText(w, h)), 60 pictures a second, sound on"
    }

    var sharpnessNote: String {
        "How much finer than the game's own picture it is drawn. Automatic suits this display (\(Settings.number(automaticSharpness))×). A lower number is faster but softer, and gives a smaller window."
    }
}

// MARK: - The window

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    /// Sharpness is under Advanced, closed unless the file holds a sharpness that is not Automatic.
    @State private var showAdvanced = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// Window and Full screen. The display-switching mode is shown only when the file already asks
    /// for it: it has never been used with anything but the standard size, and a game that stops
    /// in it can leave the display in the wrong mode.
    private var screenOptions: [ScreenMode] {
        var options: [ScreenMode] = [.window, .desktop]
        if model.settings.screen == .exclusive { options.append(.exclusive) }
        return options
    }

    /// One list, in the order of the sizes drawn, with "Match this display" last; a size the file
    /// holds that the list does not offer is added so the window shows what is really set.
    private var pictureOptions: [Picture] {
        var options = Settings.pictureSizes.map { Picture.size($0.0, $0.1) }
        if case .size = model.settings.picture, !options.contains(model.settings.picture) {
            options.append(model.settings.picture)
        }
        options.append(.matchDisplay)
        return options
    }

    private var frameOptions: [Int] {
        var options = Settings.frameCaps.map { $0.0 }
        if !options.contains(model.settings.frameCap) { options.append(model.settings.frameCap) }
        return options
    }

    private func title(frames v: Int) -> String {
        Settings.frameCaps.first(where: { $0.0 == v })?.1 ?? "\(v) (set in the file)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.gameRunning {
                    Section {
                        Label("Black & White is open. Changes are used the next time it is opened; “Save and Restart Game” does that now, and the game saves as it quits. While you play, the game's own Options screen (Esc) has Screen and Resolution too: Screen changes at once there, Resolution restarts the game.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Screen") {
                    Picker("Screen", selection: $model.settings.screen) {
                        ForEach(screenOptions) { Text($0.title).tag($0) }
                    }
                    Picker("Resolution", selection: $model.settings.picture) {
                        ForEach(pictureOptions, id: \.self) { Text(model.resolutionTitle($0)).tag($0) }
                    }
                    Text(model.sizeNote).font(.caption).foregroundStyle(.secondary)
                    Text(model.resolutionNote).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Picker("Sharpness", selection: $model.settings.sharpness) {
                            ForEach(model.sharpnessOptions, id: \.self) { Text(model.sharpnessTitle($0)).tag($0) }
                        }
                        Text(model.sharpnessNote).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Speed") {
                    Picker("Frame rate limit", selection: $model.settings.frameCap) {
                        ForEach(frameOptions, id: \.self) { Text(title(frames: $0)).tag($0) }
                    }
                    Text("Pictures a second at most. The game itself always runs at the same speed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Sound") {
                    Toggle("Play sound", isOn: $model.settings.sound)
                }

                Section {
                    HStack {
                        Button("Show Settings File") {
                            NSWorkspace.shared.activateFileViewerSelecting([Locations.settingsFile])
                        }
                        Button("Show Logs") { NSWorkspace.shared.open(Locations.logs) }
                        Spacer()
                    }
                    Text("The game's own options (detail level, volumes, controls) stay in the game's Options screen, which has Screen (changes at once) and Resolution (restarts the game) too while you play. Saved games are never touched from here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Button("Recommended") { model.recommend() }.disabled(model.busy)
                    .help(model.recommendedHelp)
                Text(model.message)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Button("Save") { model.saveOnly() }
                    .disabled(model.busy || !model.changed)
                Button(model.gameRunning ? "Save and Restart Game" : "Save and Play") { model.saveAndOpen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
            .padding(14)
        }
        .frame(width: 600, height: 720)
        .onAppear { showAdvanced = !model.sharpnessIsAutomatic }
        .onReceive(timer) { _ in model.refreshGame() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SettingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Black & White Settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Without a window

@MainActor
enum Command {
    static func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    static func report(_ s: Settings, display: Display) {
        let (lw, lh) = s.logicalSize(on: display)
        switch s.picture {
        case .size(let w, let h): say("resolution=\(w)x\(h)")
        case .matchDisplay: say("resolution=native (\(lw)x\(lh) here)")
        }
        say("screen=\(s.screen.rawValue)")
        say("sharpness=\(s.sharpness.map { Settings.number($0) } ?? "auto")")
        let (dw, dh) = s.drawnSize(on: display)
        say("drawn=\(dw)x\(dh)")
        say("fps=\(s.frameCap)")
        say("sound=\(s.sound ? "on" : "off")")
        say("volume=\(s.volume)")
    }

    /// The choices of the Resolution list for these settings: the standard sizes, one the file holds
    /// that they do not include, and Match this display last.
    static func pictureChoices(_ s: Settings) -> [Picture] {
        var choices = Settings.pictureSizes.map { Picture.size($0.0, $0.1) }
        if case .size = s.picture, !choices.contains(s.picture) { choices.append(s.picture) }
        choices.append(.matchDisplay)
        return choices
    }

    /// The `resolution=` value --set takes for a choice.
    static func token(_ p: Picture) -> String {
        switch p {
        case .size(let w, let h): return "\(w)x\(h)"
        case .matchDisplay: return "native"
        }
    }

    /// The Resolution list as the window shows it for the saved settings, one choice a line:
    /// its name, then the `resolution=` value that --set takes for it.
    static func listResolutions(_ s: Settings, display: Display) {
        for p in pictureChoices(s) { say("\(s.resolutionTitle(p, on: display))\tresolution=\(token(p))") }
    }

    /// What the game's Options screen shows of the Screen and Resolution choices, in its own plain
    /// ASCII: `screen`, `resolution` and `current` lines, each with tabs between its parts. The names
    /// are the window's, so the two say the same thing; the display's mode switch is offered only
    /// where the file already asks for it, as in the window.
    static func menuLines(_ s: Settings, display: Display) -> [String] {
        func ascii(_ t: String) -> String {
            t.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "–", with: "-")
        }
        var screens: [ScreenMode] = [.window, .desktop]
        if s.screen == .exclusive { screens.append(.exclusive) }
        var lines = screens.map { "screen\t\($0.rawValue)\t\(ascii($0.gameTitle))" }
        lines += pictureChoices(s).map { "resolution\t\(token($0))\t\(ascii(s.resolutionTitle($0, on: display)))" }
        lines.append("current\tscreen\t\(s.screen.rawValue)")
        lines.append("current\tresolution\t\(token(s.picture))")
        return lines
    }

    /// Quits the running game the way Cmd-Q does, waits for it to end (it saves as it ends), and opens
    /// it again so it starts with the settings just written. Returns the exit code.
    static func restartGame() -> Int32 {
        final class Outcome { var finished = false; var code: Int32 = 0 }
        let outcome = Outcome()
        Task { @MainActor in
            if Game.isRunning, !(await Game.quit(timeout: 25)) {
                FileHandle.standardError.write(Data("the game is still running; it ignores a quit at some moments\n".utf8))
                outcome.code = 1
            } else if !(await Game.open()) {
                FileHandle.standardError.write(Data("the game could not be opened\n".utf8))
                outcome.code = 1
            }
            outcome.finished = true
        }
        while !outcome.finished { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        return outcome.code
    }

    static func run(_ args: [String]) -> Int32? {
        guard let first = args.first else { return nil }
        let display = Display.main()
        switch first {
        case "--selftest":
            return SelfTest.run()
        case "--print":
            report(SettingsModel.readSettings(), display: display)
            return 0
        case "--window-size":
            let (w, h) = SettingsModel.readSettings().windowPoints(on: display)
            say("\(w)x\(h)")
            return 0
        case "--list-resolutions":
            listResolutions(SettingsModel.readSettings(), display: display)
            return 0
        case "--game-menu":
            menuLines(SettingsModel.readSettings(), display: display).forEach(say)
            return 0
        case "--restart-game":
            return restartGame()
        case "--set":
            let model = SettingsModel()
            var restart = false
            for pair in args.dropFirst() {
                if pair == "--restart-game" { restart = true; continue }
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { FileHandle.standardError.write(Data("bad setting \(pair)\n".utf8)); return 2 }
                let v = parts[1]
                switch parts[0] {
                case "screen":
                    guard let m = ScreenMode(rawValue: v) else { return fail("screen must be window, desktop or exclusive") }
                    model.settings.screen = m
                case "resolution":
                    if v == "native" {
                        model.settings.picture = .matchDisplay
                    } else if let (w, h) = Settings.parseSize(v) {
                        model.settings.picture = .size(w, h)
                    } else {
                        return fail("resolution must be WIDTHxHEIGHT or native")
                    }
                case "sharpness":
                    if v == "auto" {
                        model.settings.sharpness = nil
                    } else {
                        guard let d = Double(v), d >= 0.5, d <= 4 else { return fail("sharpness must be auto or 0.5 to 4") }
                        model.settings.sharpness = d
                    }
                case "fps":
                    guard let n = Int(v), n >= 0, n <= 999 else { return fail("fps must be 0 to 999") }
                    model.settings.frameCap = n
                case "sound":
                    guard v == "on" || v == "off" else { return fail("sound must be on or off") }
                    model.settings.sound = v == "on"
                case "volume":
                    guard let n = Int(v), n >= 0, n <= 100 else { return fail("volume must be 0 to 100") }
                    model.settings.volume = n
                default:
                    return fail("unknown setting \(parts[0])")
                }
            }
            guard model.save() else { return fail(model.message) }
            return restart ? restartGame() : 0
        default:
            return nil
        }
    }

    static func fail(_ s: String) -> Int32 {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        return 2
    }
}

extension SettingsModel {
    static func readSettings() -> Settings { Settings(file: readFile()) }
}

// MARK: - Self-test

@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        Command.say((ok ? "ok    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func read(_ text: String) -> Settings { Settings(file: ConfFile(text: text)) }

    static func run() -> Int32 {
        let display = Display(pointsWide: 2056, pointsHigh: 1329, usableWide: 2056, usableHigh: 1275, density: 2)

        // Reading
        check(read("") == Settings(), "an empty file is the standard settings")
        let old = """
        # an older file
        SCREEN_MODE=window
        RESOLUTION=1280x800
        AUDIO=device
        GAME_DIR=/somewhere/Black & White
        """
        let oldSettings = read(old)
        check(oldSettings.picture == .classic && oldSettings.sharpness == nil && oldSettings.frameCap == 60,
              "a file from an earlier build reads, with the missing keys at their standard values (no RENDER_SCALE is Automatic)")
        check(read("PICTURE=4k").picture == .size(1920, 1080) && read("PICTURE=4k").sharpness == 2,
              "PICTURE=4k is 1920x1080 at a scale of 2")
        check(read("PICTURE=1440p").picture == .size(1280, 720) && read("PICTURE=1440p").sharpness == 2,
              "PICTURE=1440p is 1280x720 at a scale of 2")
        check(read("PICTURE=native").picture == .matchDisplay && read("PICTURE=native").sharpness == nil,
              "PICTURE=native matches the display at the automatic scale")
        check(read("RENDER_SCALE=auto").sharpness == nil && read("RENDER_SCALE=AUTO\nPICTURE=4k").sharpness == nil
                && read("RENDER_SCALE=").sharpness == nil, "RENDER_SCALE=auto and an empty one are Automatic, presets or not")
        check(read("PICTURE=4k\nRENDER_SCALE=1.5").sharpness == 1.5, "RENDER_SCALE wins over a preset's scale")
        check(read("RENDER_SCALE=1").sharpness == 1, "RENDER_SCALE=1 is a sharpness of 1, not Automatic")
        check(read("RESOLUTION=1280x800\nRENDER_SCALE=2").sharpness == 2, "RENDER_SCALE counts with the classic picture")
        check(read("RESOLUTION=1024x768\nRESOLUTION=1440x900").picture == .size(1440, 900), "the last of a repeated key counts")
        check(read("SCREEN_MODE=\"desktop\"").screen == .desktop, "quotes round a value are dropped")
        check(read("SCREEN_MODE=nonsense").screen == .window, "a value that makes no sense falls back")
        check(read("FPS_CAP=0").frameCap == 0 && read("AUDIO=off").sound == false, "FPS_CAP=0 and AUDIO=off")
        check(read("VOLUME=40").volume == 40 && read("VOLUME=250").volume == 100
                && read("VOLUME=-5").volume == 100, "VOLUME counts, and one out of range falls back")

        // Writing and reading again
        var s = Settings()
        s.screen = .desktop
        s.picture = .size(1920, 1200)
        s.sharpness = 2
        s.frameCap = 120
        s.sound = false
        s.volume = 40
        let text = s.fileText(keeping: [])
        check(read(text) == s, "what is written reads back the same")
        var native = Settings()
        native.picture = .matchDisplay
        native.sharpness = 2
        check(read(native.fileText(keeping: [])) == native, "match-this-display reads back the same")
        var half = Settings()
        half.sharpness = 1.5
        check(read(half.fileText(keeping: [])) == half, "a scale of 1.5 reads back the same")
        check(read(Settings().fileText(keeping: [])) == Settings(), "the standard settings read back the same")
        check(Settings().fileText(keeping: []).contains("\nRENDER_SCALE=\n"), "Automatic is written as an empty RENDER_SCALE")
        var nativeAuto = Settings()
        nativeAuto.picture = .matchDisplay
        check(read(nativeAuto.fileText(keeping: [])) == nativeAuto, "match-this-display at Automatic reads back the same")
        var one = Settings()
        one.sharpness = 1
        check(one.fileText(keeping: []).contains("\nRENDER_SCALE=1\n") && read(one.fileText(keeping: [])) == one,
              "a sharpness of 1 is written as 1 and reads back as 1, not as Automatic")

        // Other keys survive
        let kept = ConfFile(text: old + "\nPOINTER=virtual\n# EXE=/not/this\nGAME_DIR=/later")
            .otherLines(managed: Settings.managedKeys)
        check(kept == ["POINTER=virtual", "GAME_DIR=/later"], "other keys are kept, the last of each, comments dropped")
        let rewritten = s.fileText(keeping: kept)
        check(ConfFile(text: rewritten).value("GAME_DIR") == "/later" && ConfFile(text: rewritten).value("POINTER") == "virtual",
              "other keys are in the file that is written")

        // The window's size
        check(Settings().windowPoints(on: display) == (1280, 800), "1280x800 at the automatic sharpness on a 2x display is 1280x800 points")
        check(one.windowPoints(on: display) == (640, 400), "1280x800 at a sharpness of 1 on a 2x display is 640x400 points")
        var sharp = Settings()
        sharp.sharpness = 2
        check(sharp.windowPoints(on: display) == (1280, 800), "1280x800 at 2x on a 2x display is 1280x800 points")
        var big = Settings()
        big.picture = .size(1920, 1080)
        big.sharpness = 3
        let (bw, bh) = big.windowPoints(on: display)
        check(bw <= 2056 && bh <= 1235 && abs(Double(bw) / Double(bh) - 1920.0 / 1080.0) < 0.01,
              "a window too large for the display is shrunk with its shape kept (\(bw)x\(bh))")
        var nat = Settings()
        nat.picture = .matchDisplay
        check(nat.logicalSize(on: display) == (2056, 1328), "match-this-display is the display's points, as even numbers")

        // The recommended settings
        check(Settings.recommended().windowPoints(on: display) == (1280, 800),
              "recommended on a 2x display is a 1280x800-point window")
        let plain = Display(pointsWide: 1920, pointsHigh: 1080, usableWide: 1920, usableHigh: 1055, density: 1)
        check(Settings.recommended().windowPoints(on: plain) == (1280, 800),
              "recommended on a 1x display is a 1280x800-point window")
        check(Settings.recommended().picture == .classic && Settings.recommended().screen == .window
                && Settings.recommended().sharpness == nil, "recommended is the standard picture size in a window, at Automatic")
        check(Settings.outputName(3840, 2160) == "4K" && Settings.outputName(2560, 1440) == "1440p"
                && Settings.outputName(1920, 1080) == "1080p" && Settings.outputName(1280, 720) == "720p"
                && Settings.outputName(2560, 1600) == nil, "the drawn sizes people know by name are named")

        // The Resolution list: one list, each choice named by what is drawn
        let auto = Settings.recommended()
        check(Settings.automaticSharpness(for: display) == 2 && Settings.automaticSharpness(for: plain) == 1,
              "automatic sharpness is the display's density (2 here, 1 on a plain display)")
        let titles = (Settings.pictureSizes.map { Picture.size($0.0, $0.1) } + [.matchDisplay])
            .map { auto.resolutionTitle($0, on: display) }
        check(titles == ["2048 × 1536", "1440p (2560 × 1440)", "2560 × 1600 – recommended", "2880 × 1800", "3360 × 2100",
                         "4K (3840 × 2160)", "3840 × 2400", "Match this display (4112 × 2656)"],
              "on this display the list reads 1440p, 4K and the other sizes by the pixels drawn: \(titles)")
        check(auto.resolutionTitle(.size(1920, 1080), on: plain) == "1080p (1920 × 1080)"
                && auto.resolutionTitle(.size(1280, 720), on: plain) == "720p (1280 × 720)"
                && auto.resolutionTitle(.size(1280, 800), on: plain) == "1280 × 800 – recommended",
              "on a plain display the same picture sizes are named by their own pixels")
        var small = Settings()
        small.sharpness = 1
        check(small.resolutionTitle(.size(1280, 800), on: display) == "1280 × 800"
                && small.resolutionTitle(.size(1920, 1080), on: display) == "1080p (1920 × 1080)",
              "at a sharpness of 1 on a 2x display the list names the smaller drawn sizes, with no recommended mark")
        var odd = Settings()
        odd.picture = .size(1366, 768)
        odd.sharpness = 2
        check(odd.resolutionTitle(.size(1366, 768), on: display) == "2732 × 1536 – set in the file",
              "a size the file holds that the list does not offer says so")
        var sharper = Settings()
        sharper.sharpness = 3
        check(sharper.drawnSize(on: display) == (3840, 2400), "drawn size is the picture size times the sharpness")
        check(auto.drawnSize(on: display) == (2560, 1600) && small.drawnSize(on: display) == (1280, 800)
                && auto.drawnSize(on: plain) == (1280, 800),
              "1280x800 is drawn at 2560x1600 at the automatic sharpness on a 2x display, 1280x800 at 1 or on a 1x display")

        // What the game's own Options screen is given
        let menu = Command.menuLines(auto, display: display)
        check(menu.prefix(2) == ["screen\twindow\tWindow", "screen\tdesktop\tFull screen"]
                && !menu.contains(where: { $0.hasPrefix("screen\texclusive") }),
              "the game's menu offers Window and Full screen, and the display's mode switch only when the file already asks for it")
        var exclusive = auto
        exclusive.screen = .exclusive
        check(Command.menuLines(exclusive, display: display).contains("screen\texclusive\tFull screen, own display mode"),
              "the game's menu offers the display's mode switch when the file asks for it")
        check(menu.contains("resolution\t1920x1080\t4K (3840 x 2160)")
                && menu.contains("resolution\t1280x720\t1440p (2560 x 1440)")
                && menu.contains("resolution\t1280x800\t2560 x 1600 - recommended")
                && menu.contains("resolution\tnative\tMatch this display (4112 x 2656)"),
              "the game's menu names the sizes as the window does, with plain characters: \(menu)")
        check(menu.allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } }, "the game's menu is plain ASCII")
        check(menu.suffix(2) == ["current\tscreen\twindow", "current\tresolution\t1280x800"],
              "the game's menu ends with the current Screen and Resolution")
        check(Command.menuLines(odd, display: display).contains("resolution\t1366x768\t2732 x 1536 - set in the file"),
              "a size the file holds that the list does not offer is in the game's menu too")

        Command.say(failures == 0 ? "all checks passed" : "\(failures) checks failed")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Start

@main
struct Entry {
    @MainActor
    static func main() {
        if let code = Command.run(Array(CommandLine.arguments.dropFirst())) { exit(code) }
        SettingsApp.main()
    }
}

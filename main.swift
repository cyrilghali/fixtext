// FixText: a background app that fixes the selected text in place, in any app.
//   ⌃F (global hotkey) → ⌘C → fix → ⌘V. Works in Electron apps (Slack) that ignore macOS Services.
//   Right-click → Services → Fix Text in Cocoa apps (macOS hands over the selection, no keystrokes).
// Fix engines, first available wins: Anthropic API, a resident `claude -p` session,
// Ollama at localhost:11434 (offline), ~/.local/bin/fix-text (one-shot claude -p).
// Store the API key once: security add-generic-password -s fix-text-anthropic -a "$USER" -w "<key>"
// Build: see build.sh next to this file.
import AppKit
import Carbon

let prompt = """
    Correct the text in its original language. Fix spelling, grammar, accents and punctuation, and make awkward \
    non-native phrasing sound natural in English, French or any other language. Reword only where needed for fluency; \
    preserve the intended meaning, tone, register and line breaks. Never translate, add ideas or explanations. \
    Keep @mentions, :emoji:, URLs and code as is. If the text is already natural, change only its errors. \
    Expand texting shorthand into full words in context (r → are, u → you, jss → je suis, pk → pourquoi, \
    bcp → beaucoup, dsl → désolé, tkt → t'inquiète, tt → tout, pb → problème); \
    keep colloquial words that are real words (réu, démo, appli, ouais). \
    Reply with the corrected text only.
    Examples:
    Input: sa va etre dur mais on va y arrivé
    Output: Ça va être dur mais on va y arriver
    Input: their is to many bug, i will fix it tomorow
    Output: There are too many bugs, I will fix it tomorrow
    Input: r u sure it works
    Output: Are you sure it works?
    Input: maybe my english is ugly because im not native thats what am i trying to say
    Output: Maybe my English sounds awkward because I'm not a native speaker. That's what I'm trying to say.
    Input: je veux que tu corrige mes phrases françaises quand elles sonne bizarre
    Output: Je veux que tu corriges mes phrases en français quand elles sonnent bizarre.
    Input: jss dsl, la demo est pas prete, @sam tu peu la lancer ?
    Output: Je suis désolé, la démo est pas prête, @sam tu peux la lancer ?
    Input: on fait un point apres la reu ?
    Output: On fait un point après la réu ?
    """

let apiKey = shell("/usr/bin/security", ["find-generic-password", "-s", "fix-text-anthropic", "-w"], stdin: nil)

// A selection copied out of a terminal pane drags its quote gutter along: Claude Code prefixes every selected line with ▎.
func stripGutter(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        let bare = line.drop { $0 == " " || $0 == "\t" }
        guard let gutter = bare.unicodeScalars.first, (0x2588...0x258F).contains(gutter.value) else { return line }
        let rest = bare.dropFirst()
        return rest.first == " " ? rest.dropFirst() : rest
    }.joined(separator: "\n")
}

func fix(_ raw: String) -> String {
    let text = stripGutter(raw)
    return fixWithAPI(text) ?? claudeSession.fix(text) ?? fixWithOllama(text)
        ?? shell("/bin/bash", ["-c", "\"$HOME/.local/bin/fix-text\""], stdin: text) ?? text
}

// One `claude -p` process kept alive on the subscription: boot and prompt cache are paid once, each fix is one round trip.
final class ClaudeSession {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var uses = 0
    private let lock = NSLock()
    var isReady: Bool { process?.isRunning == true }

    func start() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.arguments = ["-p", "--model", "haiku", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "", "--setting-sources", "",
                       "--settings", "{\"alwaysThinkingEnabled\":false}",   // a spelling fix needs no reasoning; thinking would 5× the latency
                       "--system-prompt", prompt + "\nEach message is an independent text to correct; never refer to earlier ones."]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        (process, input, output, pending, uses) = (p, stdin.fileHandleForWriting, stdout.fileHandleForReading, Data(), 0)
        _ = roundTrip("warm up")   // pays the boot and caches the system prompt before the first real fix
    }

    func fix(_ text: String) -> String? {
        guard lock.try() else { return nil }   // (re)starting: let the next engine answer
        defer { lock.unlock() }
        guard isReady else { return nil }
        let fixed = roundTrip(text)
        uses += 1
        if uses >= 30 || fixed == nil { DispatchQueue.global().async { self.start() } }   // fresh context, or recover from a dead process
        return fixed
    }

    private func roundTrip(_ text: String) -> String? {
        guard let input, let output,
              let message = try? JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": text]])
        else { return nil }
        input.write(message + Data("\n".utf8))
        let killer = DispatchWorkItem { [weak self] in self?.process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        defer { killer.cancel() }
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], event["type"] as? String == "result" {
                    return (event["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                continue
            }
            let chunk = output.availableData
            if chunk.isEmpty { return nil }   // process gone
            pending.append(chunk)
        }
    }
}
let claudeSession = ClaudeSession()

func fixWithOllama(_ text: String) -> String? {
    post("http://localhost:11434/api/chat", headers: [:], body: [
        "model": "gemma3:4b", "stream": false, "keep_alive": "24h", "options": ["temperature": 0],
        "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]],
    ]).flatMap { ($0["message"] as? [String: Any])?["content"] as? String }
}

func fixWithAPI(_ text: String) -> String? {
    guard let apiKey else { return nil }
    return post("https://api.anthropic.com/v1/messages",
                headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
                body: ["model": "claude-haiku-4-5-20251001", "max_tokens": 2048, "system": prompt,
                       "messages": [["role": "user", "content": text]]])
        .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
}

func post(_ url: String, headers: [String: String], body: [String: Any]) -> [String: Any]? {
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    var result: [String: Any]?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
            result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        done.signal()
    }.resume()
    done.wait()
    return result
}

func shell(_ path: String, _ args: [String], stdin input: String?) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
    stdin.fileHandleForWriting.closeFile()
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
    process.waitUntilExit()
    return process.terminationStatus == 0 && !output.isEmpty ? output : nil
}

// Services path: macOS gives the selection on the pasteboard and replaces it with what we put back.
final class Provider: NSObject {
    @objc func fixText(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        let fixed = fix(text)
        pboard.clearContents()
        pboard.setString(fixed.isEmpty ? text : fixed, forType: .string)   // never blank the selection
    }
}

// Hotkey path: copy the selection ourselves, fix, paste over it.
func pressCommand(_ key: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func fixSelectionInPlace() {
    guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else { return }
    let pasteboard = NSPasteboard.general
    let before = pasteboard.changeCount
    pressCommand(CGKeyCode(kVK_ANSI_C))
    DispatchQueue.global().async {
        let deadline = Date().addingTimeInterval(0.5)
        while pasteboard.changeCount == before && Date() < deadline { usleep(20_000) }
        guard pasteboard.changeCount != before, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let fixed = fix(text)
        DispatchQueue.main.async {
            pasteboard.clearContents()
            pasteboard.setString(fixed.isEmpty ? text : fixed, forType: .string)
            usleep(50_000)
            pressCommand(CGKeyCode(kVK_ANSI_V))
        }
    }
}

// Menu bar item: shows the app is on, which engine answers, and whether ⌃F may type (Accessibility).
final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Fix Text")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Fix selection", action: #selector(fixNow), keyEquivalent: "f").keyEquivalentModifierMask = .control
        menu.addItem(.separator())
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")   // engine, filled on open
        menu.addItem(withTitle: "", action: #selector(openAccessibility), keyEquivalent: "")   // accessibility, filled on open
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Fix Text", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let ollamaUp = (try? Data(contentsOf: URL(string: "http://localhost:11434/api/version")!)) != nil
        menu.items[2].title = "Engine: " + (apiKey != nil ? "Claude Haiku, API" : claudeSession.isReady ? "Claude Haiku, subscription"
                                            : ollamaUp ? "Gemma 3, local" : "Claude Haiku, CLI")
        let trusted = AXIsProcessTrusted()
        menu.items[3].title = trusted ? "Accessibility: granted" : "Accessibility: not granted, click to open settings"
        menu.items[3].isEnabled = !trusted
    }

    @objc func fixNow() { fixSelectionInPlace() }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)  // ask once, at launch
let provider = Provider()
app.servicesProvider = provider
NSUpdateDynamicServices()
let statusMenu = StatusMenu()
DispatchQueue.global().async { claudeSession.start() }

var hotkeyRef: EventHotKeyRef?
var hotkeySpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in fixSelectionInPlace(); return noErr }, 1, &hotkeySpec, nil, nil)
RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey), EventHotKeyID(signature: 0x46495854, id: 1),
                    GetApplicationEventTarget(), 0, &hotkeyRef)

app.run()

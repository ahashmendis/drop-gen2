#!/bin/bash
# Installs "Drop": a small floating popup at the top of the screen.
# Drop PDF / Word files on it -> local Ollama model answers -> answer is copied to the clipboard.
set -e

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Installing Apple Command Line Tools..."
  xcode-select --install
  echo "Run this script again after the install finishes."
  exit 1
fi

DIR="$HOME/Library/Application Support/Drop"
APP="$HOME/Applications/Drop.app"
mkdir -p "$DIR" "$HOME/Applications"

# Remove the older attempts
rm -rf "$HOME/Applications/Java Answers.app"
pkill -x Drop 2>/dev/null || true

cat > "$DIR/main.swift" <<'EOF'
import Cocoa
import PDFKit
import Carbon

let DEFAULT_MODEL = "qwen3-coder"
let SKIP_DIRS: Set<String> = [".idea", "target", ".git", "node_modules", "build", ".mvn", ".gradle", "out", ".vscode"]
let TEXT_EXT: Set<String> = ["java", "xml", "md", "properties", "yml", "yaml", "json", "txt", "sql", "gradle", "kts", "html", "csv"]
let PROMPT_HEADER = """
You are an expert Java 17 / Spring Boot developer. Below is a practical exam paper (Word/PDF/README)
followed by the files of the starter Maven project that goes with it.
Rules:
- Do EVERY task in the paper (Task 1, Task 2, ...), following each marking point exactly.
- Read the STARTER PROJECT FILES first. Use their exact package names, class names, method names,
  record fields and constructor parameters. Never invent repository methods or packages.
- Work inside the starter project: fill in every TODO, keep the same package names, class names,
  method signatures and file paths. Do NOT change the parent class, DTO records or repository API
  unless a task says so. Create any new class the paper asks for. Uncomment seed lines when told to.
- Use polymorphism where the paper asks (no instanceof / type checks). Validate inputs as described.
- Null-check text BEFORE calling any method on it: if (x == null || x.isBlank()) throw new
  IllegalArgumentException(...); only then x.trim(). A null field in a POST body must give 400, never 500.
- Put @Override on EVERY method that overrides a parent method (including ones the starter left without it).
- If a bullet says a SERVICE method must validate something, validate it explicitly in that service method
  too (e.g. if (minutes <= 0) throw new IllegalArgumentException(...)), even if the model also checks it.
- Do overflow-prone maths fully in long (e.g. long hours = (minutes + 59L) / 60).
- Build comparators as a variable first, then sort: Comparator<T> c = Comparator.comparingInt(...).reversed()
  .thenComparingLong(T::getId); list.sort(c);  Never call thenComparing on a Stream.
- Never put ! in front of an int or a comparison like !a == b; write a != b.
- Idempotency (same key + same request -> same result, same key + different request -> 409): keep a
  Map<String, OriginalRequest> and a Map<String, Result>; on a repeat compare the stored REQUEST with the
  new one using equals(); identical -> return the stored result without saving again; different -> throw
  the starter's conflict exception. Never compare the request with values taken from the result.
- When choosing a status or reason, decide it with the parent type's methods (e.g. latestStartTick(),
  getters), never with instanceof or casts. Use each listed reason code in its exact situation.
- Error codes: 400 -> ApiError("BAD_REQUEST", ...), 404 -> "NOT_FOUND", 409 -> "CONFLICT" unless the paper says otherwise.
- Preview / plan / quote methods must never change stored state; work on copies. Only commit/save methods persist.
- Capacity per time unit: build a Map<Integer, int[]> of usage from the confirmed reservations PLUS what you
  selected so far in this run, and check EVERY tick of the half-open interval [start, start + duration).
- Rejection reasons: check in this order unless the paper says otherwise: job larger than capacity ->
  EXCEEDS_CAPACITY; deadline already impossible (latestStartTick() < earliest start) -> DEADLINE; window
  ends before the earliest start -> RELEASE_OUTSIDE_WINDOW; no feasible start found -> NO_SLOT.
- Lists returned by GET endpoints must be in a deterministic order (sort them, e.g. by start then id).
- Keep every annotation that is already in the starter (e.g. @RestControllerAdvice stays @RestControllerAdvice).
- Keep ALL the starter's existing import lines exactly (e.g. keep import java.util.*;). Never replace
  a wildcard import with single imports; only ADD imports you need.
- Variable and return types must match the starter's method return types exactly (if a service method
  returns the parent type, the controller must use the parent type too).
- If the paper says an endpoint "returns a JSON object containing X", return Map.of("X", value), never a bare number.
- Wrap Math.toIntExact / energy or price calculations that can overflow in try/catch(ArithmeticException)
  and rethrow new IllegalArgumentException(...) so the API answers 400, not 500.
- Name every @PathVariable / @RequestParam explicitly, e.g. @PathVariable("id"), @RequestParam("capacity").
- Controller methods only call the service: no try/catch, no validation, no building error bodies there;
  the @RestControllerAdvice handler turns exceptions into 400/404 with ApiError(code, message).
- A POST that creates something returns ResponseEntity.status(HttpStatus.CREATED).body(created).
- Sort with Comparator.comparingInt(Parent::a).reversed().thenComparingInt(Parent::b).thenComparingLong(Parent::getId)
  exactly in the direction the paper states.
- Method references only work for methods with matching parameters: urgencyAt(int) needs a lambda,
  e.g. Comparator.comparingInt((Workload w) -> w.urgencyAt(nowTick)). Return types must match exactly
  (a method declared to return List cannot return a Collection).
- Before finishing, re-read every file you wrote and fix anything that would not compile:
  wrong types, missing imports, methods or constructors that do not exist in the starter.
Output ONLY code, no markdown, and NO task list or summary at the start.
Organise the answer BY TASK, in order. Start each task with its own header line, then give every
Java file that task adds or changes, each one COMPLETE, with a FILE header naming the file to put it in:
// ===== Task 1 =====
// ===== FILE: src/main/java/.../GroundMission.java =====
// ===== Task 2 =====
// ===== FILE: src/main/java/.../AirMission.java =====
// ===== FILE: src/main/java/.../DispatchService.java =====
(Directly under each FILE header write that file's full Java code. Never write placeholders.)
If a file was already given under an earlier task and this task changes it, give it AGAIN, complete,
including the earlier tasks' code (so the last copy of each file is the final version).
Finish with a comment block "// ===== HOW TO TEST =====" listing curl commands for the paper's functional checks.
For plain Java tasks with no starter project, use // ===== Task 1 ===== headers and include a main method.
"""
let REVIEW_HEADER = ""
let REPAIR_HEADER = """
Your previous answer above does NOT compile. The JAVAC ERRORS section shows the exact errors.
Fix every error. Use only classes, methods, record fields and constructors that exist in the starter
files (or that you create yourself). Keep everything that was already correct.
Output ONLY the files you change to fix the errors, each one COMPLETE and starting with its
// ===== FILE: src/main/java/.../ClassName.java ===== header line.
No task list, no explanations, no test commands, no unchanged files.
"""

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var title = "Drop to share" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                     : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()

        let t = title as NSString
        let ta: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor]
        let ts = t.size(withAttributes: ta)
        t.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - 1), withAttributes: ta)

        let s = subtitle as NSString
        let sa: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor]
        let ss = s.size(withAttributes: sa)
        let w = min(ss.width, bounds.width - 16)
        s.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - ss.height, width: w, height: ss.height),
               withAttributes: sa)
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let u = urls(sender)
        if u.isEmpty { return false }
        onDrop?(u)
        return true
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatPanel!
    let dropView = DropView(frame: .zero)
    let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var expandBtn: NSButton!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var running = false
    var starterFiles: [String: String] = [:]
    var lastAnswer = ""
    var expanded = false
    let W: CGFloat = 230
    let compactH: CGFloat = 68
    let answerH: CGFloat = 240

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.midX - W / 2, y: screen.maxY - compactH - 6, width: W, height: compactH)
        panel = FloatPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        dropView.onDrop = { [weak self] urls in self?.handle(urls) }
        dropView.onClick = { [weak self] in self?.chooseFiles() }

        modelPopup.controlSize = .small
        modelPopup.font = NSFont.systemFont(ofSize: 11)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.addItem(withTitle: DEFAULT_MODEL)

        func small(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.controlSize = .mini
            b.font = NSFont.systemFont(ofSize: 9)
            b.bezelStyle = .rounded
            return b
        }
        let copyBtn = small("Copy", #selector(copyAgain))
        expandBtn = small("Share ▾", #selector(toggleAnswer))
        let quitBtn = small("✕", #selector(hidePanel))
        quitBtn.toolTip = "Hide (click the menu bar icon to show again)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, copyBtn, expandBtn, quitBtn])
        row.spacing = 6

        textView.isEditable = false
        textView.font = mono
        textView.drawsBackground = false
        scroll.drawsBackground = false
        scroll.isHidden = true

        let stack = NSStackView(views: [dropView, row, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: fx.bottomAnchor, constant: -8),
            dropView.heightAnchor.constraint(equalToConstant: 30),
            dropView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: answerH - 5),
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Drop")
            b.image?.isTemplate = true
            b.toolTip = "Drop – click to show/hide, right-click for menu"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        registerHotKey()
        panel.orderFrontRegardless()
        setStatus("Connecting to Ollama…")
        loadModels()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func setStatus(_ s: String) { dropView.subtitle = s }

    func loadModels() {
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:11434/api/tags")!)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let names = ((obj?["models"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["name"] as? String }
                    .filter { !$0.contains("cloud") }
                modelPopup.removeAllItems()
                modelPopup.addItems(withTitles: names.isEmpty ? [DEFAULT_MODEL] : names)
                if let saved = UserDefaults.standard.string(forKey: "model"), names.contains(saved) {
                    modelPopup.selectItem(withTitle: saved)
                } else if let m = names.first(where: { $0.hasPrefix(DEFAULT_MODEL) }) {
                    modelPopup.selectItem(withTitle: m)
                }
                setStatus("Ready · click to choose files")
            } catch {
                setStatus("⚠️ Ollama not running – open the Ollama app")
            }
        }
    }

    @objc func modelChanged() {
        UserDefaults.standard.set(modelPopup.titleOfSelectedItem, forKey: "model")
    }

    @objc func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.level = .modalPanel
        if open.runModal() == .OK { handle(open.urls) }
    }

    @objc func copyAgain() {
        if lastAnswer.isEmpty { return }
        copyToClipboard(lastAnswer)
        setStatus("📋 Copied again · paste with ⌘V")
    }

    @objc func toggleAnswer() {
        expanded.toggle()
        scroll.isHidden = !expanded
        expandBtn.title = expanded ? "Share ▴" : "Share ▾"
        var f = panel.frame
        let h = expanded ? compactH + answerH : compactH
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func hidePanel() { panel.orderOut(nil) }

    @objc func toggleDoubleCheck() {
        let cur = UserDefaults.standard.object(forKey: "doubleCheck") as? Bool ?? false
        UserDefaults.standard.set(!cur, forKey: "doubleCheck")
        setStatus(!cur ? "Double-check on" : "Double-check off")
    }

    // Control + Option + D shows / hides the popup from anywhere
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.togglePanel() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x44524F50), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            let show = NSMenuItem(title: "Show / Hide", action: #selector(togglePanel), keyEquivalent: "")
            show.target = self
            m.addItem(show)
            let copy = NSMenuItem(title: "Copy last answer", action: #selector(copyAgain), keyEquivalent: "")
            copy.target = self
            m.addItem(copy)
            m.addItem(.separator())
            let q = NSMenuItem(title: "Quit Drop", action: #selector(quit), keyEquivalent: "q")
            q.target = self
            m.addItem(q)
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    func extractText(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string ?? "" }
        if ["txt", "java", "md", "csv"].contains(ext) {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Reads a file, or every useful text file inside a folder (e.g. a starter project)
    func collect(_ url: URL) -> (String, Int) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            if url.pathExtension.lowercased() == "zip" { return collectZip(url) }
            return ("\n===== FILE: \(url.lastPathComponent) =====\n" + extractText(url), 1)
        }
        var zips: [URL] = []
        var docs = ""
        var code = ""
        var count = 0
        var total = 0
        let base = url.path
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return ("", 0) }
        for case let f as URL in en {
            let vals = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                if SKIP_DIRS.contains(f.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if (vals?.fileSize ?? 0) > 150_000 || f.lastPathComponent.hasPrefix("~$") { continue }
            let ext = f.pathExtension.lowercased()
            if ext == "zip" { zips.append(f); continue }
            var text = ""
            if TEXT_EXT.contains(ext) {
                text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            } else if ["pdf", "docx", "doc", "rtf"].contains(ext) {
                text = extractText(f)
            } else { continue }
            if text.isEmpty { continue }
            total += text.count
            if total > 400_000 { code += "\n[... more files skipped: project too large ...]\n"; break }
            let rel = f.path.hasPrefix(base + "/") ? String(f.path.dropFirst(base.count + 1)) : f.lastPathComponent
            if ext == "java", let r = rel.range(of: "src/main/java/") { starterFiles[String(rel[r.lowerBound...])] = text }
            let chunk = "\n===== FILE: \(rel) =====\n" + text
            if ["pdf", "docx", "doc", "rtf", "md", "txt"].contains(ext) { docs += chunk } else { code += chunk }
            count += 1
        }
        // No unzipped project in the folder? Read the starter ZIP instead.
        if code.isEmpty {
            for z in zips {
                let (t, n) = collectZip(z)
                code += t
                count += n
            }
        }
        let paper = docs.isEmpty ? "" : "\n######## EXAM PAPER / INSTRUCTIONS ########\n" + docs
        let project = code.isEmpty ? "" : "\n######## STARTER PROJECT FILES ########\n" + code
        return (paper + project, count)
    }

    func collectZip(_ zip: URL) -> (String, Int) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return ("", 0) }
        let (text, n) = collect(tmp)
        try? FileManager.default.removeItem(at: tmp)
        return (text, n)
    }

    func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func stripFences(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func handle(_ urls: [URL]) {
        if running { setStatus("⏳ Busy – wait for the current answer"); return }
        starterFiles = [:]
        var paper = ""
        var fileCount = 0
        for f in urls {
            let (text, n) = collect(f)
            paper += text
            fileCount += n
        }
        if paper.split(whereSeparator: { $0.isWhitespace }).count < 15 {
            setStatus(fileCount == 0 ? "⚠️ macOS blocked reading – allow Drop in Privacy settings"
                                      : "⚠️ No readable text (scanned PDF?)")
            return
        }
        let model = modelPopup.titleOfSelectedItem ?? DEFAULT_MODEL
        running = true
        textView.string = ""
        dropView.title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        let prompt = PROMPT_HEADER + "\n\n" + paper
        if !paper.contains(".java =====") {
            setStatus("⚠️ No Java starter found · thinking anyway…")
        } else {
            setStatus("⏳ Read \(fileCount) file(s) · thinking…")
        }
        let check = false
        Task { @MainActor in
            defer { self.running = false; self.dropView.title = "Drop to share" }
            guard var answer = await self.generate(prompt: prompt, model: model, label: "✍️ Writing") else { return }
            if check {
                let review = REVIEW_HEADER + "\n\n######## RULES ########\n" + PROMPT_HEADER
                    + "\n\n" + paper + "\n\n######## DRAFT SOLUTION ########\n" + answer
                self.textView.string = ""
                if let fixed = await self.generate(prompt: review, model: model, label: "🔍 Double-checking"),
                   fixed.count > answer.count / 3 {
                    answer = fixed
                }
            }
            // Compile the answer against the starter; if javac fails, send the errors back for a fix (max 2 rounds)
            var compiled: Bool? = nil
            var rounds = 0
            while true {
                self.setStatus("🧪 Compiling…")
                guard let errs = await self.compileErrors(answer) else { compiled = nil; break }
                if errs.isEmpty { compiled = true; break }
                compiled = false
                if rounds >= 2 { break }
                rounds += 1
                let n = errs.components(separatedBy: "error:").count - 1
                let fixPrompt = PROMPT_HEADER + "\n\n" + paper
                    + "\n\n######## YOUR PREVIOUS ANSWER ########\n" + answer
                    + "\n\n######## JAVAC ERRORS ########\n" + String(errs.prefix(6000))
                    + "\n\n" + REPAIR_HEADER
                self.textView.string = ""
                guard let fixes = await self.generate(prompt: fixPrompt, model: model, label: "🔧 Fixing \(n) compile error(s)") else { break }
                let merged = AppDelegate.mergeFixes(answer, fixes)
                if merged == answer { break }
                answer = merged
            }
            self.lastAnswer = AppDelegate.applyImportFix(self.stripFences(answer))
            self.textView.string = self.lastAnswer
            self.copyToClipboard(self.lastAnswer)
            NSSound(named: NSSound.Name("Glass"))?.play()
            switch compiled {
            case .some(true): self.setStatus("✅ Copied! Compiles · paste with ⌘V")
            case .some(false): self.setStatus("⚠️ Copied, but still has compile errors – check IntelliJ")
            case .none: self.setStatus(self.starterFiles.isEmpty ? "✅ Copied! (no starter to compile against)"
                                                                 : "⚠️ Copied – couldn't compile-check (no JDK/Spring found)")
            }
        }
    }

    func compileErrors(_ answer: String) async -> String? {
        let files = starterFiles
        if files.isEmpty { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            return AppDelegate.runJavac(answer: answer, starter: files)
        }.value
    }

    // nil = could not check (no JDK / no Spring jars in ~/.m2), "" = compiles, otherwise javac errors
    static func runJavac(answer: String, starter: [String: String]) -> String? {
        let fm = FileManager.default
        let jh = Process()
        jh.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let jp = Pipe()
        jh.standardOutput = jp
        jh.standardError = Pipe()
        do { try jh.run() } catch { return nil }
        let homeData = jp.fileHandleForReading.readDataToEndOfFile()
        jh.waitUntilExit()
        let home = (String(data: homeData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if jh.terminationStatus == 0 && !home.isEmpty { candidates.append(home + "/bin/javac") }
        let userHome = fm.homeDirectoryForCurrentUser.path
        for dir in [userHome + "/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"] {
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().reversed() {
                candidates.append(dir + "/" + name + "/Contents/Home/bin/javac")
            }
        }
        for app in ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []) where app.hasPrefix("IntelliJ") {
            candidates.append("/Applications/" + app + "/Contents/jbr/Contents/Home/bin/javac")
        }
        candidates += ["/opt/homebrew/opt/openjdk/bin/javac", "/usr/local/opt/openjdk/bin/javac"]
        guard let javac = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }

        let m2 = fm.homeDirectoryForCurrentUser.appendingPathComponent(".m2/repository")
        var jars: [String] = []
        for sub in ["org/springframework", "jakarta", "com/fasterxml/jackson"] {
            if let en = fm.enumerator(at: m2.appendingPathComponent(sub), includingPropertiesForKeys: nil) {
                for case let f as URL in en where f.pathExtension == "jar" {
                    let n = f.lastPathComponent
                    if !n.contains("sources") && !n.contains("javadoc") { jars.append(f.path) }
                }
            }
        }
        if !jars.contains(where: { $0.contains("spring-web") }) { return nil }

        let tmp = fm.temporaryDirectory.appendingPathComponent("dropc-" + UUID().uuidString)
        var sources = starter
        for (k, v) in parseAnswerFiles(answer) { sources[k] = AppDelegate.ensureUtilImport(v) }
        var paths: [String] = []
        for (k, v) in sources {
            let u = tmp.appendingPathComponent(k)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? v.write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        let out = tmp.appendingPathComponent("out")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: javac)
        p.arguments = ["--release", "17", "-proc:none", "-nowarn", "-encoding", "UTF-8",
                       "-d", out.path, "-cp", jars.joined(separator: ":")] + paths
        let ep = Pipe()
        p.standardError = ep
        p.standardOutput = ep
        do { try p.run() } catch { return nil }
        let data = ep.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
        if p.terminationStatus == 0 { return "" }
        let text = String(data: data, encoding: .utf8) ?? "compile failed"
        return text.replacingOccurrences(of: tmp.path + "/", with: "")
    }

    static func sections(_ text: String) -> [(String?, [String])] {
        var res: [(String?, [String])] = [(nil, [])]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("// =====") {
                res.append((line, []))
            } else {
                res[res.count - 1].1.append(line)
            }
        }
        return res
    }

    static func fileName(_ header: String?) -> String? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.hasPrefix("// ===== FILE:") else { return nil }
        let rest = String(h.dropFirst("// ===== FILE:".count)).trimmingCharacters(in: .whitespaces)
        guard let path = rest.components(separatedBy: " ").first, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    // Replaces the answer's FILE sections with the fixed versions (adds new files before HOW TO TEST)
    static func mergeFixes(_ answer: String, _ fixes: String) -> String {
        let fixSecs = sections(fixes).filter { fileName($0.0) != nil }
        if fixSecs.isEmpty { return answer }
        var byName: [String: (String?, [String])] = [:]
        for f in fixSecs { byName[fileName(f.0)!] = f }
        var used = Set<String>()
        var out: [String] = []
        func emitUnused() {
            for f in fixSecs {
                let n = fileName(f.0)!
                if !used.contains(n) { out.append(f.0!); out += f.1; used.insert(n) }
            }
        }
        for sec in sections(answer) {
            if let n = fileName(sec.0), let f = byName[n] {
                out.append(f.0!); out += f.1; used.insert(n)
            } else {
                if let h = sec.0, h.contains("HOW TO TEST") { emitUnused() }
                if let h = sec.0 { out.append(h) }
                out += sec.1
            }
        }
        emitUnused()
        return out.joined(separator: "\n")
    }

    // Adds "import java.util.*;" after the package line when a file has no java.util wildcard import
    static func ensureUtilImport(_ code: String) -> String {
        if code.contains("import java.util.*;") { return code }
        var lines = code.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package ") }) {
            lines.insert("import java.util.*;", at: i + 1)
            return lines.joined(separator: "\n")
        }
        return code
    }

    // Rewrites every FILE section of the answer with the import fix applied (so what you paste matches what compiled)
    static func applyImportFix(_ answer: String) -> String {
        var out: [String] = []
        var inFile = false
        var buf: [String] = []
        func flush() {
            if inFile { out.append(contentsOf: ensureUtilImport(buf.joined(separator: "\n")).components(separatedBy: "\n")) }
            else { out.append(contentsOf: buf) }
            buf = []
        }
        for line in answer.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// =====") {
                flush()
                out.append(line)
                inFile = t.hasPrefix("// ===== FILE:")
            } else {
                buf.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    // Splits "// ===== FILE: ... =====" sections into src/main/java/<package>/<File>.java -> content
    static func parseAnswerFiles(_ answer: String) -> [String: String] {
        var result: [String: String] = [:]
        var name: String? = nil
        var buf: [String] = []
        func flush() {
            guard let n = name else { return }
            let body = buf.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
            var pkg = ""
            for l in body.components(separatedBy: "\n") {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("package ") {
                    pkg = String(t.dropFirst(8)).replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            let file = (n as NSString).lastPathComponent
            guard file.hasSuffix(".java") else { return }
            let dir = pkg.isEmpty ? "" : pkg.replacingOccurrences(of: ".", with: "/") + "/"
            result["src/main/java/" + dir + file] = body
        }
        for line in answer.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// ===== FILE:") {
                flush()
                buf = []
                let rest = String(t.dropFirst("// ===== FILE:".count)).trimmingCharacters(in: .whitespaces)
                name = rest.components(separatedBy: " ").first
            } else if t.hasPrefix("// =====") {
                flush()
                buf = []
                name = nil
            } else if name != nil {
                buf.append(line)
            }
        }
        flush()
        return result
    }

    func contextSize(for prompt: String) -> Int {
        let needed = prompt.count / 3 + 8000
        var ctx = 8192
        while ctx < needed && ctx < 65536 { ctx *= 2 }
        return ctx
    }

    @MainActor
    func generate(prompt: String, model: String, label: String) async -> String? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": true,
                                   "keep_alive": "30m", "options": ["num_ctx": contextSize(for: prompt), "temperature": 0.2]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var answer = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                var err = ""
                for try await l in bytes.lines { err += l }
                setStatus("❌ Ollama error \(h.statusCode)")
                textView.string = err
                return nil
            }
            for try await line in bytes.lines {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let e = obj["error"] as? String { setStatus("❌ \(e)"); return nil }
                if let piece = obj["response"] as? String, !piece.isEmpty {
                    answer += piece
                    textView.textStorage?.append(NSAttributedString(string: piece, attributes: [
                        .font: mono, .foregroundColor: NSColor.textColor]))
                    textView.scrollToEndOfDocument(nil)
                    setStatus("\(label)… \(answer.count) chars")
                }
            }
            return answer
        } catch {
            setStatus("❌ \(error.localizedDescription)")
            return nil
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
EOF

cat > "$DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.drop</string>
  <key>CFBundleName</key><string>Drop</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
EOF

echo "Building Drop..."
swiftc -O "$DIR/main.swift" -o "$DIR/Drop" -framework Cocoa -framework PDFKit -framework Carbon \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"

# Run Drop through launchd (so macOS doesn't show the launcher in the Dock as "running in background")
AGENT="$HOME/Library/LaunchAgents/local.drop.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.drop</string>
  <key>ProgramArguments</key><array><string>$DIR/Drop</string></array>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$DIR/log.txt</string>
  <key>StandardErrorPath</key><string>$DIR/log.txt</string>
</dict>
</plist>
EOF2
launchctl bootout "gui/$(id -u)/local.drop" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

# Small launcher app (Spotlight: "Drop") - just asks launchd to (re)start the popup
rm -rf "$APP"
osacompile -o "$APP" \
  -e 'do shell script "launchctl kickstart -k gui/$(id -u)/local.drop"'

# Custom icon
[ -f "$HOME/Downloads/Drop.icns" ] && cp "$HOME/Downloads/Drop.icns" "$DIR/Drop.icns"
if [ -f "$DIR/Drop.icns" ]; then
  cp "$DIR/Drop.icns" "$APP/Contents/Resources/applet.icns"
  touch "$APP"
fi

echo "✅ Installed. Starting Drop..."
launchctl kickstart -k "gui/$(id -u)/local.drop"


// ---- ACD harness driver (replaces the app launch lines) ----
// modes: run <inputDir> <base> <out.json> <toggleMidRun 0|1> | oop-while-acd <inputDir> <base> <out.json> | copy <out.json>
let aArgs = CommandLine.arguments
let aApp = NSApplication.shared
let aD = AppDelegate()
let aPB = NSPasteboard.general
let aSavedClip = aPB.string(forType: .string)
UserDefaults.standard.removeObject(forKey: "subject")
if ProcessInfo.processInfo.environment["DROP_CAREFUL"] == "1" { AcdSettings.setCareful(true) } else { AcdSettings.setCareful(false) }
let aDefaultWasOOP = Subject.saved == .oop
aD.subject = Subject.saved
aD.subjectControl = NSSegmentedControl(labels: ["OOP", "ACD"], trackingMode: .selectOne, target: aD, action: #selector(AppDelegate.subjectChanged))
aD.runFolderBtn = NSButton(title: "", target: nil, action: nil)
aD.partField = NSTextField(string: "")
aD.partRow = NSStackView()
aD.config.provider = "ollama"
if aArgs.count > 3 { aD.config.ollamaBase = aArgs[3] }
aD.modelPopup.addItem(withTitle: "qwen-mock:1b")
aD.modelPopup.selectItem(at: 0)
let aProviderBefore = aD.config.provider, aModelBefore = aD.modelPopup.titleOfSelectedItem ?? "", aBaseBefore = aD.config.ollamaBase
let aCfgBefore = (try? Data(contentsOf: CONFIG_URL)).map { benchHash($0) } ?? "none"
func waitIdle() { let dl = Date().addingTimeInterval(300); while aD.running && Date() < dl { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
var out: [String: Any] = ["defaultWasOOP": aDefaultWasOOP]
aPB.clearContents()
switch aArgs[1] {
case "run":
    aD.subjectControl.selectedSegment = 1; aD.subjectChanged()
    out["subjectAfterSelect"] = UserDefaults.standard.string(forKey: "subject") ?? ""
    aD.handleACD([URL(fileURLWithPath: aArgs[2])])
    out["runningAfterStart"] = aD.running
    if aArgs[5] == "1" { aD.subjectControl.selectedSegment = 0; aD.subjectChanged() }   // toggle while the run is active
    waitIdle()
    out["textHead"] = String(aD.textView.string.prefix(60))
case "oop-pertask":
    out["defaultOff"] = !AcdSettings.oopPerTask                          // opt-in: off unless the user turns it on
    AcdSettings.setOopPerTask(true); aD.subject = .oop; aD.dispatchSubject([URL(fileURLWithPath: aArgs[2])])   // the popup path with the setting on
    AcdSettings.setOopPerTask(false)
    waitIdle()
case "oop-while-acd":
    aD.subjectControl.selectedSegment = 1; aD.subjectChanged()
    aD.handle([URL(fileURLWithPath: aArgs[2])])      // what the OOP hotkey does: handle() directly
    waitIdle()
case "copy":
    let acdAns = "// ===== Task 1 =====\n// ===== Q A1 =====\nB\n// ===== Q A2 =====\nFalse\n// ===== Task 2 =====\n// ===== FILE: src/components/Hello.tsx =====\nexport const h = 1;\n"
    aD.lastAnswer = "// ===== Task 1 =====\nOOP-ONE\n// ===== Task 2 =====\nOOP-TWO"
    aD.lastAnswerACD = acdAns
    aD.subjectControl.selectedSegment = 1; aD.subjectChanged()
    func clip() -> String { aPB.string(forType: .string) ?? "" }
    aD.copyAllHotkey();           out["hotkeyCopyAllWhileACD"] = clip()
    aD.copyTaskHotkey(2);         out["hotkeyTask2WhileACD"] = clip()
    aD.copyAgain();               out["copyButtonACD"] = clip()
    aD.partField.stringValue = "A1";           aD.copyPart(); out["partA1"] = clip()
    aD.partField.stringValue = "Hello.tsx";    aD.copyPart(); out["partFile"] = clip()
    aD.partField.stringValue = "2";            aD.copyPart(); out["partTask2ACD"] = clip()
    aD.partField.stringValue = "Z9";           aD.copyPart(); out["partMissingStatus"] = aD.dropView.subtitle
    aD.subjectControl.selectedSegment = 0; aD.subjectChanged()
    aD.copyAgain();               out["copyButtonOOP"] = clip()
    aD.partField.stringValue = "2";            aD.copyPart(); out["partTask2OOP"] = clip()
    out["subjectPersisted"] = UserDefaults.standard.string(forKey: "subject") ?? ""
default: break
}
out["lastAnswerACD"] = aD.lastAnswerACD
out["lastAnswerOOP"] = aD.lastAnswer
out["status"] = aD.dropView.subtitle
out["clipboard"] = aPB.string(forType: .string) ?? ""
out["subjectDefaults"] = UserDefaults.standard.string(forKey: "subject") ?? ""
out["providerUnchanged"] = aD.config.provider == aProviderBefore && aD.config.ollamaBase == aBaseBefore
out["modelUnchanged"] = (aD.modelPopup.titleOfSelectedItem ?? "") == aModelBefore
out["configFileUnchanged"] = ((try? Data(contentsOf: CONFIG_URL)).map { benchHash($0) } ?? "none") == aCfgBefore
aPB.clearContents(); if let s = aSavedClip { aPB.setString(s, forType: .string) }
try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: aArgs[aArgs[1] == "copy" ? 2 : 4]))
exit(0)

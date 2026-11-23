
// ---- characterization driver (replaces the app launch lines) ----
// args: <input-dir> <ollama-base-url> <out.json>
let drvArgs = CommandLine.arguments
let drvApp = NSApplication.shared
let drvDelegate = AppDelegate()
let drvPB = NSPasteboard.general
let drvSavedClip = drvPB.string(forType: .string)
if ProcessInfo.processInfo.environment["DROP_CAREFUL"] == "1" { AcdSettings.setCareful(true) }
drvDelegate.config.provider = "ollama"
drvDelegate.config.ollamaBase = drvArgs[2]
drvDelegate.modelPopup.addItem(withTitle: "qwen-mock:1b")
drvDelegate.modelPopup.selectItem(at: 0)
drvPB.clearContents()   // start from an empty clipboard so runs that copy nothing compare equal
drvDelegate.handle([URL(fileURLWithPath: drvArgs[1])])
let drvDeadline = Date().addingTimeInterval(600)
while drvDelegate.running && Date() < drvDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let drvClip = drvPB.string(forType: .string) ?? ""
drvPB.clearContents()
if let s = drvSavedClip { drvPB.setString(s, forType: .string) }
let drvOut: [String: Any] = ["lastAnswer": drvDelegate.lastAnswer,
                             "status": drvDelegate.dropView.subtitle,
                             "clipboard": drvClip,
                             "stillRunning": drvDelegate.running]
let drvData = try! JSONSerialization.data(withJSONObject: drvOut, options: [.prettyPrinted, .sortedKeys])
try! drvData.write(to: URL(fileURLWithPath: drvArgs[3]))
exit(0)


// ---- benchmark end-to-end driver (replaces the app launch lines) ----
// args: <ollama-base-url>
let bApp = NSApplication.shared
var bCfg = DropConfig()
bCfg.provider = "ollama"
bCfg.ollamaBase = CommandLine.arguments[1]
Task { @MainActor in
    let tasks = BenchTask.loadAll()
    let infos = await BenchStore.ollamaInfo(base: bCfg.ollamaBase)
    let models = ["qwen-ref:1b", "qwen-mutant:1b", "qwen-broken:1b"].map { BenchModelRef(provider: "ollama", name: $0, info: infos[$0] ?? [:]) }
    let runner = BenchRunner(tasks: tasks, models: models, settings: BenchSettings(runId: "e2e", base: bCfg),
                             log: { print($0); fflush(stdout) })
    await runner.runAll()
    if let u = BenchReport.writeReport() { print("REPORT \(u.path)") }
    exit(0)
}
dispatchMain()


// ---- real-model benchmark driver: one model, the ACD mock task, real Ollama ----
// args: <ollama-base-url> <model-name> [task-id]
let rApp = NSApplication.shared
var rCfg = DropConfig()
rCfg.provider = "ollama"
rCfg.ollamaBase = CommandLine.arguments[1]
Task { @MainActor in
    let wantTask = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "acd-mock-ict"
    let tasks = BenchTask.loadAll().filter { $0.id == wantTask }
    let infos = await BenchStore.ollamaInfo(base: rCfg.ollamaBase)
    let name = CommandLine.arguments[2]
    let runner = BenchRunner(tasks: tasks, models: [BenchModelRef(provider: "ollama", name: name, info: infos[name] ?? [:])], settings: BenchSettings(runId: "real", base: rCfg, oopPerTask: ProcessInfo.processInfo.environment["DROP_OOP_PERTASK"] == "1", oopMode: ProcessInfo.processInfo.environment["DROP_OOP_MODE"] ?? "original"),
                             log: { print($0); fflush(stdout) })
    await runner.runAll()
    if let u = BenchReport.writeReport() { print("REPORT \(u.path)") }
    exit(0)
}
rApp.run()

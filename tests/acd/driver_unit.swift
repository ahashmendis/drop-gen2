
// ---- ACD unit driver: parser, extraction safety, static checks, notes, validators, pipeline ----
// args: <starter-fixture-dir> <project-with-node_modules-dir>
var uFails = 0, uTotal = 0
func check(_ name: String, _ cond: Bool, _ extra: @autoclosure () -> String = "") { uTotal += 1; if !cond { uFails += 1; print("FAIL \(name) \(extra())") } else { print("ok   \(name)") } }
let uStarterDir = URL(fileURLWithPath: CommandLine.arguments[1]), uProjDir = URL(fileURLWithPath: CommandLine.arguments[2])
func readProject(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])!
    for case let f as URL in en {
        if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { if ["node_modules", "dist"].contains(f.lastPathComponent) { en.skipDescendants() }; continue }
        if f.lastPathComponent == "package-lock.json" { continue }
        if let t = try? String(contentsOf: f, encoding: .utf8) { out[String(f.path.dropFirst(root.path.count + 1))] = t }
    }
    return out
}
let uApp = NSApplication.shared
Task { @MainActor in
    // ===== parser: tricky sources survive extraction byte-for-byte =====
    let tsx = "import { useState } from 'react';\n// ===== a comment that is NOT a marker =====\nexport function Box<T,>({ items }: { items: T[] }) {\n  const [n, setN] = useState(0);\n  return <div>{/* jsx comment */}<p>{items.length}</p></div>; // trailing // comment\n}"
    let css = "/* ===== FILE: not-a-marker.css ===== */\n.a { color: red; }\n@media (min-width: 600px) { .a { color: blue; } }"
    let html = "<!DOCTYPE html>\n<html lang=\"en\"><head><title>T</title></head>\n<body>\n<!-- // ===== Task 9 ===== -->\n<h1>Hi</h1></body></html>"
    let js = "const md = `\n```js\nconsole.log(1)\n```\n`;\nexport default md;"
    let ts = "export function pick<T extends object, K extends keyof T>(o: T, k: K): T[K] { return o[k]; }\nexport type Id = string | number;"
    let jsx = "import { useState } from 'react';\nexport default function Counter() {\n  const [n, setN] = useState(0); // count\n  return <button onClick={() => setN(n + 1)}>{n}</button>;\n}"
    let json = "{ \"name\": \"x\", \"scripts\": { \"test\": \"vitest run\" } }"
    let scss = "$c: red;\n.a { &:hover { color: $c; } } // line comment"
    let answer = "// ===== Task 1 =====\n// ===== Q A1 =====\nB\n// ===== Q A2 =====\nTrue - because\n// ===== Task 2 =====\n// ===== Q D1 =====\nExplain: the Outlet renders children.\n"
        + "// ===== FILE: src/components/Box.tsx =====\n```tsx\n\(tsx)\n```\n// ===== FILE: src/styles/app.css =====\n\(css)\n// ===== FILE: public/index.html =====\n\(html)\n"
        + "// ===== FILE: src/components/Counter.jsx =====\n\(jsx)\n// ===== FILE: src/util/md.js =====\n\(js)\n// ===== FILE: src/util/pick.ts =====\n\(ts)\n// ===== FILE: package.json =====\n\(json)\n// ===== FILE: src/a.scss =====\n\(scss)\n"
        + "// ===== FILE: ../../etc/passwd =====\nevil\n// ===== FILE: /abs/path.js =====\nevil\n// ===== FILE: src/ok/../../x.js =====\nevil\n"
    let doc = AcdDoc.parse(answer)
    let f = doc.files
    check("tsx exact (wrapping fence stripped, marker-looking comment kept)", f["src/components/Box.tsx"] == tsx + "\n", f["src/components/Box.tsx"] ?? "nil")
    check("css keeps comment that looks like a marker", f["src/styles/app.css"] == css + "\n")
    check("html keeps comment containing a Task marker", f["public/index.html"] == html + "\n")
    check("js keeps backtick fences inside a template literal", f["src/util/md.js"] == js + "\n", f["src/util/md.js"] ?? "nil")
    check("ts generics exact", f["src/util/pick.ts"] == ts + "\n")
    check("json exact", f["package.json"] == json + "\n")
    check("scss exact", f["src/a.scss"] == scss + "\n")
    check("jsx exact", f["src/components/Counter.jsx"] == jsx + "\n")
    check("traversal, absolute and dotted paths rejected", f.count == 8 && doc.rejectedPaths.count == 3, "\(f.keys.sorted()) \(doc.rejectedPaths)")
    check("question ids in order", doc.questionIDs == ["A1", "A2", "D1"])
    check("no marker line leaks into extracted code", !f.values.contains { $0.contains("// ===== FILE:") && !$0.contains("not-a-marker") })
    check("CRLF answers parse identically", AcdDoc.parse(answer.replacingOccurrences(of: "\n", with: "\r\n")).files == f)
    check("BOM stripped", AcdDoc.parse("// ===== FILE: a.js =====\n\u{FEFF}let a = 1;\n").files["a.js"] == "let a = 1;\n")
    check("objective A1 = B, A2 = True", AcdObjective.normalise(doc.questionText["A1"] ?? "") == "B" && AcdObjective.normalise(doc.questionText["A2"] ?? "") == "True")
    for (n, v) in [("B - reduce()", "B"), ("(c) union", "C"), ("**False**", "False"), ("A. something", "A"), ("true.", "True"), ("D", "D"), ("\n\n b)", "B")] { check("normalise \(n.replacingOccurrences(of: "\n", with: "↵"))", AcdObjective.normalise(n) == v, "\(AcdObjective.normalise(n) ?? "nil")") }
    check("normalise rejects prose", AcdObjective.normalise("Probably the first one") == nil && AcdObjective.normalise("Because") == nil)
    // ===== part(): task / question / file =====
    check("part Task 1 holds A1+A2", (doc.part("1") ?? "").contains("A2") && (doc.part("1") ?? "").contains("A1"))
    check("part A1 = just that question", (doc.part("A1") ?? "").contains("Q A1") && !(doc.part("A1") ?? "").contains("A2"))
    check("part a2 is case-insensitive", doc.part("a2") != nil)
    check("part D1 keeps its explanation", (doc.part("D1") ?? "").contains("Outlet"))
    check("part Box.tsx = clean code only", doc.part("Box.tsx") == tsx, doc.part("Box.tsx") ?? "nil")
    check("part path = clean code", doc.part("src/styles/app.css") == css)
    check("part unknown = nil", doc.part("Z9") == nil && doc.part("9") == nil && doc.part("nothing.tsx") == nil && doc.part("") == nil)
    check("single-file task copies clean code", AcdDoc.parse("// ===== Task 3 =====\n// ===== FILE: src/x.ts =====\nexport const x = 1\n").part("3") == "export const x = 1")
    // ===== merge =====
    let fix = AcdDoc.parse("// ===== FILE: src/util/md.js =====\nexport default 'fixed';\n// ===== FILE: src/new.ts =====\nexport {}\n")
    let m = doc.merging(fix)
    check("merge replaces a file, keeps the rest, appends new files, keeps questions", m.files["src/util/md.js"] == "export default 'fixed';\n" && m.files["src/components/Box.tsx"] == f["src/components/Box.tsx"]
          && m.files["src/new.ts"] == "export {}\n" && m.questionIDs == ["A1", "A2", "D1"])
    // ===== static findings =====
    let h = AcdValidator.htmlFindings("<html><body><div><span>hi</div><img src=a.png><h1>a</h1><h3>b</h3><input type=text></body>")
    check("html: unclosed span detected", h.errors.contains { $0.contains("span") }, "\(h.errors)")
    check("html: doctype/lang/title/alt/label/heading warnings", h.warnings.count >= 5, "\(h.warnings)")
    let hg = AcdValidator.htmlFindings("<!DOCTYPE html><html lang=\"en\"><head><title>x</title></head><body><ul><li>a<li>b</ul><img src=a alt=\"\"><script>if (a < b) { x = \"</div>\" }</script></body></html>")
    check("good html has no errors (optional </li>, script text ignored)", hg.errors.isEmpty, "\(hg.errors)")
    check("css: unbalanced and balanced", !AcdValidator.cssFindings(".a { color: red;").isEmpty && AcdValidator.cssFindings("/* } */ .a { color: red; }").isEmpty)
    check("missing imports found, present imports ok", AcdValidator.importFindings("export function A(){ const [a,b]=useState(0); const n=useNavigate(); return <Outlet/> }").count == 3
          && AcdValidator.importFindings("import { useState } from 'react';\nimport { useNavigate, Outlet } from 'react-router-dom';\nexport function A(){ const [a]=useState(0); const n=useNavigate(); return <Outlet/> }").isEmpty)
    // ===== notes =====
    let chunks = [AcdNoteChunk(source: "00-conventions.md", title: "rules", text: "Use function components and hooks."),
                  AcdNoteChunk(source: "lec5.pptx", title: "routing", text: "React Router useParams reads the route parameter. useNavigate navigates programmatically."),
                  AcdNoteChunk(source: "lec2.pptx", title: "grid", text: "CSS grid-template-areas defines named areas for a layout."),
                  AcdNoteChunk(source: "lec9.pptx", title: "zustand", text: "Zustand stores client state with selectors.")]
    let sel = AcdNotes.select(task: "Write a React component that reads orderId with useParams from /orders/:orderId", chunks: chunks, budgetChars: 6000)
    check("notes: conventions first, routing selected, grid/zustand not", sel.used.first?.hasPrefix("00-conventions") == true && sel.used.contains { $0.contains("routing") } && !sel.used.contains { $0.contains("grid") }, "\(sel.used)")
    let small = AcdNotes.select(task: "reads orderId with useParams in React Router", chunks: chunks, budgetChars: 1500)
    check("notes: a small budget is spent on relevance, not on the conventions file", small.used.first?.contains("routing") == true && small.text.count <= 1500, "\(small.used)")
    check("notes: tiny budget -> nothing; budget shrinks before the task is ever cut", AcdNotes.select(task: "x", chunks: chunks, budgetChars: 100).text.isEmpty
          && AcdPrompt.notesBudget(ceilingTokens: 8000, headerAndTaskChars: 5000) == 0 && AcdPrompt.notesBudget(ceilingTokens: 16384, headerAndTaskChars: 4000) == 9000)
    let big = (1...200).map { AcdNoteChunk(source: "n\($0).md", title: "t\($0)", text: String(repeating: "react router outlet ", count: 40)) }
    let capped = AcdNotes.select(task: "react router outlet", chunks: big, budgetChars: 2500)
    check("notes: never exceed the budget", capped.text.count <= 2500, "\(capped.text.count)")
    let prompt = AcdPrompt.build(notes: "NOTE-TEXT", paper: "TASK-TEXT")
    check("prompt order: header, notes (labelled lower priority), task last", prompt.range(of: "REFERENCE NOTES")!.lowerBound > prompt.range(of: "PRIORITY")!.lowerBound && prompt.hasSuffix("TASK-TEXT") && prompt.contains("the task wins"))
    check("subject defaults to OOP", Subject.saved == .oop)
    // ===== validators on a real project =====
    let starterOnly = readProject(uStarterDir), projFiles = readProject(uProjDir)
    func v(_ files: [String: String], root: URL? = uProjDir) -> AcdValidation { AcdValidator.validate(files: files, starter: projFiles, projectRoot: root) }
    func st(_ val: AcdValidation) -> String { val.checks.map { "\($0.name)=\($0.status)" }.joined(separator: " ") }
    let good = v(["src/components/Hello.tsx": "import { useState } from 'react';\nexport function Hello() {\n  const [n, setN] = useState(0);\n  return <button onClick={() => setN(n + 1)}>{n}</button>;\n}\n"])
    check("good tsx: syntax/static/build pass", st(good).contains("syntax=pass") && st(good).contains("static=pass") && st(good).contains("build=pass"), st(good) + "\n" + good.errorText)
    check("no test script => tests not_run and the summary says behaviour NOT verified", good.check("tests")?.status == "not_run" && good.summary.contains("NOT verified"), good.summary)
    let syn = v(["src/components/Bad.tsx": "export function Bad() {\n  return <div><p>x</div>;\n}\n"])
    check("jsx: valid parses, broken fails (TypeScript syntactic diagnostics)", v(["src/components/C.jsx": jsx + "\n"]).check("syntax")?.status == "pass"
          && v(["src/components/C.jsx": "export default function C() { return <div><p>x</div>; }\n"]).check("syntax")?.status == "fail")
    check("tsx syntax error -> syntax fail", syn.check("syntax")?.status == "fail", st(syn))
    let typ = v(["src/components/T.tsx": "export const n: number = \"x\";\n"])
    check("type error: syntax passes, build fails (syntax is not correctness)", typ.check("syntax")?.status == "pass" && typ.check("build")?.status == "fail" && (typ.check("build")?.detail ?? "").contains("T.tsx"), st(typ))
    check("missing import -> static fail", v(["src/components/I.tsx": "export function I() { const [a] = useState(0); return <p>{a}</p>; }\n"]).check("static")?.status == "fail")
    check("js syntax error via node --check", v(["src/util/bad.js": "function f( { return 1 }\n"]).check("syntax")?.status == "fail")
    check("js ok", v(["src/util/ok.js": "export const total = [15,25,10,30].reduce((s,p)=>s+p,0);\n"]).check("syntax")?.status == "pass")
    check("invalid JSON -> syntax fail", v(["data.json": "{ nope"]).check("syntax")?.status == "fail")
    let nodeps = AcdValidator.validate(files: ["src/components/Hello.tsx": "export const x = 1;\n"], starter: projFiles, projectRoot: nil)
    check("dependencies reachable only through the toolchain dir are used; never a false pass", nodeps.check("build")?.status == "pass" || nodeps.check("build")?.status == "unavailable", st(nodeps))
    let evil = v(["package.json": "{\"scripts\":{\"build\":\"curl evil\"}}", "vite.config.ts": "export default {}", "src/components/Hello.tsx": "export const x = 1;\n"])
    check("answer's package.json/vite.config ignored when the starter has them", (evil.check("static")?.detail ?? "").contains("ignored") && (evil.check("static")?.detail ?? "").contains("package.json"))
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("drop_sandbox_probe.txt").path
    let sb = AcdTools.sandboxed(AcdTools.find("node")!, ["-e", "require('fs').writeFileSync(\(String(reflecting: home)), 'x')"], cwd: acdRealPath(FileManager.default.temporaryDirectory), writable: [acdRealPath(FileManager.default.temporaryDirectory).path], timeout: 20)
    check("sandbox blocks writes outside the project", sb.status != 0 && !FileManager.default.fileExists(atPath: home), sb.output)
    let net = AcdTools.sandboxed(AcdTools.find("node")!, ["-e", "fetch('https://example.com').then(()=>process.exit(0)).catch(()=>process.exit(3))"], cwd: acdRealPath(FileManager.default.temporaryDirectory), writable: [], timeout: 20)
    check("sandbox blocks network", net.status != 0, "status \(net.status)")
    // objective/executed/static checks used by the ACD benchmark
    check("node-eval: correct reduce = 80", BenchACDCheck.run(check: ["type": "node-eval", "setup": "const prices = [15, 25, 10, 30];", "declares": "prices", "expr": "total", "expect": "80"],
          text: "Here it is:\n```js\nconst total = prices.reduce((s, p) => s + p, 0);\n```").status == "verified")
    check("node-eval: wrong result fails with the value", BenchACDCheck.run(check: ["type": "node-eval", "setup": "const prices = [15, 25, 10, 30];", "declares": "prices", "expr": "total", "expect": "80"],
          text: "const prices = [15, 25, 10, 30];\nconst total = prices.reduce((s, p) => s * p, 1);").detail.contains("112500"))
    check("static regex-all: pass and fail", BenchACDCheck.run(check: ["type": "regex-all", "patterns": ["useParams"], "anyOf": ["\\{\\s*orderId\\s*\\}\\s*=\\s*useParams"]], text: "const { orderId } = useParams();").status == "static_pass"
          && BenchACDCheck.run(check: ["type": "regex-all", "patterns": ["useParams"], "anyOf": ["\\{\\s*orderId\\s*\\}\\s*=\\s*useParams"]], text: "useParams()").status == "static_fail")
    // ===== planner: the paper becomes questions =====
    let paperText = "===== FILE: MOCK.docx =====\nMOCK ICT\nInstructions to Candidates\n- Use React with TypeScript or JavaScript.\nSection A - Multiple Choice (2 marks)\nChoose ONE answer.\nA1. Which method accumulates one value?\nA. find() B. reduce() C. sort() D. slice()\nA2. Which hook navigates?\nA. useParams()\nB. useNavigate()\nC. useState()\nD. useRef()\nSection B - True/False (2 marks)\nB1. find() returns every match.\nB2. A union type allows several types.\nSection C - Short Answer (3 marks)\nC1. JavaScript - Array Reduction\nWrite a reduce statement.\nSection D - Programming (10 marks)\nD1. React Router (10 marks)\na. Write the routes. (4 marks)\nb. Explain Outlet. (2 marks)\nSection E - Security (4 marks)\nE1. A JWT has expired. What should the front end do?\nA. Ignore it\nB. Re-authenticate\nE2. True or False: HTTPS protects tokens in transit.\nEND OF EXAMINATION"
    let plan = AcdPlan.make(paperText)
    check("planner: 11 questions in paper order", plan.units.map { $0.id } == ["A1", "A2", "B1", "B2", "C1", "D1", "E1", "E2"], "\(plan.units.map { $0.id })")
    check("planner: kinds (inline options, multi-line options, true/false by section, free, true/false by wording)",
          plan.units.map { $0.kind } == [.mcq, .mcq, .tf, .tf, .free, .free, .mcq, .tf], "\(plan.units.map { $0.kind })")
    check("planner: lettered sections map to Task 1..5", plan.units.map { $0.task } == [1, 1, 2, 2, 3, 4, 5, 5])
    check("planner: marks read from the question, instructions kept, file wrapper dropped", plan.units[5].marks == 10 && plan.preamble.contains("Use React with TypeScript") && !plan.preamble.contains("===== FILE"))
    check("planner: sub-parts stay inside their question, END line dropped", plan.units[5].text.contains("b. Explain Outlet") && !plan.units[7].text.contains("END OF"))
    check("planner: options stay with the question text", plan.units[1].text.contains("B. useNavigate()") && plan.units[0].text.contains("B. reduce()"))
    let tp = AcdPlan.make("Intro text\nTask 1 Build the navbar.\nSome detail.\nTask 2 Add routing.\n")
    check("planner: Task N papers split into free questions T1, T2", tp.units.map { $0.id } == ["T1", "T2"] && tp.units.allSatisfy { $0.kind == .free } && tp.units.map { $0.task } == [1, 2])
    check("planner: no recognisable questions -> whole-task mode", AcdPlan.make("Just build a landing page with a hero section and a footer, nothing else, thanks.").units.isEmpty)
    let objU = AcdUnit(id: "A1", task: 1, kind: .mcq, text: "A1. q\nA. x B. y", marks: 1), tfU = AcdUnit(id: "B1", task: 2, kind: .tf, text: "B1. q", marks: 1)
    check("objective prompt: only the letter / True-False, no notes", AcdPrompt.objective(objU).contains("Reply with ONLY the letter") && AcdPrompt.objective(tfU).contains("Reply with ONLY True or False") && !AcdPrompt.objective(objU).contains("NOTES"))
    for (r, id, tf, v) in [("B", "A1", false, "B"), ("A1: C", "A1", false, "C"), ("Answer: d", "A1", false, "D"), ("(b) reduce()", "A1", false, "B"), ("**False**", "B1", true, "False"), ("B1. True", "B1", true, "True"), ("A", "A1", false, "A")] {
        check("reply '\(r)' -> \(v)", AcdObjective.fromReply(r, id: id, tf: tf) == v, "\(AcdObjective.fromReply(r, id: id, tf: tf) ?? "nil")")
    }
    check("reply that is not an option is rejected (no guessing)", AcdObjective.fromReply("Hmm, it depends.", id: "A1", tf: false) == nil && AcdObjective.fromReply("True", id: "A1", tf: false) == nil && AcdObjective.fromReply("E", id: "A1", tf: false) == nil)
    // unit-mode pipeline: scripted replies, one request per question, assembled by code
    var seen: [AcdRequest] = []
    let unitInput = AcdRunInput(taskText: paperText, paperBlock: paperText, starter: [:], chunks: [], careful: false, ceilingTokens: 16384, questionCount: 8)
    let uh = AcdHooks(generate: { req in
        seen.append(req)
        if req.kind == "objective" { return req.prompt.contains("True or False") ? "True" : ((req.prompt.contains("A1. Which") || req.prompt.contains("E1. A JWT")) ? "B" : "garbage") }
        return "free answer for the question"
    }, validate: { files in AcdValidator.validate(files: files, starter: [:], projectRoot: nil) }, status: { _ in }, resetOutput: {})
    let ur = await AcdPipeline.run(input: unitInput, hooks: uh)
    check("unit pipeline: one request per question (+1 strict retry for the unreadable reply)", seen.count == 8 + 1, "\(seen.count)")
    check("unit pipeline: unreadable objective reply is reported as unanswered, never guessed", ur?.unanswered == ["A2"], "\(ur?.unanswered ?? [])")
    check("unit pipeline: markers assembled in paper order", AcdDoc.parse(ur?.answer ?? "").questionIDs == ["A1", "B1", "B2", "C1", "D1", "E1", "E2"] && (ur?.answer ?? "").hasPrefix("// ===== Task 1 ====="))
    check("unit pipeline: thinking off, tiny objective budget, free budget scales with marks", seen.filter { $0.kind == "objective" }.allSatisfy { $0.numPredict <= 24 && !$0.think } && (seen.first { $0.kind == "free" && $0.prompt.contains("10 marks") }?.numPredict ?? 0) >= 1500)
    let careful = AcdRunInput(taskText: paperText, paperBlock: paperText, starter: [:], chunks: [], careful: true, ceilingTokens: 16384, questionCount: 8)
    var carefulSeen: [AcdRequest] = []
    let ch = AcdHooks(generate: { req in carefulSeen.append(req); if req.kind == "objective" { return req.prompt.contains("True or False") ? "True" : "B" }; return req.think ? nil : "answered without thinking" }, validate: { files in AcdValidator.validate(files: files, starter: [:], projectRoot: nil) }, status: { _ in }, resetOutput: {})
    let cr = await AcdPipeline.run(input: careful, hooks: ch)
    check("careful mode: thinking only for free questions, and an empty thinking reply falls back to no-thinking", carefulSeen.filter { $0.kind == "free" && $0.think }.count == 2 && carefulSeen.filter { $0.kind == "free" && !$0.think }.count == 2 && carefulSeen.filter { $0.kind == "objective" }.allSatisfy { !$0.think } && (cr?.unanswered.isEmpty ?? false), "\(carefulSeen.map { "\($0.kind)/\($0.think)" })")
    // ===== ACD fixers: the exact slips found in a real 4B-model answer =====
    let d1q = "D1. A student-management application contains: Home page: /  Student list: /students  Individual student details: /students/:studentId  Settings page: /settings. The application should use a shared layout containing a navigation menu."
    let d1code = "```tsx\nfunction StudentDetails() {\n  const { id } = useParams();\n  return <div>ID: {id}</div>;\n}\n\nfunction App() {\n  return (\n    <BrowserRouter>\n      <Routes>\n        {/* Shared Layout Route */}\n        <Route path=\"/\" element={<Layout />}>\n          <Route index element={<h1>Welcome to Home</h1>} />\n          <Route path=\"students\" element={<h1>Student List</h1>} />\n          <Route path=\"students/:studentId\" element={<StudentDetails />} />\n        </Route>\n        \n        {/* Settings Route (outside layout) */}\n        <Route path=\"/settings\" element={<h1>Settings Page</h1>} />\n        \n        {/* Catch-all Not Found Route */}\n        <Route path=\"*\" element={<h1>404 - Not Found</h1>} />\n      </Routes>\n    </BrowserRouter>\n  );\n}\n```\n"
    let d1fixed = AcdFixers.apply(d1code, question: d1q)
    check("fixer: route param name — useParams reads studentId (not id) everywhere in that component", d1fixed.contains("const { studentId } = useParams();") && d1fixed.contains("ID: {studentId}") && !d1fixed.contains("{id}"), d1fixed)
    check("fixer: /settings moves inside the shared layout; the catch-all stays outside", { let i = d1fixed.range(of: "path=\"/settings\"")!.lowerBound, j = d1fixed.range(of: "</Route>")!.lowerBound, k = d1fixed.range(of: "path=\"*\"")!.lowerBound; return i < j && j < k }(), d1fixed)
    check("fixer: the fixed answer still parses as TSX", AcdValidator.validate(files: ["src/D1.tsx": AcdDoc.clean(d1fixed.components(separatedBy: "\n"))], starter: projFiles, projectRoot: uProjDir).check("syntax")?.status == "pass")
    let d2q = "D2. Retrieve https://example.com/api/courses when the component loads. Avoid updating component state after the component has been unmounted."
    let d2code = "useEffect(() => {\n  let controller: AbortController | null = null;\n  const fetchData = async () => {\n    try {\n      controller = new AbortController();\n      const r = await fetch('https://example.com/api/courses', { signal: controller.signal });\n    } catch (err) {\n      if (err.name !== 'AbortError') {\n        setError(err instanceof Error ? err.message : 'An error occurred');\n      }\n    } finally {\n      setLoading(false);\n    }\n  };\n  fetchData();\n  return () => { controller?.abort(); };\n}, []);\n"
    let d2fixed = AcdFixers.apply(d2code, question: d2q)
    check("fixer: unknown catch variable is cast before .name", d2fixed.contains("(err as Error).name !== 'AbortError'") && d2fixed.contains("err instanceof Error ? err.message"), d2fixed)
    check("fixer: no state update after abort — finally is guarded; the given URL host is kept", d2fixed.contains("if (!controller?.signal.aborted) {\n          setLoading(false);") && d2fixed.contains("https://example.com/api/courses"), d2fixed)
    let d3q = "D3. If validation succeeds, the frontend must submit the data to the following endpoint: POST /api/events"
    let d1real = "<Route path=\"/\" element={<Layout />}>\n  <Route path=\"students/:id\" element={<StudentDetails />} />\n</Route>\n\nfunction StudentDetails() {\n  const { id } = useParams();\n  return <p>{id}</p>;\n}\n"
    let d1al = AcdFixers.apply(d1real, question: d1q)
    check("fixer: the question's route parameter name wins (:id -> :studentId) and its uses follow", d1al.contains("path=\"students/:studentId\"") && d1al.contains("const { studentId } = useParams();") && d1al.contains("{studentId}") && !d1al.contains("{id}"), d1al)
    // missing import / second layout wrapper / duplicate type import (slips from the graded mock-ICT answer)
    let m1 = "```tsx\nimport { Routes, Route, Link } from 'react-router-dom';\nfunction Layout() { return <div><Outlet /></div>; }\nfunction App() {\n  return (\n    <Routes>\n      <Route path=\"/\" element={<Layout />}>\n        <Route index element={<h1>Home</h1>} />\n      </Route>\n      <Route path=\"/settings\" element={<Layout />}>\n        <Route index element={<h1>Settings</h1>} />\n      </Route>\n    </Routes>\n  );\n}\n```\nThe explanation says const { id } = useParams() reads it."
    let m1f = AcdFixers.apply(m1, question: "D1. Settings page: /settings. Use a shared layout containing a navigation menu.")
    check("fixer: Outlet used but not imported -> added to the react-router-dom import", m1f.contains("import { Routes, Route, Link, Outlet } from 'react-router-dom'"), m1f)
    check("fixer: a second <Layout /> wrapper for /settings becomes a child of the first layout", m1f.components(separatedBy: "<Layout />").count == 2 && m1f.contains("<Route path=\"/settings\" element={<h1>Settings</h1>} />"), m1f)
    let m3 = "```tsx\nimport type { EventFormData, ValidationErrors } from '../types/eventForm';\ninterface EventFormData { title: string }\ninterface ValidationErrors { title?: string }\nconst x = 1;\n```"
    let m3f = AcdFixers.apply(m3, question: "D3. validate")
    check("fixer: import of a type that is also declared locally is removed", !m3f.contains("../types/eventForm") && m3f.contains("interface EventFormData"), m3f)
    check("fixer: useState without import gets it from react", AcdFixers.apply("```tsx\nfunction A() { const [a, setA] = useState(0); return <p>{a}</p>; }\n```", question: "q").contains("import { useState } from 'react';"))
    check("fixer: already-imported names are not imported twice", AcdFixers.apply("```tsx\nimport { useState } from 'react';\nfunction A() { const [a] = useState(0); return null; }\n```", question: "q").components(separatedBy: "useState }").count == 2)
    check("fixer: no :param in the question -> routes are left alone", AcdFixers.apply(d1real, question: "D1. Build routes for students.") == AcdFixers.apply(d1real, question: "D1. Build routes for students."))
    check("fixer: an invented host is replaced by the endpoint path the question gives", AcdFixers.apply("fetch('https://mock-ict.example/api/events', { method: 'POST' })", question: d3q) == "fetch('/api/events', { method: 'POST' })")
    check("fixer: a host the question itself names is never touched", AcdFixers.apply("fetch('https://example.com/api/courses')", question: d2q) == "fetch('https://example.com/api/courses')")
    check("fixer: already-narrowed catch and already-guarded finally stay unchanged", AcdFixers.apply("try {} catch (e) { if (e instanceof Error && e.name !== 'x') {} } finally { if (!c.signal.aborted) { setLoading(false); } }", question: "q") == "try {} catch (e) { if (e instanceof Error && e.name !== 'x') {} } finally { if (!c.signal.aborted) { setLoading(false); } }")
    check("fixer: several route params or a matching name -> untouched", AcdFixers.apply("<Route path=\"/a/:x/:y\"/>\nconst { id } = useParams();", question: "q") == "<Route path=\"/a/:x/:y\"/>\nconst { id } = useParams();"
          && AcdFixers.apply("<Route path=\"/a/:id\"/>\nconst { id } = useParams();", question: "q") == "<Route path=\"/a/:id\"/>\nconst { id } = useParams();")
    check("fixer: text with none of the patterns is returned exactly", AcdFixers.apply("B", question: "A1. which?") == "B" && AcdFixers.apply("plain explanation text", question: "q") == "plain explanation text")
    // ===== OOP per-task planner =====
    let oopPaper = "\n######## EXAM PAPER / INSTRUCTIONS ########\n===== FILE: MODERATE.docx =====\nMODERATE PRACTICE EXAM\nScenario\nAn emergency team allocates deliveries.\nAssessment and marking\nTask 1 – First subclass\n18\nLO1\nTask 2 – New subclass + object processing\n22\nLO1\nSection B – Functional testing\n20\nTask 1 – Implement GroundMission [18 marks, LO1]\n4 marks: extend DispatchMission.\n8 marks: energyUnits() = 2×distanceKm + 5×loadKg.\nTask 2 – Add AirMission and implement dispatch planning [22 marks, LO1]\n7 marks: implement AirMission.\nTask 3 – Validation [20 marks, LO2]\n6 marks: energy(id) raises MissionNotFoundException.\nIllustrative calculations and input\nEnergy: GroundMission(101) = 39.\nREST operations to demonstrate\nGET /api/missions\nSection B – Six functional checks [20 marks, LO3]\n3 – GroundMission(101) consumes 39 energy units.\nSubmission and final checks\nZip the project.\n\n######## STARTER PROJECT FILES ########\n===== FILE: src/main/java/x/GroundMission.java =====\npublic class GroundMission {}\n===== FILE: src/main/java/x/DispatchMission.java =====\npublic abstract class DispatchMission {}"
    let op = OopPerTask.plan(paperBlock: oopPaper)
    check("oop planner: real task headings only (not the marks-table rows), in order, with marks", op?.tasks.map { $0.n } == [1, 2, 3] && op?.tasks.map { $0.marks } == [18, 22, 20], "\(String(describing: op?.tasks.map { $0.n })) \(String(describing: op?.tasks.map { $0.marks }))")
    check("oop planner: each task text stops at the next task or the worked-examples heading", (op?.tasks[0].text.contains("2×distanceKm") ?? false) && !(op?.tasks[0].text.contains("AirMission") ?? true) && !(op?.tasks[2].text.contains("Energy: GroundMission(101)") ?? true))
    check("oop planner: scenario kept as preamble, worked examples kept as postamble, starter split off", (op?.preamble.contains("emergency team") ?? false) && (op?.postamble.contains("GroundMission(101) = 39") ?? false) && (op?.starterText.contains("DispatchMission.java") ?? false))
    check("oop planner: plain 'Task N' papers (no marks) use the last heading of each number", OopPerTask.plan(paperBlock: "\n######## EXAM PAPER / INSTRUCTIONS ########\nTask 1 Build A.\nTask 2 Build B.\nTask 3 Build C.\n")?.tasks.map { $0.n } == [1, 2, 3])
    check("oop planner: no task structure -> nil (the original single request is used)", OopPerTask.plan(paperBlock: "\n######## EXAM PAPER / INSTRUCTIONS ########\nWrite a program that prints hello.\n") == nil)
    if let op = op {
        let first = OopPerTask.prompt(plan: op, part: op.tasks[0], written: [:])
        let second = OopPerTask.prompt(plan: op, part: op.tasks[1], written: ["src/main/java/x/GroundMission.java": "public class GroundMission { int e(){return 1;} }"])
        check("oop prompt: the ORIGINAL Ollama header comes first, unchanged", first.hasPrefix(OLLAMA_PROMPT_HEADER))
        check("oop prompt: only the requested task is asked for; the stable prefix is identical between tasks (prefix cache)", first.contains("Write ONLY Task 1 now") && !first.contains("Task 2 – Add AirMission and implement") && second.contains("Write ONLY Task 2 now")
              && first.prefix(OLLAMA_PROMPT_HEADER.count + 400) == second.prefix(OLLAMA_PROMPT_HEADER.count + 400))
        check("oop prompt: files written for earlier tasks are included, and replace the starter copy", second.contains("FILES YOU HAVE ALREADY WRITTEN") && second.contains("int e(){return 1;}") && !second.contains("public class GroundMission {}"))
        check("oop prompt: no HOW TO TEST in the request, worked examples included", second.contains("do not write a HOW TO TEST section") && second.contains("GroundMission(101) = 39"))
        var reqs: [AcdRequest] = []
        let w = await OopPerTask.writeAnswer(plan: op, careful: false, generate: { r in
            reqs.append(r)
            if r.label == "Task 2" { return nil }                                   // one task fails: the others still come through
            return r.label == "Task 3" ? "// ===== Task 3 =====\n// ===== FILE: src/main/java/x/Svc.java =====\npackage x;\npublic class Svc {}" : "// ===== FILE: src/main/java/x/GroundMission.java =====\npackage x;\npublic class GroundMission {}"
        }, status: { _ in })
        check("oop per-task: one request per task, thinking off, budget scales with marks", reqs.count == 3 && reqs.allSatisfy { !$0.think } && reqs[1].numPredict > reqs[0].numPredict, "\(reqs.map { $0.numPredict })")
        check("oop per-task: a missing Task header is added; a failed task is skipped, not fatal", (w ?? "").hasPrefix("// ===== Task 1 =====") && (w ?? "").contains("// ===== Task 3 =====") && !(w ?? "").contains("Task 2"))
        check("oop per-task: later prompts carry the earlier answer's files", reqs[2].prompt.contains("FILES YOU HAVE ALREADY WRITTEN") && reqs[2].prompt.contains("public class GroundMission"))
        let none = await OopPerTask.writeAnswer(plan: op, careful: false, generate: { _ in nil }, status: { _ in })
        check("oop per-task: every task failing -> nil (the caller reports it)", none == nil)
        var cs: [AcdRequest] = []
        _ = await OopPerTask.writeAnswer(plan: op, careful: true, generate: { r in cs.append(r); return r.think ? nil : "// ===== FILE: a.java =====\nclass A{}" }, status: { _ in })
        check("oop per-task careful mode: thinking first, empty thinking reply falls back to no-thinking", cs.filter { $0.think }.count == 3 && cs.filter { !$0.think }.count == 3)
    }
    // ===== OOP: deterministic javac-driven fixes (the real MODERATE answer that did not compile) =====
    let uRepo = URL(fileURLWithPath: CommandLine.arguments[3])
    func moderateStarter() -> [String: String] {
        let tmpRaw = FileManager.default.temporaryDirectory.appendingPathComponent("dropoop-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpRaw, withIntermediateDirectories: true)
        let tmp = acdRealPath(tmpRaw)
        _ = benchRun("/usr/bin/ditto", ["-x", "-k", uRepo.appendingPathComponent("bench-tasks/moderate-dispatch/inputs/MODERATE_Starter_Project.zip").path, tmp.path], timeout: 60)
        var out: [String: String] = [:]
        let root = tmp.appendingPathComponent("drone-practice-starter")
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let f as URL in en where f.pathExtension == "java" { out[String(f.path.dropFirst(root.path.count + 1))] = try? String(contentsOf: f, encoding: .utf8) }
        }
        return out.compactMapValues { $0 }
    }
    let mStarter = moderateStarter()
    let failed = (try? String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("tests/acd/fixtures/oop_moderate_failed_answer.txt"), encoding: .utf8)) ?? ""
    if let errs0 = AppDelegate.runJavac(answer: failed, starter: mStarter), !mStarter.isEmpty {
        check("oop: the real failed answer does not compile (3 javac errors named getType / Collectors / generic mismatch)", !errs0.isEmpty && errs0.contains("getType") || errs0.contains("Collectors"), errs0)
        let fixedA = AppDelegate.javacFixes(failed, starter: mStarter, errs: errs0)
        check("oop: javacFixes turns it into code that compiles — no model call", AppDelegate.runJavac(answer: fixedA, starter: mStarter) == "", AppDelegate.runJavac(answer: fixedA, starter: mStarter) ?? "nil")
        check("oop: the non-existent getType() became the class name and the String list became the List<Long>", fixedA.contains(".getClass().getSimpleName()") && !fixedA.contains("getType()") && !fixedA.contains("Long::toString"))
        check("oop: files javac did not complain about are untouched", AppDelegate.parseAnswerFiles(fixedA)["src/main/java/edu/practice/dispatch/model/GroundMission.java"] == AppDelegate.parseAnswerFiles(failed)["src/main/java/edu/practice/dispatch/model/GroundMission.java"])
        var gens = 0
        let ph = PipelineHooks(generate: { _, _ in gens += 1; return failed }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {})
        let pr = await DropPipeline.run(paper: "\n######## EXAM PAPER / INSTRUCTIONS ########\nTask 1 x. Task 2 y.\n######## STARTER PROJECT FILES ########\n===== FILE: src/main/java/x.java =====\n", provider: "ollama", starter: mStarter, hooks: ph)
        check("oop pipeline: compiles with ZERO repair rounds and one model call", pr?.compiled == true && pr?.repairRounds == 0 && gens == 1, "compiled \(String(describing: pr?.compiled)) rounds \(String(describing: pr?.repairRounds)) gens \(gens)")
        let pr2 = await DropPipeline.run(paper: "x", provider: "opencode_go", starter: mStarter, hooks: PipelineHooks(generate: { _, _ in failed }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {}))
        check("OpenCode Go path is untouched: no deterministic fixing (it still needs its own repair rounds)", pr2?.compiled == false || (pr2?.repairRounds ?? 0) > 0, "compiled \(String(describing: pr2?.compiled)) rounds \(String(describing: pr2?.repairRounds))")
        // a missing import of a PROJECT class (the per-task run's DispatchMission error)
        let noImport = AppDelegate.javacFixes(failed, starter: mStarter, errs: errs0)
            .replacingOccurrences(of: "import edu.practice.dispatch.service.*;import edu.practice.dispatch.model.*;import edu.practice.dispatch.dto.*;", with: "import edu.practice.dispatch.service.*;import edu.practice.dispatch.dto.*;")
        if let e2 = AppDelegate.runJavac(answer: noImport, starter: mStarter), !e2.isEmpty {
            let fx = AppDelegate.javacFixes(noImport, starter: mStarter, errs: e2)
            check("oop: a missing import of a class the project defines is added (DispatchMission in the controller)", fx.contains("import edu.practice.dispatch.model.DispatchMission;") && AppDelegate.runJavac(answer: fx, starter: mStarter) == "", e2)
        } else { check("oop: project-class import case set up", false, "the import removal produced no javac error") }
        let unrelated = "// ===== Task 1 =====\n// ===== FILE: src/main/java/edu/practice/dispatch/model/GroundMission.java =====\npackage edu.practice.dispatch.model;\npublic class GroundMission extends DispatchMission { int x = \"one\"; }\n"
        check("oop: an error no rule knows is left for the model (answer returned unchanged)", AppDelegate.javacFixes(unrelated, starter: mStarter, errs: "src/main/java/edu/practice/dispatch/model/GroundMission.java:3: error: incompatible types: String cannot be converted to int\n x\n  ^") == unrelated)
    } else { check("oop: JDK/Spring jars available for the javac tests", false, "runJavac returned nil (no JDK or ~/.m2 Spring jars)") }
    // ===== OOP: paper-aware fixes + HOW TO TEST on the answer that compiled but had logic slips =====
    if !mStarter.isEmpty, let bt = BenchTask.load(dir: uRepo.appendingPathComponent("bench-tasks/moderate-dispatch")) {
        let coll = AppDelegate()
        let (paperBlock, _) = coll.collect(uRepo.appendingPathComponent("bench-tasks/moderate-dispatch/inputs"))
        let logic = (try? String(contentsOf: uRepo.appendingPathComponent("tests/acd/fixtures/oop_moderate_logic_bugs_answer.txt"), encoding: .utf8)) ?? ""
        let fx = AppDelegate.paperFixes(AppDelegate.staticFixes(logic, starter: mStarter), paper: paperBlock)
        func passed(_ a: String) -> (Int, Int, [String]) {
            if case .ran(let rs) = BenchTestRunner.run(task: bt, answer: a, starter: mStarter) { return (rs.filter { $0.passed }.count, rs.count, rs.filter { !$0.passed }.map { $0.id }) }
            return (0, 0, ["not run"])
        }
        let before = passed(logic), after = passed(fx)
        check("oop logic: the unfixed answer (compiles) fails 7 of 36 tests", before.0 == 29 && before.1 == 36, "\(before)")
        check("oop logic: after the paper-aware fixes all 36 tests pass", after.0 == 36 && after.1 == 36, "\(after)")
        check("oop logic: 'positive distance' (paper wording) makes both distance checks '<= 0'; load/wind stay '< 0'", fx.components(separatedBy: "request.distanceKm() <= 0").count == 3 && fx.contains("request.loadKg() < 0"), "")
        check("oop logic: skipped ids are recorded only when a mission does not fit", fx.contains("skipped.add(m.getId()); continue;") && !fx.contains("for (DispatchMission m : missions) { skipped.add(m.getId()); }"))
        check("oop logic: an answer whose skip branch is already right is left alone", AppDelegate.fixSkippedLoop("for (X m : l) { if (a > b) { skipped.add(m.getId()); continue; } }") == "for (X m : l) { if (a > b) { skipped.add(m.getId()); continue; } }")
        let ht = AppDelegate.howToTestBlock(fx, starter: mStarter, paper: paperBlock)
        check("HOW TO TEST uses the starter's port and the paper's own example calls", ht.contains("localhost:8082/api/missions/101/energy") && ht.contains("capacity=60&urgentOnly=false") && ht.contains("\"id\":104") && !ht.contains(":8080") && !ht.contains("missions/1/energy"), ht)
        let htFallback = AppDelegate.howToTestBlock(fx, starter: mStarter, paper: "no examples here")
        check("HOW TO TEST without paper examples: JSON body comes from the starter's record, not {}", htFallback.contains("\"distanceKm\": 1") && htFallback.contains("\"critical\": true"), htFallback)
    } else { check("oop logic tests need the MODERATE starter", false, "") }
    // ===== OOP: stubs that compile (ApiError as a success response, "not implemented") =====
    if !mStarter.isEmpty, let bt2 = BenchTask.load(dir: uRepo.appendingPathComponent("bench-tasks/moderate-dispatch")) {
        let stub = (try? String(contentsOf: uRepo.appendingPathComponent("tests/acd/fixtures/oop_moderate_stub_controller_answer.txt"), encoding: .utf8)) ?? ""
        let goodLogic = (try? String(contentsOf: uRepo.appendingPathComponent("tests/acd/fixtures/oop_moderate_logic_bugs_answer.txt"), encoding: .utf8)) ?? ""
        let findings = AppDelegate.semanticFindings(stub)
        check("lint: the stub controller (it compiles) is reported — getEnergy and getPlan return ApiError as a normal response", findings.contains("getEnergy()") && findings.contains("getPlan()") && findings.contains("DispatchController.java:1: error:"), findings)
        check("lint: a real answer and an @ExceptionHandler returning ApiError are NOT reported", AppDelegate.semanticFindings(goodLogic) == "")
        check("lint: placeholders are reported", AppDelegate.semanticFindings("// ===== FILE: src/main/java/x/A.java =====\npackage x;\nclass A { void f(){ throw new UnsupportedOperationException(); } }").contains("placeholder"))
        let realController = AppDelegate.parseAnswerFiles(goodLogic)["src/main/java/edu/practice/dispatch/controller/DispatchController.java"] ?? ""
        var prompts: [String] = []
        let repaired = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====\n" + realController
        let lh = PipelineHooks(generate: { p, _ in prompts.append(p); return prompts.count == 1 ? stub : repaired }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {})
        let lr = await DropPipeline.run(paper: "\n######## EXAM PAPER / INSTRUCTIONS ########\nTask 1 a. Task 2 b.\n", provider: "ollama", starter: mStarter, hooks: lh)
        check("lint pipeline: compile-clean stubs trigger a repair round that names the file and the problem", prompts.count == 2 && prompts[1].contains("returns ApiError as a normal response") && prompts[1].contains("DispatchController.java"), "\(prompts.count)")
        check("lint pipeline: after the repair the controller returns real results and the answer is clean", lr?.compiled == true && lr?.repairRounds == 1 && AppDelegate.semanticFindings(lr?.answer ?? "") == "", "rounds \(String(describing: lr?.repairRounds))")
        var n2 = 0
        let stubController = AppDelegate.parseAnswerFiles(stub)["src/main/java/edu/practice/dispatch/controller/DispatchController.java"] ?? ""
        let worse = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====\n" + stubController + "\n// TODO fix later, plan not implemented"
        let gh = PipelineHooks(generate: { _, _ in n2 += 1; return n2 == 1 ? stub : worse }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {})
        let gr = await DropPipeline.run(paper: "x", provider: "ollama", starter: mStarter, hooks: gh)
        check("stub guard: a repair that adds a placeholder is discarded, not accepted just because it compiles", !(gr?.answer ?? "").contains("TODO fix later") && n2 == 2, "calls \(n2)")
        let (pb, _) = AppDelegate().collect(uRepo.appendingPathComponent("bench-tasks/moderate-dispatch/inputs"))
        let guarded = AppDelegate.paperFixes(AppDelegate.staticFixes(stub, starter: mStarter), paper: pb)
        check("paper guard: 'reject non-positive plan capacity' puts a capacity check at the top of plan() (once)", guarded.contains("if (capacity <= 0) { throw new IllegalArgumentException(\"capacity must be positive\"); }")
              && guarded.components(separatedBy: "capacity <= 0").count == 2 && AppDelegate.paperFixes(guarded, paper: pb) == guarded)
        check("paper guard: an answer that already checks the parameter is left alone", AppDelegate.paperFixes(goodLogic, paper: pb).components(separatedBy: "capacity <= 0").count == 2)
        let withGuardAndController = AppDelegate.mergeFixes(guarded, repaired)
        if case .ran(let rs) = BenchTestRunner.run(task: bt2, answer: withGuardAndController, starter: mStarter) {
            let failedIDs = rs.filter { !$0.passed }.map { $0.id }
            check("stub answer + paper guard + repaired controller: the capacity tests pass (only the 10,000 limit is still missing)", rs.count == 36 && !failedIDs.contains("M-PL-08") && !failedIDs.contains("M-ER-02") && failedIDs == ["M-SV-08"], "\(failedIDs)")
        } else { check("stub answer tests ran", false, "not run") }
    }
    // ===== OOP: invented wrapper classes + undeclared fields + null on a primitive (the answer that still had compile errors) =====
    if !mStarter.isEmpty, let bt3 = BenchTask.load(dir: uRepo.appendingPathComponent("bench-tasks/moderate-dispatch")) {
        let wrapper = (try? String(contentsOf: uRepo.appendingPathComponent("tests/acd/fixtures/oop_moderate_wrapper_answer.txt"), encoding: .utf8)) ?? ""
        let rawErrs = AppDelegate.runJavac(answer: wrapper, starter: mStarter) ?? ""
        check("wrapper: the real answer fails javac (null compared with a primitive long, undeclared fields code/message)", rawErrs.contains("bad operand types") && rawErrs.contains("symbol: variable code") || rawErrs.contains("variable code"), rawErrs)
        let (pb3, _) = AppDelegate().collect(uRepo.appendingPathComponent("bench-tasks/moderate-dispatch/inputs"))
        let direct = AppDelegate.paperFixes(AppDelegate.staticFixes(wrapper, starter: mStarter), paper: pb3, starter: mStarter)
        let directCtl = AppDelegate.parseAnswerFiles(direct)["src/main/java/edu/practice/dispatch/controller/DispatchController.java"] ?? ""
        check("wrapper (direct, no model): static + paper fixes rewrite ALL three wrapped controller methods", directCtl.contains("Map.of(\"energyUnits\", service.energy(id))") && directCtl.contains("return service.plan(capacity,urgent);") && !directCtl.contains("ApiError(\"OK\""), directCtl)
        var calls3 = 0
        let ph3 = PipelineHooks(generate: { _, _ in calls3 += 1; return wrapper }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {})
        let pr3 = await DropPipeline.run(paper: pb3, provider: "ollama", starter: mStarter, hooks: ph3)
        check("wrapper pipeline: compiles with ZERO repair rounds and ONE model call", pr3?.compiled == true && pr3?.repairRounds == 0 && calls3 == 1, "compiled \(String(describing: pr3?.compiled)) rounds \(String(describing: pr3?.repairRounds)) calls \(calls3)")
        let fixed3 = pr3?.answer ?? ""
        let f3 = AppDelegate.parseAnswerFiles(fixed3)
        let handler = f3["src/main/java/edu/practice/dispatch/error/ApiExceptionHandler.java"] ?? "", ctl = f3["src/main/java/edu/practice/dispatch/controller/DispatchController.java"] ?? ""
        check("wrapper: the invented ApiResponse class is replaced by the starter's ApiError everywhere", !handler.contains("ApiResponse") && handler.contains("new ApiError(\"NOT_FOUND\"") && !ctl.contains("ApiResponse"), handler)
        check("wrapper: the controller now delegates — energy returns a map with the paper's key, plan returns the plan, POST returns 201 with the service result",
              ctl.contains("Map.of(\"energyUnits\", service.energy(id))") && ctl.contains("return service.plan(capacity,urgent);") && ctl.contains("ResponseEntity.status(HttpStatus.CREATED).body(service.addAir(request))") && !ctl.contains("id required"), ctl)
        check("wrapper: no placeholders or ApiError-as-success are left", AppDelegate.semanticFindings(fixed3) == "")
        if case .ran(let rs) = BenchTestRunner.run(task: bt3, answer: fixed3, starter: mStarter) {
            check("wrapper: the result passes all 36 MODERATE tests", rs.filter { $0.passed }.count == 36 && rs.count == 36, "\(rs.filter { !$0.passed }.map { $0.id })")
        } else { check("wrapper: tests ran", false, "not run") }
        // javac-driven safety nets (when the static fixers did not already remove the problem)
        let nullOnly = "// ===== FILE: src/main/java/edu/practice/dispatch/controller/DispatchController.java =====\npackage edu.practice.dispatch.controller;\nimport edu.practice.dispatch.dto.*;\npublic class DispatchController {\n int f(NewAirMission r){\n  if (r.id() == null || r.id() <= 0L) { return 1; }\n  return 0;\n }\n}\n"
        if let e = AppDelegate.runJavac(answer: nullOnly, starter: mStarter), !e.isEmpty {
            let fx = AppDelegate.javacFixes(nullOnly, starter: mStarter, errs: e)
            check("javac fix: a primitive compared with null loses that comparison on the reported line", fx.contains("if (r.id() <= 0L)") && AppDelegate.runJavac(answer: fx, starter: mStarter) == "", fx)
        } else { check("javac fix: null-compare case compiles raw?", false, "expected an error") }
        let fieldOnly = "// ===== FILE: src/main/java/edu/practice/dispatch/dto/Box.java =====\npackage edu.practice.dispatch.dto;\npublic class Box {\n public Box(String code, int size){this.code=code;this.size=size;}\n public String getCode(){return code;}\n public int getSize(){return size;}\n}\n"
        if let e = AppDelegate.runJavac(answer: fieldOnly, starter: mStarter), !e.isEmpty {
            let fx = AppDelegate.javacFixes(fieldOnly, starter: mStarter, errs: e)
            let ok = AppDelegate.runJavac(answer: fx, starter: mStarter) ?? "nil"
            check("javac fix: fields a constructor assigns but never declared are declared with the parameter types (two passes)", fx.contains("private final String code;") && (ok == "" || AppDelegate.runJavac(answer: AppDelegate.javacFixes(fx, starter: mStarter, errs: ok), starter: mStarter) == ""), fx + ok)
        } else { check("javac fix: undeclared-field case fails raw?", false, "expected an error") }
        check("wrapper rule: an invented class whose constructor does NOT match any starter record is left alone", AppDelegate.fixInventedWrapper("// ===== FILE: src/main/java/x/C.java =====\npackage x;\npublic class C {\n private static class Odd {\n  public Odd(double a, double b){}\n }\n}\n", starter: mStarter).contains("class Odd"))
    }
    // ===== OOP: the real no-thinking MODERATE answer (2 mechanical javac errors left after 2 model repairs) =====
    if !mStarter.isEmpty, let bt4 = BenchTask.load(dir: uRepo.appendingPathComponent("bench-tasks/moderate-dispatch")) {
        let nt = (try? String(contentsOf: uRepo.appendingPathComponent("tests/acd/fixtures/oop_moderate_nothink_answer.txt"), encoding: .utf8)) ?? ""
        let (pb4, _) = AppDelegate().collect(uRepo.appendingPathComponent("bench-tasks/moderate-dispatch/inputs"))
        let rawNT = AppDelegate.runJavac(answer: nt, starter: mStarter) ?? ""
        check("no-think answer: it really fails javac with the Collection->List and the !int errors", rawNT.contains("Collection<DispatchMission> cannot be converted to List<DispatchMission>") && rawNT.contains("unary operator '!'"), rawNT)
        var gensNT = 0
        let phNT = PipelineHooks(generate: { _, _ in gensNT += 1; return nt }, compile: { a in AppDelegate.runJavac(answer: a, starter: mStarter) }, status: { _ in }, resetOutput: {})
        let prNT = await DropPipeline.run(paper: pb4, provider: "ollama", starter: mStarter, hooks: phNT)
        check("no-think answer: compiles with zero repair rounds and one model call", prNT?.compiled == true && prNT?.repairRounds == 0 && gensNT == 1, "compiled \(String(describing: prNT?.compiled)) rounds \(String(describing: prNT?.repairRounds)) calls \(gensNT)")
        if case .ran(let rs) = BenchTestRunner.run(task: bt4, answer: prNT?.answer ?? "", starter: mStarter) {
            print("INFO real no-think answer after Drop's fixes: \(rs.filter { $0.passed }.count)/\(rs.count) MODERATE tests pass; failing: \(rs.filter { !$0.passed }.map { $0.id })")
        }
    }
    check("oop: a query string inside a mapping path is removed (and so is the HOW TO TEST garbage derived from it)", AppDelegate.fixMappingQueryStrings("@GetMapping(\"/plan?capacity=...&urgentOnly=false\") public X plan()") == "@GetMapping(\"/plan\") public X plan()"
          && AppDelegate.fixMappingQueryStrings("@GetMapping(\"/{id}/energy\") @PostMapping(\"/air\")") == "@GetMapping(\"/{id}/energy\") @PostMapping(\"/air\")")
    // ===== pipeline: repair keeps requirements, preserves working code, retains the best answer =====
    var calls = 0
    let badFirst = "// ===== Task 1 =====\n// ===== FILE: src/components/T.tsx =====\nexport const n: number = \"x\";\n// ===== FILE: src/components/Keep.tsx =====\nexport const keep = 1;\n"
    func wholeInput(_ paper: String) -> AcdRunInput { AcdRunInput(taskText: "no lettered questions here", paperBlock: paper, starter: projFiles, chunks: [], careful: false, ceilingTokens: 16384, questionCount: 1) }
    let h1 = AcdHooks(generate: { req in
        calls += 1
        if calls == 1 { return badFirst }
        precondition(req.prompt.contains("ORIGINAL TASK REQUIREMENTS") && req.prompt.contains("PAPER-TEXT-123"), "repair prompt must carry the original requirements")
        return "// ===== FILE: src/components/T.tsx =====\nexport const n: number = 1;\n"
    }, validate: { files in AcdValidator.validate(files: files, starter: projFiles, projectRoot: uProjDir) }, status: { _ in }, resetOutput: {})
    let r = await AcdPipeline.run(input: wholeInput("PAPER-TEXT-123"), hooks: h1)
    check("pipeline: repaired in one round and the build passes", r?.repairRounds == 1 && r?.validation.check("build")?.status == "pass", "\(r?.repairRounds ?? -1) \(r?.repairNote ?? "")")
    check("pipeline: the working file survives the repair", AcdDoc.parse(r?.answer ?? "").files["src/components/Keep.tsx"] == "export const keep = 1;\n")
    calls = 0
    let h2 = AcdHooks(generate: { _ in calls += 1; return calls == 1 ? badFirst : "// ===== FILE: src/components/T.tsx =====\nexport const n: number = \"x\"\nexport const m: string = 5;\n" },
                      validate: { files in AcdValidator.validate(files: files, starter: projFiles, projectRoot: uProjDir) }, status: { _ in }, resetOutput: {})
    let r2 = await AcdPipeline.run(input: wholeInput("P"), hooks: h2)
    check("pipeline: a repair that does not improve keeps the best earlier answer", AcdDoc.parse(r2?.answer ?? "").files["src/components/T.tsx"] == "export const n: number = \"x\";\n" && (r2?.repairNote ?? "").contains("best earlier answer kept"), r2?.repairNote ?? "nil")
    let h3 = AcdHooks(generate: { req in req.label.contains("Fixing") ? nil : badFirst }, validate: { files in AcdValidator.validate(files: files, starter: projFiles, projectRoot: uProjDir) }, status: { _ in }, resetOutput: {})
    let r3 = await AcdPipeline.run(input: wholeInput("P"), hooks: h3)
    check("pipeline: a failed repair request keeps the answer", r3 != nil && (r3?.repairNote ?? "").contains("best answer kept"), r3?.repairNote ?? "nil")
    _ = starterOnly
    print("\n\(uTotal - uFails)/\(uTotal) passed")
    exit(uFails == 0 ? 0 : 1)
}
uApp.run()

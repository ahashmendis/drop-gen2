# ACD tests for the Windows core (DropAcd*.ps1): port of the ACD cases of tests/acd/driver_unit.swift.
#   pwsh -NoProfile -File tests/windows/core/test-acd.ps1
# The build/type-check cases need a node_modules with react/vite/typescript:  $env:ACD_TEST_NODE_MODULES = '<dir>'
. (Join-Path $PSScriptRoot 'lib.ps1')
$nm = if ($env:ACD_TEST_NODE_MODULES) { $env:ACD_TEST_NODE_MODULES } else { Join-Path $HOME 'Desktop/IIT/ACD/Week 2 Tut/campus-events-frontend/node_modules' }
function J([string[]]$l) { return ($l -join "`n") }

# ===== parser: tricky sources survive extraction byte-for-byte =====
$tsx = "import { useState } from 'react';`n// ===== a comment that is NOT a marker =====`nexport function Box<T,>({ items }: { items: T[] }) {`n  const [n, setN] = useState(0);`n  return <div>{/* jsx comment */}<p>{items.length}</p></div>; // trailing // comment`n}"
$css = "/* ===== FILE: not-a-marker.css ===== */`n.a { color: red; }`n@media (min-width: 600px) { .a { color: blue; } }"
$html = "<!DOCTYPE html>`n<html lang=""en""><head><title>T</title></head>`n<body>`n<!-- // ===== Task 9 ===== -->`n<h1>Hi</h1></body></html>"
$js = "const md = ``n``````js`nconsole.log(1)`n```````n``;`nexport default md;"
$ts = "export function pick<T extends object, K extends keyof T>(o: T, k: K): T[K] { return o[k]; }`nexport type Id = string | number;"
$jsx = "import { useState } from 'react';`nexport default function Counter() {`n  const [n, setN] = useState(0); // count`n  return <button onClick={() => setN(n + 1)}>{n}</button>;`n}"
$json = '{ "name": "x", "scripts": { "test": "vitest run" } }'
$scss = "`$c: red;`n.a { &:hover { color: `$c; } } // line comment"
$answer = "// ===== Task 1 =====`n// ===== Q A1 =====`nB`n// ===== Q A2 =====`nTrue - because`n// ===== Task 2 =====`n// ===== Q D1 =====`nExplain: the Outlet renders children.`n" +
    "// ===== FILE: src/components/Box.tsx =====`n``````tsx`n$tsx`n```````n// ===== FILE: src/styles/app.css =====`n$css`n// ===== FILE: public/index.html =====`n$html`n" +
    "// ===== FILE: src/components/Counter.jsx =====`n$jsx`n// ===== FILE: src/util/md.js =====`n$js`n// ===== FILE: src/util/pick.ts =====`n$ts`n// ===== FILE: package.json =====`n$json`n// ===== FILE: src/a.scss =====`n$scss`n" +
    "// ===== FILE: ../../etc/passwd =====`nevil`n// ===== FILE: /abs/path.js =====`nevil`n// ===== FILE: src/ok/../../x.js =====`nevil`n"
$doc = ConvertFrom-AcdText $answer
$f = Get-AcdFiles $doc
Check 'tsx exact (wrapping fence stripped, marker-looking comment kept)' ($f['src/components/Box.tsx'] -ceq ($tsx + "`n")) $f['src/components/Box.tsx']
Check 'css keeps a comment that looks like a marker' ($f['src/styles/app.css'] -ceq ($css + "`n"))
Check 'html keeps a comment containing a Task marker' ($f['public/index.html'] -ceq ($html + "`n"))
Check 'js keeps backtick fences inside a template literal' ($f['src/util/md.js'] -ceq ($js + "`n")) $f['src/util/md.js']
Check 'ts generics exact' ($f['src/util/pick.ts'] -ceq ($ts + "`n"))
Check 'json exact' ($f['package.json'] -ceq ($json + "`n"))
Check 'scss exact' ($f['src/a.scss'] -ceq ($scss + "`n"))
Check 'jsx exact' ($f['src/components/Counter.jsx'] -ceq ($jsx + "`n"))
Check 'traversal, absolute and dotted paths rejected' ($f.Count -eq 8 -and (Get-AcdRejectedPaths $doc).Count -eq 3) "$($f.Keys -join ',') | $((Get-AcdRejectedPaths $doc) -join ',')"
Check 'question ids in order' ((Get-AcdQuestionIds $doc) -join ',' -eq 'A1,A2,D1')
Check 'no marker line leaks into extracted code' (-not (@($f.Values | Where-Object { $_.Contains('// ===== FILE:') -and -not $_.Contains('not-a-marker') })).Count)
$crlf = Get-AcdFiles (ConvertFrom-AcdText $answer.Replace("`n", "`r`n"))
Check 'CRLF answers parse identically' ((($crlf.Keys | Sort-Object) -join '|') -eq (($f.Keys | Sort-Object) -join '|') -and $crlf['src/components/Box.tsx'] -ceq $f['src/components/Box.tsx'])
Check 'BOM stripped' ((Get-AcdFiles (ConvertFrom-AcdText "// ===== FILE: a.js =====`n$([char]0xFEFF)let a = 1;`n"))['a.js'] -ceq "let a = 1;`n")
$qt = Get-AcdQuestionText $doc
Check 'objective A1 = B, A2 = True' ((ConvertTo-AcdObjective $qt['A1']) -eq 'B' -and (ConvertTo-AcdObjective $qt['A2']) -eq 'True')
foreach ($c in @(@('B - reduce()', 'B'), @('(c) union', 'C'), @('**False**', 'False'), @('A. something', 'A'), @('true.', 'True'), @('D', 'D'), @("`n`n b)", 'B'))) {
    Check ("normalise " + $c[0].Replace("`n", '|')) ((ConvertTo-AcdObjective $c[0]) -ceq $c[1]) (ConvertTo-AcdObjective $c[0])
}
Check 'normalise rejects prose' ($null -eq (ConvertTo-AcdObjective 'Probably the first one') -and $null -eq (ConvertTo-AcdObjective 'Because'))

# ===== part(): task / question / file =====
Check 'part Task 1 holds A1+A2' ((Get-AcdPart $doc '1').Contains('A2') -and (Get-AcdPart $doc '1').Contains('A1'))
Check 'part A1 = just that question' ((Get-AcdPart $doc 'A1').Contains('Q A1') -and -not (Get-AcdPart $doc 'A1').Contains('A2'))
Check 'part a2 is case-insensitive' ($null -ne (Get-AcdPart $doc 'a2'))
Check 'part D1 keeps its explanation' ((Get-AcdPart $doc 'D1').Contains('Outlet'))
Check 'part Box.tsx = clean code only' ((Get-AcdPart $doc 'Box.tsx') -ceq $tsx) (Get-AcdPart $doc 'Box.tsx')
Check 'part path = clean code' ((Get-AcdPart $doc 'src/styles/app.css') -ceq $css)
Check 'part unknown = null' ($null -eq (Get-AcdPart $doc 'Z9') -and $null -eq (Get-AcdPart $doc '9') -and $null -eq (Get-AcdPart $doc 'nothing.tsx') -and $null -eq (Get-AcdPart $doc ''))
Check 'single-file task copies clean code' ((Get-AcdPart (ConvertFrom-AcdText "// ===== Task 3 =====`n// ===== FILE: src/x.ts =====`nexport const x = 1`n") '3') -ceq 'export const x = 1')

# ===== merge =====
$fix = ConvertFrom-AcdText "// ===== FILE: src/util/md.js =====`nexport default 'fixed';`n// ===== FILE: src/new.ts =====`nexport {}`n"
$mg = Merge-AcdDoc $doc $fix
$mf = Get-AcdFiles $mg
Check 'merge replaces a file, keeps the rest, appends new files, keeps questions' ($mf['src/util/md.js'] -ceq "export default 'fixed';`n" -and $mf['src/components/Box.tsx'] -ceq $f['src/components/Box.tsx'] -and $mf['src/new.ts'] -ceq "export {}`n" -and (Get-AcdQuestionIds $mg) -join ',' -eq 'A1,A2,D1')

# ===== static findings =====
$h = Get-AcdHtmlFindings '<html><body><div><span>hi</div><img src=a.png><h1>a</h1><h3>b</h3><input type=text></body>'
Check 'html: unclosed span detected' (@($h.Errors | Where-Object { $_.Contains('span') }).Count -gt 0) ($h.Errors -join ';')
Check 'html: doctype/lang/title/alt/label/heading warnings' ($h.Warnings.Count -ge 5) ($h.Warnings -join ';')
$hg = Get-AcdHtmlFindings '<!DOCTYPE html><html lang="en"><head><title>x</title></head><body><ul><li>a<li>b</ul><img src=a alt=""><script>if (a < b) { x = "</div>" }</script></body></html>'
Check 'good html has no errors (optional </li>, script text ignored)' ($hg.Errors.Count -eq 0) ($hg.Errors -join ';')
Check 'css: unbalanced and balanced' ((Get-AcdCssFindings '.a { color: red;').Count -gt 0 -and (Get-AcdCssFindings '/* } */ .a { color: red; }').Count -eq 0)
Check 'missing imports found, present imports ok' ((Get-AcdImportFindings 'export function A(){ const [a,b]=useState(0); const n=useNavigate(); return <Outlet/> }').Count -eq 3 -and (Get-AcdImportFindings "import { useState } from 'react';`nimport { useNavigate, Outlet } from 'react-router-dom';`nexport function A(){ const [a]=useState(0); const n=useNavigate(); return <Outlet/> }").Count -eq 0)

# ===== notes =====
$chunks = @(
    @{ Source = '00-conventions.md'; Title = 'rules'; Text = 'Use function components and hooks.' },
    @{ Source = 'lec5.pptx'; Title = 'routing'; Text = 'React Router useParams reads the route parameter. useNavigate navigates programmatically.' },
    @{ Source = 'lec2.pptx'; Title = 'grid'; Text = 'CSS grid-template-areas defines named areas for a layout.' },
    @{ Source = 'lec9.pptx'; Title = 'zustand'; Text = 'Zustand stores client state with selectors.' })
$sel = Select-AcdNotes 'Write a React component that reads orderId with useParams from /orders/:orderId' $chunks 6000
Check 'notes: conventions first, routing selected, grid/zustand not' ($sel.Used[0].StartsWith('00-conventions') -and @($sel.Used | Where-Object { $_.Contains('routing') }).Count -gt 0 -and @($sel.Used | Where-Object { $_.Contains('grid') }).Count -eq 0) ($sel.Used -join ';')
$small = Select-AcdNotes 'reads orderId with useParams in React Router' $chunks 1500
Check 'notes: a small budget is spent on relevance, not on the conventions file' ($small.Used[0].Contains('routing') -and $small.Text.Length -le 1500) ($small.Used -join ';')
Check 'notes: tiny budget -> nothing; budget shrinks before the task is ever cut' ((Select-AcdNotes 'x' $chunks 100).Text -eq '' -and (Get-AcdNotesBudget 8000 5000) -eq 0 -and (Get-AcdNotesBudget 16384 4000) -eq 9000)
$big = @(1..200 | ForEach-Object { @{ Source = "n$_.md"; Title = "t$_"; Text = ('react router outlet ' * 40) } })
Check 'notes: never exceed the budget' ((Select-AcdNotes 'react router outlet' $big 2500).Text.Length -le 2500)
$prompt = Get-AcdWholePrompt 'NOTE-TEXT' 'TASK-TEXT'
Check 'prompt order: header, notes (labelled lower priority), task last' ($prompt.IndexOf('REFERENCE NOTES') -gt $prompt.IndexOf('PRIORITY') -and $prompt.EndsWith('TASK-TEXT') -and $prompt.Contains('the task wins'))
Check 'subject defaults to OOP and is stored under its own key (settings.json, never config.json)' ((Get-DropSubject) -eq 'oop')
Set-DropSubject 'acd'
Check 'subject persists across reads; config.json is not created' ((Get-DropSubject) -eq 'acd' -and (Test-Path (Get-DropSettingsPath)) -and -not (Test-Path (Join-Path $script:TestData 'config.json')))
Set-DropSubject 'oop'

# ===== planner: the paper becomes questions =====
$paperText = "===== FILE: MOCK.docx =====`nMOCK ICT`nInstructions to Candidates`n- Use React with TypeScript or JavaScript.`nSection A - Multiple Choice (2 marks)`nChoose ONE answer.`nA1. Which method accumulates one value?`nA. find() B. reduce() C. sort() D. slice()`nA2. Which hook navigates?`nA. useParams()`nB. useNavigate()`nC. useState()`nD. useRef()`nSection B - True/False (2 marks)`nB1. find() returns every match.`nB2. A union type allows several types.`nSection C - Short Answer (3 marks)`nC1. JavaScript - Array Reduction`nWrite a reduce statement.`nSection D - Programming (10 marks)`nD1. React Router (10 marks)`na. Write the routes. (4 marks)`nb. Explain Outlet. (2 marks)`nSection E - Security (4 marks)`nE1. A JWT has expired. What should the front end do?`nA. Ignore it`nB. Re-authenticate`nE2. True or False: HTTPS protects tokens in transit.`nEND OF EXAMINATION"
$plan = New-AcdPlan $paperText
$u = @($plan.Units)
Check 'planner: 8 questions in paper order' (($u | ForEach-Object { $_.Id }) -join ',' -eq 'A1,A2,B1,B2,C1,D1,E1,E2') (($u | ForEach-Object { $_.Id }) -join ',')
Check 'planner: kinds (inline options, multi-line options, true/false by section, free, true/false by wording)' (($u | ForEach-Object { $_.Kind }) -join ',' -eq 'mcq,mcq,tf,tf,free,free,mcq,tf') (($u | ForEach-Object { $_.Kind }) -join ',')
Check 'planner: lettered sections map to Task 1..5' (($u | ForEach-Object { $_.Task }) -join ',' -eq '1,1,2,2,3,4,5,5')
Check 'planner: marks read from the question, instructions kept, file wrapper dropped' ($u[5].Marks -eq 10 -and $plan.Preamble.Contains('Use React with TypeScript') -and -not $plan.Preamble.Contains('===== FILE'))
Check 'planner: sub-parts stay inside their question, END line dropped' ($u[5].Text.Contains('b. Explain Outlet') -and -not $u[7].Text.Contains('END OF'))
Check 'planner: options stay with the question text' ($u[1].Text.Contains('B. useNavigate()') -and $u[0].Text.Contains('B. reduce()'))
$tp = @((New-AcdPlan "Intro text`nTask 1 Build the navbar.`nSome detail.`nTask 2 Add routing.`n").Units)
Check 'planner: Task N papers split into free questions T1, T2' (($tp | ForEach-Object { $_.Id }) -join ',' -eq 'T1,T2' -and -not ($tp | Where-Object { $_.Kind -ne 'free' }) -and ($tp | ForEach-Object { $_.Task }) -join ',' -eq '1,2')
Check 'planner: no recognisable questions -> whole-task mode' (@((New-AcdPlan 'Just build a landing page with a hero section and a footer, nothing else, thanks.').Units).Count -eq 0)
$objU = @{ Id = 'A1'; Task = 1; Kind = 'mcq'; Text = "A1. q`nA. x B. y"; Marks = 1 }; $tfU = @{ Id = 'B1'; Task = 2; Kind = 'tf'; Text = 'B1. q'; Marks = 1 }
Check 'objective prompt: only the letter / True-False, no notes' ((Get-AcdObjectivePrompt $objU).Contains('Reply with ONLY the letter') -and (Get-AcdObjectivePrompt $tfU).Contains('Reply with ONLY True or False') -and -not (Get-AcdObjectivePrompt $objU).Contains('NOTES'))
foreach ($c in @(@('B', 'A1', $false, 'B'), @('A1: C', 'A1', $false, 'C'), @('Answer: d', 'A1', $false, 'D'), @('(b) reduce()', 'A1', $false, 'B'), @('**False**', 'B1', $true, 'False'), @('B1. True', 'B1', $true, 'True'), @('A', 'A1', $false, 'A'))) {
    Check ("reply '$($c[0])' -> $($c[3])") ((Get-AcdObjectiveFromReply $c[0] $c[1] $c[2]) -ceq $c[3]) (Get-AcdObjectiveFromReply $c[0] $c[1] $c[2])
}
Check 'reply that is not an option is rejected (no guessing)' ($null -eq (Get-AcdObjectiveFromReply 'Hmm, it depends.' 'A1' $false) -and $null -eq (Get-AcdObjectiveFromReply 'True' 'A1' $false) -and $null -eq (Get-AcdObjectiveFromReply 'E' 'A1' $false))

# ===== unit-mode pipeline: scripted replies, one request per question, assembled by code =====
$script:seen = New-Object System.Collections.Generic.List[object]
$unitIn = @{ TaskText = $paperText; PaperBlock = $paperText; Starter = @{}; Chunks = @(); Careful = $false; CeilingTokens = 16384; QuestionCount = 8 }
$uh = @{
    Generate = { param($req)
        $script:seen.Add($req)
        if ($req.Kind -eq 'objective') { if ($req.Prompt.Contains('True or False')) { return 'True' } elseif ($req.Prompt.Contains('A1. Which') -or $req.Prompt.Contains('E1. A JWT')) { return 'B' } else { return 'garbage' } }
        return 'free answer for the question' }
    Validate = { param($files) return (Invoke-AcdValidate $files @{} $null) }
    Status = { param($s) } }
$ur = Invoke-AcdPipeline $unitIn $uh
Check 'unit pipeline: one request per question (+1 strict retry for the unreadable reply)' ($script:seen.Count -eq 9) "$($script:seen.Count)"
Check 'unit pipeline: unreadable objective reply is reported as unanswered, never guessed' (($ur.Unanswered -join ',') -eq 'A2') ($ur.Unanswered -join ',')
Check 'unit pipeline: markers assembled in paper order' ((Get-AcdQuestionIds (ConvertFrom-AcdText $ur.Answer)) -join ',' -eq 'A1,B1,B2,C1,D1,E1,E2' -and $ur.Answer.StartsWith('// ===== Task 1 ====='))
Check 'unit pipeline: thinking off, tiny objective budget, free budget scales with marks' (-not ($script:seen | Where-Object { $_.Kind -eq 'objective' -and ($_.NumPredict -gt 24 -or $_.Think) }) -and (@($script:seen | Where-Object { $_.Kind -eq 'free' -and $_.Prompt.Contains('10 marks') })[0].NumPredict -ge 1500))
$script:cseen = New-Object System.Collections.Generic.List[object]
$careful = @{ TaskText = $paperText; PaperBlock = $paperText; Starter = @{}; Chunks = @(); Careful = $true; CeilingTokens = 16384; QuestionCount = 8 }
$ch = @{ Generate = { param($req) $script:cseen.Add($req); if ($req.Kind -eq 'objective') { if ($req.Prompt.Contains('True or False')) { return 'True' } else { return 'B' } }; if ($req.Think) { return $null }; return 'answered without thinking' }
         Validate = { param($files) return (Invoke-AcdValidate $files @{} $null) }; Status = { param($s) } }
$cr = Invoke-AcdPipeline $careful $ch
Check 'careful mode: thinking only for free questions, an empty thinking reply falls back to no-thinking' (@($script:cseen | Where-Object { $_.Kind -eq 'free' -and $_.Think }).Count -eq 2 -and @($script:cseen | Where-Object { $_.Kind -eq 'free' -and -not $_.Think }).Count -eq 2 -and -not ($script:cseen | Where-Object { $_.Kind -eq 'objective' -and $_.Think }) -and $cr.Unanswered.Count -eq 0)

# ===== ACD fixers: the exact slips found in a real 4B-model answer =====
$d1q = 'D1. A student-management application contains: Home page: /  Student list: /students  Individual student details: /students/:studentId  Settings page: /settings. The application should use a shared layout containing a navigation menu.'
$d1code = "``````tsx`nfunction StudentDetails() {`n  const { id } = useParams();`n  return <div>ID: {id}</div>;`n}`n`nfunction App() {`n  return (`n    <BrowserRouter>`n      <Routes>`n        {/* Shared Layout Route */}`n        <Route path=""/"" element={<Layout />}>`n          <Route index element={<h1>Welcome to Home</h1>} />`n          <Route path=""students"" element={<h1>Student List</h1>} />`n          <Route path=""students/:studentId"" element={<StudentDetails />} />`n        </Route>`n        `n        {/* Settings Route (outside layout) */}`n        <Route path=""/settings"" element={<h1>Settings Page</h1>} />`n        `n        {/* Catch-all Not Found Route */}`n        <Route path=""*"" element={<h1>404 - Not Found</h1>} />`n      </Routes>`n    </BrowserRouter>`n  );`n}`n``````n"
$d1fixed = Invoke-AcdFixers $d1code $d1q
Check 'fixer: route param name - useParams reads studentId (not id) everywhere in that component' ($d1fixed.Contains('const { studentId } = useParams();') -and $d1fixed.Contains('ID: {studentId}') -and -not $d1fixed.Contains('{id}')) $d1fixed
$iS = $d1fixed.IndexOf('path="/settings"'); $iC = $d1fixed.IndexOf('</Route>'); $iK = $d1fixed.IndexOf('path="*"')
Check 'fixer: /settings moves inside the shared layout; the catch-all stays outside' ($iS -ge 0 -and $iS -lt $iC -and $iC -lt $iK) $d1fixed
$d2q = 'D2. Retrieve https://example.com/api/courses when the component loads. Avoid updating component state after the component has been unmounted.'
$d2code = "useEffect(() => {`n  let controller: AbortController | null = null;`n  const fetchData = async () => {`n    try {`n      controller = new AbortController();`n      const r = await fetch('https://example.com/api/courses', { signal: controller.signal });`n    } catch (err) {`n      if (err.name !== 'AbortError') {`n        setError(err instanceof Error ? err.message : 'An error occurred');`n      }`n    } finally {`n      setLoading(false);`n    }`n  };`n  fetchData();`n  return () => { controller?.abort(); };`n}, []);`n"
$d2fixed = Invoke-AcdFixers $d2code $d2q
Check 'fixer: unknown catch variable is cast before .name' ($d2fixed.Contains("(err as Error).name !== 'AbortError'") -and $d2fixed.Contains('err instanceof Error ? err.message')) $d2fixed
Check 'fixer: no state update after abort - finally is guarded; the given URL host is kept' ($d2fixed.Contains("if (!controller?.signal.aborted) {`n          setLoading(false);") -and $d2fixed.Contains('https://example.com/api/courses')) $d2fixed
$d3q = 'D3. If validation succeeds, the frontend must submit the data to the following endpoint: POST /api/events'
$d1real = "<Route path=""/"" element={<Layout />}>`n  <Route path=""students/:id"" element={<StudentDetails />} />`n</Route>`n`nfunction StudentDetails() {`n  const { id } = useParams();`n  return <p>{id}</p>;`n}`n"
$d1al = Invoke-AcdFixers $d1real $d1q
Check "fixer: the question's route parameter name wins (:id -> :studentId) and its uses follow" ($d1al.Contains('path="students/:studentId"') -and $d1al.Contains('const { studentId } = useParams();') -and $d1al.Contains('{studentId}') -and -not $d1al.Contains('{id}')) $d1al
$m1 = "``````tsx`nimport { Routes, Route, Link } from 'react-router-dom';`nfunction Layout() { return <div><Outlet /></div>; }`nfunction App() {`n  return (`n    <Routes>`n      <Route path=""/"" element={<Layout />}>`n        <Route index element={<h1>Home</h1>} />`n      </Route>`n      <Route path=""/settings"" element={<Layout />}>`n        <Route index element={<h1>Settings</h1>} />`n      </Route>`n    </Routes>`n  );`n}`n``````nThe explanation says const { id } = useParams() reads it."
$m1f = Invoke-AcdFixers $m1 'D1. Settings page: /settings. Use a shared layout containing a navigation menu.'
Check 'fixer: Outlet used but not imported -> added to the react-router-dom import' ($m1f.Contains("import { Routes, Route, Link, Outlet } from 'react-router-dom'")) $m1f
Check 'fixer: a second <Layout /> wrapper for /settings becomes a child of the first layout' (($m1f -split [regex]::Escape('<Layout />')).Count -eq 2 -and $m1f.Contains('<Route path="/settings" element={<h1>Settings</h1>} />')) $m1f
$m3 = "``````tsx`nimport type { EventFormData, ValidationErrors } from '../types/eventForm';`ninterface EventFormData { title: string }`ninterface ValidationErrors { title?: string }`nconst x = 1;`n``````"
$m3f = Invoke-AcdFixers $m3 'D3. validate'
Check 'fixer: import of a type that is also declared locally is removed' (-not $m3f.Contains('../types/eventForm') -and $m3f.Contains('interface EventFormData')) $m3f
Check 'fixer: useState without import gets it from react' ((Invoke-AcdFixers "``````tsx`nfunction A() { const [a, setA] = useState(0); return <p>{a}</p>; }`n``````" 'q').Contains("import { useState } from 'react';"))
Check 'fixer: already-imported names are not imported twice' (((Invoke-AcdFixers "``````tsx`nimport { useState } from 'react';`nfunction A() { const [a] = useState(0); return null; }`n``````" 'q') -split [regex]::Escape('useState }')).Count -eq 2)
Check 'fixer: no :param in the question -> routes are left alone' ((Invoke-AcdFixers $d1real 'D1. Build routes for students.') -ceq (Invoke-AcdFixers $d1real 'D1. Build routes for students.'))
Check 'fixer: an invented host is replaced by the endpoint path the question gives' ((Invoke-AcdFixers "fetch('https://mock-ict.example/api/events', { method: 'POST' })" $d3q) -ceq "fetch('/api/events', { method: 'POST' })")
Check 'fixer: a host the question itself names is never touched' ((Invoke-AcdFixers "fetch('https://example.com/api/courses')" $d2q) -ceq "fetch('https://example.com/api/courses')")
$stay = 'try {} catch (e) { if (e instanceof Error && e.name !== ''x'') {} } finally { if (!c.signal.aborted) { setLoading(false); } }'
Check 'fixer: already-narrowed catch and already-guarded finally stay unchanged' ((Invoke-AcdFixers $stay 'q') -ceq $stay)
$r1 = "<Route path=""/a/:x/:y""/>`nconst { id } = useParams();"; $r2 = "<Route path=""/a/:id""/>`nconst { id } = useParams();"
Check 'fixer: several route params or a matching name -> untouched' ((Invoke-AcdFixers $r1 'q') -ceq $r1 -and (Invoke-AcdFixers $r2 'q') -ceq $r2)
Check 'fixer: text with none of the patterns is returned exactly' ((Invoke-AcdFixers 'B' 'A1. which?') -ceq 'B' -and (Invoke-AcdFixers 'plain explanation text' 'q') -ceq 'plain explanation text')

# ===== validators on a real project =====
if (-not (Test-Path -LiteralPath $nm)) {
    Write-Host "SKIP build/type-check cases: no node_modules (set ACD_TEST_NODE_MODULES)"
} else {
    $proj = Join-Path $script:TestData 'proj'
    Copy-Item -Path (Join-Path $script:RepoRoot 'tests/acd/fixtures/starter') -Destination $proj -Recurse
    if (Test-DropWindows) { [void](New-Item -ItemType Junction -Path (Join-Path $proj 'node_modules') -Target $nm) } else { [void](New-Item -ItemType SymbolicLink -Path (Join-Path $proj 'node_modules') -Target $nm) }
    $projFiles = @{}
    foreach ($ff in (Get-ChildItem $proj -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' -and $_.Name -ne 'package-lock.json' })) {
        $projFiles[$ff.FullName.Substring($proj.Length + 1).Replace('\', '/')] = [System.IO.File]::ReadAllText($ff.FullName)
    }
    function V($files, $root = $proj) { return (Invoke-AcdValidate $files $projFiles $root) }
    function St($v) { return (($v.Checks | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' ') }
    $good = V @{ 'src/components/Hello.tsx' = "import { useState } from 'react';`nexport function Hello() {`n  const [n, setN] = useState(0);`n  return <button onClick={() => setN(n + 1)}>{n}</button>;`n}`n" }
    Check 'good tsx: syntax/static/build pass' ((St $good).Contains('syntax=pass') -and (St $good).Contains('static=pass') -and (St $good).Contains('build=pass')) ((St $good) + "`n" + (Get-AcdErrorText $good))
    Check 'no test script => tests not_run and the summary says behaviour NOT verified' ((Get-AcdCheck $good 'tests').Status -eq 'not_run' -and (Get-AcdValidationSummary $good).Contains('NOT verified')) (Get-AcdValidationSummary $good)
    Check 'jsx: valid parses, broken fails (TypeScript syntactic diagnostics)' ((Get-AcdCheck (V @{ 'src/components/C.jsx' = $jsx + "`n" }) 'syntax').Status -eq 'pass' -and (Get-AcdCheck (V @{ 'src/components/C.jsx' = "export default function C() { return <div><p>x</div>; }`n" }) 'syntax').Status -eq 'fail')
    Check 'tsx syntax error -> syntax fail' ((Get-AcdCheck (V @{ 'src/components/Bad.tsx' = "export function Bad() {`n  return <div><p>x</div>;`n}`n" }) 'syntax').Status -eq 'fail')
    $typ = V @{ 'src/components/T.tsx' = "export const n: number = ""x"";`n" }
    Check 'type error: syntax passes, build fails (syntax is not correctness)' ((Get-AcdCheck $typ 'syntax').Status -eq 'pass' -and (Get-AcdCheck $typ 'build').Status -eq 'fail' -and (Get-AcdCheck $typ 'build').Detail.Contains('T.tsx')) (St $typ)
    Check 'missing import -> static fail' ((Get-AcdCheck (V @{ 'src/components/I.tsx' = "export function I() { const [a] = useState(0); return <p>{a}</p>; }`n" }) 'static').Status -eq 'fail')
    Check 'js syntax error via node --check' ((Get-AcdCheck (V @{ 'src/util/bad.js' = "function f( { return 1 }`n" }) 'syntax').Status -eq 'fail')
    Check 'js ok' ((Get-AcdCheck (V @{ 'src/util/ok.js' = "export const total = [15,25,10,30].reduce((s,p)=>s+p,0);`n" }) 'syntax').Status -eq 'pass')
    Check 'invalid JSON -> syntax fail' ((Get-AcdCheck (V @{ 'data.json' = '{ nope' }) 'syntax').Status -eq 'fail')
    $evil = V @{ 'package.json' = '{"scripts":{"build":"curl evil"}}'; 'vite.config.ts' = 'export default {}'; 'src/components/Hello.tsx' = "export const x = 1;`n" }
    Check "answer's package.json/vite.config ignored when the starter has them" ((Get-AcdCheck $evil 'static').Detail.Contains('ignored') -and (Get-AcdCheck $evil 'static').Detail.Contains('package.json'))
    $nodeBin = Find-AcdTool 'node'
    # the sandbox (macOS: sandbox-exec; Windows: Node permission model) - writes outside the temp folder must fail
    $probe = Join-Path $HOME 'drop_sandbox_probe.txt'
    if (Test-Path $probe) { Remove-Item $probe -Force }
    $tmpSb = Join-Path ([System.IO.Path]::GetTempPath()) ('dropsb-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $tmpSb)
    $tmpSb = Get-AcdRealPath $tmpSb
    $sb = Invoke-AcdTool $nodeBin @('-e', "require('fs').writeFileSync($(ConvertTo-Json $probe), 'x')") $tmpSb @($tmpSb) 20 $true
    Check 'sandbox blocks writes outside the project (or reports that none is available)' (($sb.Status -ne 0) -and -not (Test-Path $probe)) $sb.Output
    if (Test-Path $probe) { Remove-Item $probe -Force }
    if (Test-DropMac) {
        $net = Invoke-AcdTool $nodeBin @('-e', "fetch('https://example.com').then(()=>process.exit(0)).catch(()=>process.exit(3))") $tmpSb @() 20 $true
        Check 'sandbox blocks network (macOS sandbox-exec)' ($net.Status -ne 0) "status $($net.Status)"
    }
    Remove-Item $tmpSb -Recurse -Force -ErrorAction SilentlyContinue

    # ===== pipeline: repair keeps requirements, preserves working code, retains the best answer =====
    $badFirst = "// ===== Task 1 =====`n// ===== FILE: src/components/T.tsx =====`nexport const n: number = ""x"";`n// ===== FILE: src/components/Keep.tsx =====`nexport const keep = 1;`n"
    $wholeIn = { param($paper) @{ TaskText = 'no lettered questions here'; PaperBlock = $paper; Starter = $projFiles; Chunks = @(); Careful = $false; CeilingTokens = 16384; QuestionCount = 1 } }
    $script:calls = 0
    $h1 = @{ Generate = { param($req) $script:calls++; if ($script:calls -eq 1) { return $badFirst }
                 if (-not ($req.Prompt.Contains('ORIGINAL TASK REQUIREMENTS') -and $req.Prompt.Contains('PAPER-TEXT-123'))) { throw 'repair prompt must carry the original requirements' }
                 return "// ===== FILE: src/components/T.tsx =====`nexport const n: number = 1;`n" }
             Validate = { param($files) return (Invoke-AcdValidate $files $projFiles $proj) }; Status = { param($s) } }
    $r = Invoke-AcdPipeline (& $wholeIn 'PAPER-TEXT-123') $h1
    Check 'pipeline: repaired in one round and the build passes' ($r.RepairRounds -eq 1 -and (Get-AcdCheck $r.Validation 'build').Status -eq 'pass') "$($r.RepairRounds) $($r.RepairNote)"
    Check 'pipeline: the working file survives the repair' ((Get-AcdFiles (ConvertFrom-AcdText $r.Answer))['src/components/Keep.tsx'] -ceq "export const keep = 1;`n")
    $script:calls = 0
    $h2 = @{ Generate = { param($req) $script:calls++; if ($script:calls -eq 1) { return $badFirst } else { return "// ===== FILE: src/components/T.tsx =====`nexport const n: number = ""x""`nexport const m: string = 5;`n" } }
             Validate = { param($files) return (Invoke-AcdValidate $files $projFiles $proj) }; Status = { param($s) } }
    $r2 = Invoke-AcdPipeline (& $wholeIn 'P') $h2
    Check 'pipeline: a repair that does not improve keeps the best earlier answer' ((Get-AcdFiles (ConvertFrom-AcdText $r2.Answer))['src/components/T.tsx'] -ceq "export const n: number = ""x"";`n" -and $r2.RepairNote.Contains('best earlier answer kept')) $r2.RepairNote
    $h3 = @{ Generate = { param($req) if ($req.Label.Contains('Fixing')) { return $null } else { return $badFirst } }
             Validate = { param($files) return (Invoke-AcdValidate $files $projFiles $proj) }; Status = { param($s) } }
    $r3 = Invoke-AcdPipeline (& $wholeIn 'P') $h3
    Check 'pipeline: a failed repair request keeps the answer' ($null -ne $r3 -and $r3.RepairNote.Contains('best answer kept')) $r3.RepairNote
    # the junction/symlink must never have been followed by cleanup: the shared node_modules is intact
    Check 'cleanup removed only the link: the real node_modules still exists' (Test-Path (Join-Path $nm 'typescript'))
}

# ===== toolchain safety, notes copy, sample task copy =====
$dsk = Join-Path $env:DROP_DESKTOP_DIR 'ACD/starter'
New-Item -ItemType Directory -Path (Join-Path $dsk 'node_modules/dep') -Force | Out-Null
Set-Content (Join-Path $dsk 'package.json') '{"name":"x"}'; Set-Content (Join-Path $dsk 'node_modules/dep/package.json') '{"name":"dep"}'
Check 'toolchain: the starter package.json is found (never one inside node_modules)' ((Find-AcdPackageJson) -eq (Join-Path $dsk 'package.json')) (Find-AcdPackageJson)
$callers = @(Get-ChildItem (Join-Path $script:RepoRoot 'windows') -Filter *.ps1 | ForEach-Object { $f = $_.Name; (Select-String -Path $_.FullName -Pattern 'Install-AcdToolchain' | ForEach-Object { "$f`:$($_.LineNumber)" }) })
Check 'toolchain: npm install is only reachable from the user-confirmed job (definition + one job call, nothing else)' ($callers.Count -eq 2) ($callers -join ', ')
$nd = Get-AcdNotesInstalledDir
Copy-DropAcdNotes (Join-Path $script:RepoRoot 'acd-notes')
Set-Content (Join-Path $nd '00-conventions.md') 'MY EDITS'
Copy-DropAcdNotes (Join-Path $script:RepoRoot 'acd-notes')
Check 'notes: copied once, never overwriting the user''s edits' ((Get-Content (Join-Path $nd '00-conventions.md') -Raw).Trim() -eq 'MY EDITS')
Copy-DropBenchSampleTasks (Join-Path $script:RepoRoot 'bench-tasks')
$tj = Join-Path (Get-DropBenchDir) 'tasks/simple-parking/task.json'
Add-Content $tj ' '
$len = (Get-Item $tj).Length
Copy-DropBenchSampleTasks (Join-Path $script:RepoRoot 'bench-tasks')
Check 'bench tasks: copied once, never overwriting edits' ((Get-Item $tj).Length -eq $len -and @(Get-DropBenchTasks).Count -eq 4)
Finish-Tests

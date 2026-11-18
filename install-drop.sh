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

# Local configuration (Phase 3): created once, never overwritten on update,
# so an existing API key survives reinstalls. 0600 = owner read/write only.
CONFIG="$DIR/config.json"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'CFGEOF'
{
  "provider": "ollama",
  "ollama": {
    "base_url": "http://127.0.0.1:11434",
    "default_model": "",
    "context": 0
  },
  "opencode_go": {
    "base_url": "https://opencode.ai/zen/go/v1",
    "api_key": "",
    "model": "mimo-v2.6-flash"
  },
  "network": {
    "connect_timeout": 20,
    "stream_idle_timeout": 120,
    "retry_attempts": 3,
    "retry_backoff": true
  },
  "preferences": {
    "remember_provider": true,
    "allow_fallback": false
  }
}
CFGEOF
fi
chmod 600 "$CONFIG" 2>/dev/null || true
chmod 700 "$DIR" 2>/dev/null || true

# Remove the older attempts
rm -rf "$HOME/Applications/Java Answers.app"
pkill -x Drop 2>/dev/null || true

cat > "$DIR/main.swift" <<'EOF'
import Cocoa
import PDFKit
import Carbon

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

// ===== Configuration (Phase 3): local file, never Keychain =====
let CONFIG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Drop/config.json")

struct DropConfig {
    var provider = "ollama"                 // "ollama" | "opencode_go"
    var ollamaBase = "http://127.0.0.1:11434"
    // Last selected Ollama model (the dropdown only ever offers models that
    // are actually installed — never a hardcoded model name).
    var ollamaDefaultModel = ""
    // Manual Ollama context override: 0 = use the hardware-aware preset.
    var ollamaContext = 0
    var ocBase = "https://opencode.ai/zen/go/v1"
    var ocKey = ""
    var ocModel = "mimo-v2.6-flash"
    var connectTimeout = 20.0
    var streamIdleTimeout = 120.0
    var retryAttempts = 3
    var retryBackoff = true
    var rememberProvider = true
    var allowFallback = false
    // x-opencode-session value: stable for one conversation (initial prompt +
    // compile-repair rounds + retries all reuse it), new id per conversation.
    // Runtime-only — never written to config.json.
    var sessionId = UUID().uuidString
    // Request streaming (SSE) replies. If the server rejects that shape with a
    // 400, the adapter retries once in the verified non-streaming shape
    // (the baseline curl contract, HTTP 200 confirmed). Internal, not persisted.
    var ocStream = true

    static func load() -> DropConfig {
        var c = DropConfig()
        guard let data = try? Data(contentsOf: CONFIG_URL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = obj["provider"] as? String { c.provider = v }
        if let o = obj["ollama"] as? [String: Any] {
            if let v = o["base_url"] as? String, !v.isEmpty { c.ollamaBase = v }
            if let v = o["default_model"] as? String { c.ollamaDefaultModel = v }
            if let v = o["context"] as? Int, v >= 0 { c.ollamaContext = v }
        }
        if let o = obj["opencode_go"] as? [String: Any] {
            if let v = o["base_url"] as? String, !v.isEmpty { c.ocBase = v }
            if let v = o["api_key"] as? String { c.ocKey = v }
            if let v = o["model"] as? String, !v.isEmpty { c.ocModel = v }
        }
        if let n = obj["network"] as? [String: Any] {
            if let v = n["connect_timeout"] as? Double { c.connectTimeout = v }
            else if let v = n["connect_timeout"] as? Int { c.connectTimeout = Double(v) }
            if let v = n["stream_idle_timeout"] as? Double { c.streamIdleTimeout = v }
            else if let v = n["stream_idle_timeout"] as? Int { c.streamIdleTimeout = Double(v) }
            if let v = n["retry_attempts"] as? Int { c.retryAttempts = v }
            if let v = n["retry_backoff"] as? Bool { c.retryBackoff = v }
        }
        if let p = obj["preferences"] as? [String: Any] {
            if let v = p["remember_provider"] as? Bool { c.rememberProvider = v }
            if let v = p["allow_fallback"] as? Bool { c.allowFallback = v }
        }
        return c
    }

    func save() {
        let obj: [String: Any] = [
            "provider": provider,
            "ollama": ["base_url": ollamaBase, "default_model": ollamaDefaultModel, "context": ollamaContext],
            "opencode_go": ["base_url": ocBase, "api_key": ocKey, "model": ocModel],
            "network": ["connect_timeout": connectTimeout, "stream_idle_timeout": streamIdleTimeout,
                        "retry_attempts": retryAttempts, "retry_backoff": retryBackoff],
            "preferences": ["remember_provider": rememberProvider, "allow_fallback": allowFallback]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: CONFIG_URL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CONFIG_URL.path)
        }
    }

    // Hardware-aware Ollama context target (conservative presets by system
    // RAM; a manual `ollama.context` override wins). Applied as a floor in
    // OllamaProvider.generate alongside the prompt-size sizing, so big papers
    // still grow the context as before while small requests get the preset.
    var ollamaTargetContext: Int {
        guard ollamaContext <= 0 else { return min(ollamaContext, 65536) }
        // Round to nearest GiB (machines report slightly under nominal RAM).
        let gib = (ProcessInfo.processInfo.physicalMemory + 536_870_912) / 1_073_741_824
        switch gib {
        case ..<16:  return 8192    // 8 GB class  → 8192
        case 16..<32: return 16384  // 16 GB       → 8192–16384
        case 32..<64: return 16384  // 32 GB       → 16384–32768 (conservative low end)
        default:      return 32768  // 64 GB+      → 32768–65536 (conservative low end)
        }
    }
}

// ===== Error classification (Phase 7A): distinct conditions, never one generic blob =====
enum DropErrorKind {
    case noInternet, dnsFailure, tcpFailure, tlsFailure, endpointUnreachable
    case authFailure, modelNotFound, invalidRequest, rateLimited, serverOutage
    case timeout, interrupted, unknown(String)

    var message: String {
        switch self {
        case .noInternet:          return "No internet connection"
        case .dnsFailure:          return "DNS lookup failed (can't resolve opencode.ai)"
        case .tcpFailure:          return "Cannot reach the server (connection refused/blocked)"
        case .tlsFailure:          return "TLS certificate error"
        case .endpointUnreachable: return "API endpoint unreachable – this network may restrict access"
        case .authFailure:         return "Invalid API key (401/403)"
        case .modelNotFound:       return "Endpoint or model not found (404)"
        case .invalidRequest:      return "Invalid request (400)"
        case .rateLimited:         return "Rate limited (429)"
        case .serverOutage:        return "Provider server error (5xx)"
        case .timeout:             return "Request timed out"
        case .interrupted:         return "Stream interrupted"
        case .unknown(let d):      return d
        }
    }
    var isTransient: Bool {
        switch self {
        case .noInternet, .dnsFailure, .tcpFailure, .endpointUnreachable, .rateLimited, .serverOutage, .timeout:
            return true
        default: return false
        }
    }
}

struct DropError: Error {
    let kind: DropErrorKind
    var retryAfter: TimeInterval? = nil
    // Server-provided explanation (e.g. WHY a 400 happened), parsed defensively
    // from the error body. Never contains the API key; capped at 200 chars.
    var detail: String? = nil

    var displayMessage: String {
        guard let d = detail, !d.isEmpty else { return kind.message }
        return "\(kind.message) — \(d)"
    }
}

func classifyURLError(_ error: Error) -> DropError {
    if let e = error as? DropError { return e }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return DropError(kind: .noInternet)
        case NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost: return DropError(kind: .dnsFailure)
        case NSURLErrorCannotConnectToHost: return DropError(kind: .tcpFailure)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid: return DropError(kind: .tlsFailure)
        case NSURLErrorTimedOut: return DropError(kind: .timeout)
        case NSURLErrorCancelled: return DropError(kind: .unknown("Cancelled"))
        default: break
        }
    }
    return DropError(kind: .unknown(error.localizedDescription))
}

func classifyHTTP(status: Int, retryAfterHeader: String?, detail: String? = nil) -> DropError {
    var ra: TimeInterval? = nil
    if let h = retryAfterHeader, let secs = TimeInterval(h) { ra = secs }
    switch status {
    case 400: return DropError(kind: .invalidRequest, retryAfter: nil, detail: detail)
    case 401, 403: return DropError(kind: .authFailure, retryAfter: nil, detail: detail)
    case 404: return DropError(kind: .modelNotFound, retryAfter: nil, detail: detail)
    case 408: return DropError(kind: .timeout, retryAfter: ra, detail: detail)
    case 429: return DropError(kind: .rateLimited, retryAfter: ra, detail: detail)
    case 500...599: return DropError(kind: .serverOutage, retryAfter: ra, detail: detail)
    default: return DropError(kind: .unknown("HTTP \(status)"), retryAfter: ra, detail: detail)
    }
}

// Best-effort extraction of the provider's own explanation from an error body.
// Handles {"error":{"message":…}}, {"error":"…"}, {"message":…}, {"detail":…}.
// Returns nil for non-JSON or unknown shapes (never fabricates a message).
func errorDetail(from body: String) -> String? {
    guard !body.isEmpty,
          let data = body.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    if let d = obj as? [String: Any] {
        if let e = d["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(200)) }
        if let e = d["error"] as? String, !e.isEmpty { return String(e.prefix(200)) }
        if let m = d["message"] as? String, !m.isEmpty { return String(m.prefix(200)) }
        if let m = d["detail"] as? String, !m.isEmpty { return String(m.prefix(200)) }
    }
    return nil
}

// ===== Provider abstraction (Phases 4-5) =====
enum GenOutcome {
    case ok(String)
    case interrupted(String)     // partial content already delivered to the UI
    case failed(DropError)
}

protocol ProviderAdapter {
    var id: String { get }
    var displayName: String { get }
    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome
    // Optional lightweight model discovery; nil = use configured default only.
    func listModels() async -> [String]?
}

// --- Ollama: existing behaviour moved verbatim (streaming, keep_alive, num_ctx) ---
struct OllamaProvider: ProviderAdapter {
    let config: DropConfig
    var id: String { "ollama" }
    var displayName: String { "Ollama" }

    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome {
        var req = URLRequest(url: URL(string: config.ollamaBase + "/api/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900
        let needed = prompt.count / 3 + 8000
        var ctx = 8192
        while ctx < needed && ctx < 65536 { ctx *= 2 }
        // Hardware-aware target (RAM preset or manual override) as a floor —
        // prompt-size growth still wins when a large paper needs more, and the
        // existing 65536 hard cap is unchanged.
        ctx = min(max(ctx, config.ollamaTargetContext), 65536)
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": true,
                                   "keep_alive": "30m", "options": ["num_ctx": ctx, "temperature": 0.2]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var answer = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                // Surface Ollama's own reason (e.g. "model 'x' not found").
                var raw = ""
                for try await l in bytes.lines {
                    raw += l
                    if raw.count > 1024 { break }
                }
                return .failed(classifyHTTP(status: h.statusCode,
                                            retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"),
                                            detail: errorDetail(from: raw)))
            }
            for try await line in bytes.lines {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let e = obj["error"] as? String {
                    return .failed(DropError(kind: .unknown("Ollama: \(e)")))
                }
                if let piece = obj["response"] as? String, !piece.isEmpty {
                    answer += piece
                    onChunk(piece)
                    onStatus("\(label)… \(answer.count) chars")
                }
            }
            return .ok(answer)
        } catch {
            let e = classifyURLError(error)
            if !answer.isEmpty { return .interrupted(answer) }
            return .failed(e)
        }
    }

    // Qwen-family discovery from GET /api/tags: model metadata first
    // (details.family / details.families), falling back to the model name.
    // All installed Qwen variants are offered — no single hardcoded model.
    static func isQwenFamily(_ m: [String: Any]) -> Bool {
        if let d = m["details"] as? [String: Any] {
            var fams: [String] = []
            if let f = d["family"] as? String { fams.append(f) }
            if let fs = d["families"] as? [String] { fams += fs }
            if fams.contains(where: { $0.lowercased().contains("qwen") }) { return true }
        }
        if let n = m["name"] as? String, n.lowercased().contains("qwen") { return true }
        return false
    }

    func listModels() async -> [String]? {
        guard let url = URL(string: config.ollamaBase + "/api/tags") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return nil }
            let names = models
                .filter { !(($0["name"] as? String) ?? "").contains("cloud") }
                .filter { OllamaProvider.isQwenFamily($0) }
                .compactMap { $0["name"] as? String }
                .sorted()
            return names
        } catch { return nil }
    }
}

// --- OpenCode Go: direct HTTPS, Bearer auth, SSE streaming, retries with backoff+jitter ---
struct OpenCodeGoProvider: ProviderAdapter {
    let config: DropConfig
    var id: String { "opencode_go" }
    var displayName: String { "OpenCode Go" }

    private var endpoint: URL? {
        let base = config.ocBase.hasSuffix("/") ? String(config.ocBase.dropLast()) : config.ocBase
        return URL(string: base + "/chat/completions")
    }

    func generate(prompt: String, model: String, label: String,
                  onChunk: @escaping (String) -> Void,
                  onStatus: @escaping (String) -> Void) async -> GenOutcome {
        guard !config.ocKey.isEmpty else { return .failed(DropError(kind: .authFailure)) }
        guard let url = endpoint else { return .failed(DropError(kind: .endpointUnreachable)) }

        let attempts = max(1, config.retryAttempts)
        let stream = config.ocStream
        var lastError = DropError(kind: .endpointUnreachable)
        for attempt in 0..<attempts {
            if attempt > 0 && config.retryBackoff {
                // Exponential backoff + jitter; honour Retry-After when the provider sent one.
                let base = pow(2.0, Double(attempt - 1))
                let jitter = Double.random(in: 0...0.5)
                let delay = max(lastError.retryAfter ?? 0, base + jitter)
                onStatus("⏳ Retry \(attempt)/\(attempts - 1) in \(String(format: "%.1f", delay))s…")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var res = await attemptOnce(url: url, prompt: prompt, model: model,
                                        label: label, stream: stream,
                                        onChunk: onChunk, onStatus: onStatus)
            if case .failed(let e) = res, stream, case .invalidRequest = e.kind {
                // Streaming shape rejected (400): retry exactly once in the
                // non-streaming shape the baseline test verified (HTTP 200).
                onStatus("⚠️ Streaming rejected – retrying non-streaming…")
                res = await attemptOnce(url: url, prompt: prompt, model: model,
                                        label: label, stream: false,
                                        onChunk: onChunk, onStatus: onStatus)
            }
            switch res {
            case .ok(let a): return .ok(a)
            case .interrupted(let partial): return .interrupted(partial)
            case .failed(let e):
                lastError = e
                // Only transient errors are retried; auth/400/404 fail fast.
                if !e.kind.isTransient { return .failed(e) }
            }
        }
        return .failed(lastError)
    }

    private func attemptOnce(url: URL, prompt: String, model: String, label: String,
                             stream: Bool,
                             onChunk: @escaping (String) -> Void,
                             onStatus: @escaping (String) -> Void) async -> GenOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + config.ocKey, forHTTPHeaderField: "Authorization")
        req.setValue("Drop/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(config.sessionId, forHTTPHeaderField: "x-opencode-session")
        req.timeoutInterval = config.streamIdleTimeout   // idle timeout; long generations keep streaming
        // Exact shape of the verified (200 OK) baseline request — no extra fields.
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": stream
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var answer = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                // Capture the error body for diagnostics (never contains the key).
                var raw = ""
                for try await l in bytes.lines {
                    raw += l
                    if raw.count > 2048 { break }
                }
                return .failed(classifyHTTP(status: h.statusCode,
                                            retryAfterHeader: h.value(forHTTPHeaderField: "Retry-After"),
                                            detail: errorDetail(from: raw)))
            }
            // Standard OpenAI-compatible SSE: data: {...} … data: [DONE]
            var plain = ""   // non-SSE lines, kept for a single-object JSON fallback
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else {
                    if plain.count < 4_194_304 { plain += line + "\n" }
                    continue
                }
                let payload = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }   // stream finished normally
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue } // malformed chunk: skip safely
                if let errObj = obj["error"] {
                    var msg = String(describing: errObj)
                    if let d = errObj as? [String: Any], let m = d["message"] as? String { msg = m }
                    if answer.isEmpty { return .failed(DropError(kind: .unknown(msg))) }
                    return .interrupted(answer)
                }
                if let choices = obj["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let piece = delta["content"] as? String, !piece.isEmpty {
                    answer += piece
                    onChunk(piece)
                    onStatus("\(label)… \(answer.count) chars")
                }
            }
            if answer.isEmpty {
                // Server replied with one chat.completion JSON object instead of
                // an SSE stream (stream ignored or stream:false) — parse it properly.
                if let s = OpenCodeGoProvider.chatContent(from: plain) {
                    onChunk(s)
                    return .ok(s)
                }
                if let d = errorDetail(from: plain) {
                    return .failed(DropError(kind: .unknown(d)))
                }
                return .failed(DropError(kind: .interrupted))
            }
            return .ok(answer)
        } catch {
            let e = classifyURLError(error)
            // Content already shown to the user: never replay the request (would duplicate output).
            if !answer.isEmpty { return .interrupted(answer) }
            return .failed(e)
        }
    }

    // GET {base}/models is OpenAI-compatible and free; fall back to the configured model.
    func listModels() async -> [String]? {
        guard !config.ocKey.isEmpty, let base = URL(string: config.ocBase.hasSuffix("/")
              ? String(config.ocBase.dropLast()) : config.ocBase) else { return nil }
        guard let url = URL(string: base.absoluteString + "/models") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + config.ocKey, forHTTPHeaderField: "Authorization")
        req.setValue("Drop/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(config.sessionId, forHTTPHeaderField: "x-opencode-session")
        req.timeoutInterval = config.connectTimeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return nil }
            let ids = arr.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : ids
        } catch { return nil }
    }

    // Extracts content from a single chat.completion JSON object
    // ({"choices":[{"message":{"content":…}}]} — the non-streaming reply shape).
    static func chatContent(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return content
    }
}

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
    var providerBtn: NSButton!
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    var running = false
    var starterFiles: [String: String] = [:]
    var lastAnswer = ""
    // Remembered so an approved provider fallback can answer the SAME request.
    var lastPrompt: String?
    var lastModel: String?
    var lastLabel: String?
    var expanded = false
    var config = DropConfig.load()
    let W: CGFloat = 230
    let compactH: CGFloat = 94    // drop row + dynamic model selector + button row
    let answerH: CGFloat = 240

    var activeProvider: ProviderAdapter {
        config.provider == "opencode_go"
            ? OpenCodeGoProvider(config: config)
            : OllamaProvider(config: config)
    }

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
        modelPopup.toolTip = "Installed Qwen models (discovered from Ollama)"

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
        providerBtn = small(config.provider == "ollama" ? "🦙 Ollama" : "☁️ OpenCode", #selector(toggleProvider))
        providerBtn.toolTip = "Switch provider (Ollama local / OpenCode Go cloud)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [providerBtn, spacer, copyBtn, expandBtn, quitBtn])
        row.spacing = 6

        textView.isEditable = false
        textView.font = mono
        textView.drawsBackground = false
        scroll.drawsBackground = false
        scroll.isHidden = true

        let stack = NSStackView(views: [dropView, modelPopup, row, scroll])
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
            modelPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        setStatus(config.provider == "opencode_go" ? "Connecting to OpenCode Go…" : "Connecting to Ollama…")
        loadModels()
    }

    // ===== Settings (Phase 6): provider, API key, connection test =====
    var settingsWin: NSWindow?
    var keyField: NSSecureTextField!
    var baseField: NSTextField!
    var modelField: NSTextField!
    var contextField: NSTextField!
    var testStatus: NSTextField!

    @objc func openSettings() {
        if settingsWin == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 258),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Drop Settings"
            let stack = NSStackView(frame: NSRect(x: 12, y: 12, width: 356, height: 234))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8

            func labeled(_ label: String, _ field: NSView) -> NSView {
                let l = NSTextField(labelWithString: label)
                l.font = NSFont.systemFont(ofSize: 11)
                l.translatesAutoresizingMaskIntoConstraints = false
                let h = NSStackView(views: [l, field])
                h.orientation = .horizontal
                h.spacing = 6
                l.widthAnchor.constraint(equalToConstant: 90).isActive = true
                return h
            }

            baseField = NSTextField(string: config.provider == "ollama" ? config.ollamaBase : config.ocBase)
            keyField = NSSecureTextField(string: config.ocKey)
            keyField.placeholderString = "oc_… (OpenCode Go only)"
            modelField = NSTextField(string: config.ocModel)
            // Ollama-only context override (0 = hardware preset). Stored in the
            // ollama config section; OpenCode Go is unaffected by this field.
            contextField = NSTextField(string: "\(config.ollamaContext)")
            contextField.placeholderString = "0 = auto (RAM preset)"
            for f in [baseField!, keyField!, modelField!, contextField!] as [NSTextField] {
                f.translatesAutoresizingMaskIntoConstraints = false
                f.widthAnchor.constraint(equalToConstant: 250).isActive = true
            }

            let fallback = NSButton(checkboxWithTitle: "Offer Ollama fallback if OpenCode Go fails",
                                    target: self, action: #selector(fallbackToggled))
            fallback.state = config.allowFallback ? .on : .off
            let remember = NSButton(checkboxWithTitle: "Remember selected provider",
                                    target: self, action: #selector(rememberToggled))
            remember.state = config.rememberProvider ? .on : .off

            let testBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
            let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveSettings))
            let btnRow = NSStackView(views: [testBtn, saveBtn])
            btnRow.orientation = .horizontal
            btnRow.spacing = 8

            testStatus = NSTextField(labelWithString: "")
            testStatus.font = NSFont.systemFont(ofSize: 11)
            testStatus.lineBreakMode = .byTruncatingTail
            testStatus.maximumNumberOfLines = 2

            stack.addArrangedSubview(labeled("Base URL", baseField))
            stack.addArrangedSubview(labeled("API key", keyField))
            stack.addArrangedSubview(labeled("Model", modelField))
            stack.addArrangedSubview(labeled("Qwen ctx", contextField))
            stack.addArrangedSubview(fallback)
            stack.addArrangedSubview(remember)
            stack.addArrangedSubview(btnRow)
            stack.addArrangedSubview(testStatus)
            w.contentView?.addSubview(stack)
            settingsWin = w
        }
        // Prefill current values each time it opens
        baseField.stringValue = config.provider == "ollama" ? config.ollamaBase : config.ocBase
        keyField.stringValue = config.ocKey
        modelField.stringValue = config.ocModel
        contextField.stringValue = "\(config.ollamaContext)"
        NSApp.activate(ignoringOtherApps: true)
        settingsWin?.makeKeyAndOrderFront(nil)
    }

    @objc func fallbackToggled(_ s: NSButton) { config.allowFallback = (s.state == .on); config.save() }
    @objc func rememberToggled(_ s: NSButton) { config.rememberProvider = (s.state == .on); config.save() }

    @objc func saveSettings() {
        // Never wipe a stored key with an empty field (Phase 3).
        let newKey = keyField.stringValue
        if !newKey.isEmpty { config.ocKey = newKey }
        let newBase = baseField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newBase.isEmpty {
            if config.provider == "ollama" { config.ollamaBase = newBase } else { config.ocBase = newBase }
        }
        let newModel = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newModel.isEmpty && config.provider == "opencode_go" { config.ocModel = newModel }
        // Ollama context override (0 = hardware preset); never touches opencode_go.
        if let v = Int(contextField.stringValue.trimmingCharacters(in: .whitespaces)), v >= 0 {
            config.ollamaContext = v
        }
        config.save()   // re-asserts 0600
        testStatus.stringValue = "Saved (key stored locally, 0600)"
        loadModels()
    }

    // Phase 6: Test Connection — real authenticated ping, key never displayed.
    @objc func testConnection() {
        saveSettings()
        let cfg = config
        testStatus.stringValue = "Testing…"
        Task { @MainActor in
            if cfg.provider == "ollama" {
                let o = OllamaProvider(config: cfg)
                if let names = await o.listModels(), !names.isEmpty {
                    testStatus.stringValue = "✅ Ollama OK – \(names.count) model(s)"
                } else {
                    testStatus.stringValue = "❌ Ollama not reachable at \(cfg.ollamaBase)"
                }
            } else {
                if cfg.ocKey.isEmpty {
                    testStatus.stringValue = "❌ Enter an API key first"
                    return
                }
                // Tiny real request proves endpoint + key + model together.
                // Single attempt, connect_timeout budget: a blocked network
                // should fail the TEST quickly instead of sitting in retries.
                var testCfg = cfg
                testCfg.retryAttempts = 1
                testCfg.streamIdleTimeout = cfg.connectTimeout
                testCfg.sessionId = UUID().uuidString   // the test is its own conversation
                testCfg.ocStream = false                // exact baseline request (verified 200 OK)
                let oc = OpenCodeGoProvider(config: testCfg)
                let out = await oc.generate(prompt: "Reply with exactly: Drop connection successful",
                                            model: cfg.ocModel, label: "Testing",
                                            onChunk: { _ in }, onStatus: { _ in })
                switch out {
                case .ok(let a):
                    testStatus.stringValue = "✅ OpenCode Go OK – \(a.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))"
                case .interrupted:
                    testStatus.stringValue = "✅ OpenCode Go OK (stream ended early)"
                case .failed(let e):
                    testStatus.stringValue = "❌ \(e.displayMessage)"
                }
            }
        }
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

    // Provider-aware discovery: Ollama hits localhost /api/tags; OpenCode Go hits
    // GET {base}/models with the stored key. No cross-talk: each path only talks
    // to its own endpoint (Phase 5: no localhost:11434 requests when OpenCode selected).
    func loadModels() {
        let provider = activeProvider
        let cfg = config
        Task { @MainActor in
            if provider.id == "opencode_go" && cfg.ocKey.isEmpty {
                modelPopup.removeAllItems()
                modelPopup.addItem(withTitle: cfg.ocModel)
                setStatus("⚠️ No OpenCode API key – open Settings (gear in tray)")
                return
            }
            let names = await provider.listModels()
            modelPopup.removeAllItems()
            // Ollama: only installed Qwen-family models (discovered from
            // /api/tags — never a hardcoded name). OpenCode Go list handling
            // unchanged.
            let list: [String]
            if provider.id == "ollama" {
                list = (names?.isEmpty == false) ? names! : []
            } else {
                list = (names?.isEmpty == false) ? names! : [cfg.ocModel]
            }
            modelPopup.addItems(withTitles: list)
            let savedKey = provider.id == "ollama" ? "model" : "oc_model"
            var missingSaved: String? = nil
            if let saved = UserDefaults.standard.string(forKey: savedKey), list.contains(saved) {
                modelPopup.selectItem(withTitle: saved)
            } else if provider.id == "ollama" {
                // Saved model no longer installed → never select a model that
                // does not exist; fall back to an existing one (or leave the
                // dropdown empty when no Qwen model is installed at all).
                if let saved = UserDefaults.standard.string(forKey: "model"), !saved.isEmpty, !list.isEmpty {
                    missingSaved = saved
                }
                if !list.isEmpty { modelPopup.selectItem(at: 0) }
            } else if provider.id == "opencode_go", let m = list.first(where: { $0 == cfg.ocModel }) {
                modelPopup.selectItem(withTitle: m)
            }
            if provider.id == "opencode_go" {
                setStatus(names != nil ? "OpenCode Go ready · \(list.count) model(s)" : "OpenCode Go · \(cfg.ocModel)")
            } else if names == nil {
                setStatus("⚠️ Ollama not running – open the Ollama app")
            } else if list.isEmpty {
                setStatus("⚠️ No Qwen models installed – ollama pull a Qwen model first")
            } else if let m = missingSaved {
                setStatus("⚠️ Saved model “\(m)” not installed · using “\(list[0])”")
            } else {
                setStatus("Ready · click to choose files")
            }
        }
    }

    @objc func modelChanged() {
        let key = config.provider == "ollama" ? "model" : "oc_model"
        UserDefaults.standard.set(modelPopup.titleOfSelectedItem, forKey: key)
        if config.provider == "opencode_go", let m = modelPopup.titleOfSelectedItem {
            config.ocModel = m
            config.save()
        } else if config.provider == "ollama", let m = modelPopup.titleOfSelectedItem {
            // Mirror the selection into config (local file, same 0600 rules).
            config.ollamaDefaultModel = m
            config.save()
        }
    }

    // Phase 6: toggle button in the popup switches provider; never silent — user clicks.
    @objc func toggleProvider() {
        guard !running else { setStatus("⏳ Busy – wait before switching"); return }
        config.provider = config.provider == "ollama" ? "opencode_go" : "ollama"
        if config.rememberProvider { config.save() }
        providerBtn.title = config.provider == "ollama" ? "🦙 Ollama" : "☁️ OpenCode"
        modelPopup.removeAllItems()
        // Ollama items arrive from loadModels() a moment later (discovered
        // Qwen models only); OpenCode Go keeps its configured model.
        if config.provider != "ollama" { modelPopup.addItem(withTitle: config.ocModel) }
        setStatus(config.provider == "ollama" ? "Ollama selected · local only"
                                              : "OpenCode Go selected · cloud")
        loadModels()
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

    // Control + Option + D shows / hides the popup from anywhere; the other
    // IntelliJ-workflow hotkeys dispatch by EventHotKeyID id (plan
    // docs/superpowers/plans/2026-11-18-intellij-hotkeys.md):
    // 1 = ⌃⌥D toggle, 2 = ⌃⌥R OOP run, 3 = ⌃⌥C copy-all, 4…13 = ⌃⌥1…9,0 task copy.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                switch hkID.id {
                case 1: me.togglePanel()
                case 2: if me.hotkeyGateAllowed { me.oopRunHotkey() }
                case 3: if me.hotkeyGateAllowed { me.copyAllHotkey() }
                case 4...13: if me.hotkeyGateAllowed { me.copyTaskHotkey(Int(hkID.id - 3)) }
                default: break
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let mods = UInt32(controlKey | optionKey)
        let bindings: [(UInt32, UInt32)] = [
            (UInt32(kVK_ANSI_D), 1), (UInt32(kVK_ANSI_R), 2),
            (UInt32(kVK_ANSI_C), 3), (UInt32(kVK_ANSI_1), 4), (UInt32(kVK_ANSI_2), 5),
            (UInt32(kVK_ANSI_3), 6), (UInt32(kVK_ANSI_4), 7), (UInt32(kVK_ANSI_5), 8),
            (UInt32(kVK_ANSI_6), 9), (UInt32(kVK_ANSI_7), 10), (UInt32(kVK_ANSI_8), 11),
            (UInt32(kVK_ANSI_9), 12), (UInt32(kVK_ANSI_0), 13)
        ]
        for (kc, hid) in bindings {
            let id = EventHotKeyID(signature: OSType(0x44524F50), id: hid)
            RegisterEventHotKey(kc, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            // Refresh the Qwen list when shown (newly installed / removed models
            // are picked up). Ollama-only: OpenCode Go never gets extra traffic.
            if config.provider == "ollama" && !running { loadModels() }
        }
    }

    // Frontmost gate for the IntelliJ-workflow hotkeys (⌃⌥R/C/1-0): they act
    // only while IntelliJ IDEA or Drop itself is frontmost; presses elsewhere
    // are ignored. ⌃⌥D stays global and ungated.
    var hotkeyGateAllowed: Bool {
        if let front = NSWorkspace.shared.frontmostApplication {
            if front.bundleIdentifier == "com.jetbrains.intellij" { return true }
            if (front.localizedName ?? "").contains("IntelliJ") { return true }
        }
        // Drop itself: the panel is .nonactivatingPanel (shown with
        // orderFrontRegardless), so it can be key while NSApp.isActive is
        // false and frontmostApplication still names the other app — check
        // key-window too, or ⌃⌥C/1-0 are ignored while the popup is key.
        if NSApp.isActive { return true }
        return NSApp.windows.contains(where: { $0.isKeyWindow })
    }

    // ⌃⌥R: read Desktop/OOP and start the run — headless, never opens the
    // panel (the user opens it manually with ⌃⌥D to watch progress).
    @objc func oopRunHotkey() {
        guard !running else { setStatus("⏳ Busy – wait for the current answer"); return }
        let oop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/OOP")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: oop.path, isDirectory: &isDir),
              isDir.boolValue else {
            setStatus("⚠️ OOP folder not found on Desktop"); return
        }
        handle([oop])   // handle() never opens the panel
    }

    // ⌃⌥C: copy the full last answer (same clipboard path as the Copy button).
    @objc func copyAllHotkey() {
        guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
        copyToClipboard(lastAnswer)
        setStatus("📋 Answer copied · paste with ⌘V")
    }

    // ⌃⌥1…0: copy just Task N's section of the last answer, so each task can
    // be pasted into IntelliJ separately.
    @objc func copyTaskHotkey(_ n: Int) {
        guard !lastAnswer.isEmpty else { setStatus("No answer yet"); return }
        guard let slice = AppDelegate.taskSection(lastAnswer, n: n) else {
            setStatus("⚠️ Task \(n) not found in answer"); return
        }
        copyToClipboard(slice)
        setStatus("✅ Task \(n) copied · paste with ⌘V")
    }

    // Slice "…// ===== Task N ===== …" up to (excluding) the next Task header.
    // hasPrefix("// ===== Task 1 =====") cannot match a Task 10 header, so N=1
    // is safe. Extracted verbatim by the task-section behavior test.
    static func taskSection(_ answer: String, n: Int) -> String? {
        let lines = answer.components(separatedBy: "\n")
        let header = "// ===== Task \(n) ====="
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(header)
        }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count
        where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("// ===== Task ") {
            end = i
            break
        }
        let slice = lines[start..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slice.isEmpty ? nil : slice
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
            let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            m.addItem(settings)
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
        // The popup only ever holds models that exist (Ollama: installed Qwen
        // models; OpenCode: configured model) — never send a nonexistent one.
        guard let model = modelPopup.titleOfSelectedItem, !model.isEmpty else {
            setStatus(config.provider == "ollama"
                      ? "⚠️ No Qwen model installed – ollama pull a Qwen model first"
                      : "⚠️ No model selected")
            return
        }
        // New conversation → new x-opencode-session id, reused by every
        // request of this run (prompt, repair rounds, retries).
        config.sessionId = UUID().uuidString
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

    // Single entry point for ALL providers (Phase 9: shared pipeline).
    // The repair loop in handle() calls this too, so both providers get
    // compile-check + two repair rounds for free.
    @MainActor
    func generate(prompt: String, model: String, label: String) async -> String? {
        let provider = activeProvider
        lastPrompt = prompt
        lastModel = model
        lastLabel = label
        let outcome = await provider.generate(
            prompt: prompt, model: model, label: label,
            // Adapters run off the main actor; hop before touching AppKit (chunks
            // dispatch in FIFO order, so output order is preserved).
            onChunk: { [weak self] piece in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.textView.textStorage?.append(NSAttributedString(string: piece, attributes: [
                        .font: self.mono,
                        .foregroundColor: NSColor.textColor]))
                    self.textView.scrollToEndOfDocument(nil)
                }
            },
            onStatus: { [weak self] s in
                DispatchQueue.main.async { self?.setStatus(s) }
            })
        switch outcome {
        case .ok(let answer):
            // A "success" with no content would otherwise copy an empty answer.
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                setStatus("❌ Empty response from provider")
                return nil
            }
            return answer
        case .interrupted(let partial):
            setStatus("⚠️ Stream interrupted – partial answer kept (\(partial.count) chars)")
            return partial.isEmpty ? nil : partial
        case .failed(let err):
            return await handleGenerationFailure(err, provider: provider)
        }
    }

    // Phase 7A/7F: distinct diagnostics + optional, user-approved Ollama fallback.
    // Returns an answer if the user approved the switch and the fallback
    // succeeded; nil otherwise (the caller's pipeline then stops cleanly).
    @MainActor
    func handleGenerationFailure(_ err: DropError, provider: ProviderAdapter) async -> String? {
        // Never echo the key; classified message + server detail contain no credentials.
        setStatus("❌ \(err.displayMessage)")
        textView.string = ""
        guard provider.id == "opencode_go" else { return nil }
        // Phase 8: fallback only ever PROPOSED, requires explicit approval, off by default.
        guard config.allowFallback else { return nil }
        let ollama = OllamaProvider(config: config)
        guard let names = await ollama.listModels(), !names.isEmpty else { return nil }
        let a = NSAlert()
        a.messageText = "OpenCode Go unavailable"
        a.informativeText = "\(err.displayMessage).\n\nOllama is running locally with \(names.count) model(s). Switch to Ollama for this answer?"
        a.addButton(withTitle: "Switch to Ollama")
        a.addButton(withTitle: "Stay on OpenCode Go")
        if a.runModal() == .alertFirstButtonReturn {
            config.provider = "ollama"
            config.save()
            providerBtn.title = "🦙 Ollama"
            setStatus("Switched to Ollama (local) · retrying…")
            loadModels()
            // Re-send the exact same request through the approved provider.
            // If Ollama also fails this returns nil (no fallback loop: the
            // provider guard above stops any second proposal).
            guard let lp = lastPrompt else { return nil }
            // lastModel is the OpenCode model (mimo…) — Ollama needs one of
            // ITS installed Qwen models instead: the saved selection if still
            // installed, otherwise the first discovered Qwen model.
            let preferred = UserDefaults.standard.string(forKey: "model")
            guard let ollamaModel = (preferred.flatMap { names.contains($0) ? $0 : nil }) ?? names.first
            else { return nil }
            return await generate(prompt: lp, model: ollamaModel, label: lastLabel ?? "✍️ Writing")
        }
        return nil
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

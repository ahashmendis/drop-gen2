#!/bin/bash
# Integrity gate: protected code must be byte-identical to the reference installer.
#   check.sh <installer.sh> [--update <reference-installer.sh>]
# `--update` (re)writes hashes.txt from a reference installer (done once from the original, pre-feature installer).
# Protected: OpenCode Go provider (endpoint, headers, payload, streaming, errors, auth), DropConfig (config format),
# the Ollama provider, error classification, and the four prompt/repair headers (the OOP prompts).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
sym_hash() { # file symbol-regex
  awk -v start="$2" '$0 ~ start {on=1} on {print} on && /^}$/ {exit}' "$1" | shasum | cut -c1-16; }
hdr_hash() { awk -v v="^let $2 = " '$0 ~ v {on=1} on {print} on && /^"""$/ {exit}' "$1" | shasum | cut -c1-16; }
SYMS=('^struct OpenCodeGoProvider' '^struct DropConfig' '^struct OllamaProvider' '^func classifyHTTP' '^func classifyURLError' '^func prepareOllama' '^protocol ProviderAdapter')
HDRS=(PROMPT_HEADER REPAIR_HEADER OLLAMA_PROMPT_HEADER OLLAMA_REPAIR_HEADER)
compute() { for s in "${SYMS[@]}"; do echo "sym $s $(sym_hash "$1" "$s")"; done; for h in "${HDRS[@]}"; do echo "hdr $h $(hdr_hash "$1" "$h")"; done; }
if [ "$2" = "--update" ]; then compute "$3" > "$HERE/hashes.txt"; echo "hashes.txt written from $3"; exit 0; fi
compute "$1" > /tmp/drop-integrity-now.txt
if diff "$HERE/hashes.txt" /tmp/drop-integrity-now.txt; then echo "INTEGRITY OK: $(wc -l < "$HERE/hashes.txt" | tr -d ' ') protected blocks identical (OpenCode Go provider, config, Ollama provider, OOP prompts)"; else echo "INTEGRITY FAILED"; exit 1; fi

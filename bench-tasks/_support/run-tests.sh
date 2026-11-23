#!/bin/bash
# Validate a task's tests against a solution directory (reference or mutant).
# usage: run-tests.sh <task-dir> <starter-project-dir> <solution-src-dir> <TestMainClass>
# Overlays solution .java files (any layout; package decides the path via the
# FILE path relative to src/main/java) onto the starter, compiles starter+solution
# +support+tests, runs the tests and prints "TEST<TAB>id<TAB>PASS|FAIL<TAB>why".
set -e
TASK="$1"; STARTER="$2"; SOL="$3"; MAIN="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp -R "$STARTER"/src "$W/src"
(cd "$SOL" && find . -name '*.java' | while read f; do mkdir -p "$W/$(dirname "$f")"; cp "$f" "$W/$f"; done)
M2="$HOME/.m2/repository"
j() { ls "$M2/$1"/*/*.jar 2>/dev/null | grep -v -e sources -e javadoc | tail -1; }
CP="$(for a in org/springframework/spring-web org/springframework/spring-core org/springframework/spring-context org/springframework/spring-beans org/springframework/spring-aop org/springframework/spring-expression com/fasterxml/jackson/core/jackson-databind com/fasterxml/jackson/core/jackson-core com/fasterxml/jackson/core/jackson-annotations org/jspecify/jspecify io/micrometer/micrometer-commons io/micrometer/micrometer-observation; do j $a; done | paste -sd: -)"
JH="$(/usr/libexec/java_home)"
mkdir -p "$W/out"
"$JH/bin/javac" --release 17 -parameters -proc:none -nowarn -encoding UTF-8 -d "$W/out" -cp "$CP" \
  $(find "$W/src" -name '*.java' ! -name '*Application.java') "$HERE"/*.java "$TASK"/tests/*.java 2>&1 | grep -v '^Note:' || true
"$JH/bin/java" -Dbench.src="$W/src/main/java" -cp "$W/out:$CP" "$MAIN"

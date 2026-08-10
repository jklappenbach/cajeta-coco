# cajeta-coco focus stack

Top of stack executes next. Pop on completion; push tangents above their
parent. Each entry carries its done-when so a pop is checkable.

## Stack

```
[4] POPPED ✓ Condition coverage derivation — validated: toy hand-check
         exact (4/4 one-way operands flagged); logging needsQuote #1
         derived true 0× / false 8×; value-consumed tails excluded.
         MC/DC still blocked by [3].

[3] POPPED ✓ Per-test attribution — zero framework changes: coco
         disassembles Runner.bc from the classpath .cja and injects a
         ProbeDump::onTest(name) call into recordResult (name = ptr %1,
         source-ordered params verified via dbg_local metadata). Per-test
         delta dumps; Σ deltas + residue == aggregate (verified exact).
         cajeta-logging: 20 labeled profiles; 162/272 covered lines
         hang on a single test; framework selftests show covered=0.
         Deferred: embedding attribution into the HTML report (TSV +
         console only). MC/DC unblocked — per-test vectors now exist.

[2] POPPED ✓ SARIF export — 5 rules (dead-code=error, uncovered-line/
         untested-method=warning, partial-branch/condition=note), valid
         2.1.0 JSON on cajeta-logging. Exposed a classification bug:
         DI-synthesized construction bypasses source ctors, so a live
         @TestComponent's ctor read "dead". Fixed with the class-liveness
         guard (never claim dead when a sibling method executed) — dead
         claims 13→6, all defensible (ConsoleAppender + Log facade).
         Driver emits coverage.sarif each run.

[1] POPPED ✓ Annotated-source view — annotated.html: per-file source,
         llvm-cov ergonomics (negative info carries color: red uncovered,
         amber partial, plain covered + hit-count gutter), slug anchors
         deep-linked from report cards. Found + worked around a runtime
         defect en route: file-open intrinsics read Strings as C strings
         without NUL termination (Io.cstr / ProbeDump path copies).
         All 21 logging files render; 33 red rows == 33 uncovered lines.

[0] POPPED ✓ Graph refactoring — COMPLETE (final verdicts:
    DigraphTests 10/10 PASSED on the IndexGraph + recursive-preorder
    build; dev.cajeta.graph suite 49 passed / 0 failed / 1 skipped):
         a. DONE ✓ cajeta.collection.graph — IndexGraph + Digraph<N>, SCC included:
            interning (hash-scan, no double ownership), lazy CSR
            (counting sort), multi-root reachableFrom mask, bfsOrder,
            dfsOrder (iterative preorder), topoOrder/isCyclic (Kahn).
            - test/collections/DigraphTests.cpp: 7/7 PASS in the
              compiler repo's own gtest/JIT harness (auto-globbed).
            - skills/collection-graph-Digraph.md ships in the package.
            - Lesson: naming a local `stack` is a parse error (reserved
              placement keyword) — and a broken stdlib file poisons
              EVERY JIT compile while the compiler binary still builds;
              only the checked-in suite caught it.
            - Explicit zeroing throughout (heap arrays not assumed
              zero-initialized).
            SCC: landed (Kosaraju, 3 fixture tests). Commit: still (noted in the skill's sharp
            edges); COMMIT — runtime/src/cajeta/collection/graph/ and
            test/collections/DigraphTests.cpp are untracked in the
            compiler repo (Julian's call).
         a+ REFACTOR ✓ IndexGraph extracted: the index-level engine
            (implicit dense nodes, CSR, all algorithms) with Digraph<N>
            as the interning veneer — driven by (b)'s first-consumer
            need (Graph already has dense indices; forcing them through
            payload interning was waste). dfsOrder rewritten to TRUE
            RECURSIVE preorder (cursor frames, O(n) stack) after
            cajeta-graph's determinism fixture caught mark-on-push
            divergence on diamond shapes. VERIFIED: 10/10.
         b. DONE* dev.cajeta.graph rebased: Core.cajeta bridge
            (mirror/symmetricMirror/renumber), Traversal.bfs+dfs and
            Components.connected/weakly/stronglyConnected delegate to
            the stdlib engine (~150 lines of duplicated algorithm code
            removed). Suite: 48/49 on first run — the 1 DFS-order fail
            drove the a+ fix; FINAL: 49/0/1 — green.
            NOT rebased (correctly): Graph's storage — weights, typed
            edges, attribute columns, NetworkX semantics are the
            library's spec'd domain (its plan 1.2.4 already rejected a
            shared immutable store once).
         c. DONE ✓ dev.cajeta.xref at /home/julian/code/cpp/cajeta-xref:
            Keys (normalize/keyOf) + XrefDoc (streaming two-pass parse,
            typed read surface: calls/overrides/decls, signatureOf,
            declSiteOf, callersOf). Built: build/archive/
            dev.cajeta.xref-0.1.0.cja. Validated against the real
            1.9 MB logging xref via (d).
         d. DONE ✓ coco is policy-only: CallGraph = XrefDoc + stdlib
            Digraph + coco's three policies (overrides-as-edges,
            coverage-seeded roots, err-toward-not-dead). Engine builds
            with --classpath=<xref cja>; logging report reproduces
            exactly (132 methods, 89.1/55.2/66.6).
            UNCOMMITTED across repos: compiler (graph pkg + tests),
            cajeta-xref (whole repo, no git init), cajeta-graph
            (Core.cajeta + Traversal + Components), coco (everything).
```

## Conventions

- Compiler repo: /home/julian/code/cpp/cajeta (stdlib source under
  runtime/src/cajeta/; embedded at compiler build).
- Sibling libs: /home/julian/code/cpp/cajeta-graph, new cajeta-xref.
- Known toolchain defects and workarounds: see project memory
  (cajeta-toolchain-defects) — enum locals, JSON DOM grow, getString.

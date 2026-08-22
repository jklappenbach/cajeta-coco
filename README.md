# cajeta-coco

Coverage, dead-code and mutation analysis for Cajeta — written in Cajeta.


## Try it

[`samples/tour`](samples/tour/README.md) is a runnable consumer project with
one class per finding coco reports — dead code, reachable-but-untested, a
surviving mutant, a high-CRAP method, a redundant test, and a control that
produces none. It resolves `dev.cajeta.coverage` from Olla rather than from
this checkout, so it demonstrates what adopting coco looks like rather than
what developing it looks like.

```
./samples/tour/run.sh     # cover + mutate, then walk the artifacts
./scripts/check-tour.sh   # the same run, with every finding asserted
```

---

## 1. Market analysis: what coverage tools actually provide in 2026

### 1.1 The commodity baseline

Every mainstream tool — JaCoCo, coverage.py, Istanbul/nyc, gcov, Codecov,
Coveralls — provides the same core: line/statement %, branch %, function %,
an HTML report with red/green source annotation, lcov / Cobertura / SARIF
export, a CI gate on a minimum percentage, and PR/diff coverage. None of that
differentiates anything any more; it is table stakes.

### 1.2 Where the leaders actually differentiate

| Capability | Who has it | Why it matters |
|---|---|---|
| **Region / sub-expression coverage** | llvm-cov (source-based) | Tracks each sub-expression independently rather than compiled branch points, so results map back to source conditions instead of to lowered CFG edges |
| **Condition + MC/DC coverage** | llvm-cov, VectorCAST, Bullseye | Per-leaf-condition true/false inside `&&`/`\|\|`; MC/DC proves each condition *independently* affects the decision. Mandatory for DO-178C / ISO 26262 |
| **Risk ranking (CRAP score)** | Clover, CoverageBrowser | Cyclomatic complexity × coverage → one score per function; >30 is high risk. Converts an open-ended hunt into a **prioritised queue** |
| **Test-gap analysis** | Teamscale | Intersects *changed* code with *untested* code. Untested changes are ~5× likelier to carry a defect |
| **Per-test attribution** | coverage.py contexts, Teamscale | "Which test covers this line" — diagnoses failures and exposes redundant tests |
| **Mutation testing** | PIT, Stryker, mutmut | Answers what coverage cannot: a line can execute with nothing asserting on it |
| **Hierarchical visualisation** | Codecov (sunburst), NDepend / Understand (treemap) | Navigating a large tree to find cold spots. Research finds **icicle plots beat treemaps** for navigation and hierarchy comprehension |
| **Dead-code detection** | Knip, Vulture, Periphery, PMD | A *separate tool category* today — essentially nobody fuses it with coverage |

### 1.3 The two gaps everyone complains about

1. **Coverage tells you what ran, not whether a test would catch a bug.**
   Execution is not verification. Mutation testing is the only broadly
   available answer, and most teams never turn it on because it is too slow.
2. **Tools report uncovered lines but do not explain *why* they are uncovered
   or *what test would reach them*.** DeepSource is among the few attempting
   risk-ranked gaps plus generated test stubs.

### 1.4 The structural insight coco is built on

Uncovered code has two completely different causes, and almost every tool
conflates them:

- **Statically unreachable** — nothing can call it. The fix is `git rm`.
- **Reachable but untested** — the fix is a test.

Conflating these is precisely why coverage reports generate busywork: they
demand tests for code that should be deleted, and they bury genuinely risky
gaps in the noise. **Fusing static reachability with dynamic coverage is the
single highest-value differentiator available**, and Cajeta hands us the call
graph needed to do it (`--emit-xref`).

---

## 2. What Cajeta already had — and the real gap

Traced through the compiler rather than taken from its documentation:

- `build-tools/plugins/code-coverage/` is a well-documented plugin with
  instrument/collect/report actions, typed excludes and four report formats.
  **It is aspirational**: its `Instrument` action shells out to
  `cajeta --instrument=coverage --coverage-grain=…`, and *that flag does not
  exist in the compiler*.
- `src/cajeta/buildtool/CoverageReport.cpp` is a *consumer* of a coverage-map
  format that nothing produces.
- `--profile-counters=on|off` appears in `--help` and is plumbed through
  `CompilerFlags`, but **has no codegen implementation** (no reference in
  `src/cajeta/type/`, `method/` or `ir/`).

So there was no working coverage. What *does* exist is better than building
instrumentation from scratch — all of the following was verified by compiling
real code and reading the emitted IR:

1. **Line probes already exist and are on by default.** With no special flags
   the compiler emits, at every statement boundary and inside every basic
   block:
   ```llvm
   call void @__cajeta_line_enter(ptr @.cajeta.framedesc)  ; {type, method, file}
   call void @__cajeta_line_mark(i32 5)                    ; literal source line
   ```
   (`--debug-info=line` is the default, and it means this shadow-stack
   mechanism — *not* DWARF metadata. The published `.cja` bitcode carries no
   `!dbg` records at all.)
2. **`--emit=ir` yields per-class `.ll`**, plus `cajeta.runtime.__stdlib__.ll`.
3. **`--emit-xref` on a full compile produced a 2,692-edge call graph**
   (`caller`, `callee`, `virtual`, file, line) — static reachability.
4. `--tree-shake=report`, `--keepset-json`, `--why-kept` give the compiler's own
   RTA verdict to cross-check dead-code findings.
5. `.cja` archives carry **bitcode and source together**; `dev.cajeta.unit`
   provides `@Test`, `Assert`, `Runner` and mocks.

Net: coco delivers line, branch and condition coverage plus dead-code analysis
**without modifying the compiler**.

---

## 3. The performance constraint that shapes the whole design

Measured on this machine, hello-world scale:

| Step | Time |
|---|---|
| `cajeta --emit=ir` | **79 s** |
| `cajeta --emit=exe` | **89 s** |
| `cajeta jit-run` | **95 s** |
| second identical build (cache warm?) | **83 s** — no caching benefit |
| `cajeta lower` one user module → `.o` | **0.03 s** |
| relink whole program from `.o` files | **0.18 s** |

Every cajeta front-end invocation re-parses and re-lowers the embedded stdlib.
That cost is per-process and does not amortise.

**Consequence:** any design that shells back into `cajeta` per instrumented
rebuild or per mutant is unusable — 100 mutants would be 2.4 hours. So coco
pays the front-end cost **exactly once**, harvests the IR, and owns everything
downstream with LLVM directly — through `cajeta lower` and `cajeta disasm`,
which expose the **compiler's own** LLVM. A separately installed `llc` cannot
be assumed to exist and, when it does, cannot be assumed to be the same LLVM:
a packaged cajeta links LLVM in and ships no CLI tools, so `llc` resolves to
the distro's, and a version skew surfaces as `unterminated attribute group`
from a parser that names neither party. A mutant becomes one module re-lowered
plus one link: **well under a second**. That is the difference between mutation
testing being a headline feature and being a demo that nobody runs.

---

## 4. Architecture

```
cajeta --emit=ir --emit-xref     ~80 s, ONCE
        │
        ├── per-class .ll ──► instrument (Cajeta engine) ──► .ll + sites.tsv
        │                        line / function / branch probes
        │
        ├── stdlib .ll ────────────────────────────────┐
        │                                              │
        └── xref.json ──► call graph ──► reachability  │
                                                       ▼
                     cajeta lower (0.03 s/module) ──► .o ──► link (0.2 s)
                                                                  │
                                                    run ──► coco.profile
                                                                  │
                                          sites.tsv + profile ──► reports
```

### 4.1 Instrumentation

`cajeta.coco.ir.Instrumenter` rewrites emitted LLVM IR:

- **Function** — a probe after the prologue's `__cajeta_line_enter`.
- **Line** — a probe after each `__cajeta_line_mark`.
- **Branch / condition** — every `br i1` has *both* edges split through
  generated trampoline blocks:

  ```llvm
  br i1 %c, label %if_then, label %if_merge
  ```
  becomes
  ```llvm
  br i1 %c, label %coco.t.7, label %coco.f.8
  ...
  coco.t.7:
    call void @"cajeta.coco.rt.Probe::hit(id:int64)"(i64 7)
    br label %if_then
  ```

  Trampolines rather than a probe at the head of the target block, because a
  block reachable from two branches would otherwise conflate their arms — an
  arm is a property of the **edge**, not of the block.

**Splitting an edge means fixing the phis.** Cajeta lowers `a && b` as:

```llvm
entry:       br i1 %lhs, label %land_rhs, label %land_merge
land_rhs:    ... br label %land_merge
land_merge:  %d = phi i1 [ %rhs, %land_rhs ], [ false, %entry ]
```

so the commonest interesting decision in any codebase is exactly the shape that
carries a `phi`. The instrumenter therefore processes each function as a unit
and repoints phi predecessor operands at the trampoline that now precedes the
block. Verified: user IR at `-O0` otherwise contains no phis (0 in the sample
modules); the stdlib carries 3,399.

### 4.2 Condition coverage without extra probes

Because `&&`/`||` short-circuit, edge counts alone recover the right-hand
operand's own true/false counts. For `a && b`:

- `RHS evaluated` ⟺ the `entry → land_rhs` edge was taken
- `decision true` ⟺ `LHS true ∧ RHS true`

therefore **RHS-true = decision-true count**, and
**RHS-false = count(entry→land_rhs) − decision-true**. The `||` case is the
mirror image. `Site` records each branch's own block and target block precisely
so the analysis layer can recognise `land_rhs` / `land_merge` / `lor_rhs` /
`lor_merge` and apply this — no additional instrumentation.

### 4.3 The probe runtime

`cajeta.coco.rt.Probe` is a flat `int64[]` indexed directly by probe id — one
bounds check and one increment per hit, no hashing, no allocation, no locking.
Probes fire on every statement of every test, so anything costlier would
dominate the measured run.

`cajeta.coco.rt` is **never instrumented** (that is what stops `hit` recursing),
and `ProbeDump` deliberately reimplements its own integer formatting rather than
sharing `cajeta.coco.util.Text`: in a self-coverage run the shared helper would
be instrumented, and its probes would fire *while the table is being
serialised*.

---

## 5. Layout

```
bin/coco                     orchestration wrapper (discovery + toolchain)
tools/lintd.sh               warm lint daemon for development
src/main/cajeta/cajeta/coco/
  Coco.cajeta                engine CLI (instrument / entry / report / lcov / mutants / mutate)
  rt/Probe.cajeta            flat counter table (linked into the measured program)
  rt/ProbeDump.cajeta        `coco-profile v1` writer
  ir/Instrumenter.cajeta     the IR rewriter (probes, trampolines, phi patching, guard filter)
  ir/Mutator.cajeta          icmp-predicate mutation: enumerate + apply
  ir/IdGen.cajeta            dense global probe ids
  model/Site.cajeta          one probe site (file, line, owner, method, kind, block, target)
  model/SiteKind.cajeta      function / line / branch-true / branch-false
  model/SiteTable.cajeta     probe-map encode/decode
  model/HitProfile.cajeta    hit counts; merge + per-test attribution model
  analysis/Coverage.cajeta   sites + profile -> per-file stats
  analysis/FileStats.cajeta  per-file totals + uncovered detail
  analysis/CallGraph.cajeta  streaming xref parse, owner::name/argc keys, BFS reachability
  analysis/Crap.cajeta       CRAP scoring, ranked
  report/Html.cajeta         the HTML report
  report/Lcov.cajeta         lcov.info emitter
  util/Text.cajeta           byte-level text helpers (String has no split)
  util/Io.cajeta             whole-file text IO
  util/IntList.cajeta        fixed-capacity int64 list (ArrayList<int64> boxes)
```

The engine works on explicit inputs and `bin/coco` does discovery, because
`cajeta.io.file` has **no directory walk in v1**.

---

## 6. Status

**Working and verified:**

- The performance model in §3 (all timings measured).
- The compiler-capability findings in §2 (all read from emitted IR).
- The whole codebase compiles, and `.build/coco-engine` links and runs.
- **Instrumentation is verified on real IR.** Run against a class exercising
  `&&`, `||` and a loop, the engine emitted 37 probe sites with the expected
  short-circuit structure:

  ```
  2  branch-true   line 5  entry       -> land_rhs     # the `a > 0` LHS
  3  branch-false  line 5  entry       -> land_merge
  4  branch-true   line 5  land_merge  -> if_then      # the whole && decision
  5  branch-false  line 5  land_merge  -> if_merge
  ```

  Phi operands were correctly repointed at the new predecessors —
  `[ false, %entry ]` became `[ false, %coco.f.3 ]`, and the `||` case
  `[ true, %entry ]` became `[ true, %coco.t.10 ]` — and **`llvm-as` accepts
  the rewritten module**, so the output is valid IR rather than plausible text.

**The full pipeline runs end to end.** `coco run` on a sample project:

```
coco: [1/6] compiling (two front-end passes)
coco: [2/6] instrumenting 1 modules
coco: assigned 39 probes
coco: [3/6] wiring entry probe.Cond::main
coco: [4/6] lowering instrumented modules to objects
coco: [5/6] linking
coco: [6/6] running measured binary
coco: exit 5
coco: lines 68.7% (11/16)  branches 42.8% (6/14)
```

The measured program returned **5**, which is `both(1,1)=1 + either(0,1)=1 +
loop(3)=3` — instrumentation preserved program semantics, not just link-ability.
The report correctly identifies `neverCalled` as never entered, the two
unreachable `return 0` fall-throughs, and the two genuinely partial decisions.

### Compiler-inserted guards are excluded — and why that is not optional

Before filtering, the same run reported **24 branches and 5 partial decisions**.
Three of those "partial decisions" were lines like `s = s + i` and `i = i + 1`:
cajeta lowers integer arithmetic with an overflow check (`ofc.add.ok` /
`ofc.add.trap`), and the trap arm ends in `llvm.trap`. It is unreachable in any
passing run, so it can never be covered by any test that anyone could write.

Left in, those guards would have permanently capped branch coverage and buried
the two real gaps under noise. Filtering them (`bounds_`, `ofc.`, `div.`,
`mod.`, `cast_`) takes the same run to **14 branches and 2 partial decisions** —
and those two are exactly the `&&` and `||` whose second operand was never
exercised. gcov and llvm-cov exclude their own compiler-inserted checks for the
same reason.

### Dead code vs untested — the classification works end to end

`coco run` captures `--emit-xref` alongside the IR; the report step
streaming-parses it (calls, overrides, method declarations), normalizes both
xref keys (`probe.Cond::both(int32,int32)`) and IR-mangled probe names
(`both(b:int32,a:int32)`) to `owner::name/argc`, and BFS-walks reachability
from the entry. Verified on a demo with one of each population:

> **Dead code (1)** — no call path from the entry reaches these. Delete rather
> than test. `probe.Cond.int32 neverCalled(int32 n)` declared at
> probe/Cond.cajeta:30
>
> **Reachable but never tested (1)** — `probe.Cond.int32 guarded(int32 n)`
> declared at probe/Cond.cajeta:26 — called from probe.Cond::main/0 at
> probe/Cond.cajeta:39

Collapsing overloads by arity is deliberate: a call to either same-arity
overload marks both reachable, so the analysis can *miss* dead code but can
never claim a live method is dead — the only acceptable error direction for a
finding that says "delete this". Overrides edges make a reachable base method
reach every override (conservative for virtual dispatch, same direction).
When the xref is missing or the entry isn't found, the report degrades to
plain coverage — "dead" is never claimed without the graph behind it.

### Mutation testing — sub-second mutants, real findings

`coco mutate` runs the classic verification check coverage cannot: change the
program slightly; if the tests still pass, they never asserted that behavior.
v1 mutates `icmp` predicates (boundary `sgt↔sge` `slt↔sle` `ugt↔uge`
`ult↔ule`, negation `eq↔ne`) — one-token changes that can never produce an
unlinkable module, chosen over arithmetic swaps because cajeta lowers checked
arithmetic through `llvm.*.with.overflow` intrinsics that would need
declaration rewrites. Each mutant is one engine rewrite + `cajeta lower` +
relink (replaying the recorded `link.tsv` line) + run
(~0.3 s); **8 mutants completed in 1.9 s total** — the payoff of the
harvest-IR-once architecture (a per-mutant front-end run would have been 12
minutes). Mutants in code the suite never executed are skipped, PIT-style:
they cannot be killed, and the coverage report already names that code.
Synthesized functions (reflection dispatch) are never mutated — a survivor
there is noise, not a finding.

On the demo, the survivors were all true positives — boundary conditions the
"suite" never probes (`a>0 → a>=0` survives because nothing tests `a == 0`),
and the loop-condition mutant was killed because it changed the program's
result.

### Exports and ranking

- **LCOV** (`coco run` emits `lcov.info`) — the lingua franca for IDE gutters,
  `genhtml`, Codecov/Coveralls and diff-coverage bots. `DA` per-line counts
  take the max over a line's probes (summing would invent executions);
  never-evaluated branch arms emit `BRDA:...,-` per the spec.
- **CRAP ranking** in the HTML report — `comp² × (1−cov)³ + comp` per method,
  worst first. Complexity comes free from the instrumentation itself
  (1 + branch-pairs, guard branches already excluded), so the score needs no
  separate parser. Scores are integer-tenths arithmetic, so CI diffs never see
  float drift. Hand-checked: `neverCalled` (comp 2, cov 0) → 6.0.

### Compiler and stdlib defects worked around

All found by building this tool, all worked around in-tree rather than waited
on, all reproducible:

- **`SIGSEGV` in codegen on a local of enum type.** `SiteKind k = s.getKind();`
  crashes cajeta 0.18.1 in `HeapField::getOrCreateAllocation` via
  `LocalVariableDeclaration::generateCode`. Comparing the accessor inline
  avoids it. The stdlib itself compiles the same shape (e.g.
  `JsonReader.skipValue`), so the defect is specific to user-module codegen.
- **The JSON DOM tier frees its own elements on growth.** `JsonObject.grow`
  and `JsonArray.grow` copy entries with a borrowing `=` and then install the
  new backing array with `this.data #= dst` — dropping the old *owning* array,
  which frees every element the new array now points at. Any document with an
  array beyond the initial capacity corrupts memory *during* `Json.parse`
  (observed as SIGSEGV at fault addresses like `0x28`: poison-filled pointer +
  field offset, reproducible at exactly n≥11 elements). The correct pattern is
  four lines away in the same stdlib: `ArrayList.reserve` uses a forwarding
  `grown[i] #= this.data[i]`, and its comment even names the discipline. The
  fix is `=` → `#=` in both grows; until then, the streaming `JsonReader`
  (which never builds a DOM) is the only safe JSON tier — coco's xref parser
  uses it, two-pass, 1.9 MB in 0.08 s.
- **`JsonObject.getString` returns an owned String inside a by-value stack
  `Optional`** — the String dies with the callee's temporary and the caller
  reads freed memory. Nothing else in the stdlib calls `getString`; the safe
  route is `get(key)` + `kind()` + `asString()` (an owned copy with a plain
  transfer-by-return contract).
- **`cajeta.aot.Profile` shadows a same-named user class.** A class named
  `Profile` in `cajeta.coco.model`, explicitly imported, still resolved to the
  stdlib annotation. Renamed to `HitProfile`.
- **File-path intrinsics read Strings as C strings.**
  `__cajeta_file_open(const char*, mode)` trusts NUL termination, but the
  lowering passes a String's raw bytes and cajeta Strings are not
  NUL-terminated. Literal paths are safe (constants carry a NUL);
  StringBuilder-built paths fail *nondeterministically* — fine on fresh zeroed
  pages, corrupted on poison-filled reuse. Observed at the syscall:
  `openat("...CapturingAppender.cajetajeta\241")` — the path plus the tail of
  a previous longer path plus the 0xA1 poison byte. Workaround: every path
  funnels through a copy into `int8[n+1]` with an explicit trailing NUL
  (`Io.cstr`; a local copy in the probe runtime).

**Reporting** ships as a self-contained HTML document: hero tiles for
line/branch/function, a worst-first file table, the **CRAP-ranked method
table**, a **line ribbon** (one cell per measurable line, in source order, so
untested regions show up as contiguous runs), and per-file gap lists that split
never-entered methods into **dead (delete)** vs **untested (here is the
signature and the callers to imitate)**. Colours are the reserved status
palette validated for CVD separation (worst adjacent pair ΔE 11.3 protan /
24.4 tritan; normal vision 27.6); every colour is paired with a visible count,
and the file table doubles as the required table view. `lcov.info` is emitted
alongside for the existing ecosystem.

**Commands** (see `bin/coco`):

```
coco run    --src <root> --entry <pkg.Class.method> [--out <dir>]   # full pipeline
coco report --out <dir> [--entry <sym>]                             # re-render, no rebuild
coco mutate --out <dir>                                             # mutation testing over a run
```

### Validated on a real cajeta-unit project

`coco run` against **cajeta-logging** — 25 classes, lib + tests compiled
together under `--profile=test`, cajeta-unit supplied as a `--classpath`
archive, tests discovered reflectively by `Runner.runAll()`:

- **All 20 tests pass under instrumentation** (`@Test` discovery,
  `@BeforeEach`, `@Disabled`, DI-selected `@TestComponent` appender) — the
  instrumented binary is behaviorally identical to the reference build.
- **Lines 89.1% (272/305), branches 55.2% (138/250).**
- **Reflection broke naive reachability, and the fix is principled.** The
  static graph reaches only 2 methods from the test entry (discovery is
  reflective), which would have called live library code "dead". Coco now
  seeds the BFS with every method the profile shows *executed* — each one is
  ground-truth evidence of a live path the graph missed — lifting reachability
  to 132 methods. The result is surgical: `ConsoleAppender()`'s constructor is
  dead *under the test profile* (DI selects `CapturingAppender` instead), while
  `ConsoleAppender.append` is correctly reported "reachable via virtual
  dispatch, never tested". "Dead" now means *unreachable from the entry AND
  from everything that demonstrably ran*.
- **Mutation: 174 mutants, 40 killed, 134 survived (23%), 7 skipped as
  uncovered.** On a suite that is green and 89% line-covered. The survivor map
  names the gap precisely: `JsonlEncoder` mutants die (EncoderTest asserts on
  JSONL output) while **38 of 38+ `TextEncoder` mutants survive** — the
  human-readable encoder is *executed* by the suite but its output is never
  asserted. That is the exact "execution is not verification" blind spot
  coverage cannot see, demonstrated on real code.

`coco run` grew `--classpath`, `--profile` and `--exclude` for this (the unit
framework stays out of the coverage denominator; classes that remain inside a
classpath archive are linked from the reference pass's objects).

### The second wave (all validated on cajeta-logging)

- **Condition coverage, derived not probed.** Short-circuit operands'
  true/false splits recovered arithmetically from edge counts (§4.2), chains
  and mixed `&&`/`||` included; value-consumed tails (e.g. `return a || b;`)
  reported as underivable, never guessed. Toy hand-check exact; on logging it
  found `needsQuote`'s first operand true 0× over 8 evaluations.
- **Per-test attribution, zero framework changes.** coco disassembles
  `Runner.bc` from the classpath archive and injects a `ProbeDump::onTest`
  call into `recordResult` — the one point the framework crosses once per
  test, name in hand. Per-test delta profiles; Σ deltas + exit residue
  reproduces the aggregate exactly. On logging: 162 of 272 covered lines hang
  on a single test; the framework's own selftests correctly show `covered=0`.
- **SARIF 2.1.0 export** — five rules (dead-code=error, uncovered-line and
  untested-method=warning, partial-branch and condition=note) for PR
  annotation. Writing it exposed a classification bug worth its own line:
  compile-time DI constructs components through synthesized paths that bypass
  source constructors, so a live `@TestComponent`'s ctor read "dead". The fix
  is the **class-liveness guard**: never claim a method dead when a sibling
  method executed. Dead claims went 13 → 6, every survivor defensible.
- **Annotated source** (`annotated.html`) — the code itself, llvm-cov
  ergonomics (negative information carries the color), hit counts in the
  gutter, deep-linked from the report's file cards.
- **`agents/focus.md`** tracks the working stack; `coco run` now emits
  coverage.html, annotated.html, lcov.info, coverage.sarif, attribution.tsv
  and mutation inputs from one invocation.

### The graph refactoring (multi-repo)

- **stdlib** gained `cajeta.collection.graph`: `IndexGraph`, the index-level
  engine (implicit dense nodes, lazy CSR via counting sort, multi-root
  reachability mask, BFS, recursive-preorder DFS, Kahn topo, Kosaraju SCC
  with condensation-ordered labels) and `Digraph<N>`, the interning veneer.
  Checked-in gtest/JIT tests (`test/collections/DigraphTests.cpp`) and a
  package skill. The two-layer split was forced by the first real consumer:
  `dev.cajeta.graph` already carries dense indices, and payload interning
  would have round-tripped every id through hashing for nothing.
- **`dev.cajeta.xref`** (new sibling library) owns the `--emit-xref` document:
  `Keys` (the `owner::name/argc` normalization) and `XrefDoc` (streaming
  two-pass parse, typed read surface). Ships as a `.cja`; validated against
  the real 1.9 MB logging index.
- **coco is policy-only** where the graph is concerned: `CallGraph` =
  `XrefDoc` + stdlib `Digraph` + the three coco policies (overrides-as-edges,
  coverage-seeded roots, err-toward-not-dead). The engine builds with
  `--classpath=<dev.cajeta.xref .cja>`; the logging report reproduces
  identically.
- **`dev.cajeta.graph`** delegates `Traversal.bfs/dfs` and all three
  `Components` functions to the stdlib engine through a small `Core` bridge —
  its *storage* (weights, typed edges, attribute columns, NetworkX semantics)
  deliberately stays its own, per its spec's earlier architecture decision.
  Its determinism fixture caught a real difference between mark-on-push DFS
  and true recursive preorder; the stdlib engine now guarantees the
  recursive order.

**Remaining:** MC/DC proper (per-test condition vectors — attribution now
provides the data).

### A note on the development loop

`tools/lintd.sh` drives the compiler's `--lint-server` to get ~2 s checks
instead of ~70 s. **It does not do full semantic resolution** — it accepted a
call to a method that does not exist. Treat it as a syntax smoke test only;
the real check is a compile.

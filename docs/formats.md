# coco artifact formats — the published interface

These are the files coco writes for other tools to read. They are a **published
interface**, not internal detail: the IntelliJ plugin consumes them across a repo
boundary on an independent release cycle, so a change here is a change to an API.

Three formats, each independently versioned:

| File | Version marker | Written by |
|---|---|---|
| `sites.tsv` | `coco-sites v1` | `coco instrument`, once per run |
| `coco.profile` | `coco-profile v1` | the probe runtime, at program exit |
| `attribution.tsv` | `# coco-attribution v1` | `coco attribution` |

## The compatibility rule

**Any incompatible change bumps the version.** Adding a field to the end of a row
is compatible; reordering, removing, retyping, or changing the meaning of a field
is not, nor is adding a new enumerated value that older readers would misread.

**A reader that does not recognise a version must refuse the file.** It must not
parse what it recognises and skip the rest.

That rule is not pedantry. Probe ids in the profile are *positional against the
site table*, so a profile read under the wrong assumptions attributes hits to the
wrong sites — the tool reports lines green that never executed, and nothing
downstream can detect it. A refusal is recoverable; a plausible wrong number is
not. coco enforces this itself: `SiteTable.decode` and `HitProfile.decode` throw
`CocoFormatException` on a header they do not recognise.

---

## `coco-sites v1` — the probe map

```
coco-sites v1
<id>	<kind>	<line>	<decision>	<file>	<owner>	<method>	<block>	<target>
```

One header line, then one tab-separated row per probe site. Nine fields, always;
a row with fewer is an error reported with its line number, never skipped.

| Field | Type | Meaning |
|---|---|---|
| `id` | integer | Probe id. **Dense and global across the run**, and the join key to the profile. |
| `kind` | enum | `function` · `line` · `branch-true` · `branch-false`. An unrecognised value is an error, not a fallback. |
| `line` | integer | 1-based source line. |
| `decision` | integer | **Declared** as the decision-grouping field, but the current engine writes `-1` on every row, branches included. Do not group on it. See below. |
| `file` | text | Source path as the compiler saw it. |
| `owner` | text | Declaring type, canonical (`probe.Cond`). |
| `method` | text | Method with its parameter signature. |
| `block` | text | IR basic block the probe sits in. |
| `target` | text | Branch target block. **Empty** for non-branch kinds, not `-`. |

The free-text fields come last and are tab-free by construction, so a reader may
split on tab without quoting rules.

**A document carries exactly one header.** `sites.tsv` is assembled by appending
one module at a time, and the header belongs to the first module only —
`SiteTable.encode` emits a complete document, `encodeRows` emits rows to append.

### Pairing branch arms

`decision` is unpopulated, so arms are paired by **`(file, owner, method, block)`**.
A basic block ends in at most one conditional branch, which makes `block` the
natural key — but block *names* repeat across methods, since every method has an
`entry`, so the enclosing method is part of the key.

Grouping on `decision` finds nothing; grouping on `block` alone over-merges. Both
were caught by the plugin's reader tests against the fixture rather than by
reading this document, which is the argument for having the fixture.

### What a consumer may assume
- `id` is unique within a run and indexes the profile directly.
- Every `branch-true` has a matching `branch-false` in the same
  `(file, owner, method, block)`.
- Compiler-inserted guard branches are **already excluded**; a consumer must not
  filter again, and must not expect them.
- Ordering is by module then by id; do not depend on it beyond that.

### What a consumer must not assume
- That ids are stable across runs — they are dense per run, not durable.
- That `file` is absolute, or relative to any particular root.
- That `method` is a stable identifier; it carries a signature and will change
  when the signature does.
- That `decision` means anything. It is reserved and currently always `-1`.

---

## `coco-profile v1` — hit counts

```
coco-profile v1
size <n>
<probe-id> <count>
```

Written by the probe runtime at exit. `size` is the probe-table length. Rows are
space-separated, and only non-zero counts appear — a probe absent from the file
was never hit.

For per-test dumps the runtime writes a `test <name>` line before `size`, and
emits one such block per test.

### What a consumer may assume
- `probe-id` indexes the site table of **the same run**.
- A missing id means zero hits.
- Counts are cumulative for the labelled scope.

### What a consumer must not assume
- That every id in `0..size` appears.
- That blocks appear in test-execution order.

---

## `coco-attribution v1` — which test covered which line

```
# coco-attribution v1
# test	<name>	covered=<n>	unique=<n>
<file>	<line>	<n-tests>	<test>|<test>|…|+<overflow>
```

Note the version marker is **inside a comment**, unlike the other two formats;
a reader must strip `#` before matching it. The `# test` block that follows is a
per-test summary, then one row per covered line.

The test list is `|`-separated and **truncated**, with `+N` naming how many were
omitted. A consumer must treat the list as a sample, not a complete set — the
counts in field 3 and in the `# test` header are authoritative.

---

## Conformance fixture

`fixtures/conformance/` holds a known-good artifact set from a real two-module
run, with `EXPECTED.md` stating what a correct reader derives from it. It is the
contract's executable half: a consumer should be able to be written against this
document plus that fixture, without reading coco's source.

The fixture lives here, in coco, because coco owns the format — this is the
source of truth. A consumer that cannot reach across repos at build time (the
IntelliJ plugin cannot: Gradle has no path to a sibling checkout that may not
exist on CI) should vendor a copy WITH a drift check that asserts byte-identity
when a coco checkout is available, and skips when it is not. Copying silently is
what creates drift; copying with a check does not.

# Conformance fixture — expected interpretation

A known-good artifact pair from a real two-module `coco run`, with what a correct
reader must derive from it. Together with [`docs/formats.md`](../../docs/formats.md)
this is enough to write a consumer without reading coco's source — which is the
point: the format is the interface, not the implementation.

Source: a two-class project (`probe.Cond`, `probe.Helper`) exercising `&&`, `||`,
a loop, a guarded branch, and one deliberately-uncalled method.

## Files

| File | Format |
|---|---|
| `sites.tsv` | `coco-sites v1` |
| `coco.profile` | `coco-profile v1` |

## What a correct reader derives

### From `sites.tsv`
- Exactly **1** header line. A second `coco-sites v1` line anywhere in the file is
  a malformed row, not a header — a document carries one.
- **47** site rows, ids **0–46**, dense with no gaps.
- Nine tab-separated fields per row.
- Kind distribution:

  | kind | count |
  |---|---|
  | `line` | 24 |
  | `branch-true` | 8 |
  | `branch-false` | 8 |
  | `function` | 7 |

- `branch-true` and `branch-false` counts are **equal**, because arms are emitted
  in pairs — 8 decisions, two arms each.
- Arms pair by `(file, owner, method, block)`. **`decision` is `-1` on every row**
  here and is not a usable key; block names alone over-merge, because every method
  has an `entry` block.
- `block` and `target` are **empty** on `function` and `line` rows.
- Two distinct owners: `probe.Cond` and `probe.Helper`. Both modules are present
  under one header — this fixture exists largely to pin that.

### From `coco.profile`
- Header `coco-profile v1`, then `size 47` — matching the site count exactly.
- **29** hit rows. A probe id absent from the file was **never hit**; it is not an
  error and must not be read as a parse failure.
- Every id present is in `0..46` and indexes `sites.tsv` directly.

### Joined
- **29 of 47** probes hit. The 18 absent ids are genuine misses, including the
  deliberately-uncalled method's `function` probe and its lines.
- Per-line hit count is the **maximum** over that line's probes, never the sum.
  Summing invents executions: several probes can sit on one line and a line
  executed once would report as executed many times.
- A `branch-true` present with its `branch-false` absent is a **partially covered
  decision** — distinct from an uncovered one, where neither arm appears.

## What a reader must reject

Derived from this fixture by mutation; each is a test a consumer should carry.

| Mutation | Required behaviour |
|---|---|
| Header changed to `coco-sites v2` | Refuse the file, naming the version found |
| Header removed entirely | Refuse — there is no v0 |
| A row truncated to fewer than 9 fields | Refuse, **reporting the 1-based line number** |
| A `kind` changed to an unrecognised value | Refuse — never coerce to `line` |
| `coco.profile` header changed to `v2` | Refuse |

Silently coping with any of these produces confident, wrong coverage: lines
reported green that never ran, with nothing downstream able to tell.

## Regenerating

This pair came from a verified run, not by hand. To refresh it, run coco over a
two-module project and copy `sites.tsv` and `run/coco.profile` — then update the
counts above, because they are assertions, not description.

Note `.build/coco-engine` is a separate binary from the `.cja`. Rebuild it before
regenerating, or the fixture will capture the behaviour of stale code.

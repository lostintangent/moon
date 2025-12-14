# Zig Contribution Cheat Sheet (idiomatic, clean, fast)

## 1) Mindset: make costs + intent obvious

* Be explicit about **allocation**, **error propagation**, **mutability**, and **lifetimes** (don’t hide them in globals or “magic helpers”). ([Zig Programming Language][1])
* Prefer code that reads like a proof: invariants, preconditions, and cleanup are *near* the code they relate to. ([Zig Programming Language][1])

---

## 2) Formatting & naming (don’t bikeshed—automate)

* Run **`zig fmt`** on everything; treat formatting diffs as noise. ([Zig Programming Language][1])
* Follow the official naming conventions:

  * `camelCaseFunctionName`, `TitleCaseTypeName`, `snake_case_variable_name`
  * “Namespace-only” containers and directories: `snake_case`
  * File names: `TitleCase` if it exports top-level fields/types; otherwise `snake_case` ([Zig Programming Language][1])
* Avoid garbage-bin names: `Value`, `Data`, `Context`, `Manager`, `utils`, `misc`, initials. ([Zig Programming Language][1])
* Avoid redundant names in fully-qualified paths (files/modules already provide namespaces). ([Zig Programming Language][1])

---

## 3) API design (the big 3: allocators, errors, ownership)

### Allocators

* **Libraries accept `Allocator` parameters**; callers decide policy. ([Zig Programming Language][1])
* Don’t introduce hidden allocations in “utility” functions—make allocation part of the signature (allocator in, owned buffer out).

### Errors

* Default to **propagate with `try`**, handle locally with `catch` when you can add meaning/recovery.
* Avoid **`anyerror`** (global error set) in APIs; it blocks the compiler from knowing/communicating what can fail. ([Zig Programming Language][1])
* Use **explicit error sets** when you need recursion, stable function pointers, or stable cross-target behavior; inferred error sets become generic and have limitations. ([Zig Programming Language][1])

### Ownership & lifetimes (project policy worth enforcing)

* Be clear whether a returned slice/pointer is:

  * **borrowed** (caller must keep backing storage alive),
  * **owned** (caller must free/deinit),
  * **arena-owned** (freed with the arena).
* Never return pointers to stack locals; stack storage dies when the function returns. ([Zig Programming Language][1])

---

## 4) Memory management patterns (pick the right allocator)

Use the “Choosing an Allocator” decision tree from the language reference: ([Zig Programming Language][1])

* **CLI / one-shot programs**: `ArenaAllocator`, free everything once with `arena.deinit()`. ([Zig Programming Language][1])
* **Cyclical workloads** (frame loop, request handler): arena-per-cycle, then reset/deinit per cycle. ([Zig Programming Language][1])
* **Bounded memory**: `FixedBufferAllocator`. ([Zig Programming Language][1])
* **Tests**: `std.testing.allocator` (leak detection) and `std.testing.FailingAllocator` (exercise OOM paths). ([Zig Programming Language][1])
* **General purpose fallback**:

  * Debug: `std.heap.DebugAllocator` (configure once in `main`) ([Zig Programming Language][1])
  * ReleaseFast: `std.heap.smp_allocator` is a solid default ([Zig Programming Language][1])

**OOM is real:** by convention Zig code returns `error.OutOfMemory` rather than crashing. ([Zig Programming Language][1])

---

## 5) Error handling & cleanup (make it impossible to forget)

* Put cleanup right next to acquisition:

  * `defer` for unconditional cleanup
  * `errdefer` for “cleanup only if we fail” (great for partial initialization) ([Zig Programming Language][1])
* Handle *some* errors, forward the rest (keeps error sets honest and code readable). ([Zig Programming Language][1])
* Use **error return traces** in Debug to move fast without losing debuggability. ([Zig Programming Language][1])

---

## 6) Performance without losing elegance

### Don’t outsmart the compiler by default

* Avoid `inline` unless you *need* comptime propagation / stack-frame shaping / measured speedups; `inline` can hurt code size, compile time, and runtime performance. ([Zig Programming Language][1])

### Safety knobs for hot paths

* You can enable/disable runtime safety per-scope with `@setRuntimeSafety(bool)`—use this surgically (and only with tests + confidence). ([Zig Programming Language][1])

### High-leverage performance rules of thumb

* First win: reduce allocations and copies (prefer passing slices/buffers, reuse scratch arenas).
* Second win: pick better algorithms/data layouts (contiguous memory, fewer branches).
* Last win: micro-opts (branch hints, prefetching, manual unrolling)—only after profiling.

---

## 7) Project organization & build system hygiene

### Structure

* Keep `src/` modular: one “public” root module (API surface), private submodules underneath.
* Avoid “misc/utils” dumping grounds; place helpers where they’re used (or make a real module with a real name). ([Zig Programming Language][1])

### Build outputs & reproducibility

* Don’t hardcode `zig-out` paths; users can override with `--prefix`. Don’t commit `zig-out` or `.zig-cache`. ([Zig Programming Language][2])
* Prefer **build-system-managed dependencies** for reproducible, cross-target builds; use system packages only when the platform ecosystem demands it. ([Zig Programming Language][2])
* Package metadata lives in `build.zig.zon` (dependencies with URL + content hash). ([Zig Programming Language][3])
* `zig init` generates modern templates and a `build.zig.zon` (useful for correct fingerprints). ([Zig Programming Language][4])

### Cross-target as a first-class constraint

* Keep platform-specific code behind clean interfaces; use the build system to test multiple targets early. ([Zig Programming Language][1])

---

## 8) Tooling: tests, docs, and stdlib navigation

* Render stdlib docs locally: `zig std`. ([Zig Programming Language][1])
* Generate docs (still experimental): `zig test -femit-docs main.zig`. ([Zig Programming Language][1])
* Treat `zig test` as the default execution environment for libraries; prefer small, focused tests and cover OOM behavior in allocation-heavy code. ([Zig Programming Language][1])

---

## 9) PR checklist (for humans + AI agents)

* [ ] `zig fmt` run; naming matches conventions; no `utils/misc/Manager/Context` dumping. ([Zig Programming Language][1])
* [ ] No hidden allocations (allocator is explicit; ownership is documented).
* [ ] `anyerror` avoided in public APIs; error sets are sane; recursion/function-pointer use doesn’t rely on inferred error sets. ([Zig Programming Language][1])
* [ ] All resources cleaned up via `defer`/`errdefer` patterns; partial init is safe. ([Zig Programming Language][1])
* [ ] Tests added/updated; OOM paths covered where relevant. ([Zig Programming Language][1])
* [ ] Build doesn’t assume output paths; no cache/artifacts committed. ([Zig Programming Language][2])
* [ ] Performance changes justified by measurement; no “inline everywhere” cargo culting. ([Zig Programming Language][1])

[1]: https://ziglang.org/documentation/master/ "Documentation - The Zig Programming Language"
[2]: https://ziglang.org/learn/build-system/ "
      Zig Build System
      ⚡
      Zig Programming Language
    "
[3]: https://ziglang.org/download/0.11.0/release-notes.html "0.11.0 Release Notes ⚡ The Zig Programming Language"
[4]: https://ziglang.org/download/0.15.1/release-notes.html "0.15.1 Release Notes ⚡ The Zig Programming Language"

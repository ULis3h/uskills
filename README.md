# uskills

Claude Code skills for writing **safe, fast, elegantly designed C++**.

The coding philosophy follows [Abseil](https://abseil.io/) and the Google
C++ style: code is written for the reader at the call site, ownership is
explicit in the type, errors are values, and the boring construct wins.
The performance philosophy follows [ClickHouse](https://clickhouse.com/):
measure everything, lay data out for the cache, process batches instead of
elements, specialize the hot path, and never claim a speedup without a
benchmark.

[中文说明见下方](#中文说明)。

## Skills

| Skill | What it does | Loads when |
|---|---|---|
| [`cpp-style`](skills/cpp-style/SKILL.md) | Abseil/Google-style APIs, naming, strings, `Status`/`StatusOr`, ownership, initialization, tests. Includes a condensed catalog of the Abseil Tip-of-the-Week canon. | Any C++ writing or editing |
| [`cpp-performance`](skills/cpp-performance/SKILL.md) | ClickHouse-style performance engineering: measurement discipline, data layout, hash tables, memory/arenas, vectorization and SIMD, algorithmic tricks. | Hot paths, "make it faster", benchmarks, profiling |
| [`cpp-safety`](skills/cpp-safety/SKILL.md) | Lifetimes, UB catalog, integer safety, bounds, sanitizers, hardened stdlib, fuzzing, crash diagnosis. | Pointers/views/casts, crashes, sanitizer reports, hardening |
| [`cpp-design-patterns`](skills/cpp-design-patterns/SKILL.md) | Static vs dynamic polymorphism, RAII, strong types, option structs, factories/registries, variant visitors, type erasure, Pimpl, safe observers. | Architecture, refactoring, "which pattern" |
| [`cpp-concurrency`](skills/cpp-concurrency/SKILL.md) | Mutexes with thread-safety annotations, atomics and memory model, thread pools, partition/merge, queues, cancellation, TSan testing. | Threads, locks, atomics, races, scaling |
| [`cpp-project-setup`](skills/cpp-project-setup/SKILL.md) | CMake presets, warnings, sanitizer/hardening configs, clang-format, clang-tidy, CI matrix. Ships copyable templates in `assets/`. | New projects, build/tooling questions |
| [`cpp-review`](skills/cpp-review/SKILL.md) | Severity-ordered review procedure and checklist across all lenses above. | Code review, self-review before submitting |

Each skill is a `SKILL.md` (loaded when the skill triggers) plus
`references/` files that Claude reads on demand, so the always-on cost is
small and the depth is there when needed.

## Install

As a Claude Code plugin (recommended):

```bash
claude plugin marketplace add ULis3h/uskills
claude plugin install cpp@uskills
```

Skills are then available as `/cpp:cpp-style`, `/cpp:cpp-review`, etc.,
and Claude loads them automatically when a task matches their description.

Or copy skills into a project or your user profile:

```bash
# project-local
git clone https://github.com/ULis3h/uskills
cp -r uskills/skills/cpp-* your-project/.claude/skills/
# user-wide
cp -r uskills/skills/cpp-* ~/.claude/skills/
```

## Making it stick: CLAUDE.md and hooks

Skills raise the default quality of what Claude writes, but they are text:
they cannot guarantee that code compiles warning-free, passes clang-tidy,
or passes tests. `cpp-project-setup/assets/` therefore also ships:

- `CLAUDE.md`: the always-in-context subset of the rules plus a "definition
  of done".
- `tools/claude/post_edit_cpp.sh`: a PostToolUse hook that clang-formats
  every edited C++ file and returns clang-tidy findings to Claude as
  blocking feedback.
- `tools/claude/stop_check_cpp.sh`: a Stop hook that refuses to let Claude
  finish while modified C++ doesn't build with `-Werror` and pass tests.
- `tools/claude/claude-settings.json`: the hook wiring for
  `.claude/settings.json`.

With those installed, the rules are enforced by the harness, not
remembered by the model. See section 0 of the `cpp-project-setup` skill.

## Usage notes

- `cpp-style` is the default for any C++ work; the other skills layer on
  top of it. Its `references/exemplar.md` is a complete header +
  implementation + test in the target style; Claude reads it before
  writing a new module. They are written to be consistent with each other: a hot loop
  in `cpp-performance` still follows `cpp-style`'s API rules at its
  boundary, and `cpp-safety`'s tooling is wired up by
  `cpp-project-setup`'s templates.
- The skills assume Abseil is available (`absl::Status`,
  `absl::string_view`, `absl::flat_hash_map`, `absl::Mutex`). Where a
  codebase uses `std::` equivalents or exceptions, the skills say how to
  adapt; the reasoning stays the same.
- To start a new project with everything wired up, ask Claude to set up
  the project and it will copy the templates from
  `skills/cpp-project-setup/assets/`.

## Contributing

- One skill per directory under `skills/`, with `SKILL.md` frontmatter
  (`name`, `description`) and optional `references/`, `assets/`,
  `scripts/`.
- Keep `SKILL.md` under ~500 lines; put depth in `references/` and link
  to it with guidance on when to read it.
- Explain *why*, not just *what*; rules without reasons get ignored by
  models and humans alike.
- Add a Tip-of-the-Week number or a ClickHouse source pointer when a rule
  comes from there, so readers can follow up.

---

## 中文说明

这是一个面向 **C++** 的 Claude Code skill 仓库，目标是让 Claude 写出**安全、
高效、设计优雅**的 C++ 代码：

- **编程风格与哲学向 Abseil / Google C++ Style 对齐**：为调用点的读者写代码，
  所有权写进类型里，错误是返回值（`absl::Status` / `StatusOr`），优先选平淡
  但清晰的写法。
- **性能思考向 ClickHouse 对齐**：一切以测量为准，围绕缓存设计数据布局，
  按批处理而不是逐元素处理，为热点路径做特化，任何提速都要有 benchmark。

### Skill 一览

| Skill | 内容 | 触发场景 |
|---|---|---|
| `cpp-style` | Abseil 风格的 API 设计、命名、字符串、错误处理、所有权、初始化、测试；附 Abseil Tip-of-the-Week 精华目录 | 任何 C++ 编写/修改 |
| `cpp-performance` | ClickHouse 式性能工程：测量纪律、数据布局、哈希表、内存与 arena、向量化与 SIMD、算法技巧 | 热点路径、"让它更快"、benchmark、profiling |
| `cpp-safety` | 生命周期、UB 清单、整数安全、越界、sanitizer、hardened stdlib、fuzzing、崩溃诊断 | 指针/视图/转换、崩溃、sanitizer 报告、加固 |
| `cpp-design-patterns` | 静态 vs 动态多态、RAII、强类型、option struct、工厂/注册表、variant 访问者、类型擦除、Pimpl、安全的观察者 | 架构、重构、"用哪种模式" |
| `cpp-concurrency` | 带线程安全注解的互斥锁、原子与内存模型、线程池、分区/合并、队列、取消与关闭、TSan 测试 | 线程、锁、原子、竞争、扩展性 |
| `cpp-project-setup` | CMake presets、警告、sanitizer/加固配置、clang-format、clang-tidy、CI 矩阵；`assets/` 内有可直接复制的模板 | 新项目、构建/工具链问题 |
| `cpp-review` | 按严重程度排序的审查流程与清单，覆盖以上所有维度 | 代码审查、提交前自审 |

### 安装

作为 Claude Code plugin 安装（推荐）：

```bash
claude plugin marketplace add ULis3h/uskills
claude plugin install cpp@uskills
```

或直接把 `skills/cpp-*` 复制到项目的 `.claude/skills/` 或用户级的
`~/.claude/skills/`。

### 约定

- skill 正文使用英文（模型消费效率更高、术语更准确），README 中英双语。
- 每个 skill 由 `SKILL.md`（触发时加载）和 `references/`（按需读取）组成，
  保持常驻上下文成本低、需要时有深度。
- 规则尽量给出"为什么"，并注明来源（Abseil ToTW 编号、ClickHouse 的实现）。

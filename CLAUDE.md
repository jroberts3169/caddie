# Workflow Orchestration

## 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately - don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy

- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop

- After ANY correction from the user: update 'tasks/lessons.md"
with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done

- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)

- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes - don't over-engineer
-Challenge your own work before presenting it

### 6. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests - then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to "tasks/todo.md" with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to "tasks/todo.md"
6. **Capture Lessons**: Update "tasks/lessons.md' after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Documentation Standards

- All docs MUST live in the `docs/` directory
- All docs MUST be written in Markdown (`.md`)
- All docs MUST include a Table of Contents

## UI Glossary Style

When asked to create or update a UI glossary for an app in this suite, follow
this pattern. The glossary's job is to give every visible UI element a single
canonical name so the user and I can refer to them unambiguously when filing
bugs or asking for changes. It is a naming contract, not a tutorial.

**Required structure:**

1. **Title + one-paragraph preamble** stating the goal ("canonical names for
   every visible element…") and pointing at the source folder for the app.
2. **§1 Top-level layout** — open with an ASCII diagram of the window's
   regions, then a table mapping each region to its **Canonical name** and
   source file (linked with workspace-relative paths, with line ranges where
   useful).
3. **§1.x "one level down" subsections** — for every non-trivial region,
   repeat the pattern: ASCII diagram → table of sub-regions with canonical
   name, visibility rule, and role. Drill down until every element a user can
   see or click has a name.
4. **Per-region detail sections** — one numbered section per major region with
   tables of every control: element description, canonical name,
   icon/shortcut/source, and notes on behavior.
5. **Behavior callouts** — document click/hover/drag/keyboard behaviors in
   tables or bulleted lists adjacent to the elements they affect (selection
   rules, context menus, hover reveals, modifier keys).
6. **Closing sections** as appropriate: cross-cutting vocabulary, keyboard
   shortcuts table, empty/loading/error states, "where do I click to…" quick
   reference, and a "Known issues to address" list when relevant.

**Naming rules:**

- Names are **Title Case Noun Phrases** ending in the element kind:
  `Refresh Button`, `App Launcher Card`, `Faces Marquee`, `Stagger-Load
  Overlay`, `People Sidebar Header`.
- Be specific enough that the name is unique app-wide. Prefer `Tile Mute
  Button` and `Global Mute Button` over two `Mute Button`s.
- Container/region names end in `Section`, `Pane`, `Bar`, `Grid`, `Sidebar`,
  `Overlay`, `Sheet`, `Popover`, `Window`, or `Area`.
- Repeating row/cell elements end in `Row`, `Cell`, `Tile`, `Card`, or `Chip`.
- Modal/transient surfaces end in `Sheet`, `Popover`, `Alert`, or `Menu`.
- Bold every canonical name on first mention (**Like This**); use backticks
  only for code symbols and SF Symbol names.

**Formatting rules:**

- ASCII diagrams use box-drawing characters (`┌─┐│├┤└┘`) and roughly match
  real proportions.
- Tables: `| Element | Canonical name | Notes |` is the default shape; vary
  columns (Icon, Shortcut, Source, Visibility, Role, Value source, Color) to
  fit the region.
- Link source files with workspace-relative markdown links and line ranges
  where helpful; never inline-code file names.
- Use blockquote callouts (`>`) for invariants, gotchas, and "is not a X"
  clarifications.
- Keep prose impersonal and terse; describe behavior, not intent.

**Process:** read every source file under the app's folder before writing,
enumerate elements by walking the view tree top-down, and only include
elements that actually exist in code — no aspirational UI.

# Albert LEX — Design System

Decisions already made for this project. Apply these on every UI change. When a new pattern gets used 2+ times, promote it into this file.

---

## Intent

**Who:** A sales leader or AE opening this at 8am with coffee. They live in Salesforce all day; Albert LEX earns its place by making them *faster and more informed than opening Salesforce directly*.

**What they do:** Delegate work. Check pulse. Launch or configure a playbook. Browse capabilities. Ask questions in natural language.

**Feel:** Quiet competence. Bloomberg-by-Linear. Numbers speak louder than adjectives. Dense where it matters, breathing room everywhere else. No bounce, no purple gradients, no cartoon empty states.

---

## Signature

**"Pulse"** — an 8px animated ring (`@keyframes pulse-ring`) that appears *only* where Albert is actively running or watching. Used in:

1. Sidebar operating-context footer (`.op-dot`)
2. Home briefing line next to the greeting (`.pulse-dot`)
3. Active Watch rows on Home (`.watch-row.is-active .watch-pulse`)
4. Chat composer footnote (`.ch-footnote .op-dot-sm`)
5. Active agent cards (`.ag-pulse` + `.ag-ambient` breathing glow)
6. Skill detail "Called by" chips (`.caller-dot`)

One element, used with intent. **Never introduce a second "alive" motif** — the pulse carries the identity.

**"Operating context" microbar** — thin strip in the sidebar footer that always shows Albert's state: `connected · salesforce · {N} agents · {M} skills`. Whisper-level instrumentation that makes the app feel live.

**Live clock** in the top bar (`.clock`): `DAY · HH:MM · AM/PM`, mono, tabular-nums, ticks every 30s. Another whisper-level signal that this is a workspace, not a static page.

---

## Typography

System stack, tuned precisely. Do not add custom fonts without a reason.

```css
--font-sans:    -apple-system, BlinkMacSystemFont, "SF Pro Text",
                "Segoe UI Variable", "Segoe UI", system-ui, sans-serif;
--font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display",
                "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif;
--font-mono:    ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
```

**Host base:** `13.5px / 1.5` with font-feature-settings `cv02 cv03 cv04 cv11`, tabular-nums where numeric.

**Scale (use these exactly):**

| Use                        | Font       | Size  | Weight | Letter-spacing | Notes |
|----------------------------|------------|-------|--------|----------------|-------|
| Page hero greeting         | display    | 32px  | 650    | -0.024em       | "Good morning, Dylan." |
| Chat hero title            | display    | 34px  | 650    | -0.024em       | |
| Page title (`.page-title`) | display    | 26px  | 650    | -0.02em        | |
| Big metric number          | display    | 28px  | 650    | -0.022em       | Pulse cards |
| Mid metric number          | display    | 24px  | 650    | -0.022em       | Stats strip |
| Skill detail name          | display    | 24px  | 650    | -0.02em        | |
| Card name                  | display    | 17px  | 600    | -0.01em        | pb/wf/deleg cards |
| Cap title                  | display    | 16px  | 600    | -0.01em        | |
| Body                       | sans       | 13.5px| 400    | 0              | Default |
| Card tagline / description | sans       | 12.5px| 400    | 0              | |
| Micro-label (UPPERCASE)    | sans       | 11px  | 600    | 0.09em         | Section titles, eyebrows |
| Agent name                 | mono       | 13px  | 600    | -0.005em       | |
| Mono data chip             | mono       | 10.5–11px | 500 | 0.01em        | tool-chip, trigger-chip, step |
| Time / code-ish data       | mono       | 11px  | 400–500| 0.01em         | feed-time, sessions, deltas |
| Kbd keys                   | mono       | 10px  | 600    | 0              | `.kbd` with 2px bottom border |

**Rules:**
- Headlines always on `--font-display` with tight tracking.
- All numeric values use `font-variant-numeric: tabular-nums`.
- Micro-labels are always UPPERCASE + 0.08–0.09em tracking + ink-8/9.
- Monospace is reserved for: data, code, timestamps, identifiers (agent names, tool names, triggers, keyboard hints).

---

## Color

Warm-tinted neutrals on paper-cream canvas. **Never use flat grays (`#6b7280`-style Tailwind neutrals).**

### Tokens

```css
/* Ink — warm-tinted neutrals */
--ink-12: #0a0b0d;   /* headlines */
--ink-11: #1a1d21;   /* primary text */
--ink-10: #2d3239;   /* important labels */
--ink-9:  #4e555e;   /* secondary */
--ink-8:  #6b7280;   /* meta text */
--ink-7:  #8a8f98;   /* tertiary / icons */
--ink-6:  #a0a4ad;   /* muted */
--ink-5:  #c4c7cd;   /* disabled */
--ink-4:  #dfe1e5;   /* placeholder / scrollbar thumb */
--ink-3:  #e8eaee;
--ink-2:  #f1f3f5;

/* Surfaces (warm-shifted across the stack) */
--canvas:   #ffffff;
--panel:    #fafafa;   /* sidebar, section backgrounds, hovers */
--inset:    #f7f7f6;   /* inputs, step-chain backgrounds, chips */
--hover:    #f3f4f2;
--pressed:  #ebece9;
--elevated: #ffffff;

/* Edges (rgba — disappear when not looking) */
--edge-whisper: rgba(10, 11, 13, 0.04);
--edge:         rgba(10, 11, 13, 0.08);
--edge-strong:  rgba(10, 11, 13, 0.14);
--edge-focus:   rgba(5, 150, 105, 0.40);

/* Accent: eucalyptus emerald — the one "alive" color */
--accent-700: #047857;
--accent-600: #059669;
--accent-500: #10b981;
--accent-400: #34d399;
--accent-soft:    rgba(16, 185, 129, 0.10);
--accent-softer:  rgba(16, 185, 129, 0.06);
--accent-whisper: rgba(16, 185, 129, 0.04);
--accent-ink:     #064e3b;

/* Signal: warm amber — reserved for attention/nudges */
--signal-600: #d97706;
--signal-soft: rgba(217, 119, 6, 0.10);

/* Rarely used */
--danger-600: #dc2626;
--danger-soft: rgba(220, 38, 38, 0.08);
--info-600:   #2563eb;
--info-soft:  rgba(37, 99, 235, 0.08);
```

### Rules

- **One accent, used with meaning.** Emerald = active/alive/progress. Never decorative.
- **Amber is reserved for attention.** Only `deltaTone: "warn"` metrics, `dot-review` activity, and pending-review states. Never as a second brand color.
- **Borders are always rgba.** Never use `#e5e7eb`-style hex edges.
- **Sidebar = same hue as canvas + one border.** Never a colored rail.
- **No purple, no teal, no info-blue accents.** Info-blue only if a Salesforce standard demands it.

---

## Depth

**Primary strategy: borders-only.**

Shadows are rare and reserved:

```css
--shadow-xs:  0 1px 2px rgba(10, 11, 13, 0.04);              /* mode pills */
--shadow-sm:  0 1px 2px rgba(10, 11, 13, 0.04),
              0 0 0 1px rgba(10, 11, 13, 0.04);              /* composer */
--shadow-md:  0 2px 10px rgba(10, 11, 13, 0.06),
              0 1px 2px rgba(10, 11, 13, 0.04);              /* composer focused */
--shadow-pop: 0 10px 32px rgba(10, 11, 13, 0.10),
              0 2px 6px rgba(10, 11, 13, 0.06);              /* popovers (reserved) */
--ring-focus: 0 0 0 3px var(--accent-soft);                  /* focus rings */
```

Hover lift on cards: `transform: translateY(-1px)` + `border-color: var(--edge-strong)` + `background: var(--panel)`. No shadow change on hover.

---

## Spacing

4px base. Scale:

```css
--s-1:  4px   --s-2:  8px   --s-3: 12px   --s-4: 16px
--s-5: 20px   --s-6: 24px   --s-8: 32px   --s-10: 40px
--s-12: 48px  --s-16: 64px
```

- Card padding: `--s-5` (20px)
- Section-to-section gap: `--s-10` (40px)
- Page padding: `--s-8` (32px)
- Component internals: `--s-2`/`--s-3` (8/12px)

---

## Radii

```css
--r-1: 2px   /* mono chips, kbd, step tags */
--r-2: 4px   /* buttons, nav items, chips */
--r-3: 6px   /* inputs, inner panels */
--r-4: 8px   /* cards, lists */
--r-5: 12px  /* composer, quick-launch */
--r-6: 16px
```

Sharper on small elements; slightly rounder on large surfaces. Never mix sharp and soft randomly.

---

## Layout

```css
--sidebar-w: 236px;
--top-h:     52px;
--page-pad:  32px;
```

Host escapes FlexiPage padding with `margin: -12px; height: calc(100vh - 90px); min-height: 720px`.

**Page max-widths** (vary by content density):

| Page                | max-width |
|---------------------|-----------|
| Home (`.hp`)        | 1200px    |
| Chat (`.ch`)        | 960px (centered) |
| Playbooks (`.pb`)   | 1240px    |
| Autonomous (`.au`)  | 1240px    |
| Workflows (`.wf`)   | 1240px    |
| Agents (`.ag`)      | 1240px    |
| Skills (`.sk`)      | 1300px    |

---

## Component Patterns

### Section scaffold
Every section uses the same head pattern:

```html
<div class="hp-section-head">
  <div class="hp-section-title">UPPERCASE MICRO LABEL</div>
  <span class="tag-count">N</span>           <!-- or meta, or link-btn -->
</div>
```

### Cards share surface treatment, never structure
All cards use the same `background / border / radius / padding / hover` treatment:
- `1px solid var(--edge)` + `var(--r-4)` + `var(--s-5)` padding
- Hover: `background: var(--panel)`, `border-color: var(--edge-strong)`, `translateY(-1px)`

But **internal structure differs per card** — pulse cards ≠ playbook cards ≠ agent cards ≠ workflow cards. Don't reuse structure across card types.

### Buttons (3 tiers)

| Class         | Style                              | Use                  |
|---------------|------------------------------------|----------------------|
| `.ql-btn`     | Solid `--ink-12` bg, white text    | Primary CTA per page |
| `.btn-ghost`  | Border + transparent bg            | Secondary actions    |
| `.link-btn`   | Text-only, `--accent-700`          | Tertiary / inline    |

Never introduce a colored "accent" button. The solid ink-12 is the only strong CTA.

### Inputs
- Default background is `--inset` (slightly darker than canvas — inputs are "inset", they receive content).
- Focus: border → `--edge-strong` + `box-shadow: var(--ring-focus)`.
- Placeholders: `--ink-6`/`--ink-7`.

### Segmented controls (`mode-pill`, `filter-chip`)
- Inset container with 2px internal padding.
- Active: canvas background + `--shadow-xs` + weight 600.
- Inactive: transparent + `--ink-9`.

### Empty states — prefer *not* to show them

**Removed as of the anti-slop pass.** Generic "Your X" empty-inline sections were deleted wholesale. A page with no user data should still show meaningful *built-in* content (templates, built-in agents, built-in skills, system-generated queue items). An empty state is a last resort — never a hero.

If one is unavoidable, keep it to a single line of mono copy, aligned left, ink-8, no CTA button, no illustration.

### Queue row (Home · "Waiting on you")
Four-column grid: `64px | 1fr | auto | 14px` (eyebrow · title+meta · age · chev). Hover reveals a 2px emerald left rail. Used for actionable items Albert has queued for the human.

### Caller chip (Skill detail · "Called by")
Mono chip prefixed with an 8px pulse dot. Says "this skill is invoked by these agents right now." Reinforces the pulse signature at the skill-detail level.

### Mono chips

| Class            | Use                                |
|------------------|------------------------------------|
| `.tool-chip`     | Agent tools                        |
| `.trigger-chip`  | Skill trigger phrases (quoted)     |
| `.step`          | Playbook step names                |
| `.feed-agent`    | Agent name on activity rows        |

All share: `font-mono`, 10.5–11px, `--inset` bg, `--edge-whisper` border, `--r-1` radius, 0.01em letter-spacing.

### Pulse element (THE signature)
```html
<span class="pulse-dot"></span>  <!-- or .op-dot, .watch-pulse, .ag-pulse -->
```
```css
.pulse-dot {
  width: 8px; height: 8px; border-radius: 50%;
  background: var(--accent-500);
  box-shadow: 0 0 0 2px var(--accent-softer);
  position: relative;
}
.pulse-dot::after {
  content: ""; position: absolute; inset: -2px;
  border-radius: 50%; background: var(--accent-500);
  opacity: 0.4;
  animation: pulse-ring 2.8s ease-out infinite;
}
@keyframes pulse-ring {
  0%   { transform: scale(1);   opacity: 0.40; }
  70%  { transform: scale(2.8); opacity: 0;    }
  100% { transform: scale(2.8); opacity: 0;    }
}
```

Always disabled under `@media (prefers-reduced-motion: reduce)`.

### Step chain (Playbooks)
Mono chips + `→` separators, in an inset panel. One visualization style for any sequential process.

### Workflow node diagram
Three node variants: `.wf-node-trigger` (emerald-tinted), `.wf-node` (default neutral), `.wf-node-end` (ink-strong). Connected by `.wf-edge` — 14px line with triangle `::after`.

---

## Icons

- **Set:** `lightning-icon` (utility set) only. Don't mix sets.
- **Size:** `xx-small` almost everywhere. `x-small` only for emphasis cases.
- **Color:** drive with `--sds-c-icon-color-foreground-default` set to an ink token.
- **Active state:** use `--accent-600` only on the currently-active nav item's icon.
- **Avatars, not icon tiles.** For agents and owners, use monochrome ink-12 circle/square with mono initial — never colored rounded icon boxes.

---

## Motion

All animation belongs to one of six named patterns. Never introduce a new one without adding it here.

| Keyframe       | Purpose                                           | Duration / timing                               |
|----------------|---------------------------------------------------|-------------------------------------------------|
| `pulse-ring`   | THE signature — 8px alive ring                    | 2.8s infinite, `ease-out`                       |
| `reveal-up`    | Page-entry stagger (`.enter`, `.enter-stagger`)   | 420ms, `cubic-bezier(.2,.7,.2,1)`, `--i` offset |
| `spark-draw`   | Sparkline SVG stroke draw-in on Home pulse cards  | 900ms, cubic ease, 160ms+80ms×i stagger         |
| `caret-blink`  | Chat composer idle caret (only when empty)        | 1.1s infinite, `steps(2)`                       |
| `wf-travel`    | Workflow edge dot travel (on card hover)          | 1.4s infinite, linear                           |
| `ag-breathe`   | Active agent card ambient radial glow             | 4.8s infinite, `ease-in-out`                    |

**Rules:**
- Transitions: 100–120ms, `ease`.
- Hover lifts: `translateY(-1px)` on cards only.
- No spring / bounce / elastic easings.
- Stagger offset pattern: `calc(var(--i, 0) * 40ms + 80ms)`.
- **Everything respects `prefers-reduced-motion: reduce`** — all six animations are explicitly disabled in that media query block.

---

## Focus

Every interactive element has `:focus-visible` styling:
```css
outline: 2px solid var(--accent-500);
outline-offset: 2px;
box-shadow: var(--ring-focus);
```

Never remove outlines without providing an equivalent ring.

---

## Copywriting

- **Voice:** dry, capable, discreet. Butler-precise.
- **No exclamation marks.** No "Let's get started!", no "🎉".
- **Numbers before adjectives.** "3 agents are watching pipeline signals" > "Albert is hard at work".
- **Eyebrows are UPPERCASE micro-labels.** Titles are display-font and sentence-case.
- **Placeholder text** uses em-dash for examples: `Describe what you want done — e.g. review my top 10 opps`.
- **Time is always monospace** and uses abbreviations: `09:12`, `Yest.`, `Mon 4:08 PM`.

---

## File Map

| File                                                               | Purpose                                    |
|--------------------------------------------------------------------|--------------------------------------------|
| `force-app/main/default/lwc/albertLexApp/albertLexApp.css`         | Design system + component styles          |
| `force-app/main/default/lwc/albertLexApp/albertLexApp.html`        | Shell + 7 page templates                  |
| `force-app/main/default/lwc/albertLexApp/albertLexApp.js`          | State, mock data, handlers                |
| `force-app/main/default/flexipages/Albert_LEX.flexipage-meta.xml`  | FlexiPage host                            |
| `force-app/main/default/tabs/Albert_LEX.tab-meta.xml`              | Custom tab                                |
| `force-app/main/default/applications/Albert_LEX.app-meta.xml`      | Lightning app                             |
| `force-app/main/default/permissionsets/Albert_LEX_User.permissionset-meta.xml` | Permset for tab visibility       |

**Deploy target:** `sdo11` (`dylan.andersen.sdo11@salesforce.com`). API version 65.0.

---

## LWC Template Gotchas (learned the hard way)

1. **No computed property access in templates** — no `.[0]`, no `arr.length` is OK but safer to precompute as a `getter` returning a number.
2. **Keys in `for:each` must be unique across all rendered siblings** — when an `lwc:else` branch renders multiple elements, give each a distinct key (e.g. `n.key` and `n.edgeKey`).
3. **Placeholder attributes** — never embed unescaped double quotes inside a double-quoted `placeholder="…"`. Use em-dashes or entity-encode.
4. **`@track` is harmless on primitives** but also unnecessary; LWC reactivity triggers on any field assignment.
5. **Expensive getters (like `filteredSkills`)** recompute on every render. At current data sizes this is fine; if arrays grow past a few hundred items, memoize.

---

## When To Update This File

- You invent a new component pattern that will be reused. Add it under "Component Patterns".
- You introduce a new CSS token. Add it under the right color/spacing/radius section.
- You find a new LWC gotcha. Add it under "LWC Template Gotchas".

If you find yourself writing a new hex color, stop — either use an existing token or add a new one to this file first.

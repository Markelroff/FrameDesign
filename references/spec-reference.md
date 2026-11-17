# Spec reference

Every diagram is a JSON object (or an R list) with a `type`. All types accept:

- `alt`: one-sentence description, stored as the SVG `<title>` for screen readers. Always set it.
- `title`: optional heading drawn on the figure. Journals usually want the title in the caption instead, so leave it out for papers.
- `desc`: optional longer description (`<desc>`).

Counts must be whole numbers. In R, use `fd_reasons(c("Reason" = 12))` to build reason lists. R lists and JSON files describe the same spec: a JSON object is a named `list()`, a JSON array is an unnamed `list()`, and single values may be given as plain vectors (`points = "2027-05"`, `spans = c(0, 3)`).

## Rendering

| Task | R | Python |
|---|---|---|
| Spec to file | `fd_render(spec, "fig.svg")` | `svg, _ = fd.render(spec); fd.write_svg(svg, "fig.svg")` |
| Spec to text + findings | `fd_svg(spec)` | `fd.render(spec)` |
| JSON spec to file | `fd_render_json("spec.json", "fig.svg")` | `python python/framedesign.py render spec.json -o fig.svg` |
| Check any SVG | `fd_check("fig.svg")` | `fd.check_svg(text)` or CLI `check` |
| PNG | `fd_png("fig.svg")` (rsvg) | `fd.export_png(...)` (cairosvg) |
| DAG adjustment sets | `fd_adjustment_sets(spec)` | `fd.adjustment_sets(spec)` or CLI `dagitty` |
| DAG to dagitty | `fd_dagitty(spec)`, `fd_dagitty(spec, object = TRUE)` | `fd.to_dagitty(spec)` |

## flow / pipeline

Steps, decisions, pipelines, hierarchies.

| Field | Meaning |
|---|---|
| `direction` | `"TB"` (top to bottom, default, fits a column) or `"LR"` (left to right, for slides) |
| `nodes` | list of nodes (below) |
| `edges` | list of `{"from", "to", "label"?, "dashed"?, "focal"?, "muted"?}` |
| `max_width` | wrap width for node text, pt (default 120 TB, 92 LR) |
| `rank_gap`, `node_gap` | spacing between layers and between nodes, pt |
| `edge_style` | `"orthogonal"` (default) or `"curved"` |

Node fields: `id` (required), `label`, `kind` (`process` default, `decision`, `terminal`, `data`, `note`, `plain`), `focal`, `muted`, `dashed`, `bold`, `group` (draws a dashed frame around nodes sharing a group), `rank` (pin to a layer), `max_width`.

An edge that points back up the flow (a loop) is detected and routed around the side, dashed.

```json
{"type": "flow", "nodes": [
  {"id": "q", "label": "Calibration acceptable?", "kind": "decision"},
  {"id": "fit", "label": "Fit model"},
  {"id": "done", "label": "Report", "kind": "terminal", "focal": true}],
 "edges": [{"from": "fit", "to": "q"}, {"from": "q", "to": "done", "label": "yes"},
           {"from": "q", "to": "fit", "label": "no"}]}
```

## dag

Causal directed acyclic graph. Laid out left to right with curved edges.

Node fields: `id`, `label`, `role` (`exposure`, `outcome`, `confounder`, `mediator`, `collider`, `instrument`, `precision`, `unmeasured`, `other`), `adjusted` (true draws a box).

Exactly one `exposure` and one `outcome`. The exposure to outcome arrow is drawn in the accent; the outcome is boxed in the accent. Unmeasured variables and their arrows are dashed gray. A key line under the diagram names the adjustment set.

The drawn set (`adjusted: true`) is tested against the backdoor criterion. `fd_adjustment_sets(spec)` returns every minimal sufficient set of measured variables, for example `list(c("Age", "SES"))`; `list(character(0))` means no adjustment is needed and an empty list means no measured set is sufficient. `fd_dagitty(spec)` returns a model such as `dag { Smoking [exposure] Revision [outcome] Age [adjusted] Frailty [latent] Smoking -> Revision }`; node ids are made dagitty-safe (spaces become underscores).

## consort

| Field | Meaning |
|---|---|
| `assessed` | assessed for eligibility |
| `excluded` | `{"total"?, "reasons": [[label, n], ...]}` (total defaults to assessed minus randomized) |
| `randomized` | number randomized |
| `arms` | list of arms (below) |
| `focal_arm` | arm name whose Analysis box gets the accent |
| `box_width`, `side_width` | pt; defaults fit a 468 pt column for 2 arms |
| `clinical` | default true; set false to skip the small-cell reminder |

Arm fields: `name`, `allocated`, `received`?, `not_received` [[label, n]], `lost` [[label, n]], `discontinued` [[label, n]], `analysed` (required), `excluded_analysis` [[label, n]], `imputed` (true if missing outcomes were imputed).

## cohort

Inclusion and exclusion cascade for observational studies (STROBE-style), with an optional split into groups.

| Field | Meaning |
|---|---|
| `start` | `{"label", "n"}` |
| `steps` | list of `{"excluded", "reasons"? [[label, n]], "label", "n"?, "exclusion_label"?}`; `n` is checked if given |
| `groups` | optional final split: `[{"label", "n", "focal"?}]`, must sum to the final cohort |
| `box_width`, `side_width`, `group_width` | pt |
| `focal_final` | accent on the final box when there are no groups (default true) |
| `clinical` | as above |

## prisma

PRISMA 2020 flow for a new or updated systematic review.

| Field | Meaning |
|---|---|
| `identification` | `{"databases": [[name, n], ...], "registers": [[name, n], ...]}` |
| `removed` | `{"duplicates", "automation", "other"}` removed before screening (each defaults to 0) |
| `screen_excluded` | number excluded at title and abstract screening, or `[[reason, n], ...]` |
| `not_retrieved` | reports sought but not retrieved |
| `full_text_excluded` | `[[reason, n], ...]` reports excluded at full text |
| `other_methods` | optional second column: `{"identified": [[source, n]], "sought"?, "not_retrieved"?, "excluded": [[reason, n]]}` |
| `previous` | optional, for an updated review: `{"studies", "reports"}` from the previous version |
| `included` | `{"studies", "reports"?}` new studies and their reports (reports is checked if given) |
| `total` | optional, updated review: `{"studies"?, "reports"?}` checked against previous plus new |
| `identified`, `screened`, `sought`, `assessed` | optional: checked against the derived counts if given |
| `box_width`, `side_width`, `focal_included` | layout; defaults fit a 468 pt column |

Stage names (Identification, Screening, Included) run vertically down the left edge, as in the PRISMA 2020 template.

## timeline

| Field | Meaning |
|---|---|
| `start`, `end` | numbers (with `unit`) or `"YYYY-MM"` strings |
| `unit` | `"month"` (default), `"week"`, `"year"`: used in the axis label for numeric timelines |
| `tracks` | `[{"label", "spans": [[start, end], ...]?, "points": [t, ...]?, "focal"?}]` |
| `milestones` | `[{"at", "label"}]`: dashed vertical rule with an italic label, staggered to avoid overlap |
| `axis_label`, `width` | optional |

A `"YYYY-MM"` end includes that whole month: a span to `"2026-12"` covers December.

## panels

Combine FrameDesign diagrams and InkSight charts into one lettered figure.

| Field | Meaning |
|---|---|
| `cols` | columns (default 2) |
| `width` | figure width, pt (default 468) |
| `gap` | space between panels, pt |
| `panels` | `[{"file": "chart.svg"} or {"spec": {...}}, "span"?: 2, "label"?: "A"}]` |
| `unify_fonts` | default true: embedded panels use the shared serif stack |
| `no_upscale` | default true: panels are shrunk to fit but never enlarged |

File paths are relative to the spec's folder (or `--base-dir` / `base_dir`), may not contain `..`, and must be `.svg`.

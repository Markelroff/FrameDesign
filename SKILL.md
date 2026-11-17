---
name: framedesign
description: Draw publication-quality research diagrams as self-contained SVG in R or Python, including flowcharts, analysis pipelines, causal DAGs (with formal adjustment sets and dagitty export), CONSORT trial flow, PRISMA 2020 review flow, cohort selection flow, study timelines, and multi-panel figures combining diagrams with InkSight charts. Counts are checked to add up and every figure is screened for collisions and identifiers. Use when asked to make, redesign or check a diagram, flowchart, participant or review flow, DAG, timeline or figure panel. For charts of data, use InkSight.
---

# FrameDesign

Structure, drawn honestly. FrameDesign draws the parts of a research figure that are boxes, arrows, stages and time. Its companion skill **InkSight** draws quantities. The two share one palette, one serif type stack and one set of data-ink rules, so a diagram and a chart sit side by side in a figure as if made by one hand.

## Files

- `R/framedesign.R`: the engine in pure R (base R only; preferred for R and RStudio users). `fd_render`, `fd_svg`, `fd_check`, `fd_reasons`, `fd_adjustment_sets`, `fd_dagitty`, `fd_png`.
- `python/framedesign.py`: the same engine in Python (standard library only). Both produce the same SVG for the same spec; `tests/reference_geometry.tsv` keeps them in step.
- `references/design-rules.md`: the rules, where each comes from, and how each is enforced, plus the pre-delivery checklist.
- `references/spec-reference.md`: every field for every diagram type, with minimal examples.
- `references/other-types.md`: how to hand-draw types the engine does not cover (sequence, swimlane, quadrant, concept map) with the same tokens.
- `examples/specs/`: one spec per type. `tests/`: Python and R tests.

## Which skill draws what

| The figure shows | Use |
|---|---|
| Steps, decisions, a pipeline, a hierarchy | FrameDesign `flow` / `pipeline` |
| Assumed causal structure | FrameDesign `dag` |
| Participants through a trial | FrameDesign `consort` |
| Records through inclusion and exclusion | FrameDesign `cohort` |
| Studies through a systematic review | FrameDesign `prisma` (PRISMA 2020, new or updated review) |
| Phases and milestones over time | FrameDesign `timeline` |
| Numbers: comparison, trend, relationship, distribution | **InkSight** |
| A diagram next to charts | FrameDesign `panels` with InkSight SVGs |

Two or three numbers are a sentence, not a figure. A list of items is a table or bullets, not a diagram.

## Workflow

1. **Understand the purpose.** What should the reader learn from the structure: the order of steps, where participants were lost, which variables are adjusted for? Ask if it is unclear. If the user describes something with numbers to compare, hand it to InkSight.
2. **Choose the type** from the table above. Check `references/spec-reference.md` for its fields.
3. **Write the spec** as JSON (or an R list). Use the user's real counts and words. Keep labels short (2 to 6 words). Mark at most one or two elements `focal`.
4. **Render.** Prefer R when the user works in R.
   - R: `source("R/framedesign.R"); fd_render(spec, "figure.svg")`, or `fd_render_json("spec.json", "figure.svg")`.
   - Python: `python python/framedesign.py render spec.json -o figure.svg` (add `--html` for a viewer page).
5. **Fix every finding.** Rendering stops with an error when counts do not add up, a DAG has a cycle, or a spec is malformed: report the exact contradiction to the user and ask which number is right; never adjust their numbers yourself. Warnings (adjustment bias, small cells, width, accent overuse) are fixed or justified in one line.
6. **For a DAG, report the adjustment analysis.** FrameDesign tests the drawn adjustment set against the backdoor criterion and lists every minimal sufficient set (`fd_adjustment_sets(spec)` in R, `adjustment_sets(spec)` in Python, `framedesign.py dagitty spec.json` on the command line). If the drawn set fails, say so and show the minimal sets. Offer the dagitty model (`fd_dagitty(spec)`) so the user can check it at dagitty.net or with the dagitty package. The DAG states assumptions; the analysis is only as good as the arrows.
7. **Look at it.** Convert to PNG (`rsvg-convert -z 2 figure.svg -o figure.png`, `fd_png()` in R, or `framedesign.export_png`) and view the image before delivering. Walk the checklist at the end of `references/design-rules.md`.
8. **Report** briefly: what the figure shows, the type chosen and why, and any finding that remains.

## Working with InkSight

- **Combined figures.** Save each InkSight chart as `.svg` at its final size, then compose:
  ```json
  {"type": "panels", "cols": 2, "panels": [
    {"span": 2, "spec": {"type": "cohort", "...": "..."}},
    {"file": "revision_rate.svg"}, {"file": "cumulative_revision.svg"}]}
  ```
  Panels get letters A, B, C. Ids inside each panel are made unique, fonts are unified to the shared serif stack, and a warning is raised when panels are scaled differently (type sizes would not match). The warning states the width each panel should be built at.
- **Panel width.** For a two-column figure in a 6.5 in column, each panel is about 203 pt (2.8 in) wide: `plt.subplots(figsize=(2.8, 2.8/1.5))` or `save_vdqi(p, "b.svg", width = 2.8)`.
- **Same text everywhere.** Use the same group names in diagrams and charts ("Reverse", not "RSA" in one and "Reverse" in the other).
- **In R, everything stays in R.** `save_vdqi(p, "b.svg", width = 2.8)` from InkSight, then `fd_render(list(type = "panels", panels = list(list(span = 2, file = "a.svg"), list(file = "b.svg"))), "figure1.svg")`. No Python is needed.
- **Matching type in Python figures.** matplotlib's default serif is DejaVu Serif and it saves text as outlines. For InkSight panels that match FrameDesign, use `plt.rc_context({"font.serif": ["Times New Roman", "Times", "Liberation Serif", "DejaVu Serif"], "svg.fonttype": "none"})` inside `ink.vdqi_style()`. ggplot2 figures saved with `svglite` already use text and are unified automatically.
- **Check anything.** `framedesign.check_svg()` / `fd_check()` also screens InkSight SVGs for identifiers, remote references and low-contrast text.

## Privacy and security rules (always apply)

- Work only on data the user provides, locally. Never upload specs, figures or file paths to a web service. Never fetch remote fonts, images, styles or packages at run time.
- Never put direct identifiers in a diagram: names, MRNs, dates of birth, exact dates of service, addresses, emails or record IDs. Counts and generic labels only. The checker flags common identifier patterns, but read every label yourself.
- For clinical or claims data, warn the user when any count in a participant or cohort flow is below 11, since many data use agreements require suppressing small cells. Set `"clinical": false` only for non-human or simulated data.
- Output SVGs contain no scripts, no external links, no remote fonts and no software or date metadata.
- Neither engine uses network, shell, `eval` or deserialization. Do not add any of these. Write output only to the path the user chose; existing files are never overwritten unless asked.

## Style defaults (and where they come from)

- Serif, upper-and-lower-case type: 10 pt labels, 8.5 pt details (InkSight; Tufte p.183). Nothing below 7 pt.
- Ink `#262626` for text and lines, gray `#A6A6A6` for secondary lines and fills, gray `#595959` for secondary text, and one blue accent `#1F5FAD` for the one or two focal elements. No red versus green.
- Thin lines (0.75 pt), focal 1.25 pt. No shadows, gradients, 3-D, icons or decoration.
- Box shapes carry meaning only where convention gives them one: rounded pill for start and end, hexagon for a decision, slanted box for data.
- Arrows mean "leads to" or "causes". If a connection is obvious from position, leave the arrow out.
- Fits a 6.5 in (468 pt) column; left-to-right pipelines wider than that are for slides.

These are guides, not dogma. If a rule makes a diagram worse for its purpose, break it and say why.

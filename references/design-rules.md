# Design rules and how FrameDesign enforces them

FrameDesign applies InkSight's data-ink rules (from E. R. Tufte, *The Visual Display of Quantitative Information*, 2nd ed., 2001; page numbers below refer to that book) to diagrams, and adds rules that come from reporting guidelines (CONSORT 2010, PRISMA 2020, STROBE) and from causal inference. The R and Python engines enforce the same rules. The rules are paraphrased; no text from any source is reproduced.

Enforcement key: **code** = done automatically when rendering, **error** = rendering stops with a message, **check** = flagged by `check_svg()` / `fd_check()`, **checklist** = Claude verifies by looking at the rendered image.

## 1. Purpose and form

| # | Rule | Enforcement |
|---|------|-------------|
| 1.1 | A diagram must show structure a reader cannot get as quickly from a sentence, list or table. Two or three facts are a sentence. | checklist |
| 1.2 | Numbers to compare go to an InkSight chart, not into box sizes or arrow widths. | checklist |
| 1.3 | One idea per node: two nodes that always travel together are one node. | checklist |
| 1.4 | Every arrow carries information ("leads to", "causes", "becomes"). Remove arrows that restate the layout. | checklist |
| 1.5 | About 9 to 12 nodes at most; beyond that, split into two diagrams or use panels. | code (warning above 12) |

## 2. Integrity of counts (participant and cohort flow)

| # | Rule | Enforcement |
|---|------|-------------|
| 2.1 | Assessed minus excluded equals randomized (CONSORT) and each step equals the previous minus its exclusions (cohort). | error |
| 2.2 | Exclusion reasons sum to the excluded total; arms or groups sum to the randomized or final cohort. | error |
| 2.3 | Received plus did-not-receive equals allocated; analysed plus excluded-from-analysis equals allocated. | error |
| 2.4 | Losses cannot exceed the allocated count; counts are whole, non-negative numbers. | error |
| 2.5 | When analysed exceeds allocated minus losses, say how missing outcomes were handled (`"imputed": true`). | code (note) |
| 2.6 | Counts below 11 in clinical data trigger a small-cell suppression reminder. | code (note) |
| 2.7 | Counts are printed with thousands separators and "(n = X)" never splits across lines. | code |

| 2.8 | PRISMA: records identified equal the sum of databases and registers; screened = identified minus removed before screening; sought = screened minus excluded; assessed = sought minus not retrieved. | error |
| 2.9 | PRISMA: reports of included studies = assessed minus excluded at full text (plus the same for other methods); studies cannot exceed reports; an updated review's totals equal previous plus new. | error |

When a count does not add up, Claude reports the contradiction and asks which number is correct. It never edits the user's numbers to make them balance.

## 3. Integrity of causal diagrams

| # | Rule | Enforcement |
|---|------|-------------|
| 3.1 | A DAG has no cycles. | error |
| 3.2 | Exactly one exposure and one outcome are named. | error |
| 3.3 | Adjusting for a descendant of the exposure (a mediator, or a collider downstream of it) blocks the effect or induces bias. | code (warning) |
| 3.4 | Adjusting for a collider that is not an ancestor of exposure or outcome can open a path (M-bias). | code (warning) |
| 3.5 | Adjusting for an instrument amplifies bias. | code (warning) |
| 3.6 | Unmeasured variables cannot be adjusted for; they are drawn dashed and gray. | error + code |
| 3.7 | No directed path from exposure to outcome means the diagram assumes no effect. | code (note) |
| 3.8 | The drawn adjustment set must satisfy the backdoor criterion: no adjusted variable descends from the exposure, and the set d-separates exposure and outcome once the exposure's outgoing arrows are removed. If it fails, every minimal sufficient set of measured variables is listed. | code (warning) |
| 3.9 | If no set of measured variables is sufficient, the effect is reported as not identified by adjustment. | code (warning) |
| 3.10 | The adjustment set is stated under the diagram in words, and the DAG can be exported to dagitty for independent checking. | code |
| 3.11 | A DAG shows assumptions, not findings. Do not put effect sizes on arrows. | checklist |

The adjustment analysis uses d-separation on the moralised ancestral graph and enumerates minimal sets for up to 18 candidate variables. During development it matched networkx's d-separation on 400 random DAGs, and the R and Python engines matched each other on 150 more. It covers adjustment (backdoor) only; front-door and instrumental-variable identification are outside its scope, so use dagitty for those.

## 4. Data-ink and chartjunk (shared with InkSight)

| # | Rule | Enforcement |
|---|------|-------------|
| 4.1 | Erase non-data ink: no shadows, gradients, 3-D, icons, clip-art or background fills (p.96, p.107-121). | code |
| 4.2 | Thin structural lines; focal lines a little heavier (p.185). | code (0.75 / 1.25 pt) |
| 4.3 | Grays carry order; one accent marks what matters, never red against green (p.154, p.183). | code + check |
| 4.4 | The accent is editorial: one or two focal elements. Using it on more erases the signal. | code (warning above 2) |
| 4.5 | Words read left to right, spelled out, serif upper-and-lower case (p.183). | code |
| 4.6 | Label directly; a legend is a last resort. The DAG key is one plain sentence. | code |
| 4.7 | Lines are knocked out behind labels so text never sits on a line. | code |

## 5. Layout accuracy

| # | Rule | Enforcement |
|---|------|-------------|
| 5.1 | Boxes are sized from measured text (Times metrics), so text never overflows. | code + check |
| 5.2 | No two nodes overlap; no label overlaps a node or another label. | check |
| 5.3 | No edge passes through a node it does not connect; no edge crosses an edge label. | check |
| 5.4 | Edge crossings are minimised (barycentre ordering) and nodes are aligned with their neighbours (isotonic placement). | code |
| 5.5 | Loops (back edges) run outside the main flow, dashed and gray. | code |
| 5.6 | Everything sits inside the canvas; a 6.5 in (468 pt) column is the default target. | check + code (width warning) |
| 5.7 | Text is at least 7 pt at final size; panels shrunk below 70% are flagged; panels at different scales are flagged. | check + code |
| 5.8 | Text contrast is at least 4.5:1 on white. | check |
| 5.9 | The same spec always produces the same SVG (no randomness), so figures are reproducible. | code + test |

## 6. Privacy and security

| # | Rule | Enforcement |
|---|------|-------------|
| 6.1 | No identifiers in labels (SSN, exact dates, MRN, email, phone, date of birth patterns). | check |
| 6.2 | No remote fonts, images, links or scripts in output or in composed panels. | code + check (refused) |
| 6.3 | Embedded SVGs with entity declarations, scripts, event handlers or foreignObject are refused. | error |
| 6.4 | No '..' in paths; files are never overwritten unless asked. | error |
| 6.5 | No software or date metadata in output. | code |

## Pre-delivery checklist (Claude runs this on every diagram)

1. The diagram answers one question the reader has, and a sentence or table would not do it better.
2. Every count is the user's own, and the render raised no arithmetic error.
3. The participant, cohort or PRISMA flow reads top to bottom, with exclusions to the right of the step they came from.
4. In a DAG, exposure, outcome and adjustment set are unmistakable, the drawn set passes the backdoor check (or the user has been shown the minimal sets), and every warning is resolved or explained.
5. Labels are short, spelled out, and use the same group names as the accompanying charts.
6. The accent marks one or two things that matter; everything else is ink or gray.
7. No overlaps, clipped text or stray arrows in the rendered PNG (look at it).
8. Type is legible at final size, and panels in a combined figure are at the same scale.
9. No identifiers; small cells flagged for clinical data.
10. `check_svg()` returns no issues, or each remaining one is justified in one line.

# FrameDesign in pure R: no Python needed. Simulated data.
# Run from the FrameDesign folder:  Rscript examples/demo.R
# Optional: rsvg (PNG), ggplot2 + svglite (InkSight panel), dagitty.

source("R/framedesign.R")
out <- "examples/output"
dir.create(out, showWarnings = FALSE)

# 1. CONSORT flow from R lists
consort <- list(
  type = "consort",
  alt = "CONSORT flow of a simulated two-arm trial",
  assessed = 412, randomized = 300,
  excluded = list(reasons = fd_reasons(c("Did not meet inclusion criteria" = 71,
                                          "Declined to participate" = 33,
                                          "Other reasons" = 8))),
  arms = list(
    list(name = "Drug A", allocated = 150, received = 146,
         not_received = fd_reasons(c("Withdrew before dosing" = 4)),
         lost = fd_reasons(c("Moved away" = 3, "No reason given" = 2)),
         discontinued = fd_reasons(c("Adverse event" = 6)),
         analysed = 150, imputed = TRUE),
    list(name = "Placebo", allocated = 150, received = 149,
         not_received = fd_reasons(c("Withdrew before dosing" = 1)),
         lost = fd_reasons(c("No reason given" = 4)),
         discontinued = fd_reasons(c("Lack of efficacy" = 3)),
         analysed = 148, excluded_analysis = fd_reasons(c("No baseline measurement" = 2)))))
fd_render(consort, file.path(out, "r_consort.svg"), overwrite = TRUE)

# 2. Causal DAG: formal adjustment sets and a dagitty model
dag <- list(type = "dag", alt = "Assumed causal structure for smoking and revision surgery",
  nodes = list(list(id = "Smoking", role = "exposure"),
               list(id = "Revision", label = "Revision surgery", role = "outcome"),
               list(id = "Age", role = "confounder", adjusted = TRUE),
               list(id = "SES", label = "Socioeconomic status", role = "confounder", adjusted = TRUE),
               list(id = "Diabetes", role = "confounder"),
               list(id = "Frailty", role = "unmeasured")),
  edges = list(list(from = "Smoking", to = "Revision"), list(from = "Age", to = "Smoking"),
               list(from = "Age", to = "Revision"), list(from = "SES", to = "Smoking"),
               list(from = "SES", to = "Diabetes"), list(from = "Diabetes", to = "Revision"),
               list(from = "Frailty", to = "Diabetes"), list(from = "Frailty", to = "Revision")))
print(fd_adjustment_sets(dag))      # minimal sufficient sets: here {Age, SES}
cat(fd_dagitty(dag), "\n")           # paste into dagitty.net, or fd_dagitty(dag, object = TRUE)
fd_render(dag, file.path(out, "r_dag.svg"), overwrite = TRUE)

# 3. Every JSON example spec, rendered by the R engine (needs jsonlite)
if (requireNamespace("jsonlite", quietly = TRUE)) {
  for (f in list.files("examples/specs", pattern = "^(09|10)_.*json$", full.names = TRUE))
    fd_render_json(f, file.path(out, sub("\\.json$", "_r.svg", basename(f))), overwrite = TRUE)
}

# 4. InkSight chart beside the CONSORT diagram, if InkSight sits next to FrameDesign
cands <- c(file.path(Sys.getenv("INKSIGHT_DIR"), "R", "inksight.R"),
           "../inksight/R/inksight.R", "../inksight/Upload/R/inksight.R")
ink <- cands[file.exists(cands)][1]
if (!is.na(ink) && requireNamespace("ggplot2", quietly = TRUE) && requireNamespace("svglite", quietly = TRUE)) {
  source(ink)
  p <- vdqi_bar(data.frame(arm = c("Drug A", "Placebo"), resp = c(42, 27)), "arm", "resp",
                ylab = "Responders at 12 weeks, %", title = "Drug A doubled the response rate")
  save_vdqi(p, file.path(out, "r_response.svg"), width = 2.8, height = 2.8 / 1.5, overwrite = TRUE)
  fig <- list(type = "panels", cols = 2,
              panels = list(list(span = 2, file = "r_consort.svg"), list(file = "r_response.svg")))
  fd_render(fig, file.path(out, "r_figure.svg"), overwrite = TRUE, base_dir = out)
  if (requireNamespace("rsvg", quietly = TRUE)) fd_png(file.path(out, "r_figure.svg"), overwrite = TRUE)
}
print(fd_check(file.path(out, "r_consort.svg")))   # character(0) means no issues

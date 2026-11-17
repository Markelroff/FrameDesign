# Run with:  Rscript tests/test_framedesign.R   (from the FrameDesign folder)
# Pure R: needs only base R. jsonlite enables the R/Python parity test;
# ggplot2 + svglite (and InkSight beside FrameDesign) enable the tie-in test.

source("R/framedesign.R")
tmp <- tempfile("fdtest"); dir.create(tmp)
pass <- 0L
ok <- function(cond, what) { if (!isTRUE(cond)) stop("FAILED: ", what, call. = FALSE); pass <<- pass + 1L }
err <- function(expr) tryCatch({ force(expr); "" }, error = function(e) conditionMessage(e))
has_json <- requireNamespace("jsonlite", quietly = TRUE)
spec_of <- function(name) fd_read_spec(file.path("examples", "specs", name))

# ---- text ---------------------------------------------------------------------
ok(abs(fd_text_width("n", 10) - 5) < 1e-9, "Times metrics: n")
ok(abs(fd_text_width("W", 10) - 9.44) < 1e-9, "Times metrics: W")
w <- fd_wrap(paste("Received allocated intervention", .fd_cnt(146)), 120, 8.5)
ok(any(grepl("146", w)) && !any(grepl("\\(n$|=$", w)), "counts never split across lines")
ok(.fd_n(48210) == "48,210", "thousands separator")

# ---- fd_reasons and R-style input -----------------------------------------------
r <- fd_reasons(c("Declined" = 33, "Other" = 8))
ok(length(r) == 2 && identical(r[[1]][[1]], "Declined") && r[[1]][[2]] == 33L, "fd_reasons pairs")
ok(nzchar(err(fd_reasons(c(a = 1.5)))), "fd_reasons rejects fractions")

consort <- list(
  type = "consort", assessed = 412, randomized = 300,
  excluded = list(total = 112, reasons = fd_reasons(c("Did not meet criteria" = 71, "Declined" = 33, "Other" = 8))),
  arms = list(
    list(name = "Drug A", allocated = 150, received = 146, not_received = list("Withdrew", 4), analysed = 150),
    list(name = "Placebo", allocated = 150, received = 149, not_received = fd_reasons(c("Withdrew" = 1)), analysed = 150)))
f <- file.path(tmp, "consort.svg")
fd_render(consort, f)
ok(file.exists(f) && length(fd_check(f)) == 0, "CONSORT renders clean (single bare pair accepted)")

# ---- arithmetic errors stop rendering ------------------------------------------------
bad <- consort; bad$randomized <- 301
ok(grepl("randomized", err(fd_render(bad, file.path(tmp, "bad.svg")))), "CONSORT: randomized mismatch")
ok(!file.exists(file.path(tmp, "bad.svg")), "nothing written for a bad spec")
bad <- consort; bad$arms[[2]]$analysed <- 149
ok(grepl("analysed", err(fd_svg(bad))), "CONSORT: analysed mismatch")
bad <- consort; bad$excluded$reasons[[1]][[2]] <- 70
ok(grepl("reasons sum", err(fd_svg(bad))), "CONSORT: reasons do not sum")
ok(grepl("exists", err(fd_render(consort, f))), "no silent overwrite")
ok(grepl("\\.\\.", err(fd_write_svg("<svg/>", "../x.svg"))), "'..' paths refused")

cohort <- list(type = "cohort", start = list(label = "Records", n = 1000),
               steps = list(list(excluded = 200, reasons = list("Too young", 200), label = "Adults", n = 800)),
               groups = list(list(label = "A", n = 500), list(label = "B", n = 300)))
ok(length(fd_svg(cohort)$findings) == 0, "cohort renders clean")
bad <- cohort; bad$steps[[1]]$n <- 790
ok(grepl("step 1", err(fd_svg(bad))), "cohort: step mismatch")
bad <- cohort; bad$groups[[1]]$n <- 1
ok(grepl("groups sum", err(fd_svg(bad))), "cohort: groups mismatch")
small <- list(type = "cohort", start = list(label = "Records", n = 20), steps = list(list(excluded = 12, label = "Kept")))
ok(any(grepl("below 11", fd_svg(small)$findings)), "small cells flagged")

# ---- PRISMA ---------------------------------------------------------------------------
prisma <- list(type = "prisma",
  identification = list(databases = fd_reasons(c(PubMed = 214, Embase = 260))),
  removed = list(duplicates = 151), screen_excluded = 271, not_retrieved = 2,
  full_text_excluded = fd_reasons(c("Wrong population" = 31, "Wrong design" = 13)),
  included = list(studies = 6, reports = 6),
  previous = list(studies = 18, reports = 21), total = list(studies = 24, reports = 27))
ok(length(fd_svg(prisma)$findings) == 0, "PRISMA (updated review) renders clean")
d <- .fd_prisma_checks(fd_normalise(prisma))
ok(d$screened == 323 && d$sought == 52 && d$assessed == 50, "PRISMA counts derived")
bad <- prisma; bad$included$reports <- 7
ok(grepl("included reports", err(fd_svg(bad))), "PRISMA: included reports mismatch")
bad <- prisma; bad$total$studies <- 23
ok(grepl("total studies", err(fd_svg(bad))), "PRISMA: totals mismatch")
bad <- prisma; bad$screen_excluded <- 400
ok(grepl("negative", err(fd_svg(bad))), "PRISMA: negative step")

# ---- DAG: formal adjustment sets ------------------------------------------------------------
dag <- function(edges, roles) {
  ids <- unique(unlist(edges))
  list(type = "dag", nodes = lapply(ids, function(v) list(id = v, role = roles[[v]] %||% "other")),
       edges = lapply(edges, function(e) list(from = e[1], to = e[2])))
}
s <- dag(list(c("C", "X"), c("C", "Y"), c("X", "Y")), list(X = "exposure", Y = "outcome"))
ok(identical(fd_adjustment_sets(s), list("C")), "confounder: {C}")
s <- dag(list(c("U1", "X"), c("U1", "M"), c("U2", "M"), c("U2", "Y"), c("X", "Y")),
         list(X = "exposure", Y = "outcome", U1 = "unmeasured", U2 = "unmeasured"))
ok(identical(fd_adjustment_sets(s), list(character(0))) && !fd_backdoor_ok(s, "M"), "M-bias: adjust for nothing, not M")
s <- dag(list(c("U", "X"), c("U", "Y"), c("X", "Y")), list(X = "exposure", Y = "outcome", U = "unmeasured"))
ok(any(grepl("not identified", fd_svg(s)$findings)), "unidentifiable effect reported")
s <- dag(list(c("X", "M"), c("M", "Y"), c("C", "X"), c("C", "Y"), c("X", "Y")), list(X = "exposure", Y = "outcome"))
s$nodes[[2]]$adjusted <- TRUE    # M, a mediator
ok(any(grepl("descendant of the exposure", fd_svg(s)$findings)), "mediator adjustment warned")
ok(grepl("backdoor criterion", paste(fd_svg(s)$findings, collapse = " ")), "insufficient set reported with minimal sets")
cyc <- dag(list(c("X", "Y"), c("Y", "X")), list(X = "exposure", Y = "outcome"))
ok(grepl("cycle", err(fd_svg(cyc))), "cycle rejected")
txt <- fd_dagitty(dag(list(c("Wound infection", "Revision")), list(`Wound infection` = "exposure", Revision = "outcome")))
ok(grepl("Wound_infection \\[exposure\\]", txt) && grepl("Wound_infection -> Revision", txt), "dagitty export")

# ---- timeline (single values from R) ------------------------------------------------------------
tl <- list(type = "timeline", start = "2026-09", end = "2027-08",
           tracks = list(list(label = "Rotation", spans = c("2026-09", "2026-12")),
                         list(label = "Qualifying exam", points = "2027-05")),
           milestones = list(list(at = "2027-01", label = "Choose advisor")))
ok(length(fd_svg(tl)$findings) == 0, "timeline with scalar points renders clean")
ok(.fd_to_num("2026-12", end = TRUE) - .fd_to_num("2026-12") == 1, "end month inclusive")

# ---- security and checker -------------------------------------------------------------------------
attacks <- c('<!DOCTYPE svg [<!ENTITY x "y">]><svg/>', "<svg><script>x</script></svg>", '<svg onload="x()"/>',
             '<svg><image href="https://example.org/a.png"/></svg>', "<svg><foreignObject/></svg>")
for (a in attacks) ok(nzchar(err(.fd_screen(a))), paste("screen refuses", substr(a, 1, 30)))
src <- paste(readLines("R/framedesign.R", warn = FALSE), collapse = "\n")
code <- gsub("#[^\n]*", "", src)
for (b in c("system(", "system2(", "eval(", "parse(text", "download.file", "readRDS", "unserialize", "socketConnection", "curl"))
  ok(!grepl(b, code, fixed = TRUE), paste("engine has no", b))
sv <- function(inner) paste0('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" font-family="serif">', inner, "</svg>")
ok(any(grepl("overlap", fd_check_svg(sv('<rect data-fd="node" data-fd-id="a" data-fd-box="10,10,50,20"/><rect data-fd="node" data-fd-id="b" data-fd-box="40,15,50,20"/>')))), "checker: overlap")
ok(any(grepl("identifiers", fd_check_svg(sv('<text fill="#262626" font-size="10">MRN 123456</text>')))), "checker: identifiers")
ok(any(grepl("contrast", fd_check_svg(sv('<text fill="#A6A6A6" font-size="10">x</text>')))), "checker: low contrast")
ok(any(grepl("Red and green", fd_check_svg(sv('<rect fill="#D62728"/><rect fill="#2CA02C"/>')))), "checker: red with green")

# ---- R / Python parity (same spec, same geometry) ----------------------------------------------------
if (has_json && file.exists("tests/reference_geometry.tsv")) {
  ref <- utils::read.delim("tests/reference_geometry.tsv", colClasses = "character", quote = "", na.strings = NULL)
  for (sp in unique(ref$spec)) {
    rr <- ref[ref$spec == sp, ]
    svg <- fd_svg(spec_of(paste0(sp, ".json")))$svg
    vb <- as.numeric(strsplit(.fd_attr(regmatches(svg, regexpr("<svg\\b[^>]*>", svg)), "viewBox"), " ")[[1]])
    els <- regmatches(svg, gregexpr("<[a-z]+\\b[^>]*data-fd=\"(node|label|bar|group|edge)\"[^>]*>", svg, perl = TRUE))[[1]]
    got <- vapply(els, function(e) { k <- .fd_attr(e, "data-fd")
      paste(k, .fd_unesc(.fd_attr(e, "data-fd-id")), if (k == "edge") .fd_attr(e, "data-fd-points") else .fd_attr(e, "data-fd-box"), sep = "\t") }, "")
    exp_ <- paste(rr$kind, rr$id, rr$values, sep = "\t")[-1]
    nums <- function(x) as.numeric(unlist(strsplit(sub("^[^\t]*\t[^\t]*\t", "", x), "[ ,]")))
    same <- length(got) == length(exp_) &&
      all(sub("\t[^\t]*$", "", got) == sub("\t[^\t]*$", "", exp_)) &&
      max(abs(nums(got) - nums(exp_)), abs(vb - as.numeric(strsplit(rr$values[1], " ")[[1]]))) < 0.02
    ok(same, paste("R matches Python geometry:", sp))
  }
} else message("jsonlite not installed: skipped the R/Python parity test")

# ---- InkSight tie-in -----------------------------------------------------------------------------------
cands <- c(file.path(Sys.getenv("INKSIGHT_DIR"), "R", "inksight.R"), file.path("..", "inksight", "R", "inksight.R"),
           file.path("..", "inksight", "Upload", "R", "inksight.R"))
ink <- cands[file.exists(cands)][1]
if (!is.na(ink) && requireNamespace("ggplot2", quietly = TRUE) && requireNamespace("svglite", quietly = TRUE)) {
  source(ink)
  p <- vdqi_bar(data.frame(arm = c("Drug A", "Placebo"), resp = c(42, 27)), "arm", "resp",
                ylab = "Responders, %", title = "Drug A doubled the response rate")
  save_vdqi(p, file.path(tmp, "response.svg"), width = 2.8, height = 2.8 / 1.5)
  fig <- list(type = "panels", cols = 2, panels = list(list(span = 2, file = "consort.svg"), list(file = "response.svg")))
  fd_render(fig, file.path(tmp, "figure.svg"), base_dir = tmp)
  ok(length(fd_check(file.path(tmp, "figure.svg"))) == 0, "InkSight + FrameDesign figure is clean")
} else message("InkSight (../inksight) or ggplot2/svglite not found: skipped the tie-in test")

cat(pass, "R checks passed\n")

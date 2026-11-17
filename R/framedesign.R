# framedesign.R (FrameDesign)
# Pure-R engine: editorial research diagrams as self-contained SVG, with no
# Python needed. Same specs, same layout and same checks as
# python/framedesign.py (a parity test in tests/ keeps the two in step).
#
# Diagram types: flow / pipeline, dag, consort, cohort, prisma, timeline, panels.
# Companion to InkSight (R/inksight.R): same palette, serif type and data-ink rules.
#
# Requires: base R only.
# Optional: jsonlite (read and write JSON specs), rsvg (PNG export),
#           dagitty (to hand a DAG to dagitty for further analysis).
#
# Security and privacy notes
# - No network calls, no system()/system2(), no eval(parse()), no deserialization.
# - Output SVG has no scripts, no remote fonts, no links, no software or date metadata.
# - SVG panels are screened: entity declarations, scripts, event handlers,
#   foreignObject and remote references are refused.
# - Files are never overwritten unless overwrite = TRUE; '..' paths are refused.

fd_version <- "1.1.0"

# ---- Shared design tokens (identical to InkSight) --------------------------
FD <- list(
  INK = "#262626", MUTED = "#A6A6A6", TEXT_MUTED = "#595959", ACCENT = "#1F5FAD",
  FILL_MUTED = "#F2F2F2", PAPER = "#FFFFFF",
  FONT = "'Times New Roman', Times, 'Liberation Serif', serif",
  FONT_CSS = "Times New Roman, Times, Liberation Serif, serif",
  SIZE_LABEL = 10, SIZE_SMALL = 8.5, SIZE_TITLE = 11, SIZE_PANEL = 12,
  STROKE = 0.75, STROKE_FOCAL = 1.25, COLUMN_PT = 468, MAX_ACCENTS = 2, M = 12
)

# Glyph advance widths (1/1000 em), ASCII 32..126, Times-compatible metrics.
.fd_W <- list(
  regular = c(250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, 556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, 333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, 500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541),
  bold = c(250, 333, 555, 500, 500, 1000, 833, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 930, 722, 667, 722, 722, 667, 611, 778, 778, 389, 500, 778, 667, 944, 722, 778, 611, 778, 722, 556, 667, 722, 722, 1000, 722, 722, 667, 333, 278, 333, 581, 500, 333, 500, 556, 444, 556, 444, 333, 500, 556, 278, 333, 556, 278, 833, 556, 500, 556, 556, 444, 389, 333, 556, 500, 722, 500, 500, 444, 394, 220, 394, 520),
  italic = c(250, 333, 420, 500, 500, 833, 778, 214, 333, 333, 500, 675, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 675, 675, 675, 500, 920, 611, 611, 667, 722, 611, 611, 722, 722, 333, 444, 667, 556, 833, 667, 722, 611, 722, 611, 500, 556, 722, 611, 833, 611, 556, 556, 389, 278, 389, 422, 500, 333, 500, 500, 444, 500, 444, 278, 500, 500, 278, 278, 444, 278, 722, 500, 500, 500, 500, 389, 389, 278, 500, 444, 667, 444, 444, 389, 400, 275, 400, 541))
# Non-ASCII glyphs are built from code points so the file parses the same in any locale.
.fd_WX <- setNames(c(250, 350, 333, 500, 564, 549, 549, 549, 576, 524, 509, 442, 643, 1000),
                   intToUtf8(c(0xA0, 0x2022, 0xB7, 0x2013, 0xD7, 0x2265, 0x2264, 0xB1, 0xB5,
                               0x3B1, 0x3B2, 0x3B3, 0x394, 0x2192), multiple = TRUE))
.fd_DUMMY <- paste0(intToUtf8(1), "d")
.fd_DOT <- intToUtf8(0xB7)
.fd_NBSP <- intToUtf8(0xA0)

`%||%` <- function(a, b) if (is.null(a)) b else a
.fd_stop <- function(...) stop(structure(class = c("fd_spec_error", "error", "condition"),
                                         list(message = paste0(...), call = NULL)))
.fd_true <- function(x) isTRUE(as.logical(x %||% FALSE))

# ---- Text measurement and wrapping ------------------------------------------
fd_text_width <- function(s, size = FD$SIZE_LABEL, style = "regular") {
  tab <- .fd_W[[style]] %||% .fd_W$regular
  s <- enc2utf8(as.character(s))
  if (!nzchar(s)) return(0)
  ch <- strsplit(s, "")[[1]]
  cp <- utf8ToInt(s)
  w <- ifelse(cp >= 32 & cp <= 126, tab[pmax(1, pmin(95, cp - 31))],
              ifelse(ch %in% names(.fd_WX), .fd_WX[ch], 600))
  sum(w) * size / 1000
}

fd_wrap <- function(text, max_w, size = FD$SIZE_LABEL, style = "regular") {
  out <- character(0)
  paras <- strsplit(as.character(text), "\n", fixed = TRUE)[[1]]
  if (!length(paras)) paras <- ""
  for (para in paras) {
    words <- strsplit(para, " ", fixed = TRUE)[[1]]
    if (!length(words)) words <- ""
    cur <- ""
    for (w in words) {
      trial <- if (!nzchar(cur)) w else paste(cur, w)
      if (nzchar(cur) && fd_text_width(trial, size, style) > max_w) {
        out <- c(out, cur); cur <- w
      } else cur <- trial
    }
    out <- c(out, cur)
  }
  out
}

.fd_esc <- function(s) {
  s <- gsub("&", "&amp;", as.character(s), fixed = TRUE)
  s <- gsub("<", "&lt;", s, fixed = TRUE); s <- gsub(">", "&gt;", s, fixed = TRUE)
  gsub('"', "&quot;", s, fixed = TRUE)
}
.fd_unesc <- function(s) {
  s <- gsub("&lt;", "<", s, fixed = TRUE); s <- gsub("&gt;", ">", s, fixed = TRUE)
  s <- gsub("&quot;", '"', s, fixed = TRUE); s <- gsub("&apos;", "'", s, fixed = TRUE)
  gsub("&amp;", "&", s, fixed = TRUE)
}
.fd_f <- function(v) {
  s <- sprintf("%.2f", v); s <- sub("0+$", "", s); sub("\\.$", "", s)
}
.fd_n <- function(v) formatC(round(as.numeric(v)), big.mark = ",", format = "d")
.fd_cnt <- function(v) paste0("(n", .fd_NBSP, "=", .fd_NBSP, .fd_n(v), ")")

# ---- SVG canvas --------------------------------------------------------------
.fd_canvas <- function() { cv <- new.env(); cv$items <- character(0); cv$accent <- 0; cv }
.fd_add <- function(cv, s) cv$items <- c(cv$items, s)

.fd_text_block <- function(cv, lines, cx, top, size = FD$SIZE_LABEL, style = "regular",
                           colour = FD$INK, anchor = "middle", lh = 1.22, maxw = NULL) {
  weight <- if (style == "bold") ' font-weight="bold"' else ""
  italic <- if (style == "italic") ' font-style="italic"' else ""
  out <- character(0)
  for (i in seq_along(lines)) {
    y <- top + size * 0.80 + (i - 1) * size * lh
    meta <- if (!is.null(maxw))
      sprintf(' data-fd-w="%s" data-fd-maxw="%s"', .fd_f(fd_text_width(lines[i], size, style)), .fd_f(maxw)) else ""
    out <- c(out, sprintf('<text x="%s" y="%s" font-size="%s"%s%s fill="%s" text-anchor="%s"%s>%s</text>',
                          .fd_f(cx), .fd_f(y), .fd_f(size), weight, italic, colour, anchor, meta, .fd_esc(lines[i])))
  }
  .fd_add(cv, paste(out, collapse = ""))
  length(lines) * size * lh
}

.fd_svg <- function(cv, width, height, title = NULL, desc = NULL) {
  head <- sprintf(paste0('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ',
                         'width="%spt" height="%spt" viewBox="0 0 %s %s" font-family="%s" data-framedesign="%s" role="img">'),
                  .fd_f(width), .fd_f(height), .fd_f(width), .fd_f(height), FD$FONT, fd_version)
  meta <- paste0(if (!is.null(title)) sprintf("<title>%s</title>", .fd_esc(title)) else "",
                 if (!is.null(desc)) sprintf("<desc>%s</desc>", .fd_esc(desc)) else "")
  mk <- function(id, size, col) sprintf(paste0('<marker id="%s" viewBox="0 0 8 8" refX="7.4" refY="4" markerWidth="%s" ',
    'markerHeight="%s" markerUnits="userSpaceOnUse" orient="auto"><path d="M0,0.6 L7.6,4 L0,7.4 Z" fill="%s"/></marker>'),
    id, size, size, col)
  defs <- paste0("<defs>", mk("fd-arrow", "6", FD$INK), mk("fd-arrow-accent", "6.5", FD$ACCENT),
                 mk("fd-arrow-muted", "6", FD$MUTED), "</defs>")
  paste0(head, meta, defs, sprintf('<rect width="100%%" height="100%%" fill="%s"/>', FD$PAPER),
         paste(cv$items, collapse = ""), "</svg>")
}

.fd_box_meta <- function(kind, ident, x, y, w, h)
  sprintf(' data-fd="%s" data-fd-id="%s" data-fd-box="%s,%s,%s,%s"', kind, .fd_esc(ident),
          .fd_f(x), .fd_f(y), .fd_f(w), .fd_f(h))

.fd_pts_str <- function(pts) paste(sprintf("%s,%s", .fd_f(pts[, 1]), .fd_f(pts[, 2])), collapse = " ")

.fd_poly <- function(pts, colour = FD$INK, width = FD$STROKE, dashed = FALSE, arrow = TRUE, ident = "") {
  d <- paste0("M", paste(sprintf("%s,%s", .fd_f(pts[, 1]), .fd_f(pts[, 2])), collapse = " L"))
  dash <- if (dashed) ' stroke-dasharray="3,2.5"' else ""
  mk <- if (arrow) sprintf(' marker-end="url(#%s)"', if (colour == FD$ACCENT) "fd-arrow-accent" else
    if (colour == FD$MUTED) "fd-arrow-muted" else "fd-arrow") else ""
  sprintf(paste0('<path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round"%s%s ',
                 'data-fd="edge" data-fd-id="%s" data-fd-points="%s"/>'),
          d, colour, .fd_f(width), dash, mk, .fd_esc(ident), .fd_pts_str(pts))
}

.fd_curve <- function(pts, colour = FD$INK, width = FD$STROKE, dashed = FALSE, ident = "") {
  if (nrow(pts) == 2) return(.fd_poly(pts, colour, width, dashed, ident = ident))
  P <- rbind(pts[1, ], pts, pts[nrow(pts), ])
  d <- sprintf("M%s,%s", .fd_f(P[2, 1]), .fd_f(P[2, 2]))
  samples <- P[2, , drop = FALSE]
  for (i in 2:(nrow(P) - 2)) {
    p0 <- P[i - 1, ]; p1 <- P[i, ]; p2 <- P[i + 1, ]; p3 <- P[i + 2, ]
    c1 <- p1 + (p2 - p0) / 6; c2 <- p2 - (p3 - p1) / 6
    d <- paste0(d, sprintf(" C%s,%s %s,%s %s,%s", .fd_f(c1[1]), .fd_f(c1[2]), .fd_f(c2[1]), .fd_f(c2[2]),
                           .fd_f(p2[1]), .fd_f(p2[2])))
    for (t in c(0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1)) {
      u <- 1 - t
      samples <- rbind(samples, u^3 * p1 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t^3 * p2)
    }
  }
  dash <- if (dashed) ' stroke-dasharray="3,2.5"' else ""
  m <- if (colour == FD$ACCENT) "fd-arrow-accent" else if (colour == FD$MUTED) "fd-arrow-muted" else "fd-arrow"
  sprintf('<path d="%s" fill="none" stroke="%s" stroke-width="%s"%s marker-end="url(#%s)" data-fd="edge" data-fd-id="%s" data-fd-points="%s"/>',
          d, colour, .fd_f(width), dash, m, .fd_esc(ident), .fd_pts_str(samples))
}

.fd_clip <- function(cx, cy, hw, hh, tx, ty, gap = 2) {
  dx <- tx - cx; dy <- ty - cy
  if (dx == 0 && dy == 0) return(c(cx, cy))
  t <- min(if (dx != 0) (hw + gap) / abs(dx) else Inf, if (dy != 0) (hh + gap) / abs(dy) else Inf)
  c(cx + dx * t, cy + dy * t)
}

.fd_shorten <- function(pts, by) {
  n <- nrow(pts); a <- pts[n - 1, ]; b <- pts[n, ]
  L <- sqrt(sum((b - a)^2))
  if (L <= by) return(pts)
  pts[n, ] <- b - (b - a) * by / L
  pts
}

# ---- Nodes -------------------------------------------------------------------
.fd_KINDS <- c("process", "decision", "terminal", "data", "note", "plain")

.fd_node_size <- function(label, kind, max_w, size = FD$SIZE_LABEL, style = "regular") {
  pad <- if (kind == "decision") c(14, 7) else c(9, 6)
  if (kind %in% c("note", "plain")) pad <- c(2, 2)
  lines <- fd_wrap(label, max_w, size, style)
  tw <- max(vapply(lines, fd_text_width, 0, size = size, style = style))
  th <- length(lines) * size * 1.22 - size * 0.22
  list(lines = lines, w = tw + 2 * pad[1] + (if (kind == "data") 10 else 0), h = th + 2 * pad[2], tw = tw)
}

.fd_draw_node <- function(cv, n, x, y, w, h, lines) {
  kind <- n$kind %||% "process"
  focal <- .fd_true(n$focal); muted <- .fd_true(n$muted)
  stroke <- if (focal) FD$ACCENT else if (muted) FD$MUTED else FD$INK
  sw <- if (focal) FD$STROKE_FOCAL else FD$STROKE
  if (focal) cv$accent <- cv$accent + 1
  style <- if (.fd_true(n$bold)) "bold" else if (kind == "note") "italic" else "regular"
  tcol <- if (kind == "note" || muted) FD$TEXT_MUTED else FD$INK
  meta <- .fd_box_meta("node", n$id, x, y, w, h)
  dash <- if (.fd_true(n$dashed)) ' stroke-dasharray="3,2.5"' else ""
  common <- sprintf('fill="%s" stroke="%s" stroke-width="%s"%s', FD$PAPER, stroke, .fd_f(sw), dash)
  poly <- function(p) paste(sprintf("%s,%s", .fd_f(p[, 1]), .fd_f(p[, 2])), collapse = " ")
  if (kind == "process") {
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="2" %s%s/>', .fd_f(x), .fd_f(y), .fd_f(w), .fd_f(h), common, meta))
  } else if (kind == "terminal") {
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" %s%s/>', .fd_f(x), .fd_f(y), .fd_f(w), .fd_f(h), .fd_f(h / 2), common, meta))
  } else if (kind == "decision") {
    k <- min(10, h / 2)
    p <- rbind(c(x + k, y), c(x + w - k, y), c(x + w, y + h / 2), c(x + w - k, y + h), c(x + k, y + h), c(x, y + h / 2))
    .fd_add(cv, sprintf('<polygon points="%s" %s%s/>', poly(p), common, meta))
  } else if (kind == "data") {
    p <- rbind(c(x + 5, y), c(x + w, y), c(x + w - 5, y + h), c(x, y + h))
    .fd_add(cv, sprintf('<polygon points="%s" %s%s/>', poly(p), common, meta))
  } else {
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" stroke="none"%s/>', .fd_f(x), .fd_f(y), .fd_f(w), .fd_f(h), FD$PAPER, meta))
  }
  size <- n$size %||% (if (kind == "note") FD$SIZE_SMALL else FD$SIZE_LABEL)
  th <- length(lines) * size * 1.22 - size * 0.22
  .fd_text_block(cv, lines, x + w / 2, y + (h - th) / 2 - size * 0.02, size = size, style = style,
                 colour = tcol, maxw = w - 2)
}

# ---- Layered layout ------------------------------------------------------------
.fd_isotonic <- function(values, weights) {
  bs <- list()
  for (i in seq_along(values)) {
    bs[[length(bs) + 1]] <- c(values[i] * weights[i], weights[i], 1)
    while (length(bs) > 1 && bs[[length(bs) - 1]][1] / bs[[length(bs) - 1]][2] > bs[[length(bs)]][1] / bs[[length(bs)]][2]) {
      b <- bs[[length(bs)]]; bs[[length(bs)]] <- NULL
      bs[[length(bs)]] <- bs[[length(bs)]] + b
    }
  }
  unlist(lapply(bs, function(b) rep(b[1] / b[2], b[3])))
}

.fd_crossings <- function(oa, ob, ea, eb) {
  pa <- match(ea, oa) - 1; pb <- match(eb, ob) - 1
  ok <- !is.na(pa) & !is.na(pb); pa <- pa[ok]; pb <- pb[ok]
  n <- length(pa); c <- 0
  if (n > 1) for (i in 1:(n - 1)) for (j in (i + 1):n) if ((pa[i] - pa[j]) * (pb[i] - pb[j]) < 0) c <- c + 1
  c
}

.fd_layout <- function(spec, max_w = NULL, rank_gap = NULL, node_gap = 18) {
  direction <- toupper(spec$direction %||% "TB")
  if (!direction %in% c("TB", "LR")) .fd_stop("direction must be 'TB' or 'LR'")
  nodes <- spec$nodes; edges <- spec$edges %||% list()
  if (!length(nodes)) .fd_stop("spec has no nodes")
  ids <- vapply(nodes, function(n) if (is.null(n$id)) "" else as.character(n$id), "")
  if (any(!nzchar(ids))) .fd_stop("every node needs an 'id'")
  if (anyDuplicated(ids)) .fd_stop("duplicate node ids: ", paste(unique(ids[duplicated(ids)]), collapse = ", "))
  for (i in seq_along(nodes)) {
    nodes[[i]]$id <- ids[i]
    if (is.null(nodes[[i]]$label)) nodes[[i]]$label <- ids[i]
    if (!(nodes[[i]]$kind %||% "process") %in% .fd_KINDS)
      .fd_stop("node ", ids[i], ": kind must be one of ", paste(sort(.fd_KINDS), collapse = ", "))
  }
  byid <- setNames(nodes, ids)
  E <- list()
  for (e in edges) {
    u <- as.character(e$from %||% ""); v <- as.character(e$to %||% "")
    if (!u %in% ids || !v %in% ids) .fd_stop("edge ", u, " -> ", v, " references an unknown node")
    if (u == v) .fd_stop("self-loop on ", u, ": describe repetition in the label instead")
    e$from <- u; e$to <- v
    E[[length(E) + 1]] <- e
  }
  nE <- length(E)
  efrom <- vapply(E, `[[`, "", "from"); eto <- vapply(E, `[[`, "", "to")
  # 1. break cycles (DFS in input order)
  state <- setNames(integer(length(ids)), ids); back <- integer(0)
  dfs <- function(u) {
    state[u] <<- 1L
    for (k in which(efrom == u)) {
      v <- eto[k]
      if (state[v] == 1L) back <<- c(back, k) else if (state[v] == 0L) dfs(v)
    }
    state[u] <<- 2L
  }
  for (i in ids) if (state[i] == 0L) dfs(i)
  fwd <- setdiff(seq_len(nE), back)
  # 2. longest-path ranks
  indeg <- setNames(integer(length(ids)), ids)
  for (k in fwd) indeg[eto[k]] <- indeg[eto[k]] + 1L
  queue <- ids[indeg == 0]; topo <- character(0)
  while (length(queue)) {
    u <- queue[1]; queue <- queue[-1]; topo <- c(topo, u)
    for (k in fwd) if (efrom[k] == u) {
      indeg[eto[k]] <- indeg[eto[k]] - 1L
      if (indeg[eto[k]] == 0) queue <- c(queue, eto[k])
    }
  }
  rank <- setNames(numeric(length(ids)), ids)
  prop <- function() for (u in topo) for (k in fwd) if (efrom[k] == u) rank[eto[k]] <<- max(rank[eto[k]], rank[u] + 1)
  prop()
  for (n in nodes) if (!is.null(n$rank)) rank[n$id] <- max(rank[n$id], as.numeric(n$rank))
  prop()
  # 3. sizes
  if (is.null(max_w)) max_w <- if (direction == "TB") 120 else 92
  info <- list()
  for (n in nodes) {
    kind <- n$kind %||% "process"
    style <- if (.fd_true(n$bold)) "bold" else if (kind == "note") "italic" else "regular"
    size <- n$size %||% (if (kind == "note") FD$SIZE_SMALL else FD$SIZE_LABEL)
    info[[n$id]] <- .fd_node_size(n$label, kind, n$max_width %||% max_w, size, style)
  }
  isd <- function(v) startsWith(v, .fd_DUMMY)
  osz <- function(v) if (isd(v)) 0 else if (direction == "TB") info[[v]]$w else info[[v]]$h
  rsz <- function(v) if (isd(v)) 0 else if (direction == "TB") info[[v]]$h else info[[v]]$w
  # 4. dummies
  nl <- max(rank) + 1
  layers <- replicate(nl, character(0), simplify = FALSE)
  for (i in ids) layers[[rank[i] + 1]] <- c(layers[[rank[i] + 1]], i)
  chains <- list(); la <- character(0); lb <- character(0); dc <- 0
  for (k in fwd) {
    u <- efrom[k]; v <- eto[k]; ch <- u
    if (rank[v] - rank[u] > 1) for (r in (rank[u] + 1):(rank[v] - 1)) {
      d <- paste0(.fd_DUMMY, dc); dc <- dc + 1
      rank[d] <- r; layers[[r + 1]] <- c(layers[[r + 1]], d); ch <- c(ch, d)
    }
    ch <- c(ch, v); chains[[as.character(k)]] <- ch
    la <- c(la, ch[-length(ch)]); lb <- c(lb, ch[-1])
  }
  # 5. ordering: barycentre sweeps, keep fewest crossings
  total_cross <- function(lys) {
    if (length(lys) < 2) return(0)
    s <- 0
    for (r in 0:(length(lys) - 2)) { sel <- rank[la] == r; s <- s + .fd_crossings(lys[[r + 1]], lys[[r + 2]], la[sel], lb[sel]) }
    s
  }
  pred <- split(la, factor(lb, levels = unique(lb))); sucs <- split(lb, factor(la, levels = unique(la)))
  best <- layers; best_c <- total_cross(best); cur <- layers
  for (it in 0:11) {
    rng <- if (it %% 2 == 0) { if (nl > 1) 1:(nl - 1) else integer(0) } else { if (nl > 1) (nl - 2):0 else integer(0) }
    for (r in rng) {
      ref <- if (it %% 2 == 0) cur[[r]] else cur[[r + 2]]
      nb <- if (it %% 2 == 0) pred else sucs
      L <- cur[[r + 1]]
      keys <- vapply(seq_along(L), function(i) {
        ps <- match(nb[[L[i]]] %||% character(0), ref) - 1; ps <- ps[!is.na(ps)]
        if (length(ps)) mean(ps) else i - 1
      }, 0)
      cur[[r + 1]] <- L[order(keys, method = "radix")]
    }
    cc <- total_cross(cur)
    if (cc < best_c) { best <- cur; best_c <- cc }
  }
  layers <- best
  grp <- function(v) if (isd(v)) NA_character_ else { g <- byid[[v]]$group; if (is.null(g)) NA_character_ else as.character(g) }
  for (r in seq_len(nl)) {
    L <- layers[[r]]; gs <- vapply(L, grp, "")
    if (any(!is.na(gs))) {
      first <- vapply(seq_along(L), function(i) if (is.na(gs[i])) i - 1 else min(which(gs == gs[i])) - 1, 0)
      layers[[r]] <- L[order(first, seq_along(L) - 1, method = "radix")]
    }
  }
  # 6. order-axis coordinates
  gap_d <- 8
  pos <- setNames(numeric(0), character(0))
  gapf <- function(a, b) {
    g <- if (!(isd(a) || isd(b))) node_gap else gap_d
    ga <- grp(a); gb <- grp(b)
    if (!is.na(ga) && !is.na(gb) && ga != gb) g <- g + 14
    g
  }
  for (r in seq_len(nl)) {
    p <- 0; L <- layers[[r]]
    for (i in seq_along(L)) { if (i > 1) p <- p + osz(L[i - 1]) / 2 + gapf(L[i - 1], L[i]) + osz(L[i]) / 2; pos[L[i]] <- p }
  }
  width_of <- function(r) { L <- layers[[r]]; (pos[L[length(L)]] + osz(L[length(L)]) / 2) - (pos[L[1]] - osz(L[1]) / 2) }
  widest <- max(vapply(seq_len(nl), width_of, 0))
  for (r in seq_len(nl)) {
    L <- layers[[r]]; off <- (widest - width_of(r)) / 2 - (pos[L[1]] - osz(L[1]) / 2)
    pos[L] <- pos[L] + off
  }
  place <- function(r, nbmap) {
    L <- layers[[r]]
    if (!length(L)) return(invisible())
    offs <- 0
    if (length(L) > 1) for (i in 2:length(L)) offs <- c(offs, offs[i - 1] + osz(L[i - 1]) / 2 + gapf(L[i - 1], L[i]) + osz(L[i]) / 2)
    desired <- numeric(length(L)); wts <- numeric(length(L))
    for (i in seq_along(L)) {
      ns <- pos[nbmap[[L[i]]] %||% character(0)]
      desired[i] <- (if (length(ns)) mean(ns) else pos[L[i]]) - offs[i]
      wts[i] <- length(ns) + (if (!length(ns)) 0.4 else 0) + (if (isd(L[i])) 2 else 0)
    }
    fit <- .fd_isotonic(desired, wts)
    pos[L] <<- fit + offs
  }
  for (rep_ in 1:6) {
    if (nl > 1) for (r in 2:nl) place(r, pred)
    if (nl > 1) for (r in (nl - 1):1) place(r, sucs)
  }
  allv <- unlist(layers)
  minp <- min(vapply(allv, function(v) pos[v] - osz(v) / 2, 0))
  pos <- pos - minp
  # 7. rank-axis coordinates
  has_labels <- any(vapply(E, function(e) !is.null(e$label) && nzchar(e$label), TRUE))
  if (is.null(rank_gap)) rank_gap <- if (has_labels) 40 else 30
  rstart <- numeric(nl); rext <- numeric(nl); acc <- 0
  for (r in seq_len(nl)) {
    ext <- max(c(vapply(layers[[r]], rsz, 0), 0))
    rstart[r] <- acc; rext[r] <- ext
    if (r < nl) {
      sel <- rank[la] == r - 1 & abs(pos[la] - pos[lb]) > 0.5
      acc <- acc + ext + rank_gap + max(0, length(unique(la[sel])) - 2) * 5
    }
  }
  list(direction = direction, nodes = nodes, byid = byid, E = E, back = sort(back), fwd = fwd,
       chains = chains, rank = rank, layers = layers, pos = pos, info = info, rstart = rstart,
       rext = rext, osz = osz, rsz = rsz, isd = isd)
}

.fd_render_layered <- function(spec, cv, origin = c(0, 0), dag_roles = FALSE) {
  L <- .fd_layout(spec, max_w = spec$max_width, rank_gap = spec$rank_gap, node_gap = spec$node_gap %||% 18)
  tb <- L$direction == "TB"; ox <- origin[1]; oy <- origin[2]
  rank <- L$rank; pos <- L$pos; info <- L$info; rstart <- L$rstart; rext <- L$rext
  RS <- function(v) rstart[rank[v] + 1]; RE <- function(v) rext[rank[v] + 1]
  xy <- function(o, r) if (tb) c(ox + o, oy + r) else c(ox + r, oy + o)
  boxes <- list()
  for (v in names(L$byid)) {
    rs <- RS(v) + (RE(v) - L$rsz(v)) / 2
    boxes[[v]] <- if (tb) c(ox + pos[[v]] - info[[v]]$w / 2, oy + rs, info[[v]]$w, info[[v]]$h) else
      c(ox + rs, oy + pos[[v]] - info[[v]]$h / 2, info[[v]]$w, info[[v]]$h)
  }
  # groups
  gnames <- unique(unlist(lapply(L$nodes, function(n) if (!is.null(n$group)) as.character(n$group))))
  groups <- lapply(setNames(gnames, gnames), function(g)
    names(L$byid)[vapply(L$nodes, function(n) identical(as.character(n$group %||% NA), g), TRUE)])
  for (g in names(groups)) {
    m <- groups[[g]]; bx <- do.call(rbind, boxes[m])
    x0 <- min(bx[, 1]) - 8; y0 <- min(bx[, 2]) - (if (tb) 8 else 17)
    x1 <- max(bx[, 1] + bx[, 3]) + 8; y1 <- max(bx[, 2] + bx[, 4]) + (if (tb) 17 else 8)
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="none" stroke="%s" stroke-width="0.6" stroke-dasharray="2,2"%s/>',
                        .fd_f(x0), .fd_f(y0), .fd_f(x1 - x0), .fd_f(y1 - y0), FD$MUTED, .fd_box_meta("group", g, x0, y0, x1 - x0, y1 - y0)))
    lw <- fd_text_width(g, FD$SIZE_SMALL, "italic"); ly <- if (tb) y1 - 4 - FD$SIZE_SMALL else y0 + 3.5
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" fill="none"%s/>', .fd_f(x0 + 4), .fd_f(ly - 0.5),
                        .fd_f(lw + 2), .fd_f(FD$SIZE_SMALL + 1), .fd_box_meta("label", paste0("group:", g), x0 + 5, ly, lw, FD$SIZE_SMALL)))
    .fd_text_block(cv, g, x0 + 5, ly, size = FD$SIZE_SMALL, style = "italic", colour = FD$TEXT_MUTED, anchor = "start")
  }
  E <- L$E
  # tracks
  track <- list()
  if (length(L$layers) > 1) for (r in 0:(length(L$layers) - 2)) {
    srcs <- character(0)
    for (k in L$fwd) { ch <- L$chains[[as.character(k)]]
      for (i in seq_len(length(ch) - 1)) { a <- ch[i]; b <- ch[i + 1]
        if (rank[a] == r && abs(pos[a] - pos[b]) > 0.5 && !a %in% srcs) srcs <- c(srcs, a) } }
    srcs <- srcs[order(pos[srcs], method = "radix")]
    for (i in seq_along(srcs)) track[[paste(r, srcs[i])]] <- c(i - 1, length(srcs))
  }
  jobs <- list()
  curved <- dag_roles || identical(spec$edge_style, "curved")
  side_of <- function(ch) if (pos[ch[length(ch)]] < pos[ch[1]] - 0.5) -1 else 1
  for (k in L$fwd) {
    e <- E[[k]]; ch <- L$chains[[as.character(k)]]
    hi <- .fd_true(e$focal) || (dag_roles && .fd_true(e$`_causal`))
    colour <- if (hi) FD$ACCENT else if (.fd_true(e$muted)) FD$MUTED else FD$INK
    ident <- paste0(e$from, "->", e$to)
    if (curved) {
      cen <- t(vapply(ch, function(v) c(pos[[v]], RS(v) + RE(v) / 2), c(0, 0)))
      a <- ch[1]; b <- ch[length(ch)]; n <- nrow(cen)
      pa <- (L$byid[[a]]$kind %||% "") %in% c("plain", "note"); pb <- (L$byid[[b]]$kind %||% "") %in% c("plain", "note")
      s <- .fd_clip(cen[1, 1], cen[1, 2], L$osz(a) / 2, L$rsz(a) / 2, cen[2, 1], cen[2, 2], if (pa) 3 else 0.5)
      t_ <- .fd_clip(cen[n, 1], cen[n, 2], L$osz(b) / 2, L$rsz(b) / 2, cen[n - 1, 1], cen[n - 1, 2], if (pb) 3 else 0.6)
      ap <- rbind(s, if (n > 2) cen[2:(n - 1), , drop = FALSE], t_)
      cp <- t(apply(ap, 1, function(p) xy(p[1], p[2])))
      .fd_add(cv, .fd_curve(cp, colour, if (hi) FD$STROKE_FOCAL else FD$STROKE, .fd_true(e$dashed), ident))
      if (!is.null(e$label)) { m <- nrow(ap)
        jobs[[length(jobs) + 1]] <- list(e$label, (ap[m - 1, 1] + ap[m, 1]) / 2, (ap[m - 1, 2] + ap[m, 2]) / 2, ident, side_of(ch)) }
      next
    }
    pts <- NULL
    for (i in seq_len(length(ch) - 1)) {
      a <- ch[i]; b <- ch[i + 1]; ra <- rank[a] + 1
      a_end <- if (!L$isd(a)) rstart[ra] + (rext[ra] + L$rsz(a)) / 2 else rstart[ra] + rext[ra]
      b_beg <- if (!L$isd(b)) RS(b) + (RE(b) - L$rsz(b)) / 2 else RS(b)
      gap0 <- rstart[ra] + rext[ra]; gap1 <- RS(b)
      if (i == 1) pts <- rbind(pts, c(pos[a], a_end)) else pts <- rbind(pts, c(pos[a], rstart[ra]), c(pos[a], gap0))
      if (abs(pos[a] - pos[b]) > 0.5) {
        tt <- track[[paste(rank[a], a)]] %||% c(0, 1)
        rm <- gap0 + (gap1 - gap0) * (tt[1] + 1) / (tt[2] + 1)
        pts <- rbind(pts, c(pos[a], rm), c(pos[b], rm))
      }
      pts <- rbind(pts, c(pos[b], b_beg))
    }
    clean <- pts[1, , drop = FALSE]
    if (nrow(pts) > 1) for (i in 2:nrow(pts))
      if (abs(pts[i, 1] - clean[nrow(clean), 1]) > 0.01 || abs(pts[i, 2] - clean[nrow(clean), 2]) > 0.01) clean <- rbind(clean, pts[i, ])
    cp <- .fd_shorten(t(apply(clean, 1, function(p) xy(p[1], p[2]))), 0.6)
    .fd_add(cv, .fd_poly(cp, colour, if (hi) FD$STROKE_FOCAL else FD$STROKE, .fd_true(e$dashed), ident = ident))
    if (!is.null(e$label)) { m <- nrow(clean)
      jobs[[length(jobs) + 1]] <- list(e$label, (clean[m - 1, 1] + clean[m, 1]) / 2, (clean[m - 1, 2] + clean[m, 2]) / 2, ident, side_of(ch)) }
  }
  extent_o <- max(vapply(names(pos), function(v) pos[[v]] + L$osz(v) / 2, 0))
  for (j in seq_along(L$back)) {
    e <- E[[L$back[j]]]; u <- e$from; v <- e$to
    lane <- extent_o + 14 + 9 * (j - 1)
    ru <- RS(u) + RE(u) / 2; rv <- RS(v) + RE(v) / 2
    p <- rbind(c(pos[[u]] + L$osz(u) / 2, ru), c(lane, ru), c(lane, rv), c(pos[[v]] + L$osz(v) / 2, rv))
    cp <- .fd_shorten(t(apply(p, 1, function(q) xy(q[1], q[2]))), 0.6)
    .fd_add(cv, .fd_poly(cp, if (.fd_true(e$focal)) FD$ACCENT else FD$MUTED, dashed = if (is.null(e$dashed)) TRUE else .fd_true(e$dashed),
                         ident = paste0(u, "->", v)))
    if (!is.null(e$label)) jobs[[length(jobs) + 1]] <- list(e$label, lane, (ru + rv) / 2, paste0(u, "->", v), 1)
  }
  for (v in names(L$byid)) { b <- boxes[[v]]; .fd_draw_node(cv, L$byid[[v]], b[1], b[2], b[3], b[4], info[[v]]$lines) }
  for (jb in jobs) {
    text <- jb[[1]]; o <- jb[[2]]; r <- jb[[3]]; side <- jb[[5]]
    tw <- fd_text_width(text, FD$SIZE_SMALL, "italic"); th <- FD$SIZE_SMALL * 1.05
    if (tb) { x <- if (side > 0) ox + o + 4 else ox + o - 4 - tw; y <- oy + r - th / 2 }
    else { x <- ox + r - tw / 2; y <- if (side > 0) oy + o + 3 else oy + o - 3 - th }
    .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"%s/>', .fd_f(x - 1.5), .fd_f(y - 0.5),
                        .fd_f(tw + 3), .fd_f(th + 1), FD$PAPER, .fd_box_meta("label", jb[[4]], x, y, tw, th)))
    .fd_text_block(cv, text, x, y, size = FD$SIZE_SMALL, style = "italic", colour = FD$TEXT_MUTED, anchor = "start")
  }
  if (any(vapply(E, function(e) .fd_true(e$focal) || (dag_roles && .fd_true(e$`_causal`)), TRUE))) cv$accent <- cv$accent + 1
  bx <- do.call(rbind, boxes)
  max_x <- max(bx[, 1] + bx[, 3]); max_y <- max(bx[, 2] + bx[, 4])
  for (g in names(groups)) { b <- do.call(rbind, boxes[groups[[g]]])
    max_x <- max(max_x, max(b[, 1] + b[, 3]) + 8); max_y <- max(max_y, max(b[, 2] + b[, 4]) + (if (tb) 17 else 8)) }
  if (length(L$back)) { lm <- extent_o + 14 + 9 * (length(L$back) - 1) + 4
    if (tb) max_x <- max(max_x, ox + lm) else max_y <- max(max_y, oy + lm) }
  for (jb in jobs) { tw <- fd_text_width(jb[[1]], FD$SIZE_SMALL, "italic")
    if (tb) max_x <- max(max_x, ox + jb[[2]] + 4 + tw + 2) else max_y <- max(max_y, oy + jb[[2]] + 3 + FD$SIZE_SMALL * 1.1) }
  c(max_x, max_y)
}

.fd_finish <- function(cv, spec, w, h, notes) {
  svg <- .fd_svg(cv, w, h, title = spec$alt %||% spec$title, desc = spec$desc)
  if (cv$accent > FD$MAX_ACCENTS)
    notes <- c(notes, sprintf("Accent used on %d elements: keep it to %d focal elements so it still signals.", cv$accent, FD$MAX_ACCENTS))
  list(svg = svg, findings = notes)
}

.fd_title <- function(cv, spec, y, width = FD$COLUMN_PT) {
  if (is.null(spec$title)) return(y)
  lines <- fd_wrap(spec$title, width - 2 * FD$M, FD$SIZE_TITLE)
  .fd_add(cv, '<g data-fd="title">')
  h <- .fd_text_block(cv, lines, FD$M, y, size = FD$SIZE_TITLE, anchor = "start")
  .fd_add(cv, "</g>")
  y + h + 8
}

# ---- flow --------------------------------------------------------------------
.fd_render_flow <- function(spec) {
  notes <- character(0); cv <- .fd_canvas(); M <- FD$M
  top <- .fd_title(cv, spec, M)
  if (length(spec$nodes) > 12) notes <- c(notes, sprintf("%d nodes: above about 9 to 12 a diagram usually reads better as two.", length(spec$nodes)))
  grouped <- any(vapply(spec$nodes, function(n) !is.null(n$group), TRUE))
  lr <- toupper(spec$direction %||% "TB") == "LR"
  g <- if (grouped) c(8, if (lr) 18 else 9) else c(0, 0)
  mx <- .fd_render_layered(spec, cv, origin = c(M + g[1], top + g[2]))
  w <- mx[1] + M; h <- mx[2] + M
  if (w > FD$COLUMN_PT * 1.15)
    notes <- c(notes, sprintf("Figure is %.0f pt wide (column is %.0f pt): use direction 'TB', shorter labels, or keep it for slides only.", w, FD$COLUMN_PT))
  .fd_finish(cv, spec, w, h, notes)
}

# ---- dag ---------------------------------------------------------------------
.fd_ROLES <- c("exposure", "outcome", "confounder", "mediator", "collider", "instrument", "precision", "unmeasured", "other")

.fd_graph <- function(spec) {
  ids <- vapply(spec$nodes, function(n) as.character(n$id), "")
  ef <- vapply(spec$edges, function(e) as.character(e$from), ""); et <- vapply(spec$edges, function(e) as.character(e$to), "")
  for (i in seq_along(ef)) if (!ef[i] %in% ids || !et[i] %in% ids) .fd_stop("edge ", ef[i], " -> ", et[i], " references an unknown node")
  list(ids = ids, parents = lapply(setNames(ids, ids), function(v) ef[et == v]),
       children = lapply(setNames(ids, ids), function(v) et[ef == v]))
}
.fd_reach <- function(start, nbr) { out <- character(0); todo <- start
  while (length(todo)) { u <- todo[1]; todo <- todo[-1]
    for (v in nbr[[u]]) if (!v %in% out) { out <- c(out, v); todo <- c(todo, v) } }
  out }
.fd_role <- function(spec, r) vapply(Filter(function(n) identical(n$role, r), spec$nodes), function(n) as.character(n$id), "")

.fd_dsep <- function(parents, xs, ys, zs) {
  keep <- unique(c(xs, ys, zs)); todo <- keep
  while (length(todo)) { u <- todo[1]; todo <- todo[-1]
    for (p in parents[[u]]) if (!p %in% keep) { keep <- c(keep, p); todo <- c(todo, p) } }
  adj <- setNames(replicate(length(keep), character(0), simplify = FALSE), keep)
  for (v in keep) { ps <- intersect(parents[[v]], keep)
    for (p in ps) { adj[[v]] <- union(adj[[v]], p); adj[[p]] <- union(adj[[p]], v) }
    if (length(ps) > 1) for (i in 1:(length(ps) - 1)) for (j in (i + 1):length(ps)) {
      adj[[ps[i]]] <- union(adj[[ps[i]]], ps[j]); adj[[ps[j]]] <- union(adj[[ps[j]]], ps[i]) } }
  seen <- xs; todo <- xs
  while (length(todo)) { u <- todo[1]; todo <- todo[-1]
    for (v in adj[[u]]) { if (v %in% zs || v %in% seen) next
      if (v %in% ys) return(FALSE)
      seen <- c(seen, v); todo <- c(todo, v) } }
  TRUE
}

# Backdoor criterion for an adjustment set (character vector of node ids).
fd_backdoor_ok <- function(spec, adjusted) {
  G <- .fd_graph(spec); x <- .fd_role(spec, "exposure"); y <- .fd_role(spec, "outcome")
  desc <- .fd_reach(x, G$children)
  if (any(adjusted %in% c(desc, x, y))) return(FALSE)
  cut <- lapply(G$parents, function(p) setdiff(p, x))
  .fd_dsep(cut, x, y, adjusted)
}

# All minimal sufficient adjustment sets of measured variables, smallest first.
fd_adjustment_sets <- function(spec, limit = 18) {
  spec <- fd_normalise(spec)
  G <- .fd_graph(spec); x <- .fd_role(spec, "exposure"); y <- .fd_role(spec, "outcome")
  if (length(x) != 1 || length(y) != 1) .fd_stop("a causal DAG needs exactly one node with role 'exposure' and one with role 'outcome'")
  desc <- .fd_reach(x, G$children)
  unm <- .fd_role(spec, "unmeasured")
  cand <- setdiff(G$ids, c(x, y, desc, unm))
  if (length(cand) > limit) return(NULL)
  found <- list()
  for (k in 0:length(cand)) {
    combos <- if (k == 0) list(character(0)) else if (length(cand) == k) list(cand) else
      lapply(seq_len(choose(length(cand), k)), function(i) NULL)
    if (k > 0 && length(cand) > k) { cm <- utils::combn(cand, k); combos <- lapply(seq_len(ncol(cm)), function(i) cm[, i]) }
    for (s in combos) {
      if (any(vapply(found, function(f) all(f %in% s), TRUE))) next
      if (fd_backdoor_ok(spec, s)) found[[length(found) + 1]] <- s
    }
  }
  found
}

# The DAG as a dagitty model. object = TRUE returns a dagitty object (needs the dagitty package).
fd_dagitty <- function(spec, object = FALSE) {
  spec <- fd_normalise(spec)
  nm <- function(i) { s <- gsub("[^A-Za-z0-9_.]", "_", as.character(i)); if (grepl("^[A-Za-z_]", s)) s else paste0("v_", s) }
  out <- "dag {"
  for (n in spec$nodes) {
    tags <- c(if (identical(n$role, "exposure")) "exposure", if (identical(n$role, "outcome")) "outcome",
              if (identical(n$role, "unmeasured")) "latent", if (.fd_true(n$adjusted)) "adjusted")
    out <- c(out, paste0("  ", nm(n$id), if (length(tags)) paste0(" [", paste(tags, collapse = ","), "]") else ""))
  }
  for (e in spec$edges) out <- c(out, sprintf("  %s -> %s", nm(e$from), nm(e$to)))
  txt <- paste(c(out, "}"), collapse = "\n")
  if (!object) return(txt)
  if (!requireNamespace("dagitty", quietly = TRUE)) stop("Install dagitty for object = TRUE")
  dagitty::dagitty(txt)
}

.fd_dag_checks <- function(spec) {
  G <- .fd_graph(spec)
  state <- setNames(integer(length(G$ids)), G$ids)
  dfs <- function(u, stack) {
    state[u] <<- 1L
    for (v in G$children[[u]]) {
      if (state[v] == 1L) .fd_stop("causal DAG has a cycle: ", paste(c(stack, u, v), collapse = " -> "))
      if (state[v] == 0L) dfs(v, c(stack, u))
    }
    state[u] <<- 2L
  }
  for (i in G$ids) if (state[i] == 0L) dfs(i, character(0))
  x <- .fd_role(spec, "exposure"); y <- .fd_role(spec, "outcome")
  if (length(x) != 1 || length(y) != 1) .fd_stop("a causal DAG needs exactly one node with role 'exposure' and one with role 'outcome'")
  notes <- character(0)
  dx <- .fd_reach(x, G$children)
  if (!y %in% dx) notes <- c(notes, sprintf("No directed path from %s to %s: the diagram assumes no causal effect. Check that this is intended.", x, y))
  anc <- union(.fd_reach(x, G$parents), .fd_reach(y, G$parents))
  for (n in spec$nodes) {
    i <- as.character(n$id); role <- n$role
    if (!is.null(role) && !role %in% .fd_ROLES) .fd_stop("node ", i, ": role must be one of ", paste(sort(.fd_ROLES), collapse = ", "))
    adj <- .fd_true(n$adjusted)
    if (adj && i %in% dx) notes <- c(notes, sprintf("%s is adjusted for but is a descendant of the exposure %s (mediator or collider path): this can block the effect or induce bias.", i, x))
    if (adj && length(G$parents[[i]]) >= 2 && !i %in% dx && !i %in% anc)
      notes <- c(notes, sprintf("%s is adjusted for and is a collider that is not an ancestor of %s or %s: conditioning on it can open a non-causal path (M-bias).", i, x, y))
    if (adj && identical(role, "instrument")) notes <- c(notes, sprintf("%s is an instrument: adjusting for it can amplify bias and reduces precision.", i))
    if (identical(role, "unmeasured") && adj) .fd_stop(i, " is marked unmeasured, so it cannot be adjusted for")
  }
  adjset <- vapply(Filter(function(n) .fd_true(n$adjusted), spec$nodes), function(n) as.character(n$id), "")
  sets <- fd_adjustment_sets(spec)
  fmt <- function(s) if (length(s)) paste0("{", paste(s, collapse = ", "), "}") else "{} (no adjustment needed)"
  if (!is.null(sets)) {
    if (!length(sets)) notes <- c(notes, sprintf("No set of measured variables closes every backdoor path from %s to %s: the effect is not identified by adjustment (unmeasured confounding).", x, y))
    else if (!fd_backdoor_ok(spec, adjset))
      notes <- c(notes, paste0("The adjusted set ", fmt(adjset), " does not satisfy the backdoor criterion. Minimal sufficient sets: ",
                               paste(vapply(utils::head(sets, 4), fmt, ""), collapse = "; "), "."))
  }
  notes
}

.fd_render_dag <- function(spec) {
  notes <- .fd_dag_checks(spec)
  spec$direction <- spec$direction %||% "LR"
  x <- .fd_role(spec, "exposure"); y <- .fd_role(spec, "outcome")
  for (i in seq_along(spec$nodes)) {
    n <- spec$nodes[[i]]; role <- n$role %||% "other"
    if (is.null(n$kind)) n$kind <- if (.fd_true(n$adjusted)) "process" else "plain"
    if (role %in% c("exposure", "outcome")) n$bold <- TRUE
    if (role == "outcome") { n$focal <- TRUE; if (n$kind == "plain") n$kind <- "process" }
    if (role == "unmeasured") n$muted <- TRUE
    spec$nodes[[i]] <- n
  }
  unm <- .fd_role(spec, "unmeasured")
  for (i in seq_along(spec$edges)) {
    e <- spec$edges[[i]]
    if (e$from %in% unm) { e$dashed <- TRUE; e$muted <- TRUE }
    if (e$from == x && e$to == y) e$`_causal` <- TRUE
    spec$edges[[i]] <- e
  }
  spec$rank_gap <- spec$rank_gap %||% 44; spec$node_gap <- spec$node_gap %||% 22
  cv <- .fd_canvas(); M <- FD$M
  top <- .fd_title(cv, spec, M)
  mx <- .fd_render_layered(spec, cv, origin = c(M, top), dag_roles = TRUE)
  adj <- vapply(Filter(function(n) .fd_true(n$adjusted), spec$nodes), function(n) as.character(n$label %||% n$id), "")
  key <- paste0("Boxed: adjusted for", if (length(adj)) paste0(" (", paste(adj, collapse = ", "), ")") else " (none)",
                ". Dashed: unmeasured. Blue: outcome and the effect of interest.")
  lines <- fd_wrap(key, max(mx[1] - M, 220), FD$SIZE_SMALL)
  .fd_text_block(cv, lines, M, mx[2] + 10, size = FD$SIZE_SMALL, colour = FD$TEXT_MUTED, anchor = "start")
  h <- mx[2] + 10 + length(lines) * FD$SIZE_SMALL * 1.22 + M
  w <- max(mx[1], M + max(vapply(lines, fd_text_width, 0, size = FD$SIZE_SMALL))) + M
  .fd_finish(cv, spec, w, h, notes)
}

# ---- participant flow helpers --------------------------------------------------
.fd_count <- function(v, where) {
  if (is.null(v) || is.logical(v) || !is.numeric(v) || length(v) != 1 || is.na(v) || v < 0 || v != round(v))
    .fd_stop(where, ": count must be a non-negative whole number, got ", format(v))
  as.numeric(v)
}
.fd_pairs <- function(x) {
  if (is.null(x) || !length(x)) return(list())
  if (is.list(x) && length(x) == 2 && is.character(x[[1]]) && length(x[[1]]) == 1 && !is.list(x[[2]])) return(list(x))
  x
}
.fd_sum <- function(items, where) {
  tot <- 0
  for (it in .fd_pairs(items)) {
    if (!(length(it) == 2)) .fd_stop(where, ": reasons must be [label, n] pairs")
    tot <- tot + .fd_count(it[[2]], paste0(where, " '", it[[1]], "'"))
  }
  tot
}
.fd_sub <- function(text, wrap_w, level = 1) {
  if (level == 2) return(paste0("\t\t", fd_wrap(text, wrap_w - 24, FD$SIZE_SMALL)))
  p <- fd_wrap(text, wrap_w - 10, FD$SIZE_SMALL)
  paste0(c(paste0(.fd_DOT, " "), rep("\t", length(p) - 1)), p)
}
.fd_reason_lines <- function(head, items, wrap_w) {
  out <- fd_wrap(head, wrap_w, FD$SIZE_LABEL)
  for (it in .fd_pairs(items)) out <- c(out, .fd_sub(paste(it[[1]], .fd_cnt(it[[2]])), wrap_w))
  out
}
.fd_is_small <- function(ln) startsWith(ln, paste0(.fd_DOT, " ")) | startsWith(ln, "\t")
.fd_indent <- function(ln) {
  b <- fd_text_width(paste0(.fd_DOT, " "), FD$SIZE_SMALL)
  if (startsWith(ln, "\t\t")) return(list(2 + b + 8, substring(ln, 3)))
  if (startsWith(ln, "\t")) return(list(2 + b, substring(ln, 2)))
  if (startsWith(ln, paste0(.fd_DOT, " "))) return(list(2, ln))
  list(0, ln)
}
.fd_box_height <- function(lines) sum(ifelse(.fd_is_small(lines), FD$SIZE_SMALL, FD$SIZE_LABEL) * 1.22) - FD$SIZE_LABEL * 0.22 + 12
.fd_flow_box <- function(cv, ident, x, y, w, lines, focal = FALSE, align = "start", min_h = 0) {
  pad <- 6
  hs <- ifelse(.fd_is_small(lines), FD$SIZE_SMALL, FD$SIZE_LABEL) * 1.22
  h <- max(sum(hs) - FD$SIZE_LABEL * 0.22 + 2 * pad, min_h)
  if (focal) cv$accent <- cv$accent + 1
  .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="%s" stroke="%s" stroke-width="%s"%s/>',
                      .fd_f(x), .fd_f(y), .fd_f(w), .fd_f(h), FD$PAPER, if (focal) FD$ACCENT else FD$INK,
                      .fd_f(if (focal) FD$STROKE_FOCAL else FD$STROKE), .fd_box_meta("node", ident, x, y, w, h)))
  cy <- y + pad
  for (i in seq_along(lines)) {
    sm <- .fd_is_small(lines[i]); id <- .fd_indent(lines[i])
    tx <- if (align == "start") x + pad + id[[1]] else x + w / 2
    .fd_text_block(cv, id[[2]], tx, cy, size = if (sm) FD$SIZE_SMALL else FD$SIZE_LABEL,
                   colour = if (sm) FD$TEXT_MUTED else FD$INK, anchor = align, maxw = w - 2 * pad - id[[1]])
    cy <- cy + hs[i]
  }
  h
}
.fd_stage <- function(cv, text, y) .fd_text_block(cv, text, FD$M, y + 2, size = FD$SIZE_SMALL, style = "italic",
                                                   colour = FD$TEXT_MUTED, anchor = "start")
.fd_arrow <- function(cv, x1, y1, x2, y2, arrow = TRUE, ident = "") .fd_add(cv, .fd_poly(rbind(c(x1, y1), c(x2, y2)), arrow = arrow, ident = ident))
.fd_small_note <- function(small, clinical) if (length(small) && !identical(clinical, FALSE))
  paste0("Counts below 11 (", paste(small, collapse = "; "), "): check small-cell suppression rules before sharing.") else character(0)

# ---- consort -------------------------------------------------------------------
.fd_consort_checks <- function(spec) {
  for (k in c("assessed", "randomized", "arms")) if (is.null(spec[[k]])) .fd_stop("CONSORT spec needs '", k, "'")
  a <- .fd_count(spec$assessed, "assessed"); r <- .fd_count(spec$randomized, "randomized")
  ex <- spec$excluded %||% list(); ext <- ex$total %||% (a - r)
  if (a - ext != r) .fd_stop(sprintf("assessed (%s) minus excluded (%s) = %s, but randomized = %s", a, ext, a - ext, r))
  rs <- .fd_sum(ex$reasons, "excluded")
  if (length(ex$reasons) && rs != ext) .fd_stop(sprintf("exclusion reasons sum to %s, but excluded total is %s", rs, ext))
  alloc <- sum(vapply(spec$arms, function(x) .fd_count(x$allocated, "allocated"), 0))
  if (alloc != r) .fd_stop(sprintf("arms are allocated %s in total, but randomized = %s", alloc, r))
  notes <- character(0); small <- character(0)
  for (arm in spec$arms) {
    nm <- arm$name %||% "?"; al <- arm$allocated
    if (!is.null(arm$received)) { nr <- .fd_sum(arm$not_received, paste(nm, "not_received"))
      if (arm$received + nr != al) .fd_stop(sprintf("%s: received (%s) + did not receive (%s) != allocated (%s)", nm, arm$received, nr, al)) }
    lost <- .fd_sum(arm$lost, paste(nm, "lost")); disc <- .fd_sum(arm$discontinued, paste(nm, "discontinued"))
    if (lost + disc > al) .fd_stop(sprintf("%s: lost (%s) + discontinued (%s) exceed allocated (%s)", nm, lost, disc, al))
    exa <- .fd_sum(arm$excluded_analysis, paste(nm, "excluded_analysis"))
    if (is.null(arm$analysed)) .fd_stop(nm, ": 'analysed' count is required")
    if (arm$analysed + exa != al) .fd_stop(sprintf("%s: analysed (%s) + excluded from analysis (%s) != allocated (%s)", nm, arm$analysed, exa, al))
    if (arm$analysed < al - lost - disc - exa && !.fd_true(arm$imputed))
      notes <- c(notes, sprintf("%s: analysed is below allocated minus losses; state how missing outcomes were handled.", nm))
    for (k in c("allocated", "received", "analysed")) if (!is.null(arm[[k]]) && arm[[k]] > 0 && arm[[k]] < 11)
      small <- c(small, sprintf("%s %s = %s", nm, k, arm[[k]]))
  }
  c(notes, .fd_small_note(small, spec$clinical))
}

.fd_render_consort <- function(spec) {
  notes <- .fd_consort_checks(spec); cv <- .fd_canvas(); M <- FD$M
  arms <- spec$arms; k <- length(arms)
  col_w <- spec$box_width %||% (if (k <= 2) 140 else 118); gutter <- 16; left <- M + 52
  total_w <- k * col_w + (k - 1) * gutter; side_w <- spec$side_width %||% 150
  width <- max(left + total_w + M, left + total_w / 2 + col_w / 2 + 24 + side_w + M)
  if (width > FD$COLUMN_PT + 1) notes <- c(notes, sprintf("Figure is %.0f pt wide, wider than a %.0f pt column: shorten labels or set box_width.", width, FD$COLUMN_PT))
  cx <- left + total_w / 2
  y <- .fd_title(cv, spec, M, width)
  ex <- spec$excluded %||% list(); ext <- ex$total %||% (spec$assessed - spec$randomized)
  .fd_stage(cv, "Enrollment", y + 4)
  l1 <- fd_wrap(paste("Assessed for eligibility", .fd_cnt(spec$assessed)), col_w - 12); h1 <- .fd_box_height(l1)
  b1x <- cx - col_w / 2
  .fd_flow_box(cv, "assessed", b1x, y, col_w, l1, align = "middle")
  y_ex <- y + h1 + 14
  lex <- .fd_reason_lines(paste("Excluded", .fd_cnt(ext)), ex$reasons, side_w - 12); hx <- .fd_box_height(lex)
  sx <- cx + col_w / 2 + 24; y_r <- y_ex + hx + 14
  lr <- fd_wrap(paste("Randomized", .fd_cnt(spec$randomized)), col_w - 12); hr <- .fd_box_height(lr)
  .fd_flow_box(cv, "excluded", sx, y_ex, side_w, lex)
  .fd_arrow(cv, cx, y + h1, cx, y_r, ident = "assessed->randomized")
  .fd_arrow(cv, cx, y_ex + hx / 2, sx - 0.6, y_ex + hx / 2, ident = "assessed->excluded")
  .fd_flow_box(cv, "randomized", b1x, y_r, col_w, lr, align = "middle")
  y <- y_r + hr
  colx <- function(i) left + i * (col_w + gutter)
  sumr <- function(x) sum(vapply(.fd_pairs(x), function(p) as.numeric(p[[2]]), 0))
  alloc <- lapply(arms, function(arm) {
    ln <- fd_wrap(paste0("Allocated to ", arm$name %||% "arm", " ", .fd_cnt(arm$allocated)), col_w - 12)
    if (!is.null(arm$received)) {
      ln <- c(ln, .fd_sub(paste("Received allocated intervention", .fd_cnt(arm$received)), col_w - 12))
      nr <- .fd_pairs(arm$not_received)
      ln <- c(ln, .fd_sub(paste("Did not receive allocated intervention", .fd_cnt(sumr(nr))), col_w - 12))
      for (p in nr) ln <- c(ln, .fd_sub(paste(p[[1]], .fd_cnt(p[[2]])), col_w - 12, level = 2))
    }
    ln })
  fu <- lapply(arms, function(arm) c(.fd_reason_lines(paste("Lost to follow-up", .fd_cnt(sumr(arm$lost))), arm$lost, col_w - 12),
                                     .fd_reason_lines(paste("Discontinued intervention", .fd_cnt(sumr(arm$discontinued))), arm$discontinued, col_w - 12)))
  an <- lapply(arms, function(arm) c(fd_wrap(paste("Analysed", .fd_cnt(arm$analysed)), col_w - 12),
                                     .fd_reason_lines(paste("Excluded from analysis", .fd_cnt(sumr(arm$excluded_analysis))), arm$excluded_analysis, col_w - 12)))
  rows <- list(Allocation = alloc, `Follow-up` = fu, Analysis = an)
  y <- y + 26; bus_y <- y - 13
  .fd_arrow(cv, cx, y - 26, cx, bus_y, arrow = FALSE, ident = "randomized->bus")
  if (k > 1) .fd_arrow(cv, colx(0) + col_w / 2, bus_y, colx(k - 1) + col_w / 2, bus_y, arrow = FALSE, ident = "bus")
  prev_y <- bus_y
  for (ri in seq_along(rows)) {
    stage <- names(rows)[ri]; rws <- rows[[ri]]
    rh <- max(vapply(rws, .fd_box_height, 0))
    .fd_stage(cv, stage, y + 4)
    for (i in seq_along(rws)) {
      bx <- colx(i - 1)
      .fd_arrow(cv, bx + col_w / 2, prev_y, bx + col_w / 2, y - 0.6, ident = paste0(stage, "-", i - 1, "-in"))
      .fd_flow_box(cv, paste0(stage, "-", i - 1), bx, y, col_w, rws[[i]], min_h = rh,
                   focal = !is.null(spec$focal_arm) && identical(spec$focal_arm, arms[[i]]$name) && ri == 3)
    }
    prev_y <- y + rh; y <- y + rh + 22
  }
  .fd_finish(cv, spec, width, y - 22 + M, notes)
}

# ---- cohort --------------------------------------------------------------------
.fd_cohort_checks <- function(spec) {
  if (is.null(spec$start) || is.null(spec$steps)) .fd_stop("cohort spec needs 'start' {label, n} and 'steps' [...]")
  n <- .fd_count(spec$start$n, "start n"); small <- character(0)
  for (i in seq_along(spec$steps)) {
    st <- spec$steps[[i]]; exc <- .fd_count(st$excluded %||% 0, sprintf("step %d excluded", i))
    rs <- .fd_sum(st$reasons, sprintf("step %d", i))
    if (length(st$reasons) && rs != exc) .fd_stop(sprintf("step %d ('%s'): reasons sum to %s, but excluded = %s", i, st$label %||% "", rs, exc))
    if (exc > n) .fd_stop(sprintf("step %d: excludes %s from only %s", i, exc, n))
    nn <- n - exc
    if (!is.null(st$n) && st$n != nn) .fd_stop(sprintf("step %d ('%s'): %s - %s = %s, but n = %s", i, st$label %||% "", n, exc, nn, st$n))
    n <- nn
    if (n > 0 && n < 11) small <- c(small, sprintf("after step %d: %s", i, n))
  }
  if (length(spec$groups)) {
    gs <- sum(vapply(spec$groups, function(g) .fd_count(g$n, "group n"), 0))
    if (gs != n) .fd_stop(sprintf("groups sum to %s, but the final cohort is %s", gs, n))
    for (g in spec$groups) if (g$n > 0 && g$n < 11) small <- c(small, sprintf("%s: %s", g$label, g$n))
  }
  .fd_small_note(small, spec$clinical)
}

.fd_render_cohort <- function(spec) {
  notes <- .fd_cohort_checks(spec); cv <- .fd_canvas(); M <- FD$M
  col_w <- spec$box_width %||% 160; side_w <- spec$side_width %||% 170
  groups <- spec$groups %||% list(); g_w <- spec$group_width %||% 120; g_gap <- 14
  gw_total <- length(groups) * g_w + max(0, length(groups) - 1) * g_gap
  cx <- M + max(col_w, gw_total) / 2
  width <- max(cx + col_w / 2 + 24 + side_w + M, M + gw_total + M)
  y <- .fd_title(cv, spec, M, width)
  n <- spec$start$n
  h <- .fd_flow_box(cv, "start", cx - col_w / 2, y, col_w,
                    fd_wrap(paste(spec$start$label %||% "Source population", .fd_cnt(n)), col_w - 12), align = "middle")
  y_prev <- y + h; y <- y + h
  for (i in seq_along(spec$steps)) {
    st <- spec$steps[[i]]; exc <- st$excluded %||% 0; n <- n - exc
    lex <- .fd_reason_lines(paste(st$exclusion_label %||% "Excluded", .fd_cnt(exc)), st$reasons, side_w - 12)
    hx <- .fd_box_height(lex); yex <- y + 14; sx <- cx + col_w / 2 + 24
    .fd_flow_box(cv, paste0("excl", i), sx, yex, side_w, lex)
    .fd_arrow(cv, cx, yex + hx / 2, sx - 0.6, yex + hx / 2, ident = paste0("excl", i))
    y_box <- yex + hx + 14
    .fd_arrow(cv, cx, y_prev, cx, y_box - 0.6, ident = paste0("step", i))
    last <- i == length(spec$steps)
    h <- .fd_flow_box(cv, paste0("step", i), cx - col_w / 2, y_box, col_w,
                      fd_wrap(paste(st$label %||% "Remaining", .fd_cnt(n)), col_w - 12), align = "middle",
                      focal = last && !identical(spec$focal_final, FALSE) && !length(groups))
    y_prev <- y_box + h; y <- y_box + h
  }
  if (length(groups)) {
    y <- y + 26; bus <- y - 13; gx0 <- cx - gw_total / 2
    .fd_arrow(cv, cx, y_prev, cx, bus, arrow = FALSE, ident = "bus-stem")
    if (length(groups) > 1) .fd_arrow(cv, gx0 + g_w / 2, bus, gx0 + gw_total - g_w / 2, bus, arrow = FALSE, ident = "bus")
    hmax <- 0
    for (j in seq_along(groups)) {
      g <- groups[[j]]; gx <- gx0 + (j - 1) * (g_w + g_gap)
      .fd_arrow(cv, gx + g_w / 2, bus, gx + g_w / 2, y - 0.6, ident = paste0("group", j - 1))
      hmax <- max(hmax, .fd_flow_box(cv, paste0("group", j - 1), gx, y, g_w, fd_wrap(paste(g$label, .fd_cnt(g$n)), g_w - 12),
                                     align = "middle", focal = .fd_true(g$focal)))
    }
    y <- y + hmax
  }
  .fd_finish(cv, spec, width, y + M, notes)
}

# ---- prisma --------------------------------------------------------------------
.fd_prisma_checks <- function(spec) {
  ident <- spec$identification %||% list()
  dbs <- .fd_pairs(ident$databases); regs <- .fd_pairs(ident$registers)
  if (!length(dbs) && !length(regs)) .fd_stop("PRISMA spec needs identification.databases and/or identification.registers")
  n_id <- .fd_sum(dbs, "databases") + .fd_sum(regs, "registers")
  if (!is.null(spec$identified) && .fd_count(spec$identified, "identified") != n_id)
    .fd_stop(sprintf("identified = %s, but databases and registers sum to %s", spec$identified, n_id))
  rem <- spec$removed %||% list()
  items <- list(list("Duplicate records removed", rem$duplicates %||% 0),
                list("Records marked as ineligible by automation tools", rem$automation %||% 0),
                list("Records removed for other reasons", rem$other %||% 0))
  n_rem <- sum(vapply(items, function(p) .fd_count(p[[2]], p[[1]]), 0))
  d <- list(identified = n_id, removed = n_rem, removed_items = items)
  step <- function(name, value, where) {
    if (!is.null(spec[[name]]) && .fd_count(spec[[name]], name) != value) .fd_stop(sprintf("%s = %s, but %s = %s", name, spec[[name]], where, value))
    if (value < 0) .fd_stop(sprintf("%s would be negative (%s): check %s", name, value, where))
    d[[name]] <<- value
  }
  step("screened", n_id - n_rem, sprintf("identified (%s) minus removed before screening (%s)", n_id, n_rem))
  sx <- spec$screen_excluded %||% 0
  sxn <- if (is.list(sx)) .fd_sum(sx, "screen_excluded") else .fd_count(sx, "screen_excluded")
  d$screen_excluded <- sxn
  step("sought", d$screened - sxn, sprintf("screened (%s) minus excluded at screening (%s)", d$screened, sxn))
  nr <- .fd_count(spec$not_retrieved %||% 0, "not_retrieved")
  step("assessed", d$sought - nr, sprintf("sought (%s) minus not retrieved (%s)", d$sought, nr))
  d$not_retrieved <- nr
  d$full_text_excluded <- .fd_sum(spec$full_text_excluded, "full_text_excluded")
  new_reports <- d$assessed - d$full_text_excluded
  if (new_reports < 0) .fd_stop(sprintf("reports excluded at full text (%s) exceed reports assessed (%s)", d$full_text_excluded, d$assessed))
  oth <- spec$other_methods
  if (length(oth)) {
    o_id <- .fd_sum(oth$identified, "other_methods.identified")
    o_s <- .fd_count(oth$sought %||% o_id, "other_methods.sought")
    if (o_s > o_id) .fd_stop(sprintf("other methods: sought (%s) exceeds identified (%s)", o_s, o_id))
    o_nr <- .fd_count(oth$not_retrieved %||% 0, "other_methods.not_retrieved"); o_as <- o_s - o_nr
    if (!is.null(oth$assessed) && .fd_count(oth$assessed, "other_methods.assessed") != o_as)
      .fd_stop(sprintf("other methods: assessed = %s, but sought (%s) minus not retrieved (%s) = %s", oth$assessed, o_s, o_nr, o_as))
    if (o_as < 0) .fd_stop("other methods: not retrieved exceeds sought")
    o_ex <- .fd_sum(oth$excluded, "other_methods.excluded")
    if (o_ex > o_as) .fd_stop(sprintf("other methods: excluded (%s) exceeds assessed (%s)", o_ex, o_as))
    d[c("o_identified", "o_sought", "o_not_retrieved", "o_assessed", "o_excluded")] <- list(o_id, o_s, o_nr, o_as, o_ex)
    new_reports <- new_reports + o_as - o_ex
  }
  inc <- spec$included %||% list()
  if (is.null(inc$studies)) .fd_stop("PRISMA spec needs included.studies")
  st <- .fd_count(inc$studies, "included.studies"); rp <- .fd_count(inc$reports %||% new_reports, "included.reports")
  if (rp != new_reports) .fd_stop(sprintf("included reports = %s, but assessed minus excluded = %s%s", rp, new_reports,
                                          if (length(oth)) " (both search columns)" else ""))
  if (st > rp) .fd_stop(sprintf("included studies (%s) cannot exceed reports of included studies (%s)", st, rp))
  d$studies <- st; d$reports <- rp
  prev <- spec$previous
  if (length(prev)) {
    ps <- .fd_count(prev$studies %||% 0, "previous.studies"); pr <- .fd_count(prev$reports %||% 0, "previous.reports")
    d[c("prev_studies", "prev_reports", "total_studies", "total_reports")] <- list(ps, pr, ps + st, pr + rp)
    tot <- spec$total %||% list()
    if (!is.null(tot$studies) && .fd_count(tot$studies, "total.studies") != ps + st)
      .fd_stop(sprintf("total studies = %s, but previous (%s) + new (%s) = %s", tot$studies, ps, st, ps + st))
    if (!is.null(tot$reports) && .fd_count(tot$reports, "total.reports") != pr + rp)
      .fd_stop(sprintf("total reports = %s, but previous (%s) + new (%s) = %s", tot$reports, pr, rp, pr + rp))
  }
  d
}

.fd_render_prisma <- function(spec) {
  if (length(spec$other_methods)) { spec$other_methods$identified <- .fd_pairs(spec$other_methods$identified)
    spec$other_methods$excluded <- .fd_pairs(spec$other_methods$excluded) }
  if (is.list(spec$screen_excluded)) spec$screen_excluded <- .fd_pairs(spec$screen_excluded)
  d <- .fd_prisma_checks(spec); notes <- character(0); cv <- .fd_canvas(); M <- FD$M
  oth <- spec$other_methods; prev <- spec$previous; has_o <- length(oth) > 0; has_p <- length(prev) > 0
  bw <- spec$box_width %||% (if (has_o) 96 else if (has_p) 112 else 140)
  sw <- spec$side_width %||% (if (has_o) 92 else if (has_p) 118 else 150)
  g <- 14; left <- M + 18
  lanes <- c(if (has_p) c(prev = bw), c(main = bw + g + sw), if (has_o) c(other = bw + g + sw))
  xs <- c(); x <- left
  for (nm in names(lanes)) { xs[nm] <- x; x <- x + lanes[[nm]] + 18 }
  width <- x - 18 + M
  y <- .fd_title(cv, spec, M, width)
  hdr <- c(prev = "Previous studies", main = "Identification of new studies via databases and registers",
           other = "Identification of new studies via other methods")
  if (has_p || has_o) {
    hh <- 0
    for (nm in names(lanes)) { ln <- fd_wrap(hdr[[nm]], lanes[[nm]] - 4, FD$SIZE_SMALL, "italic")
      .fd_text_block(cv, ln, xs[[nm]], y, size = FD$SIZE_SMALL, style = "italic", colour = FD$TEXT_MUTED, anchor = "start")
      hh <- max(hh, length(ln) * FD$SIZE_SMALL * 1.22) }
    y <- y + hh + 8
  }
  W <- function(t, w) fd_wrap(t, w - 12); S <- function(t, w) .fd_sub(t, w - 12)
  lst <- function(pairs, w) unlist(lapply(.fd_pairs(pairs), function(p) S(paste(p[[1]], .fd_cnt(p[[2]])), w)))
  r0 <- list(main = c(W("Records identified from:", bw), lst(spec$identification$databases, bw), lst(spec$identification$registers, bw)),
             main_side = c(W("Records removed before screening:", sw), lst(d$removed_items, sw)))
  if (has_o) r0$other <- c(W("Records identified from:", bw), lst(oth$identified, bw))
  if (has_p) r0$prev <- c(W(paste("Studies included in previous version of review", .fd_cnt(d$prev_studies)), bw),
                          W(paste("Reports of studies included in previous version of review", .fd_cnt(d$prev_reports)), bw))
  sxl <- spec$screen_excluded
  r1 <- list(main = W(paste("Records screened", .fd_cnt(d$screened)), bw),
             main_side = c(W(paste("Records excluded", .fd_cnt(d$screen_excluded)), sw), if (is.list(sxl)) lst(sxl, sw)))
  r2 <- list(main = W(paste("Reports sought for retrieval", .fd_cnt(d$sought)), bw),
             main_side = W(paste("Reports not retrieved", .fd_cnt(d$not_retrieved)), sw))
  r3 <- list(main = W(paste("Reports assessed for eligibility", .fd_cnt(d$assessed)), bw),
             main_side = c(W("Reports excluded:", sw), lst(spec$full_text_excluded, sw)))
  if (has_o) {
    r2$other <- W(paste("Reports sought for retrieval", .fd_cnt(d$o_sought)), bw)
    r2$other_side <- W(paste("Reports not retrieved", .fd_cnt(d$o_not_retrieved)), sw)
    r3$other <- W(paste("Reports assessed for eligibility", .fd_cnt(d$o_assessed)), bw)
    r3$other_side <- c(W("Reports excluded:", sw), lst(oth$excluded, sw))
  }
  rows <- list(r0, r1, r2, r3); pos <- list(); sy <- numeric(3)
  for (ri in 1:4) {
    row <- rows[[ri]]; rh <- max(vapply(row, .fd_box_height, 0))
    if (ri <= 2) sy[ri] <- y
    for (slot in names(row)) {
      side <- endsWith(slot, "_side"); lane <- sub("_side$", "", slot)
      bx <- xs[[lane]] + (if (side) bw + g else 0); w <- if (side) sw else bw
      h <- .fd_flow_box(cv, paste0(slot, "-", ri - 1), bx, y, w, row[[slot]])
      pos[[paste(ri - 1, slot)]] <- c(bx, y, w, h)
    }
    y <- y + rh + 20
    if (ri == 1) e0 <- y - 20
    if (ri == 4) e1 <- y - 20
  }
  sy[3] <- y
  mx <- xs[["main"]]
  inc <- if (has_p) c(W(paste("New studies included in review", .fd_cnt(d$studies)), bw), W(paste("Reports of new included studies", .fd_cnt(d$reports)), bw)) else
    c(W(paste("Studies included in review", .fd_cnt(d$studies)), bw), W(paste("Reports of included studies", .fd_cnt(d$reports)), bw))
  ih <- .fd_flow_box(cv, "included", mx, y, bw, inc, focal = !has_p && !identical(spec$focal_included, FALSE))
  pos[["inc main"]] <- c(mx, y, bw, ih); y <- y + ih
  if (has_p) {
    y <- y + 20
    tot <- c(W(paste("Total studies included in review", .fd_cnt(d$total_studies)), bw), W(paste("Reports of total included studies", .fd_cnt(d$total_reports)), bw))
    th <- .fd_flow_box(cv, "total", mx, y, bw, tot, focal = !identical(spec$focal_included, FALSE))
    pos[["tot main"]] <- c(mx, y, bw, th); y <- y + th
  }
  down <- function(a, b, id) .fd_arrow(cv, a[1] + a[3] / 2, a[2] + a[4], b[1] + b[3] / 2, b[2] - 0.6, ident = id)
  side <- function(a, b, id) { yy <- b[2] + min(b[4], a[4]) / 2; .fd_arrow(cv, a[1] + a[3], yy, b[1] - 0.6, yy, ident = id) }
  for (ri in 0:3) side(pos[[paste(ri, "main")]], pos[[paste(ri, "main_side")]], sprintf("main%d->side", ri))
  for (ri in 0:2) down(pos[[paste(ri, "main")]], pos[[paste(ri + 1, "main")]], sprintf("main%d->main%d", ri, ri + 1))
  down(pos[["3 main"]], pos[["inc main"]], "main3->included")
  if (has_o) {
    down(pos[["0 other"]], pos[["2 other"]], "other0->other2")
    for (ri in 2:3) side(pos[[paste(ri, "other")]], pos[[paste(ri, "other_side")]], sprintf("other%d->side", ri))
    down(pos[["2 other"]], pos[["3 other"]], "other2->other3")
    o <- pos[["3 other"]]; i <- pos[["inc main"]]; cxo <- o[1] + o[3] / 2
    .fd_add(cv, .fd_poly(rbind(c(cxo, o[2] + o[4]), c(cxo, i[2] + i[4] / 2), c(i[1] + i[3] + 0.6, i[2] + i[4] / 2)), ident = "other3->included"))
  }
  if (has_p) {
    p <- pos[["0 prev"]]; t_ <- pos[["tot main"]]
    .fd_add(cv, .fd_poly(rbind(c(p[1] + p[3] / 2, p[2] + p[4]), c(p[1] + p[3] / 2, t_[2] + t_[4] / 2), c(t_[1] - 0.6, t_[2] + t_[4] / 2)), ident = "prev->total"))
    down(pos[["inc main"]], pos[["tot main"]], "included->total")
  }
  spans <- list(c(sy[1], e0, "Identification"), c(sy[2], e1, "Screening"), c(sy[3], y, "Included"))
  for (s in spans) {
    y0 <- as.numeric(s[1]); y1 <- as.numeric(s[2]); cx_ <- M + 5; cy_ <- (y0 + y1) / 2
    .fd_add(cv, sprintf('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="0.6"/>', .fd_f(M + 12), .fd_f(y0), .fd_f(M + 12), .fd_f(y1), FD$MUTED))
    .fd_add(cv, sprintf('<text x="%s" y="%s" font-size="%s" font-style="italic" fill="%s" text-anchor="middle" transform="rotate(-90 %s %s)">%s</text>',
                        .fd_f(cx_), .fd_f(cy_), .fd_f(FD$SIZE_SMALL), FD$TEXT_MUTED, .fd_f(cx_), .fd_f(cy_), s[3]))
  }
  if (width > FD$COLUMN_PT + 1) notes <- c(notes, sprintf("Figure is %.0f pt wide, wider than a %.0f pt column: set box_width and side_width smaller, or use it as a full-page figure.", width, FD$COLUMN_PT))
  .fd_finish(cv, spec, width, y + M, notes)
}

# ---- timeline ------------------------------------------------------------------
.fd_to_num <- function(v, end = FALSE) {
  if (is.numeric(v)) return(as.numeric(v))
  m <- regmatches(v, regexec("^(\\d{4})-(\\d{2})(?:-(\\d{2}))?$", as.character(v), perl = TRUE))[[1]]
  if (!length(m)) .fd_stop("timeline value '", v, "': use a number or 'YYYY-MM'")
  yy <- as.integer(m[2]); mo <- as.integer(m[3])
  if (mo < 1 || mo > 12) .fd_stop("timeline value '", v, "': month must be 01 to 12")
  if (is.na(m[4]) || !nzchar(m[4])) return(yy * 12 + (mo - 1) + (if (end) 1 else 0))
  yy * 12 + (mo - 1) + (as.integer(m[4]) - 1) / 30.5
}
.fd_nice_ticks <- function(a, b, target = 7) {
  raw <- (b - a) / target; mag <- if (raw > 0) 10^floor(log10(raw)) else 1
  st <- c(1, 2, 3, 6, 12, 5, 10) * mag; st <- st[st >= raw]
  step <- if (length(st)) min(st) else mag * 10
  t <- ceiling(a / step) * step; out <- numeric(0)
  while (t <= b + 1e-9) { out <- c(out, t); t <- t + step }
  out
}

.fd_render_timeline <- function(spec) {
  tracks <- spec$tracks
  if (!length(tracks)) .fd_stop("timeline needs 'tracks'")
  dated <- is.character(spec$start); unit <- spec$unit %||% "month"
  t0 <- .fd_to_num(spec$start); t1 <- .fd_to_num(spec$end, end = TRUE)
  if (t1 <= t0) .fd_stop("timeline 'end' must be after 'start'")
  cv <- .fd_canvas(); M <- FD$M; width <- spec$width %||% FD$COLUMN_PT
  lab_w <- min(max(vapply(tracks, function(t) fd_text_width(t$label), 0)) + 10, 150)
  x0 <- M + lab_w; x1 <- width - M - 6
  sx <- function(t) x0 + (t - t0) / (t1 - t0) * (x1 - x0)
  y <- .fd_title(cv, spec, M, width)
  ms <- spec$milestones %||% list()
  if (length(ms)) ms <- ms[order(vapply(ms, function(m) .fd_to_num(m$at), 0), method = "radix")]
  levels <- numeric(0); draw <- list()
  for (m in ms) {
    t <- .fd_to_num(m$at)
    if (t < t0 || t > t1) .fd_stop(sprintf("milestone '%s' at %s is outside the timeline", m$label, m$at))
    x <- sx(t); tw <- fd_text_width(m$label, FD$SIZE_SMALL, "italic")
    lx <- min(max(x - tw / 2, M), width - M - tw)
    lvl <- 1
    while (lvl <= length(levels) && levels[lvl] > lx - 4) lvl <- lvl + 1
    if (lvl > length(levels)) levels <- c(levels, 0)
    levels[lvl] <- lx + tw
    draw[[length(draw) + 1]] <- list(x = x, lx = lx, lvl = lvl - 1, label = m$label)
  }
  top <- y + length(levels) * FD$SIZE_SMALL * 1.3 + (if (length(levels)) 6 else 0)
  row_h <- 18; bar_h <- 8
  for (i in seq_along(tracks)) {
    tr <- tracks[[i]]; ry <- top + (i - 1) * row_h
    .fd_text_block(cv, fd_wrap(tr$label, 148)[1], x0 - 8, ry + (row_h - FD$SIZE_LABEL) / 2, anchor = "end")
    for (sp in tr$spans %||% list()) {
      a <- .fd_to_num(sp[[1]]); b <- .fd_to_num(sp[[2]], end = TRUE)
      if (!(t0 <= a && a < b && b <= t1)) .fd_stop(sprintf("span %s to %s of '%s' is empty or outside the timeline", sp[[1]], sp[[2]], tr$label))
      focal <- .fd_true(tr$focal); if (focal) cv$accent <- cv$accent + 1
      bx <- sx(a); bwid <- sx(b) - sx(a); by <- ry + (row_h - bar_h) / 2
      .fd_add(cv, sprintf('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"%s/>', .fd_f(bx), .fd_f(by), .fd_f(bwid), .fd_f(bar_h),
                          if (focal) FD$ACCENT else FD$MUTED, .fd_box_meta("bar", tr$label, bx, by, bwid, bar_h)))
    }
    for (p in tr$points %||% list()) {
      px <- sx(.fd_to_num(p)); cy <- ry + row_h / 2
      .fd_add(cv, sprintf('<path d="M%s,%s L%s,%s L%s,%s L%s,%s Z" fill="%s"/>', .fd_f(px), .fd_f(cy - 4), .fd_f(px + 4), .fd_f(cy),
                          .fd_f(px), .fd_f(cy + 4), .fd_f(px - 4), .fd_f(cy), FD$INK))
    }
  }
  bottom <- top + length(tracks) * row_h
  for (m in draw) {
    ly <- y + m$lvl * FD$SIZE_SMALL * 1.3
    .fd_add(cv, sprintf('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="0.5" stroke-dasharray="1.5,2"/>',
                        .fd_f(m$x), .fd_f(ly + FD$SIZE_SMALL * 1.1), .fd_f(m$x), .fd_f(bottom), FD$INK))
    .fd_text_block(cv, m$label, m$lx, ly, size = FD$SIZE_SMALL, style = "italic", colour = FD$TEXT_MUTED, anchor = "start")
  }
  .fd_add(cv, sprintf('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="0.4"/>', .fd_f(x0), .fd_f(bottom + 4), .fd_f(x1), .fd_f(bottom + 4), FD$INK))
  if (dated) {
    step <- if (t1 - t0 <= 30) 1 else if (t1 - t0 <= 60) 3 else 6
    if (t1 - t0 > 36) step <- 6
    tk <- ceiling(t0):floor(t1); ticks <- tk[tk %% step == 0 | (t1 - t0 <= 14)]
    mon <- c("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    lab <- function(t) paste0(mon[t %% 12 + 1], if (t %% 12 == 0 || t == ticks[1]) paste0(" ", t %/% 12) else "")
  } else { ticks <- .fd_nice_ticks(t0, t1); lab <- function(t) .fd_f(t) }
  last_end <- -1e9
  for (t in ticks) {
    x <- sx(t)
    .fd_add(cv, sprintf('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="0.4"/>', .fd_f(x), .fd_f(bottom + 4), .fd_f(x), .fd_f(bottom + 7), FD$INK))
    s <- lab(t); tw <- fd_text_width(s, FD$SIZE_SMALL)
    if (x - tw / 2 > last_end + 3) { .fd_text_block(cv, s, x, bottom + 9, size = FD$SIZE_SMALL); last_end <- x + tw / 2 }
  }
  axis_label <- spec$axis_label %||% (if (dated) "" else paste0(toupper(substr(unit, 1, 1)), substring(unit, 2), "s"))
  yy <- bottom + 9 + FD$SIZE_SMALL * 1.3
  if (nzchar(axis_label)) { .fd_text_block(cv, axis_label, x1, yy, size = FD$SIZE_SMALL, colour = FD$TEXT_MUTED, anchor = "end"); yy <- yy + FD$SIZE_SMALL * 1.3 }
  .fd_finish(cv, spec, width, yy + M, character(0))
}

# ---- safe SVG reading and panels ---------------------------------------------------
.fd_screen <- function(text, where = "svg") {
  if (grepl("<!ENTITY", text, ignore.case = TRUE) || grepl("<!DOCTYPE[^>]*\\[", text, ignore.case = TRUE, perl = TRUE))
    .fd_stop(where, ": ENTITY declarations and DOCTYPE internal subsets are not allowed")
  if (grepl("<script|<foreignObject|\\son[a-z]+\\s*=", text, ignore.case = TRUE, perl = TRUE))
    .fd_stop(where, ": scripts, event handlers and foreignObject are not allowed")
  if (grepl("(?:href|src)\\s*=\\s*[\"']\\s*(?:https?:|//|data:text/html|javascript:)|@import|url\\(\\s*[\"']?\\s*(?:https?:|//)", text, ignore.case = TRUE, perl = TRUE))
    .fd_stop(where, ": remote references (links, fonts, images) are not allowed")
  invisible(TRUE)
}
.fd_read_svg <- function(path) {
  if (!grepl("\\.svg$", path, ignore.case = TRUE)) .fd_stop(path, ": panels must be .svg files (save InkSight figures with .svg)")
  if (file.size(path) > 2e7) .fd_stop(path, ": larger than 20 MB")
  text <- readChar(path, file.size(path), useBytes = TRUE); Encoding(text) <- "UTF-8"
  .fd_screen(text, basename(path))
  gsub("<!DOCTYPE[^>]*>", "", text, ignore.case = TRUE, perl = TRUE)
}
.fd_attr <- function(attrs, name) {
  m <- regmatches(attrs, regexec(paste0("\\b", name, "\\s*=\\s*[\"']([^\"']*)[\"']"), attrs, perl = TRUE))[[1]]
  if (length(m)) m[2] else NULL
}
.fd_svg_size <- function(attrs) {
  num <- function(nm) { m <- regmatches(attrs, regexec(paste0("\\b", nm, "\\s*=\\s*[\"']([\\d.]+)\\s*(pt|px|in|mm|cm)?[\"']"), attrs, perl = TRUE))[[1]]
    if (!length(m)) return(NULL)
    as.numeric(m[2]) * c(pt = 1, px = 0.75, `in` = 72, mm = 72 / 25.4, cm = 72 / 2.54)[[if (nzchar(m[3])) m[3] else "px"]] }
  w <- num("width"); h <- num("height")
  vb <- regmatches(attrs, regexec("viewBox\\s*=\\s*[\"']([-\\d.eE]+)[ ,]+([-\\d.eE]+)[ ,]+([\\d.eE]+)[ ,]+([\\d.eE]+)[\"']", attrs, perl = TRUE))[[1]]
  vbox <- if (length(vb)) as.numeric(vb[2:5]) else NULL
  if (!is.null(vbox) && (is.null(w) || is.null(h))) { w <- vbox[3] * 0.75; h <- vbox[4] * 0.75 }
  if (is.null(w) || is.null(h)) .fd_stop("panel SVG has no width/height or viewBox")
  list(w = w, h = h, vbox = vbox)
}
.fd_rx <- function(s) gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", s)
.fd_prefix_ids <- function(body, prefix) {
  ids <- unique(regmatches(body, gregexpr("\\bid\\s*=\\s*[\"']([^\"']+)[\"']", body, perl = TRUE))[[1]])
  ids <- sub("^id\\s*=\\s*[\"']", "", sub("[\"']$", "", ids), perl = TRUE)
  for (i in ids[order(-nchar(ids))]) {
    q <- .fd_rx(i)
    body <- gsub(paste0("\\bid(\\s*=\\s*)([\"'])", q, "\\2"), paste0("id\\1\\2", prefix, i, "\\2"), body, perl = TRUE)
    body <- gsub(paste0("url\\(\\s*#", q, "\\s*\\)"), paste0("url(#", prefix, i, ")"), body, perl = TRUE)
    body <- gsub(paste0("((?:xlink:)?href\\s*=\\s*[\"'])#", q, "([\"'])"), paste0("\\1#", prefix, i, "\\2"), body, perl = TRUE)
  }
  body
}
.fd_unify_fonts <- function(body) {
  fam <- FD$FONT_CSS; nm <- "(?:\"[^\"]*\"|'[^']*'|[\\w -]+)"
  body <- gsub("font-family\\s*=\\s*([\"'])(?:(?!\\1).)*\\1", paste0("font-family=\\1", fam, "\\1"), body, perl = TRUE)
  body <- gsub(paste0("font-family\\s*:\\s*", nm, "(?:\\s*,\\s*", nm, ")*"), paste0("font-family: ", fam), body, perl = TRUE)
  gsub(paste0("(font\\s*:\\s*(?:[\\w.-]+\\s+)*?[\\d.]+(?:px|pt))\\s+", nm, "(?:\\s*,\\s*", nm, ")*"), paste0("\\1 ", fam), body, perl = TRUE)
}

.fd_compose <- function(spec, base_dir = ".") {
  panels <- spec$panels
  if (!length(panels)) .fd_stop("panels spec needs 'panels'")
  cols <- as.integer(spec$cols %||% 2); width <- as.numeric(spec$width %||% FD$COLUMN_PT); gap <- as.numeric(spec$gap %||% 14)
  notes <- character(0); M <- FD$M; cell_w <- (width - 2 * M - (cols - 1) * gap) / cols
  cv <- .fd_canvas(); y <- .fd_title(cv, spec, M, width)
  col <- 0; row_h <- 0; scales <- list()
  for (i in seq_along(panels)) {
    p <- panels[[i]]; L <- LETTERS[i]; span <- min(as.integer(p$span %||% 1), cols)
    if (col + span > cols) { y <- y + row_h + gap; col <- 0; row_h <- 0 }
    if (!is.null(p$file)) {
      parts <- strsplit(gsub("\\\\", "/", p$file), "/", fixed = TRUE)[[1]]
      if (".." %in% parts) .fd_stop("panel paths may not contain '..'")
      text <- .fd_read_svg(file.path(base_dir, p$file))
    } else if (!is.null(p$spec)) {
      r <- fd_svg(p$spec, base_dir); text <- r$svg
      notes <- c(notes, if (length(r$findings)) paste0("panel ", L, ": ", r$findings))
    } else .fd_stop("each panel needs 'file' or 'spec'")
    m <- regmatches(text, regexec("<svg\\b([^>]*)>(.*)</svg>\\s*$", text, perl = TRUE))[[1]]
    if (!length(m)) {   # regexec has no dotall flag: retry with (?s)
      m <- regmatches(text, regexec("(?s)<svg\\b([^>]*)>(.*)</svg>\\s*$", text, perl = TRUE))[[1]]
      if (!length(m)) .fd_stop(sprintf("panel %d: not an SVG document", i))
    }
    attrs <- m[2]; body <- m[3]
    sz <- .fd_svg_size(attrs)
    avail <- cell_w * span + gap * (span - 1) - FD$SIZE_PANEL
    scale <- if (!identical(spec$no_upscale, FALSE)) min(1, avail / sz$w) else avail / sz$w
    dw <- sz$w * scale; dh <- sz$h * scale
    scales[[length(scales) + 1]] <- list(L, scale, avail)
    if (scale < 0.7) notes <- c(notes, sprintf("panel %s is shrunk to %.0f%%: its text may fall below 7 pt. Make it at the final size instead.", L, 100 * scale))
    x <- M + col * (cell_w + gap)
    body <- .fd_prefix_ids(body, paste0("p", i - 1, "-"))
    if (!identical(spec$unify_fonts, FALSE)) body <- .fd_unify_fonts(body)
    vb <- if (!is.null(sz$vbox)) paste(.fd_f(sz$vbox), collapse = " ") else sprintf("0 0 %s %s", .fd_f(sz$w), .fd_f(sz$h))
    extra <- ""; cl <- .fd_attr(attrs, "class"); if (!is.null(cl)) extra <- sprintf(' class="%s"', cl)
    ns <- regmatches(attrs, gregexpr("\\bxmlns:([\\w.-]+)\\s*=\\s*[\"']([^\"']+)[\"']", attrs, perl = TRUE))[[1]]
    for (d in ns) { pre <- sub("^xmlns:([\\w.-]+).*$", "\\1", d, perl = TRUE)
      if (pre != "xlink") extra <- paste0(extra, " ", sub("=\\s*'([^']*)'", '="\\1"', d)) }
    .fd_add(cv, sprintf('<svg x="%s" y="%s" width="%s" height="%s" viewBox="%s" preserveAspectRatio="xMinYMin meet" overflow="hidden"%s data-fd="panel" data-fd-id="%s">%s</svg>',
                        .fd_f(x + FD$SIZE_PANEL), .fd_f(y), .fd_f(dw), .fd_f(dh), vb, extra, L, body))
    .fd_text_block(cv, p$label %||% L, x, y, size = FD$SIZE_PANEL, style = "bold", anchor = "start")
    row_h <- max(row_h, dh); col <- col + span
  }
  sc <- vapply(scales, `[[`, 0, 2)
  if (length(sc) && max(sc) - min(sc) > 0.12)
    notes <- c(notes, paste0("Panels are scaled differently (", paste(vapply(scales, function(s) sprintf("%s %.0f%% (fits %.0f pt wide)", s[[1]], 100 * s[[2]], s[[3]]), ""), collapse = ", "),
                             "), so type sizes will not match. Build each panel at the width shown."))
  .fd_finish(cv, spec, width, y + row_h + M, notes)
}

# ---- checker ------------------------------------------------------------------------
.fd_PHI <- list(
  c("\\b\\d{3}-\\d{2}-\\d{4}\\b", "looks like a Social Security number"),
  c("\\b(?:19|20)\\d{2}-[01]\\d-[0-3]\\d\\b", "contains an exact date (YYYY-MM-DD)"),
  c("\\b[01]?\\d/[0-3]?\\d/(?:19|20)?\\d{2}\\b", "contains an exact date (MM/DD/YYYY)"),
  c("(?i)\\bMRN\\s*[:#]?\\s*\\d+|\\bmedical record\\b", "mentions a medical record number"),
  c("[\\w.+-]+@[\\w-]+\\.[\\w.]+", "contains an email address"),
  c("\\b(?:\\+?1[ .-]?)?\\(?\\d{3}\\)?[ .-]\\d{3}[ .-]\\d{4}\\b", "contains a phone number"),
  c("(?i)\\b(?:DOB|date of birth)\\b", "mentions date of birth"))

.fd_lum <- function(hex) {
  h <- sub("^#", "", hex); if (nchar(h) == 3) h <- paste(rep(strsplit(h, "")[[1]], each = 2), collapse = "")
  v <- strtoi(substring(h, c(1, 3, 5), c(2, 4, 6)), 16L) / 255
  v <- ifelse(v <= 0.03928, v / 12.92, ((v + 0.055) / 1.055)^2.4)
  sum(c(0.2126, 0.7152, 0.0722) * v)
}
fd_contrast <- function(a, b = "#FFFFFF") { l <- sort(c(.fd_lum(a), .fd_lum(b)), decreasing = TRUE); (l[1] + 0.05) / (l[2] + 0.05) }
.fd_overlap <- function(a, b, pad = 0.5) a[1] + pad < b[1] + b[3] && b[1] + pad < a[1] + a[3] && a[2] + pad < b[2] + b[4] && b[2] + pad < a[2] + a[4]
.fd_seg_hits <- function(p, q, box, shrink = 1) {
  x0 <- box[1] + shrink; y0 <- box[2] + shrink; x1 <- box[1] + box[3] - shrink; y1 <- box[2] + box[4] - shrink
  dx <- q[1] - p[1]; dy <- q[2] - p[2]; t0 <- 0; t1 <- 1
  for (pq in list(c(-dx, p[1] - x0), c(dx, x1 - p[1]), c(-dy, p[2] - y0), c(dy, y1 - p[2]))) {
    if (pq[1] == 0) { if (pq[2] < 0) return(FALSE) } else {
      t <- pq[2] / pq[1]
      if (pq[1] < 0) t0 <- max(t0, t) else t1 <- min(t1, t)
      if (t0 > t1) return(FALSE) }
  }
  t1 - t0 > 1e-6
}
.fd_strip_panels <- function(svg) {
  repeat {
    st <- regexpr("<svg\\b[^>]*data-fd=\"panel\"[^>]*>", svg, perl = TRUE)
    if (st < 0) return(svg)
    from <- st + attr(st, "match.length"); depth <- 1; pos <- from
    opens <- gregexpr("<svg\\b", svg, perl = TRUE)[[1]]; closes <- gregexpr("</svg>", svg, fixed = TRUE)[[1]]
    ev <- sort(c(setNames(opens[opens >= from], rep("o", sum(opens >= from))), setNames(closes[closes >= from], rep("c", sum(closes >= from)))))
    end <- NA
    for (k in seq_along(ev)) { depth <- depth + if (names(ev)[k] == "o") 1 else -1; if (depth == 0) { end <- ev[k] + 6; break } }
    if (is.na(end)) return(svg)
    svg <- paste0(substr(svg, 1, st - 1), substr(svg, end, nchar(svg)))
  }
}

# Design, accuracy and privacy checks on SVG text. Returns character(0) when clean.
fd_check_svg <- function(svg) {
  issues <- character(0)
  .fd_screen(svg)
  root <- regmatches(svg, regexpr("<svg\\b[^>]*>", svg, perl = TRUE))
  W <- H <- NULL
  vb <- .fd_attr(root, "viewBox")
  if (!is.null(vb)) { v <- as.numeric(strsplit(trimws(gsub(",", " ", vb)), "\\s+")[[1]]); W <- v[3]; H <- v[4] }
  tags <- regmatches(svg, gregexpr("<[A-Za-z][\\w:.-]*\\b[^>]*>", svg, perl = TRUE))[[1]]
  cols <- character(0)
  for (tg in tags) for (a in c("fill", "stroke")) { c_ <- .fd_attr(tg, a); if (!is.null(c_) && startsWith(c_, "#")) cols <- c(cols, toupper(c_)) }
  tm <- regmatches(svg, gregexpr("(?s)<text\\b([^>]*)>(.*?)</text>", svg, perl = TRUE))[[1]]
  texts <- character(0)
  for (t in tm) {
    attrs <- sub("(?s)^<text\\b([^>]*)>.*$", "\\1", t, perl = TRUE)
    s <- .fd_unesc(gsub("<[^>]+>", "", sub("(?s)^<text\\b[^>]*>(.*)</text>$", "\\1", t, perl = TRUE), perl = TRUE))
    texts <- c(texts, s); s30 <- substr(s, 1, 30)
    fill <- .fd_attr(attrs, "fill") %||% FD$INK
    if (startsWith(fill, "#") && fd_contrast(fill) < 4.5)
      issues <- c(issues, sprintf("Text '%s' has contrast %.1f:1 on white; use at least 4.5:1 (InkSight TEXT_MUTED %s).", s30, fd_contrast(fill), FD$TEXT_MUTED))
    fs <- .fd_attr(attrs, "font-size")
    if (!is.null(fs) && !is.na(suppressWarnings(as.numeric(fs))) && as.numeric(fs) < 7)
      issues <- c(issues, sprintf("Text '%s' is %s pt: below 7 pt is illegible in print.", s30, fs))
    w <- .fd_attr(attrs, "data-fd-w"); mw <- .fd_attr(attrs, "data-fd-maxw")
    if (!is.null(w) && !is.null(mw) && as.numeric(w) > as.numeric(mw) + 0.5)
      issues <- c(issues, sprintf("Text '%s' overflows its box by %.1f pt.", s30, as.numeric(w) - as.numeric(mw)))
  }
  ff <- unlist(lapply(tags, function(tg) .fd_attr(tg, "font-family")))
  if (length(ff) && nzchar(trimws(paste(ff, collapse = " "))) && !grepl("serif", paste(ff, collapse = " ")))
    issues <- c(issues, "Font family has no serif fallback; InkSight and FrameDesign use serif type.")
  reds <- grepl("^#(?:[C-F][0-9A-F]|[89AB][0-9A-F])[0-4][0-9A-F][0-4][0-9A-F]$", cols, perl = TRUE)
  greens <- grepl("^#[0-4][0-9A-F](?:[89A-F][0-9A-F])[0-4][0-9A-F]$", cols, perl = TRUE)
  if (any(reds) && any(greens)) issues <- c(issues, "Red and green are both used: colour-deficient readers cannot separate them (Tufte p.183).")
  for (s in texts) for (rx in .fd_PHI) if (grepl(rx[1], s, perl = TRUE))
    issues <- c(issues, sprintf("Label '%s' %s: remove identifiers before sharing.", substr(s, 1, 40), rx[2]))
  own <- .fd_strip_panels(svg)
  el <- regmatches(own, gregexpr("<[A-Za-z][\\w:.-]*\\b[^>]*\\bdata-fd=\"[^\"]+\"[^>]*>", own, perl = TRUE))[[1]]
  boxes <- list(); labels <- list(); edges <- list()
  for (e in el) {
    kind <- .fd_attr(e, "data-fd"); id <- .fd_unesc(.fd_attr(e, "data-fd-id") %||% "")
    if (kind %in% c("node", "label", "bar", "group")) {
      b <- as.numeric(strsplit(.fd_attr(e, "data-fd-box"), ",")[[1]])
      if (kind == "node") boxes[[length(boxes) + 1]] <- list(id, b)
      if (kind == "label") labels[[length(labels) + 1]] <- list(id, b)
      if (!is.null(W) && (b[1] < -0.5 || b[2] < -0.5 || b[1] + b[3] > W + 0.5 || b[2] + b[4] > H + 0.5))
        issues <- c(issues, sprintf("%s '%s' extends past the canvas edge.", kind, id))
    } else if (kind == "edge") {
      pts <- do.call(rbind, lapply(strsplit(strsplit(.fd_attr(e, "data-fd-points"), " ")[[1]], ","), as.numeric))
      edges[[length(edges) + 1]] <- list(id, pts)
    }
  }
  nb <- length(boxes); nl <- length(labels)
  if (nb > 1) for (i in 1:(nb - 1)) for (j in (i + 1):nb) if (.fd_overlap(boxes[[i]][[2]], boxes[[j]][[2]]))
    issues <- c(issues, sprintf("Nodes '%s' and '%s' overlap.", boxes[[i]][[1]], boxes[[j]][[1]]))
  for (l in labels) for (b in boxes) if (.fd_overlap(l[[2]], b[[2]])) issues <- c(issues, sprintf("Label '%s' overlaps node '%s'.", l[[1]], b[[1]]))
  if (nl > 1) for (i in 1:(nl - 1)) for (j in (i + 1):nl) if (.fd_overlap(labels[[i]][[2]], labels[[j]][[2]]))
    issues <- c(issues, sprintf("Labels '%s' and '%s' overlap.", labels[[i]][[1]], labels[[j]][[1]]))
  segs <- function(p) if (nrow(p) > 1) lapply(1:(nrow(p) - 1), function(k) list(p[k, ], p[k + 1, ])) else list()
  for (l in labels) for (e in edges) { if (e[[1]] == l[[1]]) next
    if (any(vapply(segs(e[[2]]), function(s) .fd_seg_hits(s[[1]], s[[2]], l[[2]], 0.3), TRUE)))
      issues <- c(issues, sprintf("Label '%s' is crossed by edge '%s'.", l[[1]], e[[1]])) }
  for (e in edges) {
    ends <- if (grepl("->", e[[1]], fixed = TRUE)) strsplit(e[[1]], "->", fixed = TRUE)[[1]] else character(0)
    for (b in boxes) { if (b[[1]] %in% ends) next
      if (any(vapply(segs(e[[2]]), function(s) .fd_seg_hits(s[[1]], s[[2]], b[[2]], 1.5), TRUE)))
        issues <- c(issues, sprintf("Edge '%s' passes through node '%s'.", e[[1]], b[[1]])) }
  }
  unique(issues)
}

# ---- input normalisation ----------------------------------------------------------
.fd_LIST_KEYS <- c("nodes", "edges", "arms", "steps", "groups", "tracks", "milestones", "panels", "reasons",
                   "not_received", "lost", "discontinued", "excluded_analysis", "points", "spans",
                   "databases", "registers", "full_text_excluded")
.fd_PAIR_KEYS <- c("reasons", "not_received", "lost", "discontinued", "excluded_analysis",
                   "databases", "registers", "full_text_excluded")
.fd_is_dict <- function(x) is.list(x) && !is.null(names(x))

# Make R or JSON input regular: scalars where lists are expected become
# one-item lists, a bare [label, n] pair is wrapped, vectors become lists.
fd_normalise <- function(obj, key = NULL) {
  if (!is.null(key) && key %in% .fd_LIST_KEYS && !(is.list(obj) && !.fd_is_dict(obj))) {
    obj <- if (is.atomic(obj) && length(obj) > 1) as.list(obj) else list(obj)
  }
  if (.fd_is_dict(obj)) { for (k in names(obj)) if (!is.null(obj[[k]])) obj[[k]] <- fd_normalise(obj[[k]], k); return(obj) }
  if (is.list(obj)) {
    if (!is.null(key) && key %in% .fd_PAIR_KEYS && length(obj) == 2 && is.character(obj[[1]]) && length(obj[[1]]) == 1 && !is.list(obj[[2]]))
      obj <- list(obj)
    if (identical(key, "spans") && length(obj) == 2 && all(vapply(obj, function(v) is.atomic(v) && length(v) == 1, TRUE)))
      obj <- list(obj)
    return(lapply(obj, fd_normalise, key = if (identical(key, "spans")) "_span" else NULL))
  }
  if (is.atomic(obj) && length(obj) > 1) return(as.list(obj))
  obj
}

# ---- public API ---------------------------------------------------------------------
# Render a spec to SVG text. Returns list(svg = <character>, findings = <character>).
fd_svg <- function(spec, base_dir = ".") {
  if (!is.list(spec)) .fd_stop("spec must be a list (or a JSON object)")
  spec <- fd_normalise(spec)
  type <- spec$type %||% ""
  r <- switch(type,
              flow = , pipeline = .fd_render_flow(spec), dag = .fd_render_dag(spec),
              consort = .fd_render_consort(spec), cohort = .fd_render_cohort(spec),
              prisma = .fd_render_prisma(spec), timeline = .fd_render_timeline(spec),
              panels = .fd_compose(spec, base_dir),
              .fd_stop("type must be one of cohort, consort, dag, flow, panels, pipeline, prisma, timeline"))
  r$findings <- unique(c(r$findings, fd_check_svg(r$svg)))
  r
}

# Exclusion or loss reasons from a named vector: fd_reasons(c("Declined" = 33, "Other" = 8))
fd_reasons <- function(x) {
  stopifnot(is.numeric(x), !is.null(names(x)), all(x >= 0), all(x == round(x)))
  unname(Map(function(lab, n) list(lab, as.integer(n)), names(x), x))
}

# Write an SVG (and optionally a self-contained HTML viewer). Refuses to overwrite.
fd_write_svg <- function(svg, file, overwrite = FALSE, html = FALSE) {
  parts <- strsplit(gsub("\\\\", "/", file), "/", fixed = TRUE)[[1]]
  if (".." %in% parts) .fd_stop("relative '..' paths are not allowed")
  ext <- tolower(tools::file_ext(file))
  if (!ext %in% c("svg", "html")) .fd_stop("use a .svg or .html file name")
  if (file.exists(file) && !overwrite) .fd_stop(file, " exists; set overwrite = TRUE to replace it")
  if (ext == "html" || html) {
    hp <- sub("\\.[^.]+$", ".html", file)
    if (file.exists(hp) && !overwrite) .fd_stop(hp, " exists; set overwrite = TRUE to replace it")
    writeLines(paste0("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Figure</title>",
                      "<style>body{margin:24px;background:#fff}</style></head><body>", svg, "</body></html>"), hp, useBytes = TRUE)
  }
  if (ext == "svg") { con <- file(file, "wb"); writeBin(charToRaw(enc2utf8(svg)), con); close(con) }
  invisible(file)
}

# Render a spec straight to a file. Findings are raised as one warning; returns the path.
fd_render <- function(spec, file, overwrite = FALSE, html = FALSE, base_dir = dirname(file)) {
  r <- tryCatch(fd_svg(spec, base_dir), fd_spec_error = function(e) stop("FrameDesign: ", conditionMessage(e), call. = FALSE))
  fd_write_svg(r$svg, file, overwrite = overwrite, html = html)
  if (length(r$findings)) warning(paste(c("FrameDesign check:", r$findings), collapse = "\n  - "), call. = FALSE)
  invisible(file)
}

# Check any SVG file (FrameDesign, InkSight, or hand-made). character(0) means no issues.
fd_check <- function(file) {
  txt <- readChar(file, file.size(file), useBytes = TRUE); Encoding(txt) <- "UTF-8"
  fd_check_svg(txt)
}

# PNG for slides: 6.5 in at 300 dpi is 1950 px wide. Needs the rsvg package.
fd_png <- function(svg, png = sub("\\.svg$", ".png", svg), width = 1950, overwrite = FALSE) {
  if (!requireNamespace("rsvg", quietly = TRUE)) stop("Install rsvg for PNG export: install.packages('rsvg')")
  if (file.exists(png) && !overwrite) stop(png, " exists; set overwrite = TRUE to replace it")
  rsvg::rsvg_png(svg, png, width = width)
  invisible(png)
}

# JSON specs (need jsonlite): read one, render one, or save an R spec as JSON.
fd_read_spec <- function(path) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite to read JSON specs")
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}
fd_render_json <- function(path, file, overwrite = FALSE, html = FALSE, base_dir = dirname(path))
  fd_render(fd_read_spec(path), file, overwrite = overwrite, html = html, base_dir = base_dir)
fd_write_spec <- function(spec, file, overwrite = FALSE) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
  if (file.exists(file) && !overwrite) stop(file, " exists; set overwrite = TRUE to replace it")
  jsonlite::write_json(spec, file, auto_unbox = TRUE, pretty = TRUE, digits = NA)
  invisible(file)
}

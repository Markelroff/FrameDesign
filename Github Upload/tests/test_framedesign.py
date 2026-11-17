"""Run with:  python -m pytest -q tests/     (or: python -m unittest discover tests)

Standard library only, like the engine itself.
"""
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import framedesign as fd  # noqa: E402

SPECS = ROOT / "examples" / "specs"


def load(name):
    return json.loads((SPECS / name).read_text(encoding="utf-8"))


def consort():
    return load("04_consort.json")


class TextAndWrap(unittest.TestCase):
    def test_times_metrics(self):
        self.assertAlmostEqual(fd.text_width("n", 10), 5.0)
        self.assertAlmostEqual(fd.text_width("W", 10), 9.44)

    def test_counts_never_split(self):
        lines = fd.wrap("Received allocated intervention " + fd._cnt(146), 120, 8.5)
        self.assertTrue(any("146" in l and "n" in l for l in lines))
        self.assertFalse(any(l.rstrip().endswith("(n") or l.rstrip().endswith("=") for l in lines))

    def test_thousands(self):
        self.assertEqual(fd._cnt(48210), "(n = 48,210)")


class ExamplesRenderClean(unittest.TestCase):
    """Every shipped example renders with no design, accuracy or privacy issues."""

    def test_examples(self):
        expected_notes = {
            "07_pipeline_slide.json": ["wide"],          # slide version is meant to be wide
            "08_figure_panels.json": None,               # needs InkSight panels on disk
        }
        for f in sorted(SPECS.glob("*.json")):
            with self.subTest(spec=f.name):
                if f.name == "08_figure_panels.json":
                    out = ROOT / "examples" / "output"
                    if not (out / "revision_rate.svg").exists():
                        self.skipTest("InkSight panels not generated")
                    svg, warns = fd.render(load(f.name), base_dir=out)
                else:
                    svg, warns = fd.render(load(f.name))
                allowed = expected_notes.get(f.name) or []
                bad = [w for w in warns if not any(a in w for a in allowed)
                       and "Counts below 11" not in w and "No directed path" not in w]
                self.assertEqual(bad, [], f"{f.name}: {bad}")
                self.assertEqual(fd.check_svg(svg), [], f.name)

    def test_deterministic(self):
        a, _ = fd.render(load("03_dag.json"))
        b, _ = fd.render(load("03_dag.json"))
        self.assertEqual(a, b)


class ConsortArithmetic(unittest.TestCase):
    def test_valid(self):
        fd.consort_checks(consort())

    def test_randomized_mismatch(self):
        s = consort(); s["randomized"] = 301
        with self.assertRaisesRegex(fd.SpecError, "randomized"):
            fd.render(s)

    def test_reasons_do_not_sum(self):
        s = consort(); s["excluded"]["reasons"][0][1] = 70
        with self.assertRaisesRegex(fd.SpecError, "reasons sum"):
            fd.render(s)

    def test_arms_do_not_sum(self):
        s = consort(); s["arms"][0]["allocated"] = 149
        with self.assertRaises(fd.SpecError):
            fd.render(s)

    def test_received_mismatch(self):
        s = consort(); s["arms"][0]["received"] = 140
        with self.assertRaisesRegex(fd.SpecError, "received"):
            fd.render(s)

    def test_analysed_mismatch(self):
        s = consort(); s["arms"][1]["analysed"] = 149
        with self.assertRaisesRegex(fd.SpecError, "analysed"):
            fd.render(s)

    def test_non_integer_count(self):
        s = consort(); s["excluded"]["reasons"][0][1] = 70.5
        with self.assertRaisesRegex(fd.SpecError, "whole number"):
            fd.render(s)

    def test_small_cells_flagged(self):
        s = consort()
        s["assessed"], s["excluded"] = 20, {"total": 4}
        s["randomized"] = 16
        s["arms"] = [{"name": "A", "allocated": 8, "analysed": 8}, {"name": "B", "allocated": 8, "analysed": 8}]
        _, warns = fd.render(s)
        self.assertTrue(any("below 11" in w for w in warns))


class CohortArithmetic(unittest.TestCase):
    def test_step_mismatch(self):
        s = load("05_cohort.json"); s["steps"][0]["n"] = 42000
        with self.assertRaisesRegex(fd.SpecError, "step 1"):
            fd.render(s)

    def test_groups_mismatch(self):
        s = load("05_cohort.json"); s["groups"][0]["n"] = 1
        with self.assertRaisesRegex(fd.SpecError, "groups sum"):
            fd.render(s)

    def test_excluding_more_than_present(self):
        s = load("05_cohort.json"); s["steps"][0] = {"excluded": 10**6}
        with self.assertRaises(fd.SpecError):
            fd.render(s)


class CausalDag(unittest.TestCase):
    def test_cycle_rejected(self):
        s = load("03_dag.json"); s["edges"].append({"from": "Revision", "to": "Smoking"})
        with self.assertRaisesRegex(fd.SpecError, "cycle"):
            fd.render(s)

    def test_mediator_adjustment_warned(self):
        s = load("03_dag.json")
        next(n for n in s["nodes"] if n["id"] == "Infection")["adjusted"] = True
        _, warns = fd.render(s)
        self.assertTrue(any("descendant of the exposure" in w for w in warns))

    def test_m_bias_warned(self):
        s = {"type": "dag", "nodes": [
            {"id": "X", "role": "exposure"}, {"id": "Y", "role": "outcome"},
            {"id": "U1", "role": "unmeasured"}, {"id": "U2", "role": "unmeasured"},
            {"id": "M", "role": "collider", "adjusted": True}],
            "edges": [{"from": "X", "to": "Y"}, {"from": "U1", "to": "X"}, {"from": "U1", "to": "M"},
                      {"from": "U2", "to": "M"}, {"from": "U2", "to": "Y"}]}
        _, warns = fd.render(s)
        self.assertTrue(any("M-bias" in w for w in warns))

    def test_needs_exposure_and_outcome(self):
        with self.assertRaisesRegex(fd.SpecError, "exactly one"):
            fd.render({"type": "dag", "nodes": [{"id": "A"}, {"id": "B"}], "edges": [{"from": "A", "to": "B"}]})

    def test_unmeasured_cannot_be_adjusted(self):
        s = load("03_dag.json")
        next(n for n in s["nodes"] if n["id"] == "Frailty")["adjusted"] = True
        with self.assertRaisesRegex(fd.SpecError, "unmeasured"):
            fd.render(s)

    def test_clean_dag_has_no_warnings(self):
        _, warns = fd.render(load("03_dag.json"))
        self.assertEqual(warns, [])


class PrismaArithmetic(unittest.TestCase):
    def test_counts_derived(self):
        d = fd.prisma_checks(load("09_prisma.json"))
        self.assertEqual((d["identified"], d["screened"], d["sought"], d["assessed"]), (2494, 1577, 175, 166))
        self.assertEqual((d["o_sought"], d["o_assessed"], d["reports"]), (40, 37, 39))

    def test_included_reports_mismatch(self):
        s = load("09_prisma.json"); s["included"]["reports"] = 25
        with self.assertRaisesRegex(fd.SpecError, "included reports"):
            fd.render(s)

    def test_screened_mismatch(self):
        s = load("09_prisma.json"); s["screened"] = 1600
        with self.assertRaisesRegex(fd.SpecError, "screened"):
            fd.render(s)

    def test_studies_exceed_reports(self):
        s = load("09_prisma.json"); s["included"]["studies"] = 40
        with self.assertRaisesRegex(fd.SpecError, "cannot exceed"):
            fd.render(s)

    def test_negative_step(self):
        s = load("10_prisma_update.json"); s["screen_excluded"] = 400
        with self.assertRaisesRegex(fd.SpecError, "negative"):
            fd.render(s)

    def test_update_totals(self):
        s = load("10_prisma_update.json"); s["total"]["studies"] = 23
        with self.assertRaisesRegex(fd.SpecError, "total studies"):
            fd.render(s)

    def test_screen_reasons_list(self):
        s = load("10_prisma_update.json"); s["screen_excluded"] = [["Off topic", 200], ["Not primary research", 71]]
        svg, _ = fd.render(s)
        self.assertEqual(fd.check_svg(svg), [])


class AdjustmentSets(unittest.TestCase):
    """Formal backdoor-criterion analysis (verified against networkx on random DAGs during development)."""

    def dag(self, edges, roles):
        names = sorted({v for e in edges for v in e})
        return {"type": "dag", "nodes": [{"id": v, "role": roles.get(v, "other")} for v in names],
                "edges": [{"from": a, "to": b} for a, b in edges]}

    def test_confounder(self):
        s = self.dag([("C", "X"), ("C", "Y"), ("X", "Y")], {"X": "exposure", "Y": "outcome"})
        self.assertEqual(fd.adjustment_sets(s), [["C"]])

    def test_m_bias_needs_nothing(self):
        s = self.dag([("U1", "X"), ("U1", "M"), ("U2", "M"), ("U2", "Y"), ("X", "Y")],
                     {"X": "exposure", "Y": "outcome", "U1": "unmeasured", "U2": "unmeasured"})
        self.assertEqual(fd.adjustment_sets(s), [[]])
        self.assertFalse(fd.backdoor_ok(s, {"M"}))

    def test_unidentifiable(self):
        s = self.dag([("U", "X"), ("U", "Y"), ("X", "Y")], {"X": "exposure", "Y": "outcome", "U": "unmeasured"})
        self.assertEqual(fd.adjustment_sets(s), [])
        _, warns = fd.render(s)
        self.assertTrue(any("not identified" in w for w in warns))

    def test_insufficient_set_reported(self):
        s = load("03_dag.json")
        for n in s["nodes"]:
            if n["id"] in ("SES", "Diabetes"):
                n["adjusted"] = False
        _, warns = fd.render(s)
        self.assertTrue(any("backdoor criterion" in w and "{Age, SES}" in w for w in warns))

    def test_example_minimal_set(self):
        self.assertEqual(fd.adjustment_sets(load("03_dag.json")), [["Age", "SES"]])

    def test_dagitty_export(self):
        txt = fd.to_dagitty(load("03_dag.json"))
        self.assertTrue(txt.startswith("dag {") and txt.endswith("}"))
        self.assertIn("Smoking [exposure]", txt)
        self.assertIn("Frailty [latent]", txt)
        self.assertIn("Age [adjusted]", txt)
        self.assertIn("Smoking -> Revision", txt)

    def test_dagitty_names_sanitised(self):
        s = {"nodes": [{"id": "Wound infection", "role": "exposure"}, {"id": "2-year revision", "role": "outcome"}],
             "edges": [{"from": "Wound infection", "to": "2-year revision"}]}
        self.assertIn("Wound_infection -> v_2_year_revision", fd.to_dagitty(s))


class FlowLayout(unittest.TestCase):
    def test_unknown_node(self):
        with self.assertRaisesRegex(fd.SpecError, "unknown node"):
            fd.render({"type": "flow", "nodes": [{"id": "a"}], "edges": [{"from": "a", "to": "b"}]})

    def test_duplicate_ids(self):
        with self.assertRaisesRegex(fd.SpecError, "duplicate"):
            fd.render({"type": "flow", "nodes": [{"id": "a"}, {"id": "a"}]})

    def test_larger_graph_has_no_collisions(self):
        nodes = [{"id": f"n{i}", "label": f"Step {i} of the analysis"} for i in range(11)]
        edges = [{"from": "n0", "to": "n1"}, {"from": "n0", "to": "n2"}, {"from": "n0", "to": "n3"},
                 {"from": "n1", "to": "n4"}, {"from": "n2", "to": "n4"}, {"from": "n2", "to": "n5"},
                 {"from": "n3", "to": "n6"}, {"from": "n4", "to": "n7"}, {"from": "n5", "to": "n7"},
                 {"from": "n6", "to": "n8"}, {"from": "n7", "to": "n9"}, {"from": "n8", "to": "n9"},
                 {"from": "n0", "to": "n9"}, {"from": "n9", "to": "n10"}]
        svg, warns = fd.render({"type": "flow", "nodes": nodes, "edges": edges})
        self.assertEqual(fd.check_svg(svg), [])

    def test_lr_labels(self):
        svg, warns = fd.render(load("07_pipeline_slide.json"))
        self.assertEqual(fd.check_svg(svg), [])

    def test_back_edge_drawn_dashed(self):
        svg, _ = fd.render(load("02_flow_loop.json"))
        self.assertIn('data-fd-id="ok-&gt;fit"', svg)


class Timeline(unittest.TestCase):
    def test_end_month_inclusive(self):
        self.assertEqual(fd._to_num("2026-12", "month", end=True) - fd._to_num("2026-12", "month"), 1.0)

    def test_span_outside(self):
        s = load("06_timeline.json"); s["tracks"][0]["spans"] = [[30, 40]]
        with self.assertRaisesRegex(fd.SpecError, "outside"):
            fd.render(s)

    def test_bad_month(self):
        with self.assertRaises(fd.SpecError):
            fd._to_num("2026-13", "month")


class RStyleInput(unittest.TestCase):
    def test_floats_and_scalars(self):
        s = consort()
        s["assessed"] = 412.0
        s["arms"][0]["not_received"] = ["Withdrew before dosing", 4.0]   # single pair, unwrapped
        t = {"type": "timeline", "start": "2026-09", "end": "2027-08",
             "tracks": {"label": "Rotation", "spans": ["2026-09", "2026-12"], "points": "2027-05"},
             "milestones": {"at": "2027-01", "label": "Choose advisor"}}
        fd.render(s)
        svg, _ = fd.render(t)
        self.assertEqual(fd.check_svg(svg), [])


class Security(unittest.TestCase):
    def test_source_has_no_network_shell_or_eval(self):
        src = (ROOT / "python" / "framedesign.py").read_text(encoding="utf-8")
        code = re.sub(r'""".*?"""', "", src, flags=re.S)  # ignore docstrings
        for bad in ("import socket", "urllib", "import subprocess", "os.system", "eval(", "exec(",
                    "import pickle", "http.client", "import requests"):
            self.assertFalse(bad in code, f"engine contains {bad!r}")

    def test_output_is_self_contained(self):
        for f in SPECS.glob("0[1-7]*.json"):
            svg, _ = fd.render(load(f.name))
            self.assertNotRegex(svg, r"https?://(?!www\.w3\.org/)")
            self.assertNotIn("<script", svg)
            self.assertNotRegex(svg, r"20\d\d-\d\d-\d\dT")  # no timestamps

    def test_screen_rejects_attacks(self):
        attacks = [
            '<!DOCTYPE svg [<!ENTITY x "y">]><svg/>',
            '<svg><script>alert(1)</script></svg>',
            '<svg onload="x()"/>',
            '<svg><image href="https://example.org/a.png"/></svg>',
            '<svg><style>@import url(https://fonts.example.org/x.css);</style></svg>',
            '<svg><foreignObject/></svg>',
        ]
        for a in attacks:
            with self.subTest(a=a), self.assertRaises(fd.SpecError):
                fd._screen_svg(a)
        fd._screen_svg('<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd"><svg/>')  # plain DOCTYPE ok

    def test_panel_path_traversal(self):
        with self.assertRaisesRegex(fd.SpecError, r"\.\."):
            fd.render({"type": "panels", "panels": [{"file": "../secret.svg"}]})

    def test_write_refuses_overwrite_and_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.svg"
            fd.write_svg("<svg/>", p)
            with self.assertRaises(fd.SpecError):
                fd.write_svg("<svg/>", p)
            with self.assertRaises(fd.SpecError):
                fd.write_svg("<svg/>", "../x.svg")
            with self.assertRaises(fd.SpecError):
                fd.write_svg("<svg/>", Path(d) / "x.txt")


class Checker(unittest.TestCase):
    def _svg(self, inner):
        return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" font-family="serif">{inner}</svg>'

    def test_overlap(self):
        svg = self._svg('<rect data-fd="node" data-fd-id="a" data-fd-box="10,10,50,20"/>'
                        '<rect data-fd="node" data-fd-id="b" data-fd-box="40,15,50,20"/>')
        self.assertTrue(any("overlap" in i for i in fd.check_svg(svg)))

    def test_edge_through_node(self):
        svg = self._svg('<rect data-fd="node" data-fd-id="a" data-fd-box="10,10,20,20"/>'
                        '<rect data-fd="node" data-fd-id="c" data-fd-box="60,10,20,20"/>'
                        '<rect data-fd="node" data-fd-id="b" data-fd-box="110,10,20,20"/>'
                        '<path data-fd="edge" data-fd-id="a->b" data-fd-points="30,20 110,20"/>')
        self.assertTrue(any("passes through node 'c'" in i for i in fd.check_svg(svg)))

    def test_identifiers(self):
        for label in ("MRN 123456", "Seen 2024-03-07", "jane.doe@hospital.org", "DOB 1/2/1980"):
            svg = self._svg(f'<text fill="#262626" font-size="10">{label}</text>')
            self.assertTrue(any("identifiers" in i for i in fd.check_svg(svg)), label)

    def test_low_contrast_text(self):
        svg = self._svg('<text fill="#A6A6A6" font-size="10">light</text>')
        self.assertTrue(any("contrast" in i for i in fd.check_svg(svg)))

    def test_red_green(self):
        svg = self._svg('<rect fill="#D62728"/><rect fill="#2CA02C"/>')
        self.assertTrue(any("Red and green" in i for i in fd.check_svg(svg)))

    def test_tiny_text(self):
        svg = self._svg('<text fill="#262626" font-size="5">tiny</text>')
        self.assertTrue(any("illegible" in i for i in fd.check_svg(svg)))

    def test_overflow(self):
        svg = self._svg('<text fill="#262626" font-size="10" data-fd-w="80" data-fd-maxw="60">long</text>')
        self.assertTrue(any("overflows" in i for i in fd.check_svg(svg)))


class Panels(unittest.TestCase):
    def test_ids_made_unique(self):
        panel = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
                 "width='100pt' height='60pt' viewBox='0 0 100 60'>"
                 "<defs><clipPath id='c1'><rect width='10' height='10'/></clipPath></defs>"
                 "<g id=\"figure_1\" clip-path='url(#c1)'><use xlink:href=\"#figure_1\"/></g></svg>")
        with tempfile.TemporaryDirectory() as d:
            for n in ("a.svg", "b.svg"):
                (Path(d) / n).write_text(panel, encoding="utf-8")
            svg, _ = fd.render({"type": "panels", "panels": [{"file": "a.svg"}, {"file": "b.svg"}]}, base_dir=d)
        ids = re.findall(r'\bid=["\']([^"\']+)', svg)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("url(#p0-c1)", svg)
        self.assertIn("url(#p1-c1)", svg)

    def test_panel_namespaces_kept(self):
        """Panels carrying extra namespaces (Inkscape, C2PA, RDF metadata) still compose."""
        panel = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:ex="http://example.org/ns" '
                 'width="100pt" height="60pt" viewBox="0 0 100 60">'
                 '<metadata><ex:note>provenance</ex:note></metadata><rect width="10" height="10"/></svg>')
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "m.svg").write_text(panel, encoding="utf-8")
            svg, warns = fd.render({"type": "panels", "panels": [{"file": "m.svg"}]}, base_dir=d)
        self.assertFalse(any("does not parse" in w for w in warns), warns)

    def test_mixed_scales_flagged(self):
        panel = ('<svg xmlns="http://www.w3.org/2000/svg" width="600pt" height="300pt" viewBox="0 0 600 300"></svg>')
        small = ('<svg xmlns="http://www.w3.org/2000/svg" width="150pt" height="100pt" viewBox="0 0 150 100"></svg>')
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "big.svg").write_text(panel); (Path(d) / "small.svg").write_text(small)
            _, warns = fd.render({"type": "panels", "panels": [{"file": "big.svg"}, {"file": "small.svg"}]}, base_dir=d)
        self.assertTrue(any("scaled differently" in w for w in warns))


if __name__ == "__main__":
    unittest.main()

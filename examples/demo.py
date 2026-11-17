"""Regenerate examples/output from examples/specs (simulated data only).

    python examples/demo.py                      # diagrams only
    INKSIGHT_DIR=../inksight python examples/demo.py   # also the combined figure

PNG previews are written when cairosvg is installed.
"""
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "python"))
import framedesign as fd  # noqa: E402

OUT = HERE / "output"
OUT.mkdir(exist_ok=True)


def inksight_panels():
    """Two InkSight charts at the width of one panel in a two-column figure."""
    cands = [os.environ.get("INKSIGHT_DIR", ""), str(HERE.parent.parent / "inksight"),
             str(HERE.parent.parent / "inksight" / "Upload")]
    for c in cands:
        if c and (Path(c) / "python" / "inksight.py").exists():
            sys.path.insert(0, str(Path(c) / "python"))
            break
    else:
        return False
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    import inksight as ink
    fix = {"font.serif": ["Times New Roman", "Times", "Liberation Serif", "DejaVu Serif"],
           "svg.fonttype": "none"}
    w = ((468 - 24 - 14) / 2 - 12) / 72  # panel width in inches
    with ink.vdqi_style(), plt.rc_context(fix):
        fig, ax = plt.subplots(figsize=(w, w / 1.5))
        ink.bar(["Reverse", "Anatomic"], [4.1, 6.3], ylabel="Revised within 2 years, %",
                title="Anatomic implants were revised more", ax=ax)
        ink.save_figure(fig, OUT / "revision_rate.svg", overwrite=True)
        fig, ax = plt.subplots(figsize=(w, w / 1.5))
        m = np.arange(0, 25, 3)
        shape = (1 - np.exp(-m / 9)) / (1 - np.exp(-24 / 9))
        ink.lines({"Anatomic": (m, 6.3 * shape), "Reverse": (m, 4.1 * shape)},
                  xlabel="Months after surgery", ylabel="Cumulative revision, %",
                  title="The gap opens in the first year", highlight="Anatomic", ax=ax)
        ink.save_figure(fig, OUT / "cumulative_revision.svg", overwrite=True)
    return True


def main():
    have_ink = inksight_panels()
    for spec_path in sorted((HERE / "specs").glob("*.json")):
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        if spec["type"] == "panels" and not have_ink:
            print(f"skip {spec_path.name}: InkSight not found (set INKSIGHT_DIR)")
            continue
        svg, findings = fd.render(spec, base_dir=OUT)
        out = fd.write_svg(svg, OUT / (spec_path.stem + ".svg"), overwrite=True)
        print(f"wrote {out.name}" + "".join(f"\n  - {f}" for f in findings))
        try:
            fd.export_png(out, out.with_suffix(".png"), dpi=200, overwrite=True)
        except fd.SpecError:
            pass


if __name__ == "__main__":
    main()

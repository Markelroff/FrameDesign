# Diagram types the engine does not draw

The engine covers the diagrams most common in clinical and biomedical papers. For anything else (sequence diagrams, swimlanes, 2 x 2 quadrants, concept maps, simple architecture sketches), write the SVG by hand with the same tokens, then run `check_svg()` on it. Keep the rules in `design-rules.md`.

## Tokens

```
font-family  'Times New Roman', Times, 'Liberation Serif', serif   (no web fonts)
text         #262626   10 pt labels, 8.5 pt details, never below 7 pt
text, muted  #595959
lines        #262626   0.75 pt;  focal 1.25 pt in #1F5FAD
fills        #FFFFFF boxes;  #F2F2F2 tint for a band or lane;  #A6A6A6 bars
accent       #1F5FAD   one or two elements only
grid         8 pt rhythm; 12 pt outer margin; boxes 2 pt corner radius
```

## Skeleton

Units are points: set `width`/`height` in pt and an equal `viewBox`.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="468pt" height="200pt" viewBox="0 0 468 200"
     font-family="'Times New Roman', Times, 'Liberation Serif', serif" role="img">
  <title>One-sentence description for screen readers</title>
  <defs>
    <marker id="arrow" viewBox="0 0 8 8" refX="7.4" refY="4" markerWidth="6" markerHeight="6"
            markerUnits="userSpaceOnUse" orient="auto"><path d="M0,0.6 L7.6,4 L0,7.4 Z" fill="#262626"/></marker>
  </defs>
  <rect width="100%" height="100%" fill="#FFFFFF"/>
  <!-- add data-fd="node" data-fd-id="..." data-fd-box="x,y,w,h" to boxes so the checker can test overlaps -->
  <rect x="12" y="12" width="120" height="28" rx="2" fill="#FFFFFF" stroke="#262626" stroke-width="0.75"
        data-fd="node" data-fd-id="a" data-fd-box="12,12,120,28"/>
  <text x="72" y="30" font-size="10" fill="#262626" text-anchor="middle">Label</text>
</svg>
```

## Type notes

- **Sequence diagram.** Participants as text headers (no boxes) with thin gray lifelines; messages as ink arrows read top to bottom; replies dashed; the one message that matters in the accent.
- **Swimlane.** Lanes as alternating `#FFFFFF` / `#F2F2F2` bands with the lane name in muted italic on the left; steps as boxes; hand-offs are the arrows that cross lanes.
- **2 x 2 quadrant.** Two thin axes crossing at the centre, axis labels at the ends in plain words ("Low effort" to "High effort"), items as dots with direct labels. If items have real coordinates, this is an InkSight scatterplot instead.
- **Concept map.** Concepts as plain text (no boxes), arrows labelled with the relationship verb in italic.
- **Architecture sketch.** Group with dashed gray frames, as in `flow` groups; data stores as slanted `data` boxes.

Avoid Venn diagrams for anything with counts: overlapping areas are not proportional to the numbers. Use an UpSet-style table or an InkSight bar chart of intersections.

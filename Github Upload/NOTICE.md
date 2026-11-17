# Notices

## Inspiration

FrameDesign was written from scratch. Its general approach (an editorial, low-density style for diagrams, one accent colour used sparingly, and an automatic self-check pass before delivery) was inspired by **diagram-design** by Cathryn Lavery, <https://github.com/cathrynlavery/diagram-design>, released under the MIT License:

> MIT License. Copyright (c) 2025 Cathryn Lavery.
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Font metrics

Glyph widths in `python/framedesign.py` are numeric advance widths measured from Liberation Serif (metric-compatible with Times New Roman; SIL Open Font License 1.1). No font files are included.

## Reporting guidelines

The CONSORT, PRISMA and cohort layouts follow the structure of the CONSORT 2010 flow diagram, the PRISMA 2020 flow diagram (Page et al., BMJ 2021) and STROBE recommendations. No template files from those groups are included.

## Causal inference

The adjustment-set analysis implements the backdoor criterion (Pearl, *Causality*, 2009) with d-separation computed on the moralised ancestral graph. The dagitty export targets the model syntax of dagitty (Textor et al., *International Journal of Epidemiology*, 2016). No dagitty code is included.

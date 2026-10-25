# Connected paths

The previous map renderer emitted an independent rectangle for every road
pair. Even correctly authored connected paths had overlapping outside edges,
open inside corners and no rounded-corner artwork. Duplicate suppression also
ignored road type, deleting a differently textured segment at the same location.

The renderer now finds degree-two endpoints within each road type, independently
of endpoint direction and object ordering. Shallow bends and authored ANGLED
corners intersect their two offset edges. Other bends trim the adjoining legs
and insert the normal or tight curve pieces from the road texture atlas. The
normal radius is 1.5 road widths; tight is 0.5. Each piece covers up to 30 degrees.
Corners too short to trim attempt the donor miter branch. Both edge
intersections must fit within both remaining legs (retaining the 0.5-unit
margin); otherwise both source edges remain unchanged. This renderer guard
prevents near-reversing corners from producing long spikes. Different road
types at the same coordinates are preserved.

## Evidence and adaptations

Donor: Open-BFME-2 matching `Code/GameEngineDevice/Source/W3DDevice/GameClient/`
`W3DRoadBuffer.cpp`: `miter`, `insertCurveSegmentAt`, `loadCurve`, and
`loadFloat4PtSection`. The shallow-angle cutoff is 0.9 times 30 degrees;
the remaining-leg cutoff is 0.5. Curve UV origins are (4/512,255/512), or
(4/512,425/512) for tight corners. The donor's asymmetrical curve quads and
projected UVs are retained. Terrain columns retain the existing maximum-height
sampling across their width and presentation lift.

This is a donor-based adaptation, not verified RotWK byte equivalence. The
small renderer represents roads as line pairs rather than the donor's reordered
RoadSegment array: it discovers degree-two adjacency explicitly, matches the
appropriate opposite edges for reversed segments, and builds tangent points
and curve centers in 2D. Endpoint ANGLED/TIGHT flags are combined at a shared
node. The final curve piece uses the remaining turn angle. Available leg length
accounts for an earlier trim at the far end. These choices are renderer-only;
simulation, pathfinding and authoritative map data are unchanged.

S-036 remains open for Y/H junctions, cross-type alpha alignment, BFME2
stacking and exact curve parity. Ordinary tees and four-way junctions now use
their dedicated tiles; unsupported junction shapes retain source geometry
and increment `special_junctions_pending`.

## Validation

Road tests cover a hand-derived 90-degree miter in both segment directions,
normal/tight curve atlas selection and tangent placement, preservation of two
road types on the same line, straight-segment UVs, pairing and terrain height.
The Harlindon Metal capture builds 74 original road pairs, 23 mitered joins and
35 rounded joins (159 strips including curve pieces). The map still reports
its pre-existing missing SkyEnv.tga standing-water texture.

Final checks: 9 road/corpus tests passed (2,938,654 assertions), including all
pure RotWK/BFME2 map parses and their existing oracle checks. Metal overview
and close captures of Harlindon were inspected for connected edges and curved
artwork. Native Release build passed.

## Tees, four-way junctions and end caps

The same donor's `insertTee`, `insert4Way`, `offset3Way`, `offset4Way`,
`loadTee`, `loadFloatSection`, `insertCrossTypeJoins` and `loadAlphaJoin`
supply these additions. At a degree-three/four node the most opposite pair
sets the junction axis. Stub centers move half a road width outward and their
edges align to the tile. The tee UV origin is (425,255)/512; four-way is
(425,425)/512. The tile uses the donor's 1.03 width adjustment.

A degree-one endpoint carrying WorldBuilder's JOIN flag receives the alpha
end piece at UV origin (106,425)/512. Its length is 48/128 road widths,
with 8/128 extra width and the donor's 0.65 backward placement. Unmarked
square ends stay square: automatically adding caps would change the map's
authored design. Both ends of a segment may independently request a cap.

Adaptation: this uses the existing endpoint graph rather than the donor's
reordered RoadSegment list. Y/H three-way shapes have different artwork and
are explicitly counted as pending when the donor angle gates identify them.
Cross-type alignment/stacking remains open; free-standing JOIN caps use the
road's own axis. These are rendering changes, with no pathfinding changes.

Tests cover ordinary tees, a four-way with reversed branches, both endpoint
directions for caps, and unmarked square ends. The Harlindon Metal render
adds six tees and thirteen caps, with zero pending special junctions.

Junction validation: 11 road/corpus tests passed (2,938,675 assertions).
Metal captures include Harlindon's actual six tees and thirteen authored caps,
and a controlled four-way junction with four caps using TRHarlindon01. The
controlled scene reports one four-way tile, four caps and no pending special
junctions. Its center and cap artwork were visually inspected.

## Review guards

Four-way tiles require two transverse arms on opposite sides of the chosen
axis, with the same angle limits used for ordinary tees. Unsupported four-way
shapes preserve all authored branch endpoints and increment
`special_junctions_pending`; validation occurs before any stub is changed.

Regression tests reproduce the review's near-reversal and east/west/north/
northeast examples. They compare rejected geometry and UVs with independent
source strips, cover reversed endpoint order, ANGLED and unmarked corners,
and same-side transverse branches in both northern and southern hemispheres.

Review validation: focused native road runner passed all 12 road tests
(580 assertions). Both new regression cases failed against the pre-fix MR
source. Existing angled/rounded corners, tees, valid crosses and end caps
continue to pass; short-leg rejection is covered alongside near-reversals.

## Maintainer follow-ups

Endpoint adjacency is indexed once by lowercase road name and exact XY
coordinate in an ordered map. Names are lowercased once per segment; junction
and corner passes reuse the same branch lists rather than scanning every road.
Group insertion preserves segment/endpoint order, so donor axis ties and draw
ordering remain stable. Endpoint grouping takes O(n log n); the pre-existing
duplicate-segment scan is unchanged.

Tee/cross stub proposals are validated together before any edge changes. Both
edges must leave more than 0.5 units toward their far endpoint. A junction that
cannot fit retains its authored strips and increments the pending count.
Regression coverage exercises every short arm of a tee/cross, with reversed
endpoints. The unused cross-product helper was removed. Source citations now
prefer the equivalent Open-BFME-2 donor functions over BFME1.

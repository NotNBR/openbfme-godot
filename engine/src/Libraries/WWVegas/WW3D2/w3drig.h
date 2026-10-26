// OpenBFME. GPL-3.0.
//
// OpenBFME infrastructure, not a port (retail has no counterpart): the W3D side of the custom unit rig API that GodotDevice/GodotW3DInstancer
// gives scripts (docs/CUSTOM_ANIMATION.md). Kept free of Godot so it is unit-tested in openbfme_core.
//
//  * Axes. Scripts see Godot's model axes: W3D (x, y, z) -> (x, z, -y), Y up, one unit per W3D unit. A pivot transform M (W3D) becomes
//    A M A^T, so a point p in a pivot's own frame becomes A p. The conversion is exact: it only moves and negates floats.
//  * Rigidity. The skinning (meshrender.h Deform_Position, the W3D vertex shader) treats every pivot transform as a rotation plus a
//    translation; a script pose with scale, shear or a reflection would distort the mesh, so it is refused.
//  * Bone skin. What each pivot carries, so a script can tell a weapon pivot from a cape pivot without a naming convention: every drawn vertex
//    counts once, for the pivot that carries most of its weight, at its position in that pivot's own frame (bind pose).

#pragma once

#include "Libraries/WWVegas/WW3D2/meshrender.h"
#include "Libraries/WWVegas/WWMath/matrix3d.h"

#include <string>
#include <vector>

// W3D -> Godot model axes (a pivot transform; the result's rows are the Godot basis rows and origin)
Matrix3D W3D_Rig_To_Godot(const Matrix3D &m);
// Godot model axes -> W3D (the inverse of W3D_Rig_To_Godot)
Matrix3D W3D_Rig_From_Godot(const Matrix3D &m);
// a point (or a pivot-frame offset) W3D -> Godot
Vector3 W3D_Rig_Point_To_Godot(const Vector3 &p);

// Largest deviation of a script pose's rotation from orthonormal that is still accepted, per dot product and per axis length. A pose composed
// by Godot's Skeleton3D down a hierarchy accumulates single-precision rounding (about 1e-6 per level on retail rigs of up to ~40 pivots); a
// bone scale of 1.0001 or more is refused.
constexpr float W3D_RIG_RIGID_TOLERANCE = 1e-4f;

// True when m can be drawn by the skinning: finite, an orthonormal rotation (within W3D_RIG_RIGID_TOLERANCE) with determinant +1. Otherwise
// false and *why names the first failure ("not finite", "scaled or sheared", "a reflection").
bool W3D_Rig_Is_Rigid(const Matrix3D &m, std::string *why);

struct W3DBoneSkin
{
	int Vertices = 0;
	Vector3 Min; // pivot frame, W3D axes; meaningful when Vertices > 0
	Vector3 Max;
};

// Adds the drawn vertices of one mesh to `bones` (one entry per pivot of the hierarchy). A rigid mesh's vertices are in the frame of the pivot
// its sub object hangs on (rigidBone); a skin stores each vertex in the frame of every bone it is bound to (Position for Bone0, Position1 for
// Bone1), and the vertex counts for the bone with the larger weight (Bone0 on a tie). False + *error for a pivot outside `bones`; `bones` is
// then unchanged.
bool W3D_Add_Bone_Skin(const MeshRenderData &mesh, int rigidBone, std::vector<W3DBoneSkin> &bones, std::string *error);

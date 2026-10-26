// OpenBFME. GPL-3.0. See w3drig.h.

#include "Libraries/WWVegas/WW3D2/w3drig.h"

#include <algorithm>
#include <cmath>

namespace
{

// A = rows (1,0,0), (0,0,1), (0,-1,0) maps W3D to Godot. Index form: godot[i] = sign[i] * w3d[axis[i]].
constexpr int Axis[3] = { 0, 2, 1 };
constexpr float Sign[3] = { 1.0f, 1.0f, -1.0f };

} // namespace

Matrix3D W3D_Rig_To_Godot(const Matrix3D &m)
{
	// (A M A^T)[i][j] = Sign[i] Sign[j] M[Axis[i]][Axis[j]]; translation A t
	Matrix3D out;
	for (int i = 0; i < 3; ++i)
	{
		for (int j = 0; j < 3; ++j)
		{
			out.Row[i][j] = Sign[i] * Sign[j] * m.Row[Axis[i]][Axis[j]];
		}
		out.Row[i][3] = Sign[i] * m.Row[Axis[i]][3];
	}
	return out;
}

Matrix3D W3D_Rig_From_Godot(const Matrix3D &m)
{
	// A^T G A: the same index map read the other way (Axis is its own inverse)
	Matrix3D out;
	for (int i = 0; i < 3; ++i)
	{
		for (int j = 0; j < 3; ++j)
		{
			out.Row[Axis[i]][Axis[j]] = Sign[i] * Sign[j] * m.Row[i][j];
		}
		out.Row[Axis[i]][3] = Sign[i] * m.Row[i][3];
	}
	return out;
}

Vector3 W3D_Rig_Point_To_Godot(const Vector3 &p)
{
	return Vector3(p.X, p.Z, -p.Y);
}

bool W3D_Rig_Is_Rigid(const Matrix3D &m, std::string *why)
{
	for (int r = 0; r < 3; ++r)
	{
		for (int c = 0; c < 4; ++c)
		{
			if (!std::isfinite(m.Row[r][c]))
			{
				if (why) *why = "not finite";
				return false;
			}
		}
	}
	// the columns are the rotated axes: unit length and pairwise perpendicular
	for (int a = 0; a < 3; ++a)
	{
		for (int b = a; b < 3; ++b)
		{
			const float dot = m.Row[0][a] * m.Row[0][b] + m.Row[1][a] * m.Row[1][b] + m.Row[2][a] * m.Row[2][b];
			if (std::fabs(dot - (a == b ? 1.0f : 0.0f)) > W3D_RIG_RIGID_TOLERANCE)
			{
				if (why) *why = "scaled or sheared";
				return false;
			}
		}
	}
	const float det = m.Row[0][0] * (m.Row[1][1] * m.Row[2][2] - m.Row[1][2] * m.Row[2][1])
		- m.Row[0][1] * (m.Row[1][0] * m.Row[2][2] - m.Row[1][2] * m.Row[2][0])
		+ m.Row[0][2] * (m.Row[1][0] * m.Row[2][1] - m.Row[1][1] * m.Row[2][0]);
	if (det < 0.0f)
	{
		if (why) *why = "a reflection";
		return false;
	}
	return true;
}

bool W3D_Add_Bone_Skin(const MeshRenderData &mesh, int rigidBone, std::vector<W3DBoneSkin> &bones, std::string *error)
{
	const int pivots = (int)bones.size();
	auto bad = [&](int bone) {
		if (error) *error = "mesh " + mesh.Name + " uses pivot " + std::to_string(bone) + " of a hierarchy with " + std::to_string(pivots);
		return false;
	};
	if (!mesh.Skin && (rigidBone < 0 || rigidBone >= pivots)) return bad(rigidBone);
	if (mesh.Skin)
	{
		for (size_t v = 0; v < mesh.NumVertices; ++v)
		{
			const int b0 = mesh.Bone0[v];
			if (b0 >= pivots) return bad(b0);
			if (mesh.DualBone && mesh.Bone1[v] >= pivots) return bad(mesh.Bone1[v]);
		}
	}
	for (size_t v = 0; v < mesh.NumVertices; ++v)
	{
		int bone = rigidBone;
		const float *at = &mesh.Position[v * 3];
		if (mesh.Skin)
		{
			const bool second = mesh.DualBone && mesh.Weight1[v] > mesh.Weight0[v];
			bone = second ? mesh.Bone1[v] : mesh.Bone0[v];
			if (second) at = &mesh.Position1[v * 3];
		}
		W3DBoneSkin &b = bones[(size_t)bone];
		if (b.Vertices++ == 0)
		{
			b.Min = b.Max = Vector3(at[0], at[1], at[2]);
			continue;
		}
		b.Min = Vector3(std::min(b.Min.X, at[0]), std::min(b.Min.Y, at[1]), std::min(b.Min.Z, at[2]));
		b.Max = Vector3(std::max(b.Max.X, at[0]), std::max(b.Max.Y, at[1]), std::max(b.Max.Z, at[2]));
	}
	return true;
}

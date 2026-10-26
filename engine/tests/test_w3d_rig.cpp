// OpenBFME unit tests: the custom unit rig's W3D side (w3drig.h) on synthetic transforms and meshes. GPL-3.0.
// Expected values are worked out by hand: the axis map W3D (x, y, z) -> Godot (x, z, -y) only moves and negates floats, so every
// comparison is exact.

#include "doctest.h"

#include "Libraries/WWVegas/WW3D2/w3drig.h"

#include <cmath>
#include <limits>
#include <string>
#include <vector>

namespace
{

Matrix3D rows(float a, float b, float c, float d, float e, float f, float g, float h, float i, float x, float y, float z)
{
	Matrix3D m;
	const float v[3][4] = { { a, b, c, x }, { d, e, f, y }, { g, h, i, z } };
	for (int r = 0; r < 3; ++r)
		for (int k = 0; k < 4; ++k) m.Row[r][k] = v[r][k];
	return m;
}

bool same(const Matrix3D &a, const Matrix3D &b)
{
	for (int r = 0; r < 3; ++r)
		for (int k = 0; k < 4; ++k)
			if (a.Row[r][k] != b.Row[r][k]) return false;
	return true;
}

MeshRenderData mesh(const char *name, bool skin, bool dual, const std::vector<float> &position)
{
	MeshRenderData m;
	m.Name = name;
	m.Skin = skin;
	m.DualBone = dual;
	m.NumVertices = position.size() / 3;
	m.Position = position;
	return m;
}

} // namespace

TEST_CASE("w3d rig: the axis map sends W3D (x, y, z) to Godot (x, z, -y)")
{
	// a translation
	const Matrix3D t = rows(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 2, 3);
	CHECK(same(W3D_Rig_To_Godot(t), rows(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 3, -2)));
	const Vector3 p = W3D_Rig_Point_To_Godot(Vector3(1, 2, 3));
	CHECK(p.X == 1.0f);
	CHECK(p.Y == 3.0f);
	CHECK(p.Z == -2.0f);
	// 90 degrees about W3D's up axis (Z) is 90 degrees about Godot's up axis (Y): Basis(Vector3.UP, PI / 2) has rows (0,0,1), (0,1,0), (-1,0,0)
	const Matrix3D rz = rows(0, -1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0);
	CHECK(same(W3D_Rig_To_Godot(rz), rows(0, 0, 1, 0, 1, 0, -1, 0, 0, 0, 0, 0)));
}

TEST_CASE("w3d rig: Godot -> W3D inverts W3D -> Godot exactly")
{
	const Matrix3D m = rows(0.36f, 0.48f, -0.8f, -0.8f, 0.6f, 0.0f, 0.48f, 0.64f, 0.6f, 12.5f, -3.25f, 7.0f);
	CHECK(same(W3D_Rig_From_Godot(W3D_Rig_To_Godot(m)), m));
	CHECK(same(W3D_Rig_To_Godot(W3D_Rig_From_Godot(m)), m));
}

TEST_CASE("w3d rig: only rigid transforms are accepted, with the reason")
{
	std::string why;
	CHECK(W3D_Rig_Is_Rigid(Matrix3D(), &why));
	CHECK(W3D_Rig_Is_Rigid(rows(0, -1, 0, 1, 0, 0, 0, 0, 1, 4, 5, 6), &why));
	// within the tolerance: the rounding of a composed pose
	CHECK(W3D_Rig_Is_Rigid(rows(1.00001f, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0), &why));

	why.clear();
	CHECK_FALSE(W3D_Rig_Is_Rigid(rows(1.001f, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0), &why));
	CHECK(why == "scaled or sheared");
	why.clear();
	CHECK_FALSE(W3D_Rig_Is_Rigid(rows(1, 0.01f, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0), &why));
	CHECK(why == "scaled or sheared");
	why.clear();
	CHECK_FALSE(W3D_Rig_Is_Rigid(rows(1, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 0), &why));
	CHECK(why == "a reflection");
	why.clear();
	CHECK_FALSE(W3D_Rig_Is_Rigid(rows(1, 0, 0, 0, 1, 0, 0, 0, 1, std::numeric_limits<float>::quiet_NaN(), 0, 0), &why));
	CHECK(why == "not finite");
	why.clear();
	CHECK_FALSE(W3D_Rig_Is_Rigid(rows(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, std::numeric_limits<float>::infinity(), 0), &why));
	CHECK(why == "not finite");
}

TEST_CASE("w3d rig: a rigid mesh's vertices count for its pivot, in that pivot's frame")
{
	std::vector<W3DBoneSkin> bones(3);
	std::string error;
	const MeshRenderData m = mesh("BLADE", false, false, { 0, 0, 0, 0.5f, -1, 30, -0.5f, 1, 2 });
	REQUIRE(W3D_Add_Bone_Skin(m, 1, bones, &error));
	CHECK(bones[0].Vertices == 0);
	CHECK(bones[1].Vertices == 3);
	CHECK(bones[2].Vertices == 0);
	CHECK(bones[1].Min.X == -0.5f);
	CHECK(bones[1].Min.Y == -1.0f);
	CHECK(bones[1].Min.Z == 0.0f);
	CHECK(bones[1].Max.X == 0.5f);
	CHECK(bones[1].Max.Y == 1.0f);
	CHECK(bones[1].Max.Z == 30.0f);
}

TEST_CASE("w3d rig: a skin vertex counts once, for the bone with the larger weight, at its position in that bone's frame")
{
	MeshRenderData m = mesh("BODY", true, true, { 1, 1, 1, 2, 2, 2, 3, 3, 3 });
	m.Position1 = { 10, 10, 10, 20, 20, 20, 30, 30, 30 };
	m.Bone0 = { 0, 0, 2 };
	m.Bone1 = { 1, 1, 1 };
	m.Weight0 = { 1.0f, 0.25f, 0.5f };
	m.Weight1 = { 0.0f, 0.75f, 0.5f };
	std::vector<W3DBoneSkin> bones(3);
	std::string error;
	REQUIRE(W3D_Add_Bone_Skin(m, -1, bones, &error));
	// vertex 0: bone 0 only; vertex 1: bone 1 carries 0.75, so its Position1; vertex 2: a tie stays with bone 0's stream (bone 2)
	CHECK(bones[0].Vertices == 1);
	CHECK(bones[0].Min.X == 1.0f);
	CHECK(bones[0].Max.Z == 1.0f);
	CHECK(bones[1].Vertices == 1);
	CHECK(bones[1].Min.X == 20.0f);
	CHECK(bones[1].Max.Y == 20.0f);
	CHECK(bones[2].Vertices == 1);
	CHECK(bones[2].Min.Z == 3.0f);
	// a second mesh adds to the same pivots: three drawn vertices plus three more, each counted once
	const MeshRenderData rigid = mesh("SHIELD", false, false, { -4, 0, 0, 4, 0, 0, 0, 5, 0 });
	REQUIRE(W3D_Add_Bone_Skin(rigid, 0, bones, &error));
	CHECK(bones[0].Vertices + bones[1].Vertices + bones[2].Vertices == 6);
	CHECK(bones[0].Min.X == -4.0f);
	CHECK(bones[0].Max.X == 4.0f);
	CHECK(bones[0].Max.Y == 5.0f);
	CHECK(bones[0].Max.Z == 1.0f);
}

TEST_CASE("w3d rig: a pivot outside the hierarchy is an error and adds nothing")
{
	std::vector<W3DBoneSkin> bones(2);
	std::string error;
	CHECK_FALSE(W3D_Add_Bone_Skin(mesh("ROCK", false, false, { 0, 0, 0 }), 2, bones, &error));
	CHECK(error == "mesh ROCK uses pivot 2 of a hierarchy with 2");
	MeshRenderData skin = mesh("CAPE", true, false, { 0, 0, 0, 1, 1, 1 });
	skin.Bone0 = { 1, 5 };
	skin.Weight0 = { 1.0f, 1.0f };
	CHECK_FALSE(W3D_Add_Bone_Skin(skin, -1, bones, &error));
	CHECK(error == "mesh CAPE uses pivot 5 of a hierarchy with 2");
	CHECK(bones[1].Vertices == 0); // the first vertex was valid, but nothing is added from a rejected mesh
}

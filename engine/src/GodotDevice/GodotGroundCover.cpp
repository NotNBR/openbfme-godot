// OpenBFME. GPL-3.0. Artistic grass, separate from retail simulation and object drawables.
#include "GodotDevice/GodotGroundCover.h"
#include "GameEngineDevice/W3DDevice/GameClient/HeightMapMesh.h"
#include "GameEngineDevice/W3DDevice/GameClient/TerrainComposite.h"
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <cmath>

namespace godot {
namespace {
float cross2(Vector2 a, Vector2 b) { return a.x * b.y - a.y * b.x; }
float segmentDistance(Vector2 p, Vector2 a, Vector2 b) {
	Vector2 d = b - a;
	float t = std::clamp((float)(p - a).dot(d) / std::max((float)d.length_squared(), 0.0001f), 0.0f, 1.0f);
	return (p - a - d * t).length();
}

struct Exclusions {
	int width, height, border;
	std::vector<uint8_t> pixels;
	Exclusions(const WorldHeightMap &m) : width(m.m_width * 2), height(m.m_height * 2), border(m.m_borderSize), pixels((size_t)width * height) {}
	void triangle(Vector2 a, Vector2 b, Vector2 c) {
		float loX = std::min({a.x, b.x, c.x}) - 3, hiX = std::max({a.x, b.x, c.x}) + 3;
		float loY = std::min({a.y, b.y, c.y}) - 3, hiY = std::max({a.y, b.y, c.y}) + 3;
		int x0 = std::max(0, (int)std::floor(loX / 5) + border * 2);
		int x1 = std::min(width - 1, (int)std::floor(hiX / 5) + border * 2);
		int y0 = std::max(0, (int)std::floor(loY / 5) + border * 2);
		int y1 = std::min(height - 1, (int)std::floor(hiY / 5) + border * 2);
		for (int y = y0; y <= y1; ++y) for (int x = x0; x <= x1; ++x) {
			Vector2 p((x - border * 2 + 0.5f) * 5, (y - border * 2 + 0.5f) * 5);
			float e0 = cross2(b - a, p - a), e1 = cross2(c - b, p - b), e2 = cross2(a - c, p - c);
			bool inside = (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0);
			if (inside || std::min({segmentDistance(p, a, b), segmentDistance(p, b, c), segmentDistance(p, c, a)}) < 3.6f)
				pixels[(size_t)y * width + x] = 1;
		}
	}
	bool blocked(float x, float y) const {
		int ix = (int)std::floor(x / 5) + border * 2, iy = (int)std::floor(y / 5) + border * 2;
		return ix < 0 || iy < 0 || ix >= width || iy >= height || pixels[(size_t)iy * width + ix];
	}
};

Ref<ArrayMesh> makeBlade() {
	PackedVector3Array positions, normals;
	PackedVector2Array uvs;
	PackedInt32Array indices;
	// One tapered, bent blade: five vertices, three opaque triangles. No clump image.
	for (Vector3 p : {Vector3(-0.5f, 0, 0), Vector3(0.5f, 0, 0), Vector3(-0.30f, 0.55f, 0.15f),
		Vector3(0.30f, 0.55f, 0.15f), Vector3(0, 1, 0.45f)}) {
		positions.push_back(p); normals.push_back(Vector3(0, 1, 0)); uvs.push_back(Vector2(0, p.y));
	}
	for (int i : {0, 1, 2, 1, 3, 2, 2, 3, 4}) indices.push_back(i);
	Array arrays; arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = positions; arrays[Mesh::ARRAY_NORMAL] = normals;
	arrays[Mesh::ARRAY_TEX_UV] = uvs; arrays[Mesh::ARRAY_INDEX] = indices;
	Ref<ArrayMesh> mesh; mesh.instantiate();
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	return mesh;
}

struct Layer {
	float u[4]{}, v[4]{}, alpha[4]{};
	ClassWrapRect wrap;
	bool flip = false, present = false;
};
Color sampleLayer(const Ref<Image> &mask, const Layer &layer, float x, float y) {
	float u = TerrainComposite::interpolateCorner(layer.u, layer.flip, x, y);
	float v = TerrainComposite::interpolateCorner(layer.v, layer.flip, x, y);
	if (layer.wrap.valid()) TerrainUv::wrapIntoClass(layer.wrap, u, v, u, v);
	return mask->get_pixel(std::clamp((int)(u * mask->get_width()), 0, mask->get_width() - 1),
		std::clamp((int)(v * mask->get_height()), 0, mask->get_height() - 1));
}
float coverage(const Ref<Image> &mask, const Layer &layer, float x, float y) { return sampleLayer(mask, layer, x, y).r; }
}

Node3D *buildGroundCover(const WorldHeightMap &map, const MapChunks &chunks,
	const TerrainLogic &terrain, const TerrainUvOptions &uvOptions, const Ref<Image> &meadowMask,
	const Ref<ShaderMaterial> &terrainMaterial, const std::vector<RoadStrip> &roads,
	bool enabled, Dictionary &report, String &error) {
	Ref<Shader> shader = ResourceLoader::get_singleton()->load("res://shaders/ground_cover.gdshader");
	Ref<Script> script = ResourceLoader::get_singleton()->load("res://scripts/ground_cover.gd");
	if (shader.is_null() || script.is_null()) { error = "ground-cover shader or patch-streaming script is missing"; return nullptr; }
	Ref<ShaderMaterial> material; material.instantiate(); material->set_shader(shader);
	for (const char *key : {"sun_dir_sage", "sun_color", "overbright", "fog_enabled", "fog_color", "fog_range_start", "fog_range_end"})
		material->set_shader_parameter(key, terrainMaterial->get_shader_parameter(key));
	material->set_meta("ground_cover", true);
	Exclusions exclusions(map);
	for (const RoadStrip &road : roads) for (size_t i = 0; i + 2 < road.index.size(); i += 3) {
		Vector2 p[3]; for (int k = 0; k < 3; ++k) { size_t j = road.index[i + k] * 3; p[k] = Vector2(road.position[j], road.position[j + 1]); }
		exclusions.triangle(p[0], p[1], p[2]);
	}
	for (const RiverArea &river : chunks.riverAreas) for (size_t i = 1; i < river.lines.size(); ++i) {
		const auto &a = river.lines[i - 1]; const auto &b = river.lines[i];
		exclusions.triangle(Vector2(a.x0, a.y0), Vector2(a.x1, a.y1), Vector2(b.x0, b.y0));
		exclusions.triangle(Vector2(a.x1, a.y1), Vector2(b.x1, b.y1), Vector2(b.x0, b.y0));
	}
	const GlobalLightingData *lighting = chunks.hasGlobalLighting ? &chunks.lighting : nullptr;
	Ref<Texture2D> atlasTexture = terrainMaterial->get_shader_parameter("base_atlas");
	Ref<Image> atlas = atlasTexture->get_image();
	Ref<Image> heights = Image::create_empty(map.m_width, map.m_height, false, Image::FORMAT_RF);
	Ref<Image> flips = Image::create_empty(map.m_width, map.m_height, false, Image::FORMAT_R8);
	Ref<Image> guide = Image::create_empty(map.m_width * 2, map.m_height * 2, false, Image::FORMAT_RGBA8);
	guide->fill(Color(0, 0, 0, 0)); flips->fill(Color(0, 0, 0));
	float minHeight = 1e9f, maxHeight = -1e9f;
	for (int y = 0; y < map.m_height; ++y) for (int x = 0; x < map.m_width; ++x) {
		float h = map.getHeight(x, y) * MAP_HEIGHT_SCALE;
		heights->set_pixel(x, y, Color(h, 0, 0));
		minHeight = std::min(minHeight, h); maxHeight = std::max(maxHeight, h);
	}
	int64_t rejectedRoadWater = 0, rejectedSlope = 0;
	for (int y = 0; y < map.m_height - 1; ++y)
	for (int x = 0; x < map.m_width - 1; ++x) {
		int cell = y * map.m_width + x;
		Layer layers[3]; layers[0].present = true;
		layers[0].flip = map.getUVData(x, y, layers[0].u, layers[0].v, uvOptions, &layers[0].wrap);
		flips->set_pixel(x, y, Color(layers[0].flip ? 1 : 0, 0, 0));
		if (x <= map.m_borderSize || y <= map.m_borderSize || x >= map.m_width-map.m_borderSize-2 || y >= map.m_height-map.m_borderSize-2) continue;
		uint8_t alpha[4];
		if (map.m_blendTileNdxes[cell]) {
			layers[1].present = true;
			map.getAlphaUVData(x, y, layers[1].u, layers[1].v, alpha, &layers[1].flip, uvOptions, &layers[1].wrap);
			for (int k = 0; k < 4; ++k) layers[1].alpha[k] = alpha[k] / 255.0f;
		}
		if (map.m_extraBlendTileNdxes[cell]) {
			bool cliff = false;
			layers[2].present = map.getExtraAlphaUVData(x, y, layers[2].u, layers[2].v, alpha, &layers[2].flip, &cliff, uvOptions, &layers[2].wrap);
			for (int k = 0; k < 4; ++k) layers[2].alpha[k] = alpha[k] / 255.0f;
		}
		for (int sy = 0; sy < 2; ++sy) for (int sx = 0; sx < 2; ++sx) {
			float fx = 0.25f + sx * 0.5f, fy = 0.25f + sy * 0.5f;
			float weight = coverage(meadowMask, layers[0], fx, fy);
			Color color = sampleLayer(atlas, layers[0], fx, fy);
			for (int k = 1; k < 3; ++k) if (layers[k].present) {
				float a = TerrainComposite::interpolateCorner(layers[k].alpha, layers[k].flip, fx, fy);
				weight += (coverage(meadowMask, layers[k], fx, fy) - weight) * a;
				color = color.lerp(sampleLayer(atlas, layers[k], fx, fy), a);
			}
			float wx = (x - map.m_borderSize + fx) * MAP_XY_FACTOR;
			float wy = (y - map.m_borderSize + fy) * MAP_XY_FACTOR;
			Coord3D normal; float z = terrain.getGroundHeight(wx, wy, &normal), water;
			if (exclusions.blocked(wx, wy) || (terrain.getStandingWaterHeight(wx, wy, water) && water >= z - 0.5f)) { weight = 0; ++rejectedRoadWater; }
			if (normal.z < 0.90f || map.getCliffState(x, y)) { weight = 0; ++rejectedSlope; }
			color.a = weight; guide->set_pixel(x * 2 + sx, y * 2 + sy, color);
		}
	}
	guide->generate_mipmaps();
	Ref<ImageTexture> guideTexture = ImageTexture::create_from_image(guide);
	material->set_shader_parameter("terrain_guide", guideTexture);
	// Grass fades in the transparent pass, like roads and rivers on the map GammaCompositeHost.
	material->set_shader_parameter("output_gamma", 1.0f);
	terrainMaterial->set_shader_parameter("terrain_guide", guideTexture);
	material->set_shader_parameter("height_map", ImageTexture::create_from_image(heights));
	material->set_shader_parameter("flip_map", ImageTexture::create_from_image(flips));
	Vector2 origin(-map.m_borderSize * MAP_XY_FACTOR, -map.m_borderSize * MAP_XY_FACTOR);
	material->set_shader_parameter("world_origin", origin);
	material->set_shader_parameter("grid_size", Vector2(map.m_width, map.m_height));
	terrainMaterial->set_shader_parameter("world_origin", origin);
	terrainMaterial->set_shader_parameter("grid_size", Vector2(map.m_width, map.m_height));
	uint8_t rgb[3] = {128, 128, 128};
	if (lighting) HeightMapMesh::staticDiffuseAt(map, lighting, VERTEX_COLOR_AMBIENT_PLUS_ACCENT_LIGHTS, map.m_width/2, map.m_height/2, rgb);
	material->set_shader_parameter("ambient_color", Vector3(rgb[0]/255.0f, rgb[1]/255.0f, rgb[2]/255.0f));
	Node3D *root = memnew(Node3D);
	root->set_name("GroundCover"); root->set_script(script);
	root->set("terrain_material", terrainMaterial); root->set("height_image", heights); root->set("world_origin", origin); root->set("enabled", enabled);
	root->set_meta("ground_cover", true);
	Ref<ArrayMesh> mesh = makeBlade();
	// Share two immutable instance buffers across the frustum-driven patch pool.
	const int side = 16, count = 4096;
	Ref<MultiMesh> batches[2];
	for (int layer = 0; layer < 2; ++layer) {
		Ref<MultiMesh> batch; batch.instantiate(); batch->set_transform_format(MultiMesh::TRANSFORM_3D);
		batch->set_mesh(mesh); batch->set_instance_count(count); batch->set_visible_instance_count(0);
		for (int j = 0; j < count; ++j) batch->set_instance_transform(j, Transform3D());
		batch->set_custom_aabb(AABB(Vector3(-5, minHeight-1, -5), Vector3(layer == 0 ? 42 : 138, maxHeight-minHeight+12, layer == 0 ? 42 : 138)));
		batches[layer] = batch;
	}
	for (int i = 0; i < side * side * 2; ++i) {
		MultiMeshInstance3D *node = memnew(MultiMeshInstance3D); node->set_multimesh(batches[i / (side*side)]);
		node->set_material_override(material); node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		node->set_name(String("GrassPatch_") + String::num_int64(i)); root->add_child(node);
	}
	report["enabled"] = enabled; report["instances"] = side*side*2*count; report["patches"] = side*side*2;
	report["shared_instance_slots"] = count*2; report["screen_size_lod"] = true;
	report["camera_local"] = true; report["triangles_per_blade"] = 3;
	report["rejected_road_water"] = rejectedRoadWater; report["rejected_slope"] = rejectedSlope;
	return root;
}
}

# Player house-colour rendering

Ordinary player colours now use the same per-texel recolouring path as custom
heroes. Live animated models, static draw modules (including building floors)
and map previews cache model variants by palette. House textures stored as
compiled JPEG plus PNG alpha are decoded through the existing packed-image
loader; ordinary model texture lookup precedence is unchanged. Changing a drawable's owner
colour switches its variant; a custom hero palette keeps precedence. The
`house_colors` option still disables this presentation feature.

Donor evidence from Open-BFME-2:

- `W3DModelDrawRva000B8FA1.cpp`, BFME2 VA 0x4B8FA1: read the controlling
  player's colour and pass kind 1, that colour and two zero colours to the
  render object's house-colour setter.
- `MeshClassRecolorPrototype.cpp`, BFME2 VA 0x54B8C0: a mesh part whose name
  begins with HOUSECOLOR, case-insensitive, receives primary-colour ambient
  and diffuse materials. The part is the text after the first dot, or the
  whole name when there is no dot. Our channel unpacking uses the existing
  target ARGB convention rather than the donor's address-derived ABI casts.
- `reverse/attempts/0x0014c470.cpp`, BFME2 VA 0x54C470: recoloured textures
  are identified by texture and palette, and classic meshes use a second
  texture stage. This is an attempted reconstruction, not additional proof
  of every effect permutation.
- `ShaderClassApply.cpp` maps the house-colour detail operation to texture-alpha
  blending. `MeshMatDescFXShaderConversion.cpp` maps detail mode 13 to
  HouseColorEnable. Neither establishes the complete RotWK effect path.

The shared recolour routine was already ported from RotWK 0x531C77 (BFME2
0x5321A7): kind 1 multiplies the house texture's red byte by each colour
channel, shifts each product right by eight, and retains alpha. Kinds 2 and 3
also accumulate the green/blue channel contributions, with saturation. Baking
runs before texture filtering, using the existing mipmap behavior. Ordinary
player colours previously multiplied the base texture by the team colour under
the house texture's alpha, ignoring its RGB shading.

Remaining limits are explicit under S-119 / S-022: the baked texture's final
alpha replacement in our shader is still inferred for RotWK; the donor's
HOUSECOLOR material behavior has not been independently verified in RotWK;
and effect-annotated FX recolouring is not newly implemented. The old per-instance
approximation remains available to callers that explicitly request it. This is
not a claim of pixel-identical retail rendering.

Validation includes `test_cah2.cpp` (palette precedence, packed black, name
classification and texel arithmetic), the shader-text suite, and
`godot/tests/player_house_color_test.gd`. The latter starts a seeded match,
checks distinct unit/building variants for two players, and reads back a real
unit's green-only baked house texture to verify its RGB channels.

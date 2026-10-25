# Terrain sunlight

An integration error reduced terrain sunlight. The retail terrain.fxo
MainDirectionalLight parameter binds Sas.DirectionalLight[0]. The colour
callback RW 0x54CFD0 doubles the RGB channels when RW 0xD9B03C is set
(0x54D001..0x54D03B); the terrain effect then halves that input in its
overbright preshader. Godot supplied raw map diffuse before that halving,
leaving the main sun at half strength. The builder now shares the same
version-gated effect colour scale as object lighting. Vertex ambient/accent
colours and the shader's existing half/double operations are unchanged.

Tests pin the retail SAS binding and callback instructions, exercise the
version/multiplier gate, and verify the scaled sun on all Harlindon terrain
materials. A Metal capture was inspected after the correction. Standing water
remains the simplified S-035 implementation, including Harlindon's missing
SkyEnv.tga; this change does not establish water-rendering parity.

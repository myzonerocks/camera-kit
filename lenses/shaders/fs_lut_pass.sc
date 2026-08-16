$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texLut, 1);

// A lut.pass node's fixed color-grading shader: samples a square strip
// LUT (an 8x8 grid of 64x64 tiles, one tile per blue level) rather than
// a true 3D texture, since a lens ships its LUT as a plain PNG. Blue
// picks the tile (nearest, not interpolated between adjacent tiles);
// red and green address within that tile, letting the sampler's own
// bilinear filtering smooth those two axes.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);

	const float grid = 8.0;
	const float tile = 64.0;

	float blueIndex = floor(color.b * (tile - 1.0) + 0.5);
	float tileX = mod(blueIndex, grid);
	float tileY = floor(blueIndex / grid);

	vec2 within = color.rg * (tile - 1.0) + 0.5;
	vec2 lutUv = (vec2(tileX, tileY) * tile + within) / (grid * tile);

	vec4 graded = texture2D(s_texLut, lutUv);
	gl_FragColor = vec4(graded.rgb, color.a);
}

$input a_position, a_texcoord0
$output v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_particleSize;

// Expands a particle centre into one camera-facing quad corner: a_texcoord0.x
// is the remaining-life fraction, a_texcoord0.y a corner index 0..3. The
// centre projects, then the corner offsets it in clip space by the half-size
// (u_particleSize.xy, ndc per axis) so the sprite holds a fixed pixel size.
void main()
{
	vec4 clip = mul(u_modelViewProj, vec4(a_position, 1.0));
	float ci = a_texcoord0.y;
	float cx = (ci > 0.5 && ci < 2.5) ? 1.0 : -1.0;
	float cy = (ci > 1.5) ? 1.0 : -1.0;
	vec2 corner = vec2(cx, cy);
	clip.xy += corner * u_particleSize.xy * clip.w;
	gl_Position = clip;
	v_billboard = vec4(corner, a_texcoord0.x, 0.0);
}

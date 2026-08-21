$input a_position, a_texcoord0
$output v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_particleSize;

// Expands a particle centre into one camera-facing quad corner: a_texcoord0.x
// is the corner index 0..3, .y the remaining-life fraction, .z a per-particle
// spin seed. The corner is scaled by the life-interpolated size (u_particleSize
// z is the size-at-death ratio), rotated by the seed plus u_particleSize.w
// turns over age, and offset in clip space by the ndc half-size (xy).
void main()
{
	vec4 clip = mul(u_modelViewProj, vec4(a_position, 1.0));
	float ci = a_texcoord0.x;
	float life = a_texcoord0.y;
	float seed = a_texcoord0.z;
	float cx = (ci > 0.5 && ci < 2.5) ? 1.0 : -1.0;
	float cy = (ci > 1.5) ? 1.0 : -1.0;
	vec2 corner = vec2(cx, cy);
	float sizeScale = mix(u_particleSize.z, 1.0, life);
	float ang = (seed + u_particleSize.w * (1.0 - life)) * 6.2831853;
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 rc = vec2(corner.x * ca - corner.y * sa, corner.x * sa + corner.y * ca);
	clip.xy += rc * u_particleSize.xy * sizeScale * clip.w;
	gl_Position = clip;
	v_billboard = vec4(corner, life, 0.0);
}

$input a_position, a_texcoord0, a_texcoord1
$output v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_particleSize;
uniform vec4 u_particleFx;

// Expands a particle centre into one camera-facing quad corner: a_texcoord0 is
// (corner index, life, spin seed), a_texcoord1 the world velocity. The corner
// scales by the life-interpolated size, then stretches along the screen
// velocity (u_particleFx.z) for streaks or spins (seed + u_particleSize.w).
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
	vec2 offset;
	if (u_particleFx.z > 0.0) {
		vec4 clipV = mul(u_modelViewProj, vec4(a_position + vec3(a_texcoord1, 0.0), 1.0));
		vec2 sv = clipV.xy / clipV.w - clip.xy / clip.w;
		float sp = length(sv);
		vec2 dir = (sp > 1e-4) ? sv / sp : vec2(0.0, 1.0);
		vec2 perp = vec2(-dir.y, dir.x);
		float amt = 1.0 + u_particleFx.z * sp * 8.0;
		offset = (corner.x * perp * u_particleSize.x + corner.y * dir * u_particleSize.y * amt) * sizeScale;
	} else {
		float ang = (seed + u_particleSize.w * (1.0 - life)) * 6.2831853;
		float ca = cos(ang);
		float sa = sin(ang);
		vec2 rc = vec2(corner.x * ca - corner.y * sa, corner.x * sa + corner.y * ca);
		offset = rc * u_particleSize.xy * sizeScale;
	}
	clip.xy += offset * clip.w;
	gl_Position = clip;
	v_billboard = vec4(corner, life, 0.0);
}

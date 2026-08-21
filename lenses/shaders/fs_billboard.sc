$input v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
uniform vec4 u_particleCool;
SAMPLER2D(s_texSprite, 0);

// A camera-facing particle sprite: v_billboard.xy is the corner in -1..1, .z
// the remaining-life fraction. A soft round falloff shapes the point, its
// rgb crossing from the node colour toward u_particleCool over life; the
// sprite texture (a white default, or the lens's own image) modulates both.
void main()
{
	vec2 corner = v_billboard.xy;
	float life = v_billboard.z;
	float falloff = 1.0 - smoothstep(0.6, 1.0, length(corner));
	vec4 sprite = texture2D(s_texSprite, corner * 0.5 + 0.5);
	vec3 rgb = mix(u_particleCool.rgb, u_modelColor.rgb, life) * sprite.rgb;
	gl_FragColor = vec4(rgb, u_modelColor.a * life * falloff * sprite.a);
}

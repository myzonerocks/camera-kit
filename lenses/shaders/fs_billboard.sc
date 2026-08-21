$input v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
uniform vec4 u_particleCool;

// A camera-facing particle sprite: v_billboard.xy is the corner in -1..1, .z
// the remaining-life fraction. A soft round falloff from the corner distance
// shapes the point, its rgb crossing from the node colour to u_particleCool
// over life and its alpha fading out, alpha-blended over the frame.
void main()
{
	vec2 corner = v_billboard.xy;
	float life = v_billboard.z;
	float d = length(corner);
	float falloff = 1.0 - smoothstep(0.6, 1.0, d);
	vec3 rgb = mix(u_particleCool.rgb, u_modelColor.rgb, life);
	gl_FragColor = vec4(rgb, u_modelColor.a * life * falloff);
}

$input v_texcoord0

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
uniform vec4 u_particleCool;

// A fading particle point: alpha scaled by the remaining-life fraction
// (v_texcoord0.x from writeFaded) so it dims to nothing as it ages, and rgb
// crossing from the node colour at birth toward u_particleCool at death (an
// ember cooling). u_particleCool equals u_modelColor when the lens sets none.
void main()
{
	vec3 rgb = mix(u_particleCool.rgb, u_modelColor.rgb, v_texcoord0.x);
	gl_FragColor = vec4(rgb, u_modelColor.a * v_texcoord0.x);
}

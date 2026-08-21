$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texBloom, 1);
uniform vec4 u_bloom;

// bloom.pass's composite stage: add the blurred bright pass back over
// the original frame, scaled by intensity (u_bloom.y), so highlights
// bleed a soft glow into their surroundings without dimming the base.
void main()
{
	vec4 base = texture2D(s_texColor, v_texcoord0);
	vec3 glow = texture2D(s_texBloom, v_texcoord0).rgb;
	gl_FragColor = vec4(clamp(base.rgb + glow * u_bloom.y, 0.0, 1.0), base.a);
}

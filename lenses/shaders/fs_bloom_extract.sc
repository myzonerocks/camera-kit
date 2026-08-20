$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_bloom;

// bloom.pass's bright-extract stage: keep only what sits above the
// threshold (u_bloom.x), scaled by how far above it sits, so the blur
// and composite stages spread a soft glow from the highlights alone.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
	float k = max(luma - u_bloom.x, 0.0);
	gl_FragColor = vec4(color.rgb * k, 1.0);
}

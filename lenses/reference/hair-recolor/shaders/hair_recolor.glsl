$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMask, 2);

void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	float hair = texture2D(s_texMask, v_texcoord0).r;
	// A cool violet shift, luminance-preserving, faded in by the mask.
	float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
	vec3 recolored = vec3(luma * 0.75, luma * 0.45, luma * 1.35);
	gl_FragColor = vec4(mix(color.rgb, recolored, hair * 0.85), color.a);
}

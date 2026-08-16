$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);

void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	gl_FragColor = vec4(color.rgb * vec3(1.15, 0.95, 0.8), color.a);
}

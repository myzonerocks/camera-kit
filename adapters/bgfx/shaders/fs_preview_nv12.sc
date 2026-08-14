$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texY, 0);
SAMPLER2D(s_texUV, 1);

uniform mat4 u_yuvTransform;

void main()
{
	float y = texture2D(s_texY, v_texcoord0).r;
	vec2 uv = texture2D(s_texUV, v_texcoord0).rg;
	vec3 rgb = mul(u_yuvTransform, vec4(y, uv.x, uv.y, 1.0) ).rgb;
	gl_FragColor = vec4(rgb, 1.0);
}

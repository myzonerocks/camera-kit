#include "bgfx_compute.sh"

SAMPLER2D(s_texY,  0);
SAMPLER2D(s_texUV, 1);
IMAGE2D_WO(i_rgba, rgba8, 2);

uniform mat4 u_yuvTransform;

NUM_THREADS(8, 8, 1)
void main()
{
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(i_rgba);
	if (xy.x >= size.x || xy.y >= size.y)
	{
		return;
	}
	vec2 uv = (vec2(xy) + vec2_splat(0.5) ) / vec2(size);
	float y = texture2DLod(s_texY, uv, 0.0).r;
	vec2 cbcr = texture2DLod(s_texUV, uv, 0.0).rg;
	vec3 rgb = mul(u_yuvTransform, vec4(y, cbcr.x, cbcr.y, 1.0) ).rgb;
	imageStore(i_rgba, xy, vec4(rgb, 1.0) );
}

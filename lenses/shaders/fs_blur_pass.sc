$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_blurStep;

// A 9-tap box blur, radius 4, weight 1/9 each - matching gpupixel's own
// BoxMonoBlurFilter at its default radius. Run once with u_blurStep set
// to the horizontal per-tap UV offset and once with it set to the
// vertical offset, the same program serving both directions of a full
// separable blur. beauty.face's smooth effect blends toward this
// output, not the raw frame.
void main()
{
	vec3 sum = vec3_splat(0.0);
	for (int i = -4; i <= 4; i++)
	{
		sum += texture2D(s_texColor, v_texcoord0 + u_blurStep.xy * float(i)).rgb;
	}
	gl_FragColor = vec4(sum / 9.0, 1.0);
}

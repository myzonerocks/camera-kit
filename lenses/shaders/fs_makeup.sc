$input v_backgroundUv, v_makeupUv

#include <bgfx_shader.sh>

SAMPLER2D(s_texBackground, 0);
SAMPLER2D(s_texMakeup, 1);
uniform vec4 u_makeupParams; // x: intensity

// beauty.lipstick/beauty.blusher's own blend, verbatim from gpupixel's
// face_makeup_filter.cc: fully transparent makeup pixels pass the
// background through unchanged; everywhere else is a straight multiply
// blend, unpremultiplying the makeup color by its own alpha first so
// the intensity scale doesn't also darken already-transparent edges.
void main()
{
	vec4 fgColor = texture2D(s_texMakeup, v_makeupUv) * u_makeupParams.x;
	vec4 bgColor = texture2D(s_texBackground, v_backgroundUv);
	if (fgColor.a == 0.0)
	{
		gl_FragColor = bgColor;
		return;
	}
	vec3 blended = bgColor.rgb * clamp(fgColor.rgb / fgColor.a, 0.0, 1.0);
	gl_FragColor = vec4(bgColor.rgb * (1.0 - fgColor.a) + blended * fgColor.a, 1.0);
}

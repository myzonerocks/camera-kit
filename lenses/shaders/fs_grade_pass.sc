$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_grade;

// A grade.pass node's parametric color grade: exposure, contrast,
// saturation and temperature packed into u_grade and applied in that
// order, so a lens can warm, cool, brighten or push contrast without
// authoring a LUT. All-default (0,1,1,0) leaves the frame untouched.
void main()
{
	vec4 color = texture2D(s_texColor, v_texcoord0);
	vec3 rgb = color.rgb;

	float exposure = u_grade.x;
	float contrast = u_grade.y;
	float saturation = u_grade.z;
	float temperature = u_grade.w;

	rgb *= exp2(exposure);
	rgb = (rgb - 0.5) * contrast + 0.5;
	rgb += vec3(temperature, 0.0, -temperature);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb = mix(vec3_splat(luma), rgb, saturation);

	gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), color.a);
}

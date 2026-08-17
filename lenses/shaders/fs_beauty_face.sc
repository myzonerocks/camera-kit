$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
SAMPLER2D(s_texMean, 1);
SAMPLER2D(s_texLookupGray, 2);
SAMPLER2D(s_texLookupOrigin, 3);
SAMPLER2D(s_texLookupSkin, 4);
SAMPLER2D(s_texLookupCustom, 5);
uniform vec4 u_beautyParams; // x: smooth amount, y: whiten amount

// beauty.face's two effects, combined in one pass since both read the
// same frame sample: skin-smoothing and whitening, both verbatim ports
// of gpupixel's own beauty_face_unit_filter.cc.
void main()
{
	vec4 iColor = texture2D(s_texColor, v_texcoord0);
	vec3 color = iColor.rgb;
	float amountSmooth = u_beautyParams.x;
	float amountWhiten = u_beautyParams.y;

	// Blends toward a wide separable blur of the frame (fs_blur_pass.sc's
	// output); how strongly a pixel blends depends on both how flat that
	// area already is (low local variance, estimated from the difference
	// between the frame and its own blur) and how close it sits to
	// mid-tone, so edges and shadows resist smoothing while flat skin
	// doesn't.
	if (amountSmooth > 0.0)
	{
		vec3 meanColor = texture2D(s_texMean, v_texcoord0).rgb;
		vec3 diff = (iColor.rgb - meanColor) * 7.07;
		diff = min(diff * diff, vec3_splat(1.0));
		float theta = 0.1;
		float p = clamp((min(iColor.r, meanColor.r - 0.1) - 0.2) * 4.0, 0.0, 1.0);
		float meanVar = (diff.r + diff.g + diff.b) / 3.0;
		float kMin = clamp((1.0 - meanVar / (meanVar + theta)) * p * amountSmooth, 0.0, 1.0);
		color = mix(iColor.rgb, meanColor, kMin);
	}

	if (amountWhiten > 0.0)
	{
		const float levelRangeInv = 1.02657;
		const float levelBlack = 0.0258820;
		const float alpha = 0.7;

		vec3 colorEPM = color;
		color = clamp((colorEPM - vec3_splat(levelBlack)) * levelRangeInv, 0.0, 1.0);
		vec3 texel = vec3(
			texture2D(s_texLookupGray, vec2(color.r, 0.5)).r,
			texture2D(s_texLookupGray, vec2(color.g, 0.5)).g,
			texture2D(s_texLookupGray, vec2(color.b, 0.5)).b
		);
		texel = mix(color, texel, 0.5);
		texel = mix(colorEPM, texel, alpha);

		texel = clamp(texel, 0.0, 1.0);
		float blueColor = texel.b * 15.0;
		vec2 quad1;
		quad1.y = floor(floor(blueColor) * 0.25);
		quad1.x = floor(blueColor) - (quad1.y * 4.0);
		vec2 quad2;
		quad2.y = floor(ceil(blueColor) * 0.25);
		quad2.x = ceil(blueColor) - (quad2.y * 4.0);
		vec2 texPos2 = texel.rg * 0.234375 + 0.0078125;
		vec2 texPos1 = quad1 * 0.25 + texPos2;
		texPos2 = quad2 * 0.25 + texPos2;
		vec3 newColor1Origin = texture2D(s_texLookupOrigin, texPos1).rgb;
		vec3 newColor2Origin = texture2D(s_texLookupOrigin, texPos2).rgb;
		vec3 colorOrigin = mix(newColor1Origin, newColor2Origin, fract(blueColor));
		texel = mix(colorOrigin, color, alpha);

		texel = clamp(texel, 0.0, 1.0);
		blueColor = texel.b * 15.0;
		quad1.y = floor(floor(blueColor) * 0.25);
		quad1.x = floor(blueColor) - (quad1.y * 4.0);
		quad2.y = floor(ceil(blueColor) * 0.25);
		quad2.x = ceil(blueColor) - (quad2.y * 4.0);
		texPos2 = texel.rg * 0.234375 + 0.0078125;
		texPos1 = quad1 * 0.25 + texPos2;
		texPos2 = quad2 * 0.25 + texPos2;
		vec3 newColor1 = texture2D(s_texLookupSkin, texPos1).rgb;
		vec3 newColor2 = texture2D(s_texLookupSkin, texPos2).rgb;
		color = mix(newColor1, newColor2, fract(blueColor));
		color = clamp(color, 0.0, 1.0);

		float blueColorCustom = color.b * 63.0;
		vec2 quad1Custom;
		quad1Custom.y = floor(floor(blueColorCustom) / 8.0);
		quad1Custom.x = floor(blueColorCustom) - (quad1Custom.y * 8.0);
		vec2 quad2Custom;
		quad2Custom.y = floor(ceil(blueColorCustom) / 8.0);
		quad2Custom.x = ceil(blueColorCustom) - (quad2Custom.y * 8.0);
		vec2 texPos1Custom;
		texPos1Custom.x = (quad1Custom.x / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.r);
		texPos1Custom.y = (quad1Custom.y / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.g);
		vec2 texPos2Custom;
		texPos2Custom.x = (quad2Custom.x / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.r);
		texPos2Custom.y = (quad2Custom.y / 8.0) + 0.5 / 512.0 + ((1.0 / 8.0 - 1.0 / 512.0) * color.g);
		newColor1 = texture2D(s_texLookupCustom, texPos1Custom).rgb;
		newColor2 = texture2D(s_texLookupCustom, texPos2Custom).rgb;
		vec3 colorCustom = mix(newColor1, newColor2, fract(blueColorCustom));
		color = mix(color, colorCustom, amountWhiten);
	}

	gl_FragColor = vec4(color, iColor.a);
}

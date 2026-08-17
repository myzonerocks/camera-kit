$input v_texcoord0

#include <bgfx_shader.sh>

SAMPLER2D(s_texColor, 0);
uniform vec4 u_reshapeParams; // x: aspect ratio, y: thin_face amount, z: big_eye amount
uniform vec4 u_facePoints[53]; // 106 tracked points, two per vec4 (xy, zw)

// A verbatim port of gpupixel's own face-reshape math
// (face_reshape_filter.cc): each pair below names two of the 106
// contour points as a curve's origin and target - thin-face pulls
// jawline points inward toward its cheek/chin targets, big-eye pushes
// texture samples outward from each eye's own center, both scaled by
// distance so the warp fades out away from the point pair it's
// anchored to.

vec2 curveWarp(vec2 textureCoord, vec2 originPosition, vec2 targetPosition, float delta, float aspectRatio)
{
	vec2 direction = (targetPosition - originPosition) * delta;
	float radius = distance(vec2(targetPosition.x, targetPosition.y / aspectRatio), vec2(originPosition.x, originPosition.y / aspectRatio));
	float ratio = distance(vec2(textureCoord.x, textureCoord.y / aspectRatio), vec2(originPosition.x, originPosition.y / aspectRatio)) / radius;
	ratio = clamp(1.0 - ratio, 0.0, 1.0);
	return textureCoord - direction * ratio;
}

vec2 enlargeEye(vec2 textureCoord, vec2 originPosition, float radius, float delta, float aspectRatio)
{
	float weight = distance(vec2(textureCoord.x, textureCoord.y / aspectRatio), vec2(originPosition.x, originPosition.y / aspectRatio)) / radius;
	weight = 1.0 - (1.0 - weight * weight) * delta;
	weight = clamp(weight, 0.0, 1.0);
	return originPosition + (textureCoord - originPosition) * weight;
}

// Each origin/target pair below is the same contour-point indexing
// facePoint(int) used to do at runtime (u_facePoints[index / 2].xy or
// .zw, picked by whether index is even or odd), unrolled here as
// literal, compile-time-constant array indices instead. GLSL ES 3.00
// restricts dynamic (non-constant, non-loop-index) indexing of a
// uniform array more than desktop GL does on some drivers; this shader
// compiled clean under shaderc for every platform/profile including
// essl_web, but that doesn't rule out a runtime-only restriction this
// project has no GPU-side capture tooling to check directly. Real,
// testable experiment either way - proves or disproves this specific
// theory rather than guessing at it.
vec2 thinFace(vec2 coord, float amount, float aspectRatio)
{
	coord = curveWarp(coord, u_facePoints[1].zw, u_facePoints[22].xy, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[14].zw, u_facePoints[22].xy, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[3].zw, u_facePoints[22].zw, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[12].zw, u_facePoints[22].zw, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[5].xy, u_facePoints[23].xy, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[11].xy, u_facePoints[23].xy, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[7].xy, u_facePoints[24].zw, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[9].xy, u_facePoints[24].zw, amount, aspectRatio);
	coord = curveWarp(coord, u_facePoints[8].xy, u_facePoints[24].zw, amount, aspectRatio);
	return coord;
}

vec2 bigEye(vec2 coord, float amount, float aspectRatio)
{
	{
		vec2 originPoint = u_facePoints[37].xy;
		vec2 targetPoint = u_facePoints[36].xy;
		float radius = distance(vec2(targetPoint.x, targetPoint.y / aspectRatio), vec2(originPoint.x, originPoint.y / aspectRatio)) * 5.0;
		coord = enlargeEye(coord, originPoint, radius, amount, aspectRatio);
	}
	{
		vec2 originPoint = u_facePoints[38].zw;
		vec2 targetPoint = u_facePoints[37].zw;
		float radius = distance(vec2(targetPoint.x, targetPoint.y / aspectRatio), vec2(originPoint.x, originPoint.y / aspectRatio)) * 5.0;
		coord = enlargeEye(coord, originPoint, radius, amount, aspectRatio);
	}
	return coord;
}

void main()
{
	float aspectRatio = u_reshapeParams.x;
	float amountThinFace = u_reshapeParams.y;
	float amountBigEye = u_reshapeParams.z;

	vec2 sampleUv = v_texcoord0;
	sampleUv = thinFace(sampleUv, amountThinFace, aspectRatio);
	sampleUv = bigEye(sampleUv, amountBigEye, aspectRatio);

	gl_FragColor = texture2D(s_texColor, sampleUv);
}

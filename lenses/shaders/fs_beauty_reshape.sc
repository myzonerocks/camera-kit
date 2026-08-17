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

vec2 facePoint(int index)
{
	vec4 pointPair = u_facePoints[index / 2];
	return (index / 2) * 2 == index ? pointPair.xy : pointPair.zw;
}

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

vec2 thinFace(vec2 coord, float amount, float aspectRatio)
{
	int origins[9];
	origins[0] = 3; origins[1] = 29; origins[2] = 7; origins[3] = 25; origins[4] = 10;
	origins[5] = 22; origins[6] = 14; origins[7] = 18; origins[8] = 16;
	int targets[9];
	targets[0] = 44; targets[1] = 44; targets[2] = 45; targets[3] = 45; targets[4] = 46;
	targets[5] = 46; targets[6] = 49; targets[7] = 49; targets[8] = 49;
	for (int i = 0; i < 9; i++)
	{
		coord = curveWarp(coord, facePoint(origins[i]), facePoint(targets[i]), amount, aspectRatio);
	}
	return coord;
}

vec2 bigEye(vec2 coord, float amount, float aspectRatio)
{
	int origins[2];
	origins[0] = 74; origins[1] = 77;
	int targets[2];
	targets[0] = 72; targets[1] = 75;
	for (int i = 0; i < 2; i++)
	{
		vec2 originPoint = facePoint(origins[i]);
		vec2 targetPoint = facePoint(targets[i]);
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

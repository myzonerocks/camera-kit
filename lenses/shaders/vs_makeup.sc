$input a_position, a_texcoord1
$output v_backgroundUv, v_makeupUv

#include <bgfx_shader.sh>

// beauty.lipstick/beauty.blusher's own mesh vertex stage: a_position is
// the live tracked landmark in 0-1 UV space, doubling as both the
// clip-space position (after the same manual NDC remap shells/ts's own
// proven WebGL2 version uses, not bgfx's usual MVP uniform - there is
// no model to transform, only a flat mesh already in UV space) and the
// background sample point, so the mesh reads the frame at exactly the
// screen position it draws over. a_texcoord1 is the mesh's own fixed
// UV into the makeup source image (bgfx's vertex attribute names are a
// closed set - a_texcoord1 rather than a more descriptive name).
void main()
{
	vec2 ndc = vec2(a_position.x * 2.0 - 1.0, 1.0 - a_position.y * 2.0);
	gl_Position = vec4(ndc, 0.0, 1.0);
	v_backgroundUv = a_position;
	v_makeupUv = a_texcoord1;
}

$input v_texcoord0

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;

// A fading particle point: the node's colour with its alpha scaled by the
// point's remaining-life fraction (carried in v_texcoord0.x by writeFaded),
// so a point dims to nothing as it ages instead of popping out when it
// respawns. Alpha-blended over the frame by the caller's draw state.
void main()
{
	gl_FragColor = vec4(u_modelColor.rgb, u_modelColor.a * v_texcoord0.x);
}

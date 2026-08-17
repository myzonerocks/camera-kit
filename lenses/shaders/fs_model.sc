$input v_texcoord0

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;

// model.gltf's own fragment stage: a flat, unlit fill from the node's
// material base_color_factor (or white with no material) - v_texcoord0
// is unused, carried only because the mesh reuses vs_lens_pass.sc's
// vertex layout rather than needing its own.
void main()
{
	gl_FragColor = u_modelColor;
}

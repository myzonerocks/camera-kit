$input v_billboard

#include <bgfx_shader.sh>

uniform vec4 u_modelColor;
uniform vec4 u_particleCool;
uniform vec4 u_particleFx;
SAMPLER2D(s_texSprite, 0);

// A camera-facing particle sprite: v_billboard.xy is the corner, .z the life.
// A soft round falloff shapes it, modulated by the sprite texture (flip-booking
// through a u_particleFx.x-frame square sheet of side u_particleFx.y over life);
// rgb crosses to u_particleCool over life and alpha fades out.
void main()
{
	vec2 corner = v_billboard.xy;
	float life = v_billboard.z;
	float falloff = 1.0 - smoothstep(0.6, 1.0, length(corner));
	vec2 uv = corner * 0.5 + 0.5;
	float dim = max(u_particleFx.y, 1.0);
	if (dim > 1.0) {
		float frames = max(u_particleFx.x, 1.0);
		float frame = min(floor((1.0 - life) * frames), frames - 1.0);
		vec2 cell = vec2(mod(frame, dim), floor(frame / dim));
		uv = (uv + cell) / dim;
	}
	vec4 sprite = texture2D(s_texSprite, uv);
	vec3 rgb = mix(u_particleCool.rgb, u_modelColor.rgb, life) * sprite.rgb;
	gl_FragColor = vec4(rgb, u_modelColor.a * life * falloff * sprite.a);
}

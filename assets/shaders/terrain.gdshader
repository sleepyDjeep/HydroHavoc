shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley;

uniform vec4 lowland_color : source_color = vec4(0.24, 0.42, 0.22, 1.0); // Earthy green
uniform vec4 cliff_color : source_color = vec4(0.38, 0.35, 0.32, 1.0);   // Rocky grey
uniform vec4 wall_top_color : source_color = vec4(0.32, 0.65, 0.28, 1.0); // Fresh bright grass
uniform vec4 grid_line_color : source_color = vec4(0.12, 0.22, 0.12, 0.4);
uniform float grid_line_width : hint_range(0.01, 0.2) = 0.05;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Slope detection (dot product with up vector)
	float slope = clamp(dot(world_normal, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);

	// Height ramp
	float h = clamp(world_pos.y / 6.0, 0.0, 1.0);
	vec3 base_flat = mix(lowland_color.rgb, wall_top_color.rgb, h);

	// Blend cliff color on steep slopes
	vec3 terrain_col = mix(cliff_color.rgb, base_flat, smoothstep(0.4, 0.8, slope));

	// Subtle grid line pattern for arcade placement feedback
	vec2 grid_uv = fract(world_pos.xz + 0.5);
	vec2 grid_dist = abs(grid_uv - 0.5);
	float edge = max(grid_dist.x, grid_dist.y);
	float grid_mask = smoothstep(0.5 - grid_line_width, 0.5, edge);

	vec3 final_color = mix(terrain_col, grid_line_color.rgb, grid_mask * grid_line_color.a);

	ALBEDO = final_color;
	ROUGHNESS = roughness;
	METALLIC = 0.05;
}

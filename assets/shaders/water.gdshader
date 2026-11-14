shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.08, 0.55, 0.88, 0.85);
uniform vec4 foam_color : source_color = vec4(0.85, 0.98, 1.0, 0.95);
uniform vec4 deep_color : source_color = vec4(0.02, 0.18, 0.45, 0.95);
uniform float metallic : hint_range(0.0, 1.0) = 0.1;
uniform float roughness : hint_range(0.0, 1.0) = 0.15;
uniform float wave_speed : hint_range(0.0, 5.0) = 1.2;
uniform float wave_amplitude : hint_range(0.0, 0.5) = 0.04;
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.25;

void vertex() {
	// Gentle wave displacement
	float wave1 = sin(VERTEX.x * 2.5 + TIME * wave_speed) * cos(VERTEX.z * 2.5 + TIME * wave_speed * 0.8);
	float wave2 = sin(VERTEX.x * 4.0 - TIME * wave_speed * 1.2) * 0.5;
	VERTEX.y += (wave1 + wave2) * wave_amplitude;
}

void fragment() {
	// Animated surface normals for water ripple
	float ripple1 = sin(UV.x * 30.0 + TIME * wave_speed * 2.0) * cos(UV.y * 30.0 + TIME * wave_speed);
	float ripple2 = cos(UV.x * 20.0 - TIME * wave_speed) * sin(UV.y * 25.0 + TIME * wave_speed * 1.5);
	vec3 norm_offset = vec3(ripple1 * 0.08, 1.0, ripple2 * 0.08);
	NORMAL = normalize(NORMAL + norm_offset);

	// Edge foam proximity based on UV border / height
	float edge_dist = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float foam_factor = smoothstep(foam_threshold, 0.01, edge_dist);

	// Blend shallow water to deep water with foam highlights
	vec4 base = mix(water_color, deep_color, 0.35);
	vec4 final_color = mix(base, foam_color, foam_factor * 0.65);

	ALBEDO = final_color.rgb;
	ALPHA = final_color.a;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = 0.6;
}

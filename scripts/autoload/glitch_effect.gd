extends CanvasLayer
## GlitchEffect (Autoload)
## A full-screen glitch (sliding bands, RGB split, inverted flashes, grain, scanlines)
## that plays for ~1 second whenever MirrorDirector fires a matching scripted_event.
##
## Autoload order: OllamaClient -> MirrorDirector -> GlitchEffect
##
## From any script you can also call it directly:
##   GlitchEffect.trigger()              # 1.0 s, full strength
##   GlitchEffect.trigger(0.6, 0.4)      # shorter + weaker

## Which director events cause a glitch, and how strong/long.
## "glitch" is a dedicated event: the director can fire it anywhere with
##   _fire("glitch", {"duration": 1.0, "intensity": 0.8})
const EVENT_PRESETS := {
	"glitch":       {"duration": 1.0, "intensity": 1.0},
	"window_shake": {"duration": 0.7, "intensity": 0.5},
	"fake_error":   {"duration": 1.0, "intensity": 0.8},
	"contact_blip": {"duration": 0.6, "intensity": 0.5},
	"name_swap":    {"duration": 1.0, "intensity": 1.0},
	"ending":       {"duration": 1.0, "intensity": 1.0},
}

## Press this key to test the glitch without waiting for the director. Delete when done.
const DEBUG_KEY := KEY_F9

const SHADER_CODE := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float t = floor(TIME * 20.0);   // stepped time = choppy, digital look

	// 1) horizontal bands slide sideways
	float bands = 26.0;
	float band = floor(uv.y * bands);
	float hit = step(1.0 - intensity * 0.55, rand(vec2(band, t)));
	uv.x += (rand(vec2(band, t + 7.0)) - 0.5) * 0.30 * intensity * hit;

	// 2) fine scanline wobble
	uv.x += (rand(vec2(floor(uv.y * 360.0), t)) - 0.5) * 0.006 * intensity;

	// 3) occasional vertical jump
	float jump = step(0.9, rand(vec2(t, 3.0))) * (rand(vec2(t, 9.0)) - 0.5) * 0.10 * intensity;
	uv.y = fract(uv.y + jump);

	// 4) RGB channel split
	float chroma = (0.004 + 0.022 * rand(vec2(t, 1.0))) * intensity;
	vec3 col = vec3(
		texture(screen_tex, vec2(uv.x + chroma, uv.y)).r,
		texture(screen_tex, uv).g,
		texture(screen_tex, vec2(uv.x - chroma, uv.y)).b
	);

	// 5) a few inverted bands
	float inv_band = floor(SCREEN_UV.y * 14.0);
	float inv = step(1.0 - intensity * 0.18, rand(vec2(inv_band, t + 31.0)));
	col = mix(col, 1.0 - col, inv);

	// 6) grain + scanlines
	col += (rand(SCREEN_UV * vec2(1920.0, 1080.0) + t) - 0.5) * 0.18 * intensity;
	col *= 1.0 - 0.12 * intensity * step(0.5, fract(SCREEN_UV.y * 300.0));

	COLOR = vec4(col, 1.0);
}
"""

var _rect: ColorRect
var _mat: ShaderMaterial
var _active := false
var _elapsed := 0.0
var _duration := 1.0
var _peak := 1.0
var _flicker := 1.0
var _flicker_timer := 0.0


func _ready() -> void:
	layer = 100   # draw above everything else
	process_mode = Node.PROCESS_MODE_ALWAYS

	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = shader

	_rect = ColorRect.new()
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never block clicks / typing
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.visible = false                              # hidden = zero cost when idle
	add_child(_rect)

	set_process(false)
	MirrorDirector.scripted_event.connect(_on_scripted_event)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == DEBUG_KEY:
		trigger()


## Play the glitch. Re-triggering while it is running restarts it at the stronger of the two.
func trigger(duration: float = 1.0, intensity: float = 1.0) -> void:
	var strength := clampf(intensity, 0.0, 1.0)
	_peak = maxf(_peak, strength) if _active else strength
	_duration = maxf(duration, 0.05)
	_elapsed = 0.0
	_active = true
	_rect.visible = true
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	var t := _elapsed / _duration
	if t >= 1.0:
		_stop()
		return
	# stuttering strength: random flicker on top of a fast fade-out
	_flicker_timer -= delta
	if _flicker_timer <= 0.0:
		_flicker = randf_range(0.45, 1.0)
		_flicker_timer = randf_range(0.03, 0.09)
	var envelope := pow(1.0 - t, 0.7)
	_mat.set_shader_parameter("intensity", _peak * envelope * _flicker)


func _stop() -> void:
	_active = false
	_mat.set_shader_parameter("intensity", 0.0)
	_rect.visible = false
	set_process(false)


func _on_scripted_event(event_name: String, data: Dictionary) -> void:
	if not EVENT_PRESETS.has(event_name):
		return
	var preset: Dictionary = EVENT_PRESETS[event_name]
	trigger(float(data.get("duration", preset.duration)), float(data.get("intensity", preset.intensity)))

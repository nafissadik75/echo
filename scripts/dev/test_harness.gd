extends Control
## Throwaway test UI. Builds itself in code, no node setup needed.
## Attach to a plain Control scene root. Enter = send, F1-F4 = jump to phase 1-4.
## Delete it once your Win98 chat window exists; it uses the same signals you will.

var _log: RichTextLabel
var usr_input: LineEdit
var _status: Label
var _phase_label: Label
var _typing: Label
var _contact_name := MirrorPrompts.CHARACTER_NAME
var _player_name := "you"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(box)

	_status = Label.new()
	_phase_label = Label.new()
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_typing = Label.new()
	usr_input = LineEdit.new()
	usr_input.placeholder_text = "type and press Enter   (F1-F4 = jump to phase)"
	usr_input.editable = false
	for node in [_status, _phase_label, _log, _typing, usr_input]:
		box.add_child(node)

	usr_input.text_submitted.connect(_on_submit)
	MirrorDirector.status_changed.connect(_on_status)
	MirrorDirector.setup_failed.connect(_on_failed)
	MirrorDirector.session_ready.connect(_on_session_ready)
	MirrorDirector.typing_changed.connect(_on_typing)
	MirrorDirector.reply_ready.connect(_on_reply)
	MirrorDirector.phase_changed.connect(_on_phase)
	MirrorDirector.scripted_event.connect(_on_event)

	MirrorDirector.start_session()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1: MirrorDirector.force_phase(1)
			KEY_F2: MirrorDirector.force_phase(2)
			KEY_F3: MirrorDirector.force_phase(3)
			KEY_F4: MirrorDirector.force_phase(4)


func _on_submit(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	_say(_player_name, text, Color.WHITE)
	usr_input.clear()
	MirrorDirector.player_said(text)


func _on_status(text: String) -> void:
	_status.text = text


func _on_failed(reason: String) -> void:
	_status.text = "FAILED: " + reason


func _on_session_ready() -> void:
	usr_input.editable = true
	usr_input.grab_focus()


func _on_typing(is_typing: bool) -> void:
	_typing.text = ("%s is typing..." % _contact_name) if is_typing else ""


func _on_reply(text: String) -> void:
	_say(_contact_name, text, Color.CYAN)


func _on_phase(p: int) -> void:
	_phase_label.text = "Phase %d" % p


func _on_event(event_name: String, data: Dictionary) -> void:
	_say("[event]", "%s %s" % [event_name, str(data)], Color.GRAY)
	match event_name:
		"prefill_input":
			usr_input.text = str(data.get("text", ""))
			usr_input.caret_column = usr_input.text.length()
		"name_swap":
			_contact_name = str(data.get("contact_name", _contact_name))
			_player_name = str(data.get("player_name", _player_name))
		"ending":
			usr_input.editable = false
			_say("[game]", "THE END (your real UI plays the fake crash here)", Color.RED)


func _say(who: String, text: String, color: Color) -> void:
	_log.push_color(color)
	_log.add_text("%s: %s\n" % [who, text])
	_log.pop()

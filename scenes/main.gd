extends Control

@onready var bsod_screen: TextureRect = $BSOD_Screen
@onready var chat_app_window: PanelContainer = $ChatAppWindow
@onready var usr_input: LineEdit = $ChatAppWindow/MarginContainer/PanelContainer/MarginContainer/VBoxContainer/PanelContainer2/LineEdit
#@onready var _log: RichTextLabel = $ChatAppWindow/MarginContainer/PanelContainer/MarginContainer/VBoxContainer/PanelContainer/RichTextLabel
@onready var _typing: Label = $ChatAppWindow/MarginContainer/PanelContainer/MarginContainer/VBoxContainer/PanelContainer/VBoxContainer/TypingLabel
@onready var _log: RichTextLabel = $ChatAppWindow/MarginContainer/PanelContainer/MarginContainer/VBoxContainer/PanelContainer/VBoxContainer/RichTextLabel

#var _status: Label
#var _phase_label: Label
#var _typing: Label
var _contact_name := MirrorPrompts.CHARACTER_NAME
var _player_name := "you"

var chat_app_clicked : int = 0

func _ready() -> void:
	chat_app_window.hide()
	
	usr_input.text_submitted.connect(_on_submit)
	#MirrorDirector.status_changed.connect(_on_status)
	#MirrorDirector.setup_failed.connect(_on_failed)
	MirrorDirector.session_ready.connect(_on_session_ready)
	MirrorDirector.typing_changed.connect(_on_typing)
	MirrorDirector.reply_ready.connect(_on_reply)
	#MirrorDirector.phase_changed.connect(_on_phase)
	MirrorDirector.scripted_event.connect(_on_event)

	MirrorDirector.start_session()
	
	MirrorDirector.scripted_event.connect(_on_scripted_event)

func _on_scripted_event(event_name : String, data : Dictionary) -> void:
	match event_name:
		"window_shake":
			GlitchEffect.trigger(0.5, 1.0)

func _on_chat_app_button_button_down() -> void:
	if chat_app_clicked == 0:
		get_tree().create_timer(0.2).timeout.connect(_on_chat_app_double_click_btn_timer_timeout)
	chat_app_clicked += 1
	if chat_app_clicked == 2:
		print("now open")
		chat_app_window.show()

func _on_chat_app_double_click_btn_timer_timeout() -> void:
	chat_app_clicked = 0

func _on_submit(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	_say(_player_name, text, Color.WHITE)
	usr_input.clear()
	usr_input.editable = false
	MirrorDirector.player_said(text)

#func _on_status(text: String) -> void:
	#_status.text = text
#
#func _on_failed(reason: String) -> void:
	#_status.text = "FAILED: " + reason

func _on_session_ready() -> void:
	usr_input.editable = true
	usr_input.grab_focus()

func _on_typing(is_typing: bool) -> void:
	_typing.text = ("%s is typing..." % _contact_name) if is_typing else ""

func _on_reply(text: String) -> void:
	_say(_contact_name, text, Color.CYAN)
	usr_input.editable = true

#func _on_phase(p: int) -> void:
	#_phase_label.text = "Phase %d" % p

func _on_event(event_name: String, data: Dictionary) -> void:
	#_say("[event]", "%s %s" % [event_name, str(data)], Color.GRAY)
	match event_name:
		"prefill_input":
			usr_input.text = str(data.get("text", ""))
			usr_input.caret_column = usr_input.text.length()
		"name_swap":
			_contact_name = str(data.get("contact_name", _contact_name))
			_player_name = str(data.get("player_name", _player_name))
		"ending":
			usr_input.editable = false
			bsod_screen.show()
			_say("[game]", "THE END (your real UI plays the fake crash here)", Color.RED)


func _say(who: String, text: String, color: Color) -> void:
	_log.push_color(color)
	_log.add_text("%s: %s\n" % [who, text])
	SfxManager.play_incoming_alert_sfx()
	_log.pop()
	await get_tree().process_frame
	usr_input.grab_focus()

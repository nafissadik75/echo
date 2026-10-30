extends PanelContainer

@onready var message: Label = $"../BottomBar/HBoxContainer/PanelContainer/Label"

func _ready() -> void:
	self.hide()
	MirrorDirector.scripted_event.connect(_on_scripted_event)

func _on_scripted_event(event_name : String, data : Dictionary) -> void:
	match event_name:
		"fake_error":
			show()
			GlitchEffect.trigger(0.5, 1.0)

func _on_button_pressed() -> void:
	self.hide()

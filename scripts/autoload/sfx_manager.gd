extends Node

const INCOMING_ALERT = preload("uid://cpqj1o0vgpf3j")
const ERROR = preload("uid://cru5m6ji5pqqy")

var messenger_sfx_player : AudioStreamPlayer = AudioStreamPlayer.new()
var bg_player : AudioStreamPlayer = AudioStreamPlayer.new()

func _ready() -> void:
	add_child(messenger_sfx_player)
	add_child(bg_player)

func play_incoming_alert_sfx() -> void:
	messenger_sfx_player.stream = INCOMING_ALERT
	messenger_sfx_player.play()

func play_error_sfx() -> void:
	messenger_sfx_player.stream = ERROR 
	messenger_sfx_player.play()

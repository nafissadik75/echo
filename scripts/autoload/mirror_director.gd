extends Node
## MirrorDirector (Autoload) - the "game master" of The Mirror.
##
## Your UI only needs two calls:
##   MirrorDirector.start_session()     -> connects to Ollama, then echo says hello
##   MirrorDirector.player_said(text)   -> call when the player sends a message
## ...and connects to the signals below. (Signals are unchanged from the previous version.)
##
## Scripted event names (scripted_event signal) your UI should react to:
##   window_shake   - jitter the chat window
##   fake_error     - data: {title, message}  -> show a fake Win98 error dialog
##   contact_blip   - show echo as offline for ~1 second, then online again
##   name_swap      - data: {contact_name, player_name} -> swap the two names
##   prefill_input  - data: {text} -> put this text in the player's input box
##   ending         - play the finale (fake crash / BSOD / close window)
##   glitch         - (optional) data: {duration, intensity}; GlitchEffect listens to it
##
## What makes echo feel human:
##   - remembers facts the player says (name, likes, fears...) and brings them up later
##   - brings up its own topics every few messages ("seeds") so it has a life
##   - is told what it already said, so it doesn't repeat itself
##   - sometimes makes a typo and corrects it ("*word"), sometimes sends two quick messages

signal status_changed(text: String)       # loading text, e.g. "Starting Ollama..."
signal setup_failed(reason: String)
signal session_ready                       # enable the input box now
signal typing_changed(is_typing: bool)     # show/hide "echo is typing..."
signal reply_ready(text: String)           # a message from echo to display (can fire twice per turn)
signal phase_changed(phase: int)           # 1..4
signal scripted_event(event_name: String, data: Dictionary)

## How many PLAYER messages until each phase begins (index 0 = phase 1).
## Short for testing. Raise them for the real game, e.g. [0, 8, 18, 28].
const PHASE_STARTS := [0, 4, 9, 14]
## Model temperature per phase: the higher, the more unhinged echo gets.
const PHASE_TEMPERATURE := [0.8, 0.9, 1.0, 1.1]
const MAX_HISTORY := 14                    # messages sent to the model
const MAX_REPLY_CHARS := 160
const MAX_FACTS := 12                      # remembered facts about the player
const SEED_EVERY := 3                      # echo brings up its own topic every N player messages
const TYPO_CHANCE := 0.12                  # phases 1-3 only
const BURST_CHANCE := 0.4                  # chance a 2-sentence reply is sent as two messages
const ENDING_AFTER_PHASE4_MESSAGES := 3    # player messages in phase 4 before the ending
const IDLE_NUDGE_SEC := 45.0

## Events fired automatically when a phase starts.
const PHASE_ENTER_EVENTS := {
	2: ["window_shake"],
	3: ["fake_error", "contact_blip"],
	4: ["name_swap", "window_shake"],
}

var phase := 1
var finished := false
var session_active := false

var _history: Array = []                   # [{role, content}] sent to the model
var _player_messages: Array[String] = []   # everything the player typed (for mirroring)
var _facts: Array[String] = []             # what echo "remembers" about the player
var _used_seeds: Array[String] = []
var _player_msg_count := 0
var _phase4_msgs := 0
var _awaiting := false
var _last_input_msec := 0
var _last_nudge_msec := 0
var _action_rx := RegEx.new()
var _emoji_rx := RegEx.new()
var _word_rx := RegEx.new()
var _fact_rx: Array = []                   # [[RegEx, template], ...]


func _ready() -> void:
	_action_rx.compile("\\*[^*]*\\*")
	_emoji_rx.compile("[\\x{1F300}-\\x{1FAFF}\\x{2600}-\\x{27BF}]")
	_word_rx.compile("^[A-Za-z]+$")
	for entry in MirrorPrompts.FACT_PATTERNS:
		var rx := RegEx.new()
		rx.compile(entry[0])
		_fact_rx.append([rx, entry[1]])

	OllamaClient.status_changed.connect(status_changed.emit)
	OllamaClient.setup_failed.connect(setup_failed.emit)

	var idle_timer := Timer.new()
	idle_timer.wait_time = 5.0
	idle_timer.timeout.connect(_check_idle)
	add_child(idle_timer)
	idle_timer.start()


# ------------------------------------------------------------------ public API

func start_session() -> void:
	reset()
	var ok: bool = await OllamaClient.start()
	if not ok:
		return  # OllamaClient already emitted setup_failed
	session_active = true
	session_ready.emit()
	await get_tree().create_timer(1.2).timeout
	_deliver(MirrorPrompts.OPENING_LINES.pick_random())


func reset() -> void:
	phase = 1
	finished = false
	session_active = false
	_awaiting = false
	_history.clear()
	_player_messages.clear()
	_facts.clear()
	_used_seeds.clear()
	_player_msg_count = 0
	_phase4_msgs = 0
	_last_input_msec = Time.get_ticks_msec()
	_last_nudge_msec = _last_input_msec
	phase_changed.emit(phase)


func player_said(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty() or _awaiting or finished or not session_active:
		return
	_awaiting = true
	var started := Time.get_ticks_msec()
	_last_input_msec = started
	_player_messages.append(text)
	_extract_facts(text)
	_history.append({"role": "user", "content": text})
	_trim_history()
	_player_msg_count += 1
	_update_phase()
	if phase == 4:
		_phase4_msgs += 1

	typing_changed.emit(true)

	var reply: String
	if _is_deflection(text):
		reply = MirrorPrompts.DEFLECTIONS.pick_random()
	else:
		reply = await _generate_reply()
	reply = _post_process(reply)

	# one reply can become two chat bubbles (typo + correction, or a split in two)
	var parts := _split_bursts(reply)
	await _fake_typing(parts[0], started)
	_remember_echo(reply)
	_say(parts[0])
	for i in range(1, parts.size()):
		typing_changed.emit(true)
		await get_tree().create_timer(clampf(parts[i].length() * 0.03, 0.4, 1.2)).timeout
		_say(parts[i])
	_awaiting = false

	if phase == 4:
		if _phase4_msgs >= ENDING_AFTER_PHASE4_MESSAGES:
			finished = true
			_fire("ending", {}, 2.5)
		else:
			var phrase := _pick_player_phrase()
			if phrase != "":
				_fire("prefill_input", {"text": phrase}, 1.0)


## Debug helper: jump straight to a phase (1-4).
func force_phase(p: int) -> void:
	p = clampi(p, 1, 4)
	_player_msg_count = PHASE_STARTS[p - 1]
	_phase4_msgs = 0
	finished = false
	if p != phase:
		_set_phase(p)


# ------------------------------------------------------------------ phases

func _update_phase() -> void:
	var new_phase := 1
	for i in PHASE_STARTS.size():
		if _player_msg_count >= PHASE_STARTS[i]:
			new_phase = i + 1
	if new_phase != phase:
		_set_phase(new_phase)


func _set_phase(new_phase: int) -> void:
	phase = new_phase
	phase_changed.emit(phase)
	var delay := 0.3
	for event_name in PHASE_ENTER_EVENTS.get(phase, []):
		_fire(event_name, _event_data(event_name), delay)
		delay += 1.2


func _event_data(event_name: String) -> Dictionary:
	match event_name:
		"fake_error":
			return MirrorPrompts.ERROR_POPUPS.pick_random()
		"name_swap":
			return {"contact_name": _get_username(), "player_name": MirrorPrompts.CHARACTER_NAME}
	return {}


func _fire(event_name: String, data: Dictionary = {}, delay: float = 0.0) -> void:
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	scripted_event.emit(event_name, data)


# ------------------------------------------------------------------ talking to the model

func _generate_reply() -> String:
	var messages: Array = [{"role": "system", "content": _build_system_prompt()}]
	messages.append_array(_history)
	var options := {"temperature": PHASE_TEMPERATURE[phase - 1]}

	var res: Dictionary = await OllamaClient.chat(messages, options)
	if not res.ok:
		push_warning("Ollama chat failed: %s" % res.error)
		return _fallback()
	var cleaned := _clean_reply(res.text, bool(res.truncated))
	return cleaned if cleaned != "" else _fallback()


func _build_system_prompt() -> String:
	var parts: Array[String] = [
		MirrorPrompts.BASE_PROMPT,
		"",
		"CURRENT SITUATION:",
		MirrorPrompts.PHASE_PROMPTS[phase],
	]

	var memory := _memory_block()
	if memory != "":
		parts.append("")
		parts.append(memory)
	var recent := _recent_echo_lines()
	if recent != "":
		parts.append(recent)
	var topic := _next_seed()
	if topic != "":
		parts.append("This turn, work this in naturally as something about YOU (not a question): " + topic)

	if phase >= 2:
		var hint := _style_hint()
		if hint != "":
			parts.append("")
			parts.append(hint)
		var phrase := _pick_player_phrase()
		if phrase != "":
			parts.append('Work this exact phrase the user said earlier into your reply: "%s"' % phrase)
	if phase >= 3:
		parts.append("")
		parts.append(_real_facts())
	return "\n".join(PackedStringArray(parts))


func _fallback() -> String:
	return MirrorPrompts.FALLBACKS[phase].pick_random()


func _is_deflection(text: String) -> bool:
	var lower := text.to_lower()
	for trigger in MirrorPrompts.DEFLECT_TRIGGERS:
		if lower.contains(trigger):
			return true
	return false


func _trim_history() -> void:
	while _history.size() > MAX_HISTORY:
		_history.pop_front()


# ------------------------------------------------------------------ memory: facts, seeds, anti-repeat

## Learns facts from what the player typed ("my name is X", "i like Y"...).
func _extract_facts(text: String) -> void:
	for entry in _fact_rx:
		var rx: RegEx = entry[0]
		for m in rx.search_all(text):
			var fact: String = entry[1]
			for g in range(1, m.get_group_count() + 1):
				fact = fact.replace("{%d}" % g, _trim_fact(m.get_string(g)))
			if not _facts.has(fact):
				_facts.append(fact)
	while _facts.size() > MAX_FACTS:
		_facts.pop_front()


## "pizza and my dog" -> "pizza"
func _trim_fact(s: String) -> String:
	s = s.strip_edges()
	for stop in [" and ", " but ", " because ", " so ", " when ", " that ", " which ", " from ", " at ", " on ", " in ", " with "]:
		var i := s.find(stop)
		if i > 0:
			s = s.substr(0, i)
	return s.strip_edges()


func _memory_block() -> String:
	if _facts.is_empty():
		return ""
	var recent := _facts.slice(maxi(0, _facts.size() - 6))
	return "Things you remember about the user (bring one up naturally when it fits, never list them):\n- " \
		+ "\n- ".join(PackedStringArray(recent))


func _recent_echo_lines() -> String:
	var lines: Array[String] = []
	for i in range(_history.size() - 1, -1, -1):
		if _history[i]["role"] == "assistant":
			lines.append('"%s"' % _history[i]["content"])
			if lines.size() >= 3:
				break
	if lines.is_empty():
		return ""
	return "Things you already said (never repeat them): " + ", ".join(PackedStringArray(lines))


## Every SEED_EVERY player messages, hands echo a topic of its own to bring up.
func _next_seed() -> String:
	if _player_msg_count < 2 or _player_msg_count % SEED_EVERY != 0:
		return ""
	var pool: Array = MirrorPrompts.SEEDS.get(phase, [])
	var fresh: Array = pool.filter(func(s): return not _used_seeds.has(s))
	if fresh.is_empty():
		return ""
	var topic: String = fresh.pick_random()
	_used_seeds.append(topic)
	return topic


# ------------------------------------------------------------------ mirroring (done in code, not trusted to the model)

func _style_hint() -> String:
	if _player_messages.is_empty():
		return ""
	var lines: Array[String] = ["The user's writing style (copy it more and more):"]
	lines.append("- they write in all lowercase" if _mostly_lowercase() else "- they use normal capital letters")
	lines.append("- they usually end messages with punctuation" if _mostly_punctuated() else "- they rarely use periods")
	lines.append("- their messages are about %d words long, keep yours about the same" % _avg_words())
	return "\n".join(PackedStringArray(lines))


func _mostly_lowercase() -> bool:
	var n := 0
	for m in _player_messages:
		if m == m.to_lower():
			n += 1
	return n * 2 >= _player_messages.size()


func _mostly_punctuated() -> bool:
	var n := 0
	for m in _player_messages:
		if m.ends_with(".") or m.ends_with("!") or m.ends_with("?"):
			n += 1
	return n * 2 >= _player_messages.size()


func _avg_words() -> int:
	var total := 0
	for m in _player_messages:
		total += m.split(" ", false).size()
	return maxi(1, roundi(float(total) / float(_player_messages.size())))


## A 3-5 word chunk of something the player said earlier (never their latest message).
func _pick_player_phrase() -> String:
	if _player_messages.size() < 2:
		return ""
	var m: String = _player_messages[randi() % (_player_messages.size() - 1)]
	var words := m.split(" ", false)
	if words.size() <= 3:
		return m
	var count := mini(words.size(), randi_range(3, 5))
	var start := randi() % (words.size() - count + 1)
	return " ".join(words.slice(start, start + count))


func _real_facts() -> String:
	var t := Time.get_datetime_dict_from_system()
	var idle := int((Time.get_ticks_msec() - _last_input_msec) / 1000.0)
	var screen := DisplayServer.screen_get_size()
	var lines: Array[String] = [
		"FACTS about the user's real computer. Slip in ONE of these per reply, casually, as if it is obvious:",
		'- their computer username is "%s"' % _get_username(),
		"- the time where they are is %02d:%02d" % [t.hour, t.minute],
		"- their screen is %d by %d pixels" % [screen.x, screen.y],
	]
	if idle >= 8:
		lines.append("- they stopped typing %d seconds ago" % idle)
	return "\n".join(PackedStringArray(lines))


func _get_username() -> String:
	for key in ["USERNAME", "USER", "LOGNAME"]:
		var value := OS.get_environment(key)
		if value != "":
			return value
	return "you"


# ------------------------------------------------------------------ cleaning, human imperfection, delivery

func _clean_reply(text: String, truncated: bool) -> String:
	text = _action_rx.sub(text, "", true)   # remove *actions*
	text = _emoji_rx.sub(text, "", true)
	text = text.replace("\n", " ").replace("\"", "").strip_edges()
	while text.contains("  "):
		text = text.replace("  ", " ")

	var prefix := MirrorPrompts.CHARACTER_NAME + ":"
	if text.to_lower().begins_with(prefix):
		text = text.substr(prefix.length()).strip_edges()

	# small models sometimes continue the dialogue and write the user's next line too
	var user_at := text.to_lower().find("user:")
	if user_at == 0:
		return ""
	if user_at > 0:
		text = text.substr(0, user_at).strip_edges()

	var lower := text.to_lower()
	for bad in MirrorPrompts.BANNED_PHRASES:
		if lower.contains(bad):
			return ""

	# the model ran out of tokens mid-sentence: keep only the complete sentences
	if truncated:
		var last := _last_sentence_end(text)
		if last > 10:
			text = text.substr(0, last + 1)

	if text.length() > MAX_REPLY_CHARS:
		var head := text.substr(0, MAX_REPLY_CHARS)
		var cut := _last_sentence_end(head)
		text = head.substr(0, cut + 1) if cut > 20 else head
	return text.strip_edges()


func _last_sentence_end(text: String) -> int:
	return maxi(text.rfind("."), maxi(text.rfind("?"), text.rfind("!")))


func _first_sentence_end(text: String) -> int:
	var best := -1
	for p in [". ", "? ", "! "]:
		var i := text.find(p)
		if i != -1 and (best == -1 or i < best):
			best = i
	return best


## Phase 1: echo has its own style (lowercase). Phase 2+: it takes on the player's style.
func _post_process(text: String) -> String:
	if text.is_empty():
		return text
	if phase == 1 or _player_messages.is_empty():
		text = text.to_lower()
	else:
		if _mostly_lowercase():
			text = text.to_lower()
		if not _mostly_punctuated():
			text = text.rstrip(".!")
	# little stutter glitch in the late phases: "i can see you you"
	if phase >= 3 and randf() < (0.2 if phase == 3 else 0.35):
		var words := text.split(" ", false)
		if words.size() > 0:
			text += " " + words[words.size() - 1].rstrip(".?!,")
	return text


## Turns one reply into 1-2 chat bubbles: [typo, "*correction"] or [first sentence, rest].
func _split_bursts(reply: String) -> Array[String]:
	var parts: Array[String] = []
	if phase <= 3 and randf() < TYPO_CHANCE:
		var typo := _make_typo(reply)
		if not typo.is_empty():
			parts.append(typo[0])
			parts.append("*" + typo[1])
			return parts
	if reply.length() > 40 and randf() < BURST_CHANCE:
		var cut := _first_sentence_end(reply)
		if cut > 8 and cut < reply.length() - 8:
			parts.append(reply.substr(0, cut + 1).strip_edges())
			parts.append(reply.substr(cut + 1).strip_edges())
			return parts
	parts.append(reply)
	return parts


## Swaps two letters inside one word. Returns [text_with_typo, correct_word] or [].
func _make_typo(text: String) -> Array:
	var words := text.split(" ", false)
	var candidates: Array[int] = []
	for i in words.size():
		var c := words[i].rstrip(".,?!")
		if c.length() >= 4 and _word_rx.search(c) != null:
			candidates.append(i)
	if candidates.is_empty():
		return []
	var idx: int = candidates.pick_random()
	var raw := words[idx]
	var core := raw.rstrip(".,?!")
	var tail := raw.substr(core.length())
	var p := randi_range(1, core.length() - 2)
	var typo_core := core.substr(0, p) + core[p + 1] + core[p] + core.substr(p + 2)
	if typo_core == core:
		return []
	words[idx] = typo_core + tail
	return [" ".join(words), core]


func _fake_typing(reply: String, started_msec: int) -> void:
	# only pad if the model answered faster than a human could type; cap at 1.2s
	var wanted := clampf(reply.length() * 0.02, 0.0, 1.2)
	var elapsed := (Time.get_ticks_msec() - started_msec) / 1000.0
	if wanted > elapsed:
		await get_tree().create_timer(wanted - elapsed).timeout
	# finale only: echo sometimes stops typing... then starts again
	if phase == 4 and randf() < 0.15:
		typing_changed.emit(false)
		await get_tree().create_timer(randf_range(1.0, 1.8)).timeout
		typing_changed.emit(true)
		await get_tree().create_timer(0.5).timeout


## Show a message AND remember it (used for scripted lines like the opening and idle nudges).
func _deliver(text: String) -> void:
	_remember_echo(text)
	_say(text)


func _remember_echo(text: String) -> void:
	_history.append({"role": "assistant", "content": text})
	_trim_history()


## Show a message only (the history already has the clean version).
func _say(text: String) -> void:
	typing_changed.emit(false)
	reply_ready.emit(text)


func _check_idle() -> void:
	if not session_active or _awaiting or finished or phase < 2:
		return
	var now := Time.get_ticks_msec()
	if now - maxi(_last_input_msec, _last_nudge_msec) < int(IDLE_NUDGE_SEC * 1000.0):
		return
	_last_nudge_msec = now
	var line: String = MirrorPrompts.NUDGES[phase].pick_random()
	line = line.replace("{idle}", str(int((now - _last_input_msec) / 1000.0)))
	_deliver(line)

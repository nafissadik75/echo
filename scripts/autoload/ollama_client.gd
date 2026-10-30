extends Node
## OllamaClient (Autoload)
## Talks to a local Ollama server over HTTP.
## Starts `ollama serve` if nothing is listening, checks the model exists, warms it up.
##
## Usage:
##   var ok: bool = await OllamaClient.start()
##   var res: Dictionary = await OllamaClient.chat(messages, {"temperature": 1.0})
##   -> {"ok": bool, "text": String, "error": String, "truncated": bool}

signal status_changed(text: String)   # progress text for a loading screen
signal setup_failed(reason: String)

const BASE_URL := "http://127.0.0.1:11434"

## Change this to your model tag (see `ollama list`).
var model_name := "gemma3:1b"
var keep_alive := "30m"
var default_options := {
	"temperature": 0.9,
	"top_p": 0.95,
	"top_k": 40,
	"repeat_penalty": 1.15,
	"num_predict": 48,   # hard cap on reply length (tokens)
	"num_ctx": 2048,     # context window: room for persona + memory + chat history
}

## Prints speed numbers to the Output panel after every reply.
var log_timings := true

var is_ready := false
var _busy := false
var _server_pid := -1  # only set when WE launched ollama, so we only ever kill our own


func _exit_tree() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)


## Returns true when the server is up, the model exists, and it is loaded in memory.
func start() -> bool:
	if is_ready:
		return true

	status_changed.emit("Looking for Ollama...")
	if not await _ping():
		status_changed.emit("Starting Ollama...")
		if not _launch_server():
			setup_failed.emit("Could not launch Ollama. Is it installed and on your PATH?")
			return false
		if not await _wait_for_server(20.0):
			setup_failed.emit("Ollama was launched but never answered on port 11434.")
			return false

	status_changed.emit("Checking model %s..." % model_name)
	if not await _has_model():
		setup_failed.emit("Model '%s' not found. Run:  ollama pull %s" % [model_name, model_name])
		return false

	status_changed.emit("Loading model into memory (first time can take a while)...")
	await _warm_up()
	is_ready = true
	status_changed.emit("Connected.")
	return true


## messages: [{"role": "system"|"user"|"assistant", "content": "..."}]
## Returns {"ok": bool, "text": String, "error": String, "truncated": bool}
## truncated = the model hit num_predict and was cut off mid-sentence.
func chat(messages: Array, options_override: Dictionary = {}) -> Dictionary:
	if _busy:
		return {"ok": false, "text": "", "error": "busy", "truncated": false}
	_busy = true

	var options: Dictionary = default_options.duplicate()
	options.merge(options_override, true)
	var body := {
		"model": model_name,
		"messages": messages,
		"stream": false,
		"keep_alive": keep_alive,
		"options": options,
	}
	var res: Dictionary = await _request(HTTPClient.METHOD_POST, "/api/chat", body, 120.0)
	_busy = false

	if not res.ok:
		return {"ok": false, "text": "", "error": str(res.get("error", "unknown")), "truncated": false}

	var data: Dictionary = res.data
	if log_timings:
		print("[ollama] total %.1fs | load %.1fs | prompt %d tok | out %d tok in %.1fs" % [
			data.get("total_duration", 0) / 1e9,
			data.get("load_duration", 0) / 1e9,
			data.get("prompt_eval_count", 0),
			data.get("eval_count", 0),
			data.get("eval_duration", 0) / 1e9,
		])
	var message: Dictionary = data.get("message", {})
	return {
		"ok": true,
		"text": str(message.get("content", "")).strip_edges(),
		"error": "",
		"truncated": str(data.get("done_reason", "")) == "length",
	}


# ---------------------------------------------------------------- internals

func _ping() -> bool:
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, "/api/version", null, 2.0)
	return bool(res.ok)


func _launch_server() -> bool:
	var candidates: Array[String] = ["ollama"]
	if OS.get_name() == "Windows":
		var local_app_data := OS.get_environment("LOCALAPPDATA")
		if local_app_data != "":
			candidates.append(local_app_data.path_join("Programs/Ollama/ollama.exe"))
	for exe in candidates:
		var pid := OS.create_process(exe, PackedStringArray(["serve"]), false)
		if pid > 0:
			_server_pid = pid
			return true
	return false


func _wait_for_server(timeout_sec: float) -> bool:
	var waited := 0.0
	while waited < timeout_sec:
		if await _ping():
			return true
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	return false


func _has_model() -> bool:
	var res: Dictionary = await _request(HTTPClient.METHOD_GET, "/api/tags", null, 5.0)
	if not res.ok:
		return false
	var data: Dictionary = res.data
	for m in data.get("models", []):
		var installed := str(m.get("name", ""))
		if installed == model_name or installed == "%s:latest" % model_name:
			return true
	return false


## Sending a request with no prompt just loads the model into memory.
## Uses the same num_ctx as chat(), otherwise Ollama would reload the model on the first message.
func _warm_up() -> void:
	await _request(HTTPClient.METHOD_POST, "/api/generate",
		{"model": model_name, "keep_alive": keep_alive, "options": {"num_ctx": default_options["num_ctx"]}}, 180.0)


func _request(method: HTTPClient.Method, path: String, body: Variant = null, timeout: float = 30.0) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)

	var payload := "" if body == null else JSON.stringify(body)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := req.request(BASE_URL + path, headers, method, payload)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "request error %d" % err}

	var result: Array = await req.request_completed
	req.queue_free()

	if result[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "network error %d" % result[0]}
	var code: int = result[1]
	var raw: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	var ok := code >= 200 and code < 300 and typeof(parsed) == TYPE_DICTIONARY
	return {"ok": ok, "code": code, "data": parsed, "error": "http %d" % code}

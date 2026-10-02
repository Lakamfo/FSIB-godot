class_name FSIB_Main
extends Node

signal status_updated(info : String)
signal progress_updated(done : int, total : int)
signal done()

const CACHE_PATH := "user://fsib_cache.json"
const CACHE_FORMAT := 1

## Extensions that affect shader variants and take part in the hash.
## Textures, audio and scripts are intentionally excluded: editing them must not invalidate the cache.
const HASH_EXT : Array[String] = [
	"tscn", "scn", "tres", "res", "material",
	"gdshader", "gdshaderinc", "glb", "gltf", "fbx",
]

## Needed for exported builds, where res:// files can't be read directly.
## If empty, application/config/version is used. Change it on every release.
@export var build_id : String = ""
@export var frames_per_batch : int = 3
## Time budget for hashing per frame, so the loading screen doesn't freeze.
@export var time_budget_ms : int = 8
@export var save_every_batches : int = 4

var _cache : Dictionary = {} # path -> hash at the moment of warmup
var _env_signature := ""
var _cancelled := false
var _file_hash_memo : Dictionary = {}
var _deps_memo : Dictionary = {}


func _ready() -> void:
	if build_id.is_empty():
		build_id = str(ProjectSettings.get_setting("application/config/version", ""))


func cancel() -> void:
	_cancelled = true


func reset_cache() -> void:
	_cache.clear()
	if FileAccess.file_exists(CACHE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_PATH))


## paths -- any resource paths (scenes, materials, meshes). Only the ones not yet warmed up are loaded.
## spawn_root -- a Node3D in front of the camera, hidden under an opaque CanvasLayer.
func warmup(paths : Array[String], spawn_root : Node3D, batch_size := 4, force := false) -> void:
	_cancelled = false
	_file_hash_memo.clear()
	_deps_memo.clear()
	_env_signature = _compute_env_signature()
	_load_cache()

	# If Godot doesn't persist its pipeline cache to disk, nothing can be skipped.
	var use_cache : bool = not force and bool(ProjectSettings.get_setting(
			"rendering/rendering_device/pipeline_cache/enable", true))

	# 1. Figure out what actually needs warming up (without loading the resources themselves)
	status_updated.emit("Checking cache...")
	var pending : Array[String] = []
	var pending_hash : Dictionary = {}
	var t := Time.get_ticks_msec()
	for p : String in paths:
		var h := _resource_hash(p)
		if not (use_cache and _cache.get(p, "") == h):
			pending.append(p)
			pending_hash[p] = h
		if Time.get_ticks_msec() - t > time_budget_ms:
			await get_tree().process_frame
			t = Time.get_ticks_msec()

	var total := pending.size()
	var done_count := 0
	var batch_no := 0
	progress_updated.emit(0, total)

	# 2. Warm up in batches, the next batch is prefetched in the background
	_request(pending.slice(0, batch_size))
	for i in range(0, total, batch_size):
		if _cancelled:
			break

		var batch_paths : Array[String] = []
		batch_paths.assign(pending.slice(i, i + batch_size))
		_request(pending.slice(i + batch_size, i + batch_size * 2))

		var spawned : Array[Node] = []
		var ok_paths : Array[String] = []
		for p : String in batch_paths:
			status_updated.emit("Loading " + p.get_file())
			var res : Resource = await _await_loaded(p)
			if res == null:
				push_warning("FSIB: failed to load " + p)
				continue
			ok_paths.append(p)

			var inst : Node = _make_instance(res)
			if inst == null:
				continue # nothing to render (script, texture, etc.), but counts as processed
			if inst is Node3D:
				var n3 := inst as Node3D
				n3.scale = Vector3.ONE * 0.1
				n3.position = Vector3(randf_range(-1, 1), randf_range(-1, 1), -3.0)
			spawn_root.add_child(inst)
			spawned.append(inst)

		# Restart particles once they are inside the tree
		for inst : Node in spawned:
			for cls : String in ["GPUParticles3D", "GPUParticles2D"]:
				for p : Node in inst.find_children("*", cls, true, false):
					p.restart()

		status_updated.emit("Compiling shaders")
		for k in frames_per_batch:
			await get_tree().process_frame

		for inst : Node in spawned:
			if is_instance_valid(inst):
				inst.queue_free()

		for p : String in ok_paths:
			_cache[p] = pending_hash[p]

		done_count += batch_paths.size()
		batch_no += 1
		progress_updated.emit(done_count, total)
		if batch_no % save_every_batches == 0:
			_save_cache()

	_save_cache()
	done.emit()


# ---------- Instance creation ----------

func _make_instance(res : Resource) -> Node:
	if res is PackedScene:
		var inst : Node = (res as PackedScene).instantiate()
		_prepare_instance(inst)
		return inst

	if res is Material:
		# Shaders of other modes (canvas_item, particles...) won't render on a 3D mesh
		if res is ShaderMaterial:
			var sh : Shader = (res as ShaderMaterial).shader
			if sh == null or sh.get_mode() != Shader.MODE_SPATIAL:
				return null
		var mi := MeshInstance3D.new()
		mi.mesh = SphereMesh.new()
		mi.material_override = res as Material
		return mi

	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res as Mesh
		return mi

	return null


func _prepare_instance(root : Node) -> void:
	var all_nodes : Array[Node] = FSIB_Tools.get_all_children(root)

	for n : Node in all_nodes:
		n.set_block_signals(true)
		n.set_script(null)
		n.process_mode = Node.PROCESS_MODE_DISABLED

		if n is Node3D:
			(n as Node3D).visible = true
		elif n is CanvasItem:
			(n as CanvasItem).visible = true

		if n is Camera3D:
			(n as Camera3D).current = false
		elif n is Camera2D:
			(n as Camera2D).enabled = false
		elif n is AudioListener3D:
			n.clear_current()
		elif n is AnimationPlayer:
			(n as AnimationPlayer).autoplay = ""
		elif n is AnimationTree:
			(n as AnimationTree).active = false
		elif n is Timer:
			(n as Timer).autostart = false
		elif n is AudioStreamPlayer or n is AudioStreamPlayer2D or n is AudioStreamPlayer3D:
			n.set("autoplay", false)
			n.set("volume_db", -80.0)
		elif n is CollisionObject3D:
			n.collision_layer = 0
			n.collision_mask = 0
		elif n is CollisionObject2D:
			n.collision_layer = 0
			n.collision_mask = 0


# ---------- Background loading ----------

func _request(paths : Array) -> void:
	for p : String in paths:
		ResourceLoader.load_threaded_request(p)


func _await_loaded(path : String) -> Resource:
	while true:
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
		elif status == ResourceLoader.THREAD_LOAD_LOADED:
			return ResourceLoader.load_threaded_get(path)
		else:
			return null
	return null


# ---------- Hashes ----------

## Resource hash = hash of its file + all dependencies that affect shaders.
## If a material inside a scene changes, the scene is warmed up again.
func _resource_hash(path : String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for p : String in _collect_deps(path):
		ctx.update(p.to_utf8_buffer())
		ctx.update(_file_hash(p).to_utf8_buffer())
	return ctx.finish().hex_encode()


func _collect_deps(root : String) -> Array[String]:
	var seen : Dictionary = {}
	var stack : Array[String] = [root]
	while not stack.is_empty():
		var p : String = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		for d : String in _direct_deps(p):
			if not seen.has(d):
				stack.append(d)
	var out : Array[String] = []
	out.assign(seen.keys())
	out.sort()
	return out


func _direct_deps(path : String) -> Array[String]:
	if _deps_memo.has(path):
		return _deps_memo[path]
	var out : Array[String] = []
	for dep : String in ResourceLoader.get_dependencies(path):
		# Format: "uid://...::Type::res://path" or just a path
		var parts := dep.split("::")
		var d : String = parts[2] if parts.size() >= 3 and not parts[2].is_empty() else parts[0]
		if d.begins_with("uid://"):
			d = ResourceUID.ensure_path(d)
		if d.get_extension().to_lower() in HASH_EXT:
			out.append(d)
	_deps_memo[path] = out
	return out


func _file_hash(path : String) -> String:
	if _file_hash_memo.has(path):
		return _file_hash_memo[path]
	var h : String
	if FileAccess.file_exists(path):
		h = FileAccess.get_sha256(path)
	else:
		# Exported build: the file was converted/renamed (.remap/.scn)
		h = "build:" + build_id
	_file_hash_memo[path] = h
	return h


## Environment signature: a change of GPU, driver, engine version or quality settings
## invalidates the whole cache.
func _compute_env_signature() -> String:
	var vp := get_viewport()
	var parts : PackedStringArray = [
		str(CACHE_FORMAT),
		str(Engine.get_version_info().get("hash", "")),
		OS.get_name(),
		RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_api_version(),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		str(vp.msaa_3d),
		str(vp.screen_space_aa),
		str(vp.use_taa),
		str(vp.scaling_3d_mode),
		str(vp.use_debanding),
	]
	return "|".join(parts).sha256_text()


# ---------- Cache storage ----------

func _load_cache() -> void:
	_cache = {}
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var data : Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if data is Dictionary and data.get("signature", "") == _env_signature:
		_cache = data.get("resources", {})


func _save_cache() -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("FSIB: can't write " + CACHE_PATH)
		return
	f.store_string(JSON.stringify({
		"signature": _env_signature,
		"resources": _cache,
	},"\t"))

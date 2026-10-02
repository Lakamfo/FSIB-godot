extends Control

@export_category("Settings")
@export var next_scene : PackedScene
@export var batch_size : int = 2
@export var force_warmup : bool = false
@export_category("Nodes")
@export var fsib_main : FSIB_Main
@export var label : Label
@export var label_bar : Label
@export var progress_bar : ProgressBar
@export var spawn_root : Node

func _ready() -> void:
	fsib_main.status_updated.connect(_status_updated)
	fsib_main.progress_updated.connect(_progress_updated)
	fsib_main.done.connect(warmup_done)
	
	fsib_main.warmup(FSIB_Tools.get_all_resources(), spawn_root, batch_size, force_warmup)

func _status_updated(status : String) -> void:
	if label: label.text = status

func _progress_updated(done : int, overral : int) -> void:
	if progress_bar and label_bar: 
		progress_bar.value = done
		progress_bar.max_value = overral
		
		label_bar.text = "%s/%s" %[done, overral]


func warmup_done() -> void:
	label.text = "Done!"
	if next_scene:
		get_tree().change_scene_to_packed(next_scene)

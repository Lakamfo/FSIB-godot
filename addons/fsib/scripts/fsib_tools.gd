class_name FSIB_Tools

static var ignored_paths : Array[String] = ["res://addons/", "res://.godot/"]
static var warmup_ext : Array[String] = [
	"tscn", "scn", "tres", "res", "material", "glb", "gltf", "fbx"
]


static func get_all_resources(p_warmup_ext : Array[String] = warmup_ext) -> Array[String]:
	var result : Array[String] = []
	for res : String in deep_search("res://", []):
		if res.get_extension().to_lower() in p_warmup_ext:
			result.append(res)
	
	return result


static func deep_search(dir : String, resources : Array[String]) -> Array[String]:
	for item : String in ResourceLoader.list_directory(dir):
		var path : String = dir.path_join(item)
		if item.ends_with("/"):
			if ignored_paths.has(path): continue
			deep_search(path, resources)
		else:
			resources.append(path)
	return resources


static func get_all_children(in_node : Node, array: Array[Node] = []) -> Array[Node]:
	array.push_back(in_node)

	for child in in_node.get_children():
		array = get_all_children(child, array)

	return array

extends RefCounted
## 只做「读 JSON + 按 id 建索引」，不依赖场景树。
## 这样无头脚本（--script）和 autoload 可以共用同一套加载逻辑。

const DATA_DIR := "res://data/"

const TABLES := ["chassis", "engines", "cunits", "weapons", "enemies", "items", "player", "quests"]


static func load_all() -> Dictionary:
	var out := {"balance": _read("balance.json")}
	for table in TABLES:
		out[table] = _index("%s.json" % table)
	var regions := _read("regions.json")
	out["regions"] = _index_rows(regions)
	out["regions_world"] = regions.get("world", {})
	out["maze"] = _read("maze.json")
	out["town_map"] = _read("town_map.json")
	return out


static func _read(file: String) -> Dictionary:
	var path := DATA_DIR + file
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		push_error("数据表解析失败：%s" % path)
		return {}
	return parsed


static func _index(file: String) -> Dictionary:
	return _index_rows(_read(file))


static func _index_rows(table: Dictionary) -> Dictionary:
	var out := {}
	for row in table.get("rows", []):
		out[row["id"]] = row
	return out

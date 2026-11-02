extends RefCounted
## 迷宫规则：把 maze.json 的矩形墙解析成网格，并提供可行走 / 连通性查询。纯函数。

## 生成网格：grid[y][x] = true 表示可走。外圈自动为墙。
static func build_grid(maze: Dictionary) -> Array:
	var cols := int(maze.get("cols", 1))
	var rows := int(maze.get("rows", 1))
	var grid: Array = []
	for y in rows:
		var line: Array = []
		for x in cols:
			var wall := x == 0 or y == 0 or x == cols - 1 or y == rows - 1
			line.append(not wall)
		grid.append(line)
	for w in maze.get("walls", []):
		var r: Array = w
		for y in range(int(r[1]), int(r[1]) + int(r[3])):
			for x in range(int(r[0]), int(r[0]) + int(r[2])):
				if y >= 0 and y < rows and x >= 0 and x < cols:
					grid[y][x] = false
	return grid


static func walkable_in(grid: Array, tile: Vector2i) -> bool:
	if tile.y < 0 or tile.y >= grid.size():
		return false
	var line: Array = grid[tile.y]
	if tile.x < 0 or tile.x >= line.size():
		return false
	return bool(line[tile.x])


static func walkable(maze: Dictionary, tile: Vector2i) -> bool:
	return walkable_in(build_grid(maze), tile)


static func point(key: String, maze: Dictionary) -> Vector2i:
	var t: Array = maze.get(key, [0, 0])
	return Vector2i(int(t[0]), int(t[1]))


## 从某格出发能走到的所有格子集合（key "x,y"），用于校验布局不会出现走不到的角落
static func reachable(grid: Array, from: Vector2i) -> Dictionary:
	var seen := {}
	var queue: Array = []
	if walkable_in(grid, from):
		seen["%d,%d" % [from.x, from.y]] = true
		queue.append(from)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		for d in dirs:
			var nxt: Vector2i = cur + d
			if not walkable_in(grid, nxt):
				continue
			var key := "%d,%d" % [nxt.x, nxt.y]
			if seen.has(key):
				continue
			seen[key] = true
			queue.append(nxt)
	return seen

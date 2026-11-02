extends RefCounted
## 六边形格子规则（纯函数，不依赖场景树）。
## 坐标统一用奇数列偏移（odd-r，尖顶六边形）：cell = Vector2i(col, row)。
## 邻居、距离、可达集、寻路、射程全部走这里，战斗逻辑与 UI 不再自己算坐标。

const INF := 999999


static func in_bounds(cell: Vector2i, cols: int, rows: int) -> bool:
	return cell.x >= 0 and cell.x < cols and cell.y >= 0 and cell.y < rows


static func neighbors(cell: Vector2i) -> Array:
	## odd-r：奇数行整体右移半格，所以右上/右下邻居的列号是 +1。
	var dirs: Array
	if (cell.y & 1) == 0:
		dirs = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1),
			Vector2i(-1, -1), Vector2i(0, 1), Vector2i(-1, 1)]
	else:
		dirs = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(1, -1),
			Vector2i(0, -1), Vector2i(1, 1), Vector2i(0, 1)]
	var out: Array = []
	for d in dirs:
		out.append(cell + d)
	return out


static func _axial(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x - (cell.y - (cell.y & 1)) / 2, cell.y)


static func _from_axial(q: int, r: int) -> Vector2i:
	return Vector2i(q + (r - (r & 1)) / 2, r)


static func distance(a: Vector2i, b: Vector2i) -> int:
	## 六边形最短步数。
	var aa := _axial(a)
	var bb := _axial(b)
	var dq := aa.x - bb.x
	var dr := aa.y - bb.y
	return (absi(dq) + absi(dr) + absi(dq + dr)) / 2


static func in_range(dist: int, range_min: int, range_max: int) -> bool:
	return dist >= range_min and dist <= range_max


static func line(a: Vector2i, b: Vector2i) -> Array:
	## 两格之间的六边形直线（含两端），用立方坐标取整插值。
	var n := distance(a, b)
	if n == 0:
		return [a]
	var av := _axial(a)
	var bv := _axial(b)
	var out: Array = []
	for i in n + 1:
		var t := float(i) / float(n)
		var q := lerpf(float(av.x), float(bv.x), t)
		var r := lerpf(float(av.y), float(bv.y), t)
		var sx := q
		var sz := r
		var sy := -sx - sz
		var rx := roundf(sx)
		var ry := roundf(sy)
		var rz := roundf(sz)
		var dx := absf(rx - sx)
		var dy := absf(ry - sy)
		var dz := absf(rz - sz)
		if dx > dy and dx > dz:
			rx = -ry - rz
		elif dy > dz:
			ry = -rx - rz
		else:
			rz = -rx - ry
		var cell := _from_axial(int(rx), int(rz))
		if out.is_empty() or out[out.size() - 1] != cell:
			out.append(cell)
	return out


static func cells_between(a: Vector2i, b: Vector2i) -> Array:
	## 直线上的中间格（不含两端），弹道遮挡只看这些格子。
	var full := line(a, b)
	var out: Array = []
	for i in range(1, full.size() - 1):
		out.append(full[i])
	return out


static func first_blocker(a: Vector2i, b: Vector2i, blocked_map: Dictionary) -> Vector2i:
	## 弹道最先撞到的障碍物格；没有则返回 (-1,-1)。
	for cell in cells_between(a, b):
		if blocked_map.has(cell):
			return cell
	return Vector2i(-1, -1)


static func cells_in_range(origin: Vector2i, range_min: int, range_max: int, cols: int, rows: int) -> Array:
	var out: Array = []
	for x in cols:
		for y in rows:
			var cell := Vector2i(x, y)
			if in_range(distance(origin, cell), range_min, range_max):
				out.append(cell)
	return out


static func _dijkstra(start: Vector2i, mp: int, cols: int, rows: int,
		blocked: Dictionary, occupied: Dictionary) -> Dictionary:
	var dist := {start: 0}
	var prev := {}
	var open: Array = [start]
	while open.size() > 0:
		var best_i := 0
		for i in range(open.size()):
			if int(dist.get(open[i], INF)) < int(dist.get(open[best_i], INF)):
				best_i = i
		var cur: Vector2i = open[best_i]
		open.remove_at(best_i)
		var base_cost := int(dist[cur])
		for n in neighbors(cur):
			if not in_bounds(n, cols, rows):
				continue
			if blocked.has(n):
				continue
			if occupied.has(n):
				continue
			var step := base_cost + 1
			if step > mp:
				continue
			if step < int(dist.get(n, INF)):
				dist[n] = step
				prev[n] = cur
				if not open.has(n):
					open.append(n)
	return {"dist": dist, "prev": prev}


static func reachable(start: Vector2i, mp: int, cols: int, rows: int,
		blocked: Dictionary, occupied: Dictionary) -> Dictionary:
	## 返回 {cell: 步数}，不含起点。occupied 里应放除自己以外的所有单位。
	var res := _dijkstra(start, mp, cols, rows, blocked, occupied)
	var out: Dictionary = {}
	for cell in res.dist.keys():
		if cell != start:
			out[cell] = int(res.dist[cell])
	return out


static func path(start: Vector2i, goal: Vector2i, mp: int, cols: int, rows: int,
		blocked: Dictionary, occupied: Dictionary) -> Array:
	## 返回从起点到终点的格子序列（不含起点）；不可达返回空数组。
	var res := _dijkstra(start, mp, cols, rows, blocked, occupied)
	var dist: Dictionary = res.dist
	if not dist.has(goal):
		return []
	var out: Array = []
	var cur: Vector2i = goal
	while cur != start:
		out.push_front(cur)
		cur = res.prev.get(cur, start)
	return out


static func nearest_distance(from: Vector2i, targets: Array) -> int:
	var best := INF
	for t in targets:
		var d := distance(from, t)
		if d < best:
			best = d
	return best

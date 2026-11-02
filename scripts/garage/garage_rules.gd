extends RefCounted
## 改装校验：GDD 4.2 的三条规则，纯函数，不依赖场景树、不依赖 autoload。
## 规则 1 槽位数量：同类武器数 ≤ 该类槽位数
## 规则 2 槽位尺寸：同类武器与同类槽位都按 size 降序逐一配对，武器 size ≤ 槽位 size
## 规则 3 载重：sum(全车部件重量) ≤ 引擎出力
## 机动值直接复用 battle_math.speed()，保证改装界面与战斗里算出来的一致。

const BM := preload("res://scripts/battle/battle_math.gd")

const SIZE_ORDER := {"S": 0, "M": 1, "L": 2}
const TYPES := ["main", "sub", "se"]
const TYPE_LABELS := {"main": "主炮", "sub": "副炮", "se": "SE"}


static func evaluate(build: Dictionary, tables: Dictionary) -> Dictionary:
	var chassis: Dictionary = tables.chassis[build.chassis_id]
	var engine: Dictionary = tables.engines[build.engine_id]
	var cunit: Dictionary = tables.cunits[build.cunit_id]

	var total := int(chassis.weight) + int(engine.weight) + int(cunit.weight)
	var weapon_rows: Array = []
	for wid in build.weapons:
		var row: Dictionary = tables.weapons[wid]
		total += int(row.weight)
		weapon_rows.append(row)

	var slot_counts := {}
	var slot_sizes := {}
	for slot in chassis.slots:
		var st: String = slot.type
		slot_counts[st] = int(slot_counts.get(st, 0)) + 1
		if not slot_sizes.has(st):
			slot_sizes[st] = []
		slot_sizes[st].append(int(SIZE_ORDER.get(slot.size, 0)))

	var weapon_counts := {}
	var weapon_sizes := {}
	for row in weapon_rows:
		var wt: String = row.type
		weapon_counts[wt] = int(weapon_counts.get(wt, 0)) + 1
		if not weapon_sizes.has(wt):
			weapon_sizes[wt] = []
		weapon_sizes[wt].append(int(SIZE_ORDER.get(row.size, 0)))

	# 逐类型判定，UI 用 type_status 高亮对应分区
	var type_status := {}
	var count_ok := true
	var size_ok := true
	for t in TYPES:
		var have := int(weapon_counts.get(t, 0))
		var cap := int(slot_counts.get(t, 0))
		var t_count_ok := have <= cap
		var t_size_ok := true
		if have > 0 and cap > 0:
			var ws: Array = weapon_sizes[t].duplicate()
			var ss: Array = slot_sizes[t].duplicate()
			ws.sort()
			ws.reverse()
			ss.sort()
			ss.reverse()
			for i in mini(ws.size(), ss.size()):
				if int(ws[i]) > int(ss[i]):
					t_size_ok = false
					break
		elif have > 0 and cap == 0:
			t_size_ok = false
		# 超出槽位的部分由数量规则负责，尺寸只比配对得上那些
		count_ok = count_ok and t_count_ok
		size_ok = size_ok and t_size_ok
		type_status[t] = {
			"have": have,
			"cap": cap,
			"count_ok": t_count_ok,
			"size_ok": t_size_ok,
			"widths": slot_sizes.get(t, []),
		}

	var output := int(engine.output)
	var load_ok := total <= output
	var speed := BM.speed(output, total, tables.balance.speed)

	var checks := [
		{
			"key": "count",
			"label": "槽位数量",
			"ok": count_ok,
			"detail": _count_detail(type_status),
		},
		{
			"key": "size",
			"label": "槽位尺寸",
			"ok": size_ok,
			"detail": "按尺寸降序配对" if size_ok else _size_detail(type_status),
		},
		{
			"key": "load",
			"label": "载重",
			"ok": load_ok,
			"detail": "%d / %d%s" % [total, output, "" if load_ok else "（超 %d）" % (total - output)],
		},
	]

	return {
		"ok": count_ok and size_ok and load_ok,
		"total_weight": total,
		"output": output,
		"overload": maxi(0, total - output),
		"speed": speed,
		"checks": checks,
		"type_status": type_status,
		"weapon_counts": weapon_counts,
		"slot_counts": slot_counts,
	}


## 该武器在该底盘上尺寸是否放得下（单件判断，用于行高亮）
static func fits_slot(weapon_row: Dictionary, chassis: Dictionary) -> bool:
	var need := int(SIZE_ORDER.get(weapon_row.size, 0))
	var wt: String = weapon_row.type
	var best := -1
	for slot in chassis.slots:
		if slot.type == wt:
			best = maxi(best, int(SIZE_ORDER.get(slot.size, 0)))
	if best < 0:
		return false
	return need <= best


static func _count_detail(type_status: Dictionary) -> String:
	var parts: Array = []
	for t in TYPES:
		var st: Dictionary = type_status[t]
		if int(st.have) > 0 or int(st.cap) > 0:
			parts.append("%s %d/%d" % [TYPE_LABELS[t], int(st.have), int(st.cap)])
	return "，".join(parts)


static func _size_detail(type_status: Dictionary) -> String:
	var parts: Array = []
	for t in TYPES:
		var st: Dictionary = type_status[t]
		if not bool(st.size_ok) and int(st.have) > 0:
			parts.append("%s 尺寸不符" % TYPE_LABELS[t])
	return "，".join(parts)

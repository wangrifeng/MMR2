extends Node
## 战场上的一个单位：战车 / 步行人物 / 敌人。
## M4 起每个单位都有六边形坐标、移动点数与武器射程；旧的一次性开火模型已移除。
## 注意：没有 class_name，Controller / AI 用 preload 引用。

signal died(unit)

const BM := preload("res://scripts/battle/battle_math.gd")
const Hex := preload("res://scripts/battle/hex_rules.gd")

var is_player: bool
var is_vehicle: bool
var is_character: bool
var label: String
var source_id: String          # 敌人表 id / 玩家单位标识
var sprite_path: String = ""   # 敌人图鉴贴图；空 = 用程序化几何图形
var ai: String

# 格子与行动
var cell: Vector2i = Vector2i(-1, -1)
var speed: int
var max_mp: int
var mp: int
var has_moved: bool
var has_acted: bool

# 生命
var armor: int
var max_armor: int
var hp: int
var max_hp: int
var def: int
var eva: int

# 公式属性
var hit_mod: int
var crit_mod: int
var reload: int
var drive_level: int
var agi: int
var power: int
var weapon_level: int
var personality_attack: int
var cunit_speed_trait: int
var chassis_speed_trait: int
# 攻击回合数加成：人物看性格，战车看 C 特性与底盘特性
var personality_rounds: int
var cunit_rounds: int
var chassis_rounds: int

# 武器：[{id,name,atk_min,atk_max,acc,ammo,max_ammo,range_min,range_max,melee,atk_speed,crit,...}]
var weapons: Array = []

# 排序 tie-break
var tie: int = 0

# 与 GameState 的回写位置：-1 = 主车，>=0 = extra_vehicles 下标；char_index 同理
var runtime_index: int = -1
var char_index: int = -1

var _dead_emitted: bool = false


func is_alive() -> bool:
	return hp > 0


func begin_activation() -> void:
	mp = max_mp
	has_moved = false
	has_acted = false


func stats() -> Dictionary:
	return {
		"is_vehicle": is_vehicle,
		"is_character": is_character,
		"speed": speed,
		"drive_level": drive_level,
		"agi": agi,
		"hit_mod": hit_mod,
		"crit_mod": crit_mod,
		"reload": reload,
		"cunit_speed_trait": cunit_speed_trait,
		"chassis_speed_trait": chassis_speed_trait,
		"personality_attack": personality_attack,
		"personality_rounds": personality_rounds,
		"cunit_rounds": cunit_rounds,
		"chassis_rounds": chassis_rounds,
		"power": power,
		"weapon_level": weapon_level,
		"def": def,
		"eva": eva,
	}


# -------- 工厂 --------

static func from_vehicle(runtime: Dictionary, build: Dictionary, chassis_row: Dictionary,
		engine_row: Dictionary, cunit_row: Dictionary, player_row: Dictionary,
		balance: Dictionary, weapon_tbl: Dictionary, label_text: String,
		runtime_idx: int = -1):
	var u = new()
	u.is_player = true
	u.is_vehicle = true
	u.is_character = false
	u.label = label_text
	u.source_id = "player_vehicle"
	u.runtime_index = runtime_idx
	u.max_armor = int(runtime.get("max_armor", 0))
	u.armor = int(runtime.get("armor", 0))
	u.max_hp = int(runtime.get("max_hp", 0))
	u.hp = int(runtime.get("hp", 0))
	u.def = int(chassis_row.get("def", 0))
	u.eva = int(cunit_row.get("eva_bonus", 0))
	u.hit_mod = int(cunit_row.get("acc_bonus", 0))
	u.crit_mod = int(cunit_row.get("crit", 0))
	u.reload = int(cunit_row.get("reload", 0))
	u.cunit_speed_trait = int(cunit_row.get("speed_trait", 0))
	u.chassis_speed_trait = int(chassis_row.get("speed_trait", 0))
	u.cunit_rounds = int(cunit_row.get("attack_rounds", 0))
	u.chassis_rounds = int(chassis_row.get("attack_rounds", 0))
	u.drive_level = int(player_row.get("drive_level", 0))
	u.agi = int(player_row.get("agi_level", 0))
	u.power = u.drive_level + int(cunit_row.get("damage_trait", 0)) \
		+ int(chassis_row.get("damage_trait", 0))
	u.weapon_level = u.drive_level

	var total_weight := int(chassis_row.get("weight", 0)) + int(engine_row.get("weight", 0)) \
		+ int(cunit_row.get("weight", 0))
	for wid in build.weapons:
		total_weight += int(weapon_tbl[wid].get("weight", 0))
	u.speed = BM.speed(int(engine_row.get("output", 0)), total_weight, balance.speed)
	u.max_mp = BM.mp_from_speed(u.speed, balance.battle)
	u.mp = u.max_mp

	var states: Array = runtime.get("weapons", [])
	if states.is_empty():
		for wid in build.weapons:
			u.weapons.append(_clone_weapon(weapon_tbl[wid], int(weapon_tbl[wid].ammo)))
	else:
		for ws in states:
			var row: Dictionary = weapon_tbl.get(str(ws.id), {})
			u.weapons.append(_clone_weapon(row, int(ws.ammo), int(ws.max_ammo)))
	return u


static func from_character(char_state: Dictionary, player_row: Dictionary, balance: Dictionary,
		char_idx: int = 0):
	var u = new()
	u.is_player = true
	u.is_vehicle = false
	u.is_character = true
	u.label = str(player_row.get("name", "猎人"))
	u.source_id = str(char_state.get("id", "p_hunter"))
	u.char_index = char_idx
	u.max_armor = 0
	u.armor = 0
	u.max_hp = int(char_state.get("max_hp", player_row.get("hp", 40)))
	u.hp = int(char_state.get("hp", u.max_hp))
	u.def = int(player_row.get("def", 0))
	u.eva = int(player_row.get("eva", 0))
	u.hit_mod = int(player_row.get("hit_mod", 0))
	u.crit_mod = int(player_row.get("crit_mod", 0))
	u.personality_attack = int(player_row.get("personality_attack", 0))
	u.personality_rounds = int(player_row.get("personality_rounds", 0))
	u.reload = 0
	u.drive_level = 0
	u.agi = int(player_row.get("agi_level", 0))
	u.power = int(player_row.get("force_level", 0))
	u.weapon_level = int(player_row.get("weapon_level", 0))
	u.speed = int(player_row.get("spd", 10))
	u.max_mp = BM.mp_from_speed(u.speed, balance.battle)
	u.mp = u.max_mp
	for w in player_row.get("weapons", []):
		u.weapons.append(_clone_weapon(w, 999))
	return u


static func from_enemy(row: Dictionary, balance: Dictionary):
	var u = new()
	u.is_player = false
	u.is_vehicle = bool(row.get("is_vehicle", false))
	u.is_character = false
	u.label = str(row.name)
	u.source_id = str(row.id)
	u.sprite_path = str(row.get("sprite", ""))
	u.ai = str(row.get("ai", "random"))
	u.max_armor = int(row.get("armor", 0))
	u.armor = int(row.get("armor", 0))
	u.max_hp = int(row.hp)
	u.hp = int(row.hp)
	u.def = int(row.get("def", 0))
	u.eva = int(row.get("eva", 0))
	u.hit_mod = int(row.get("hit_mod", 0))
	u.crit_mod = int(row.get("crit_mod", 0))
	u.reload = 0
	u.drive_level = int(row.get("drive_level", 8))
	u.agi = int(row.get("agi_level", 8))
	u.power = u.drive_level
	u.weapon_level = u.drive_level
	u.speed = int(row.get("spd", 10))
	u.max_mp = BM.mp_from_speed(u.speed, balance.battle)
	u.mp = u.max_mp
	u.weapons.append(_clone_weapon({
		"id": "natural",
		"name": str(row.name),
		"atk": int(row.get("atk", 0)),
		"atk_min": int(row.get("atk_min", row.get("atk", 0))),
		"atk_max": int(row.get("atk_max", row.get("atk", 0))),
		"acc": int(row.get("acc", 0)),
		"range_min": int(row.get("range_min", 1)),
		"range_max": int(row.get("range_max", 1)),
		"melee": bool(row.get("melee", false)),
		"atk_speed": int(row.get("atk_speed", 1)),
		"crit": float(row.get("crit", 0)),
		"hit_trait": int(row.get("hit_trait", 0)),
		"damage_trait": int(row.get("damage_trait", 0)),
		"aoe": bool(row.get("aoe", false)),
		"aoe_radius": int(row.get("aoe_radius", 0)),
		"atk_rounds": int(row.get("atk_rounds", 1)),
	}, 999))
	return u


static func _clone_weapon(row: Dictionary, ammo_value: int = -1, max_ammo_value: int = -1) -> Dictionary:
	var max_ammo := max_ammo_value if max_ammo_value >= 0 else int(row.get("ammo", 999))
	var ammo := ammo_value if ammo_value >= 0 else max_ammo
	return {
		"id": str(row.get("id", "natural")),
		"name": str(row.get("name", "")),
		"atk": int(row.get("atk", 0)),
		"atk_min": int(row.get("atk_min", row.get("atk", 0))),
		"atk_max": int(row.get("atk_max", row.get("atk", 0))),
		"acc": int(row.get("acc", 0)),
		"ammo": ammo,
		"max_ammo": max_ammo,
		"range_min": int(row.get("range_min", 1)),
		"range_max": int(row.get("range_max", 1)),
		"melee": bool(row.get("melee", false)),
		"atk_speed": int(row.get("atk_speed", 0)),
		"crit": float(row.get("crit", 0)),
		"hit_trait": int(row.get("hit_trait", 0)),
		"damage_trait": int(row.get("damage_trait", 0)),
		"aoe": bool(row.get("aoe", false)),
		"aoe_radius": int(row.get("aoe_radius", 0)),
		"atk_rounds": int(row.get("atk_rounds", 1)),
	}


# -------- 动作 --------

func usable_weapons() -> Array:
	var out: Array = []
	for w in weapons:
		if int(w.ammo) > 0:
			out.append(w)
	return out


func can_hit(cell_from: Vector2i, target, weapon: Dictionary, cfg: Dictionary) -> bool:
	var dist := Hex.distance(cell_from, target.cell)
	# 低于最小射程打不到；射程内照常打，超出最大射程则限在 range_max×2 内强攻
	if dist < int(weapon.range_min):
		return false
	return BM.in_attack_span(dist, weapon, cfg)


func fire(weapon: Dictionary, targets: Array, balance: Dictionary, rng: RandomNumberGenerator) -> Array:
	## 每次攻击独立走 命中→暴击→伤害；返回每一击 vs 每个目标的结果。
	## 总发数 = 攻击回合数 × 一回攻击几次，按回合依次打光（弹药不够就提前停）。
	var cfg: Dictionary = balance.combat_v2
	var results: Array = []
	var rounds := BM.attack_rounds(stats(), weapon, cfg)
	var count := BM.attack_count(stats(), weapon, cfg)
	var damage_power := power
	if is_character and not bool(weapon.melee):
		damage_power = weapon_level
	for _r in rounds:
		for _i in count:
			if int(weapon.ammo) <= 0:
				break
			weapon.ammo = int(weapon.ammo) - 1
			for t in targets:
				if not t.is_alive():
					continue
				var dist := Hex.distance(cell, t.cell)
				var probability := BM.effective_hit_chance(weapon, stats(), t.stats(), dist, cfg)
				if rng.randf() > probability:
					results.append({"target": t, "hit": false, "crit": "none", "damage": 0,
						"armor_left": t.armor, "hp_left": t.hp})
					continue
				var crit_kind := "none"
				# 超出最大射程的强攻必定不暴击
				if not BM.is_overrange(dist, weapon):
					var crit_rate := BM.crit_chance(weapon, stats(), dist,
						int(weapon.range_min), int(weapon.range_max), cfg)
					if rng.randf() < crit_rate:
						if rng.randf() < float(cfg.crit.true_sub_rate):
							crit_kind = "true"
						else:
							crit_kind = "normal"
				var ratio := BM.distance_ratio(dist, int(weapon.range_min), int(weapon.range_max))
				var roll := rng.randi_range(int(weapon.atk_min), int(weapon.atk_max))
				var base := BM.raw_damage(damage_power, roll, dist, ratio, cfg,
					not bool(weapon.melee))
				var damage := BM.branch_damage(base, int(t.def), crit_kind, cfg)
				t.take_damage(damage)
				results.append({"target": t, "hit": true, "crit": crit_kind, "damage": damage,
					"armor_left": t.armor, "hp_left": t.hp})
		if int(weapon.ammo) <= 0:
			break
	return results


func take_damage(damage: int) -> void:
	## 装甲是吸收池：有甲先扣甲，溢出打 HP；HP 归零才算报废。
	var rest := damage
	if is_vehicle:
		var absorbed := mini(armor, rest)
		armor -= absorbed
		rest -= absorbed
	if rest > 0:
		hp = maxi(0, hp - rest)
	if hp <= 0 and not _dead_emitted:
		_dead_emitted = true
		died.emit(self)

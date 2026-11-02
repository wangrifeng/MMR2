class_name BattleMath
extends RefCounted
## 所有战斗公式的唯一实现。系数一律从 balance.json 传入，这里不出现任何魔法数。
## combat_v2 段对应《战斗数值策划文档 V1.0》：
##   攻击次数 = floor(加权和)，保底 1
##   命中率 = clamp(sigmoid(加权和), 5%, 95%)
##   暴击率 = clamp(sigmoid(加权和), 1%, 70%)，A 方案：暴击后再 roll 子概率升级为真实暴击
##   伤害 = (基础值 × 距离伤害加成) 按暴击分支结算，最终伤害保底 1
## 旧 combat 段的方法保留给 M0 模拟器与改装厂（机动值计算）。


## 机动 = clamp(round(出力 / 总重 × weight_factor), min, max)
static func speed(output: int, total_weight: int, speed_cfg: Dictionary) -> int:
	if total_weight <= 0:
		return int(speed_cfg.min)
	var raw := float(output) / float(total_weight) * float(speed_cfg.weight_factor)
	return clampi(roundi(raw), int(speed_cfg.min), int(speed_cfg.max))


# ==================== M4 六边形战棋公式 ====================

static func sigmoid(x: float) -> float:
	return 1.0 / (1.0 + exp(-x))


## 移动点数：机动越高，格子内能走的步数越多。
static func mp_from_speed(speed_value: int, battle_cfg: Dictionary) -> int:
	var divisor := maxi(1, int(battle_cfg.get("mp_divisor", 8)))
	return clampi(roundi(float(speed_value) / float(divisor)),
		int(battle_cfg.get("mp_min", 2)), int(battle_cfg.get("mp_max", 6)))


## 每回合攻击次数。stats 需要 is_vehicle / speed / drive_level / reload / 特性字段。
static func attack_count(stats: Dictionary, weapon: Dictionary, cfg: Dictionary) -> int:
	var ac: Dictionary = cfg.attack_count
	var raw := 0.0
	if bool(stats.get("is_vehicle", false)):
		raw = float(stats.get("drive_level", 0)) * float(ac.veh_k_driver) \
			+ float(weapon.get("atk_speed", 0)) * float(ac.veh_k_weapon) \
			+ float(stats.get("reload", 0)) * float(ac.veh_k_reload) \
			+ float(stats.get("cunit_speed_trait", 0)) * float(ac.veh_k_cunit_trait) \
			+ float(stats.get("chassis_speed_trait", 0)) * float(ac.veh_k_chassis_trait)
	else:
		raw = float(stats.get("personality_attack", 0)) * float(ac.char_k_personality) \
			+ float(stats.get("speed", 0)) * float(ac.char_k_speed) \
			+ float(weapon.get("atk_speed", 0)) * float(ac.char_k_weapon)
	return maxi(int(ac.min), int(floor(raw)))


## 攻击回合数：人物 = 性格加成 + 武器自带回合数；
## 战车 = C特性加成 + 底盘特性加成 + 武器自带回合数。
static func attack_rounds(stats: Dictionary, weapon: Dictionary, cfg: Dictionary) -> int:
	var ar: Dictionary = cfg.attack_rounds
	var raw := float(weapon.get("atk_rounds", ar.get("weapon_default", 1)))
	if bool(stats.get("is_vehicle", false)):
		raw += float(stats.get("cunit_rounds", 0)) + float(stats.get("chassis_rounds", 0))
	else:
		raw += float(stats.get("personality_rounds", 0))
	return clampi(roundi(raw), int(ar.min), int(ar.max))


## 一次攻击的总发数 = 攻击回合数 × 一回攻击几次。
static func total_attacks(stats: Dictionary, weapon: Dictionary, cfg: Dictionary) -> int:
	return attack_rounds(stats, weapon, cfg) * attack_count(stats, weapon, cfg)


## 距离占比：在武器有效射程内归一化，最近=0，最远=1。
static func distance_ratio(dist: int, range_min: int, range_max: int) -> float:
	if range_max <= range_min:
		return 0.0
	return clampf(float(dist - range_min) / float(range_max - range_min), 0.0, 1.0)


## 命中率（钳位后）。对方闪避在判定时叠加，见 effective_hit_chance。
static func hit_chance(weapon: Dictionary, stats: Dictionary, distance: int, cfg: Dictionary) -> float:
	var h: Dictionary = cfg.hit
	var raw := float(weapon.get("acc", 0)) * float(h.k_weapon_acc) \
		+ float(stats.get("hit_mod", 0)) * float(h.k_hit_mod) \
		+ float(stats.get("drive_level", 0)) * float(h.k_driver) \
		+ float(stats.get("agi", 0)) * float(h.k_agi) \
		- float(distance) * float(h.k_distance) \
		+ float(h.in_range_bonus) * float(h.k_range) \
		+ float(weapon.get("hit_trait", 0)) * float(h.k_trait)
	return clampf(sigmoid(raw), float(h.min), float(h.max))


## 实际命中概率：文档口径「命中率 > 随机值 + 对方闪避」。
static func effective_hit_chance(weapon: Dictionary, stats: Dictionary, target: Dictionary,
		distance: int, cfg: Dictionary) -> float:
	var h: Dictionary = cfg.hit
	var eva := clampf(float(target.get("eva", 0)) / 100.0 * float(h.k_eva), 0.0, float(h.max_eva_cut))
	var chance := overrange_hit_chance(weapon, stats, distance, cfg) \
		if is_overrange(distance, weapon) else hit_chance(weapon, stats, distance, cfg)
	return clampf(chance - eva, 0.0, 1.0)


## 是否属于「超出最大射程的强攻」：近战武器不行；比最小射程还近也不算。
static func is_overrange(distance: int, weapon: Dictionary) -> bool:
	if bool(weapon.get("melee", false)):
		return false
	return distance > int(weapon.get("range_max", 1))


## 能打到的最大格数：远程武器可打到 range_max × range_multiplier，近战仍只到 range_max。
static func max_attack_range(weapon: Dictionary, cfg: Dictionary) -> int:
	var reach := int(weapon.get("range_max", 1))
	if bool(weapon.get("melee", false)):
		return reach
	return reach * int(cfg.overrange.range_multiplier)


## 是否落在可攻击距离内（射程内 + 超程强攻的最大距离）。
static func in_attack_span(distance: int, weapon: Dictionary, cfg: Dictionary) -> bool:
	return distance <= max_attack_range(weapon, cfg)


## 超程强攻命中率：基础命中 × 衰减倍数，每多 1 格再扣固定值，钳在最低命中之上。
static func overrange_hit_chance(weapon: Dictionary, stats: Dictionary, distance: int,
		cfg: Dictionary) -> float:
	var o: Dictionary = cfg.overrange
	var extra := float(maxi(0, distance - int(weapon.get("range_max", 1))))
	var base := hit_chance(weapon, stats, distance, cfg)
	return clampf(base * float(o.hit_multiplier) - float(o.per_hex_penalty) * extra,
		float(o.min_hit), float(cfg.hit.max))


## 暴击率。距离越近，距离暴击修正越高。
static func crit_chance(weapon: Dictionary, stats: Dictionary, distance: int,
		range_min: int, range_max: int, cfg: Dictionary) -> float:
	var c: Dictionary = cfg.crit
	var ratio := distance_ratio(distance, range_min, range_max)
	var correction := float(c.crit_correction) * (1.0 - ratio)
	var raw := float(weapon.get("crit", 0)) * float(c.k_weapon_base) \
		+ float(stats.get("crit_mod", 0)) * float(c.k_crit_mod) \
		+ float(stats.get("agi", 0)) * float(c.k_agi) \
		+ correction * float(c.k_distance) \
		+ float(c.bias)
	return clampf(sigmoid(raw), float(c.min), float(c.max))


## 基础伤害：力量/驾驶等级等 + 武器区间随机值（远程再加双方距离），再乘距离伤害加成。
static func raw_damage(power: int, weapon_roll: int, distance: int,
		ratio: float, cfg: Dictionary, add_distance: bool) -> float:
	var d: Dictionary = cfg.damage
	var value := float(power + weapon_roll)
	if add_distance:
		value += float(distance)
	return value * (1.0 + float(d.k_dmg) * ratio)


## 三种暴击分支的最终伤害。
static func branch_damage(base: float, target_def: int, crit_kind: String, cfg: Dictionary) -> int:
	var c: Dictionary = cfg.crit
	var d: Dictionary = cfg.damage
	var minimum := int(d.min)
	var value := 0.0
	match crit_kind:
		"true":
			return maxi(minimum, roundi(base * float(c.true_multiplier)))
		"normal":
			value = base * float(c.normal_multiplier) - float(target_def) * float(d.def_factor)
		_:
			value = base - float(target_def) * float(d.def_factor)
	return maxi(minimum, roundi(value))


## AI 打分用的期望值：命中 × 单次期望伤害 × 攻击次数。
static func expected_v2(stats: Dictionary, weapon: Dictionary, target: Dictionary,
		distance: int, cfg: Dictionary) -> float:
	var ratio := distance_ratio(distance, int(weapon.get("range_min", 1)), int(weapon.get("range_max", 1)))
	var roll := (int(weapon.get("atk_min", 0)) + int(weapon.get("atk_max", 0))) / 2.0
	var add_distance := not bool(weapon.get("melee", false))
	var power := int(stats.get("power", 0))
	if bool(stats.get("is_character", false)) and not bool(weapon.get("melee", false)):
		power = int(stats.get("weapon_level", power))
	var base := raw_damage(power, int(roll), distance, ratio, cfg, add_distance)
	# 超程强攻必定不暴击，期望值里也不计暴击收益
	var crit := 0.0
	if not is_overrange(distance, weapon):
		crit = crit_chance(weapon, stats, distance,
			int(weapon.get("range_min", 1)), int(weapon.get("range_max", 1)), cfg)
	var damage := base * (1.0 + crit * (float(cfg.crit.normal_multiplier) - 1.0)) \
		- float(target.get("def", 0)) * float(cfg.damage.def_factor)
	var probability := effective_hit_chance(weapon, stats, target, distance, cfg)
	return float(maxi(1, roundi(damage))) * probability * float(total_attacks(stats, weapon, cfg))


# ==================== 旧 combat 段（M0 模拟器 / 改装厂） ====================

## 命中率，返回 0.0–1.0
static func hit_rate(weapon_acc: int, acc_bonus: int, target_eva: int, combat: Dictionary) -> float:
	var percent := clampf(
		float(weapon_acc + acc_bonus - target_eva),
		float(combat.hit_base_min),
		float(combat.hit_base_max)
	)
	return percent / 100.0


## 基础伤害（未乘浮动、未算暴击）
static func base_damage(atk: int, target_def: int, combat: Dictionary) -> float:
	return float(atk) - float(target_def) * float(combat.defense_factor)


## 单次攻击的期望伤害（已含暴击概率，不含命中率）
static func expected_damage(atk: int, target_def: int, combat: Dictionary) -> float:
	var crit_avg := 1.0 + float(combat.crit_rate) * (float(combat.crit_multiplier) - 1.0)
	return maxf(0.0, base_damage(atk, target_def, combat)) * crit_avg


## 掷一次伤害：浮动 + 暴击 + 保底
static func roll_damage(atk: int, target_def: int, combat: Dictionary, rng: RandomNumberGenerator) -> int:
	var variance := float(combat.damage_variance)
	var value := base_damage(atk, target_def, combat) * rng.randf_range(1.0 - variance, 1.0 + variance)
	if rng.randf() < float(combat.crit_rate):
		value *= float(combat.crit_multiplier)
	return maxi(int(combat.min_damage), roundi(value))

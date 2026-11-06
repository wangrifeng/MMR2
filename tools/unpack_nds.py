#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NDS ROM 解包工具（基于 ndspy）。

功能：
  1. 读取 .nds ROM，导出完整文件系统到 <out>/rom/
  2. 递归识别 NARC 容器（含 NARC 内嵌 NARC），解包到 <out>/narc/
  3. 识别本作使用的 pack_data.pak 自定义包，解包到 <out>/pak/
  4. 按魔数/扩展名收集 NSCR / NCGR / NCLR，复制到 <out>/sorted/{nscr,ncgr,nclr}/

用法：
  python unpack_nds.py "游戏.nds"
  python unpack_nds.py "游戏.nds" -o "unpacked" --max-depth 3
  python unpack_nds.py "游戏.nds" --dry-run
"""

import argparse
import os
import re
import shutil
import struct
import sys
from pathlib import Path

try:
    import ndspy.rom
    from ndspy.narc import NARC
    from ndspy.soundArchive import SDAT
except ImportError as exc:  # pragma: no cover
    sys.exit("缺少依赖 ndspy，请先安装：pip install ndspy\n(%s)" % exc)

NARC_MAGIC = b"NARC"
SDAT_MAGIC = b"SDAT"
# DS 图形格式的魔数（字节倒序存储）
GRAPHICS_MAGIC = {
    b"RCSN": "nscr",   # 地图布局
    b"RGCN": "ncgr",   # 图块
    b"RLCN": "nclr",   # 调色板
}
# 音频容器 SDAT 及其子块魔数
AUDIO_MAGIC = {
    b"SSEQ": "sseq",   # 序列音乐（BGM）
    b"SBNK": "sbnk",   # 乐器库
    b"SWAR": "swar",   # 波表目录
    b"SWAV": "swav",   # 短音频（音效）
    b"STRM": "strm",   # 流式音频
}
EXT_TO_KIND = {".nscr": "nscr", ".ncgr": "ncgr", ".nclr": "nclr"}
AUDIO_EXT_TO_KIND = {".sseq": "sseq", ".sbnk": "sbnk", ".swar": "swar",
                      ".swav": "swav", ".strm": "strm"}
# 解包时按魔数补的扩展名
MAGIC_EXT = {
    b"RCSN": ".nscr",
    b"RGCN": ".ncgr",
    b"RLCN": ".nclr",
    b"RTFN": ".nftr",
    b"NARC": ".narc",
    b"SSEQ": ".sseq",
    b"SBNK": ".sbnk",
    b"SWAR": ".swar",
    b"SWAV": ".swav",
    b"STRM": ".strm",
}
BAD_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def safe(name, fallback="file"):
    """把 ROM/NARC 内的名字清洗成 Windows 可用文件名。"""
    name = BAD_CHARS.sub("_", str(name)).strip(" .")
    return name or fallback


def graphics_kind(head, filename=""):
    """优先按 4 字节魔数判定，其次按扩展名。"""
    if len(head) >= 4:
        kind = GRAPHICS_MAGIC.get(bytes(head[:4]))
        if kind:
            return kind
    return EXT_TO_KIND.get(os.path.splitext(filename)[1].lower())


class Stats:
    def __init__(self):
        self.rom_files = 0
        self.narcs = 0
        self.narc_files = 0
        self.narc_failed = 0
        self.paks = 0
        self.pak_files = 0
        self.pak_failed = 0
        self.sdats = 0
        self.sdat_items = 0   # sseq/sbnk/swar/swav/strm 总数
        self.sdat_failed = 0
        self.graphics = {"nscr": 0, "ncgr": 0, "nclr": 0}
        self.audio = {"sseq": 0, "sbnk": 0, "swar": 0, "swav": 0, "strm": 0}

    def summary(self):
        return (
            "ROM 文件 %d 个 | NARC %d 个（失败 %d）| NARC 内文件 %d 个 | "
            "pak %d 个（失败 %d）| pak 内文件 %d 个 | "
            "SDAT %d 个（失败 %d）| SDAT 内 %d 个 | "
            "NSCR %d / NCGR %d / NCLR %d | "
            "SSEQ %d / SBNK %d / SWAR %d / SWAV %d / STRM %d"
            % (
                self.rom_files,
                self.narcs,
                self.narc_failed,
                self.narc_files,
                self.paks,
                self.pak_failed,
                self.pak_files,
                self.sdats,
                self.sdat_failed,
                self.sdat_items,
                self.graphics["nscr"],
                self.graphics["ncgr"],
                self.graphics["nclr"],
                self.audio["sseq"],
                self.audio["sbnk"],
                self.audio["swar"],
                self.audio["swav"],
                self.audio["strm"],
            )
        )


def write_bytes(path, data, dry):
    if dry:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fp:
        fp.write(bytes(data))


def narc_names(filename_table):
    """把 ndspy 的文件名表展开成 {文件ID: NARC 内相对路径}。

    ndspy 的 NARC.filenames 是 fnt.Folder（不可迭代、不能按下标取值），
    这里手动遍历它的 files / folders 两层结构。
    """
    if not filename_table:
        return {}
    if isinstance(filename_table, (list, tuple)):  # 兼容旧版 ndspy 的纯列表
        return {i: str(n) for i, n in enumerate(filename_table) if n}

    names = {}
    stack = [("", filename_table)]
    while stack:
        prefix, folder = stack.pop()
        first = getattr(folder, "firstID", 0)
        for i, fname in enumerate(getattr(folder, "files", None) or []):
            names[first + i] = prefix + str(fname)
        for sub_name, sub in getattr(folder, "folders", None) or []:
            stack.append((prefix + str(sub_name) + "/", sub))
    return names


def relative_parts(raw):
    """把 NARC 内的相对路径拆成安全的路径片段。"""
    raw = raw.replace("\\", "/")
    return [safe(p) for p in raw.split("/") if p not in ("", ".", "..")]


def parse_pak(data):
    """解析 pack_data.pak（本作自定义包）。

    结构：
        0x00 u16 条目数 count
        0x02 u16 条目表偏移 tableOffset
        0x04 u16 保留（恒 0）
        0x06 u16 名字池结束偏移 namesEnd
        0x08 .. namesEnd    '\\0' 分隔的字符串池
        namesEnd .. table  未知元数据区（本工具不关心）
        table    count 条 { u32 size, u32 offset }（absolute 偏移）
        数据区从 table + count*8 开始

    返回 (names, entries)；不是合法 pak 时返回 None。
    """
    if len(data) < 8:
        return None
    count, table, reserved, names_end = struct.unpack_from("<HHHH", data, 0)
    if reserved != 0 or table > len(data) or names_end < 8 or names_end > len(data):
        return None
    names = [
        s.decode("cp932", "replace")
        for s in bytes(data[8:names_end]).split(b"\x00")
        if s
    ]
    if count == 0:  # 空包：8 字节头，count/条目全为 0
        return names, []
    if table < 8 or names_end > table:
        return None
    table_end = table + count * 8
    if table_end > len(data):
        return None

    entries = []
    for i in range(count):
        size, offset = struct.unpack_from("<II", data, table + i * 8)
        if offset < table_end or offset + size > len(data):
            return None
        entries.append((size, offset))
    # 数据区必须紧跟在条目表后面（所有 pak 都满足，可排除误判）
    if min(offset for _size, offset in entries) != table_end:
        return None
    return names, entries


def is_pak(data):
    return parse_pak(data) is not None


def pak_name(names, count, index, blob):
    """给出 pak 条目在磁盘上的文件名。

    count == len(names) 时名字池就是完整文件名，直接用；
    否则名字池只是前缀/后缀片段（无法还原），退化为 file_序号，
    并按魔数补扩展名。
    """
    parts = []
    if names and count == len(names):
        parts = relative_parts(names[index])
    if parts:
        stem = safe(Path(parts[-1]).stem or ("file_%04d" % index))
        folder = parts[:-1]
        ext = Path(parts[-1]).suffix.lower()
    else:
        stem = "file_%04d" % index
        folder = []
        ext = ""
    if not ext:
        ext = MAGIC_EXT.get(bytes(blob[:4]), ".bin")
    return folder, stem + ext


def unpack_pak(data, dest, stats, dry, log):
    """把 pak 内容写进 dest 目录，返回写出文件数。"""
    parsed = parse_pak(data)
    if parsed is None:
        stats.pak_failed += 1
        log("    ! pak 解析失败")
        return 0

    names, entries = parsed
    stats.paks += 1
    if not dry:
        dest.mkdir(parents=True, exist_ok=True)

    for index, (size, offset) in enumerate(entries):
        blob = bytes(data[offset:offset + size])
        folder, filename = pak_name(names, len(entries), index, blob)
        target = dest.joinpath(*folder) if folder else dest
        write_bytes(target / filename, blob, dry)
        stats.pak_files += 1
    return len(entries)


def unpack_narc(data, dest, depth, max_depth, stats, dry, log):
    """把 NARC 内容写进 dest 目录，遇到嵌套 NARC 递归处理。返回写出文件数。"""
    try:
        narc = NARC(bytes(data))
    except Exception as exc:
        stats.narc_failed += 1
        log("    ! NARC 解析失败：%s" % exc)
        return 0

    stats.narcs += 1
    if not dry:
        dest.mkdir(parents=True, exist_ok=True)

    names = narc_names(narc.filenames)
    written = 0
    for i, blob in enumerate(narc.files):
        parts = relative_parts(names.get(i, ""))
        stem = safe(Path(parts[-1]).stem or "file%d" % i) if parts else "file%d" % i
        ext = Path(parts[-1]).suffix.lower() if parts else ""
        folder = dest.joinpath(*parts[:-1]) if len(parts) > 1 else dest
        blob = bytes(blob)

        if blob[:4] == NARC_MAGIC and depth < max_depth:
            sub = folder / ("%04d_%s_narc" % (i, stem))
            written += unpack_narc(blob, sub, depth + 1, max_depth, stats, dry, log)
            continue

        write_bytes(folder / ("%04d_%s%s" % (i, stem, ext)), blob, dry)
        stats.narc_files += 1
        written += 1
    return written


def unpack_sdat(data, dest, stats, dry, log):
    """把 SDAT 内部的 sseq/sbnk/swar/swav/strm 解出到 dest/<类型>/ 下。"""
    try:
        sdat = SDAT(bytes(data))
    except Exception as exc:
        stats.sdat_failed += 1
        log("    ! SDAT 解析失败：%s" % exc)
        return
    stats.sdats += 1
    if not dry:
        dest.mkdir(parents=True, exist_ok=True)

    def save_items(named_list, ext, kind_name):
        count = 0
        for idx, named in enumerate(named_list):
            if isinstance(named, (list, tuple)) and len(named) == 2:
                name, obj = named
            else:
                name = None
                obj = named
            blob = obj.save() if hasattr(obj, "save") else bytes(obj)
            fname = safe(str(name)) + ".%s" % ext if name else "file%04d.%s" % (idx, ext)
            write_bytes(dest / kind_name / fname, blob, dry)
            count += 1
            stats.sdat_items += 1
            stats.audio[ext] += 1
        return count

    n_sseq = save_items(sdat.sequences, "sseq", "sseq")
    n_sbnk = save_items(sdat.banks, "sbnk", "sbnk")
    n_swar = save_items(sdat.waveArchives, "swar", "swar")
    n_strm = save_items(sdat.streams, "strm", "strm")
    # SWAV 挂在 SWAR.waves 里，不是顶层。每个 SWAR 下翻出来另存一份方便直接访问。
    n_swav = 0
    for _wname, swar in sdat.waveArchives:
        for widx, swav in enumerate(swar.waves):
            blob = swav.save() if hasattr(swav, "save") else bytes(swav)
            write_bytes(dest / "swav" / ("wave%04d.swav" % (n_swav + widx)), blob, dry)
            n_swav += 1
            stats.sdat_items += 1
            stats.audio["swav"] += 1
    log("    -> %d SSEQ / %d SBNK / %d SWAR / %d SWAV / %d STRM"
        % (n_sseq, n_sbnk, n_swar, n_swav, n_strm))


def extract_rom(rom, rom_dir, narc_dir, pak_dir, sdat_dir, max_depth, stats, dry, write_rom, log):
    total = len(rom.files)
    for fid in range(total):
        try:
            name = rom.filenames.filenameOf(fid)
        except Exception:
            name = None
        if isinstance(name, (bytes, bytearray)):
            name = name.decode("utf-8", "replace")
        if not name:
            name = "file_%04d.bin" % fid
        rel = [safe(p) for p in str(name).replace("\\", "/").split("/") if p not in ("", ".", "..")]
        rel_path = Path(*rel) if rel else Path("file_%04d.bin" % fid)
        data = bytes(rom.files[fid])

        write_bytes(rom_dir / rel_path, data, dry or not write_rom)
        stats.rom_files += 1

        if data[:4] == NARC_MAGIC:
            target = narc_dir / rel_path.with_suffix("")
            log("  [NARC] %s" % rel_path.as_posix())
            unpack_narc(data, target, 1, max_depth, stats, dry, log)
        elif data[:4] == SDAT_MAGIC:
            target = sdat_dir / rel_path.with_suffix("")
            log("  [SDAT] %s" % rel_path.as_posix())
            unpack_sdat(data, target, stats, dry, log)
        elif rel_path.suffix.lower() == ".pak" or is_pak(data):
            target = pak_dir / rel_path.parent
            log("  [PAK ] %s" % rel_path.as_posix())
            unpack_pak(data, target, stats, dry, log)

        if (fid + 1) % 200 == 0:
            log("  ... 已处理 %d/%d" % (fid + 1, total))


def collect_graphics(out_dir, sorted_dir, stats, dry):
    """遍历解包结果，把 NSCR/NCGR/NCLR 和音频子块复制到 sorted/<类型>/ 下并保持相对路径。"""
    for root, _dirs, files in os.walk(out_dir):
        rel_root = Path(root).relative_to(out_dir)
        if rel_root.parts and rel_root.parts[0] == "sorted":
            continue
        for fname in files:
            src = Path(root) / fname
            try:
                with open(src, "rb") as fp:
                    head = fp.read(4)
            except OSError:
                continue
            head4 = bytes(head)
            kind = GRAPHICS_MAGIC.get(head4) \
                or AUDIO_MAGIC.get(head4) \
                or EXT_TO_KIND.get(fname.lower()) \
                or AUDIO_EXT_TO_KIND.get(fname.lower())
            if not kind:
                continue
            dst = sorted_dir / kind / rel_root / (safe(src.stem) + "." + kind)
            if not dry:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)
            if kind in stats.graphics:
                stats.graphics[kind] += 1
            elif kind in stats.audio:
                stats.audio[kind] += 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="NDS ROM 全量解包 + NARC 递归解包 + SDAT 音频解包 + 图形/音频分类"
    )
    parser.add_argument("rom", help=".nds ROM 文件路径")
    parser.add_argument("-o", "--out", help="输出目录（默认 <ROM名>_unpacked）")
    parser.add_argument("--max-depth", type=int, default=3, help="NARC 递归层数，默认 3")
    parser.add_argument("--dry-run", action="store_true", help="只统计，不写任何文件")
    parser.add_argument("--no-rom", action="store_true", help="不导出 rom/ 原始文件")
    parser.add_argument("--no-sorted", action="store_true", help="不生成 sorted/ 分类目录")
    args = parser.parse_args(argv)

    rom_path = Path(args.rom)
    if not rom_path.is_file():
        sys.exit("找不到 ROM：%s" % rom_path)

    out_dir = Path(args.out) if args.out else rom_path.with_name(rom_path.stem + "_unpacked")
    out_dir = out_dir.resolve()
    rom_dir = out_dir / "rom"
    narc_dir = out_dir / "narc"
    pak_dir = out_dir / "pak"
    sdat_dir = out_dir / "sdat"
    sorted_dir = out_dir / "sorted"
    dry = args.dry_run

    def log(msg):
        print(msg, flush=True)

    log("ROM   : %s" % rom_path)
    log("输出  : %s%s" % (out_dir, "（dry-run，不写盘）" if dry else ""))
    if not dry:
        out_dir.mkdir(parents=True, exist_ok=True)

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    stats = Stats()

    log("\n[1/3] 导出 ROM 文件系统并解包 NARC / pak / SDAT ...")
    extract_rom(rom, rom_dir, narc_dir, pak_dir, sdat_dir,
                args.max_depth, stats, dry, not args.no_rom, log)
    if args.no_rom:
        log("  （--no-rom：未写出 rom/ 原始文件）")

    if not args.no_sorted:
        log("\n[2/3] 分类 NSCR/NCGR/NCLR + SSEQ/SBNK/SWAR/SWAV/STRM ...")
        collect_graphics(out_dir, sorted_dir, stats, dry)

    log("\n[3/3] 完成：%s" % stats.summary())
    log("目录：rom/（原始文件）  narc/（NARC 解包）  pak/（pack_data.pak 解包）  "
        "sdat/（SDAT 音频解包）  sorted/<类型>/（图形 & 音频 分类副本）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

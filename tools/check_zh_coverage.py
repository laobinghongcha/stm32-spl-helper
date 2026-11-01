#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HAL/LL 中文 overlay 覆盖率与一致性自检（任务 task-5 要求）。

检查内容：
1. 各库 briefZh 覆盖率（目标是 HAL >= 95%、LL >= 85%）
2. 仍缺 briefZh 的函数名，按库 / 外设分组列出
3. overlay 里出现的函数 id 是否真实存在于对应数据文件（防止拼错导致静默丢失）
4. exampleCode 里出现的 HAL/LL API 是否都在函数 id 白名单内（防止编造接口）

用法：
    python tools/check_zh_coverage.py            # 完整报告
    python tools/check_zh_coverage.py --quiet    # 只打印汇总行

退出码：0 达标；1 有硬错误（非法 id / 编造 API）或覆盖率未达标。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "assets" / "data"
OVERLAY_DIR = PROJECT_ROOT / "data" / "zh_overlay_hal"

# 覆盖率目标（契约 §7 / task-5）
TARGETS = {"hal": 95.0, "ll": 85.0}

EVENTS = "SPL|HAL|LL|EXTI|NVIC|SysTick|USB|CAN|ADC|DMA|TIM|GPIO|RCC|USART|UART|SPI|I2C|RTC|"
""


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[错误] 读不了 {path}: {exc}", file=sys.stderr)
        return None


def load_index(lib: str) -> dict[str, dict]:
    """返回 {函数 id: 函数对象}"""
    idx: dict[str, dict] = {}
    d = DATA_DIR / "functions" / lib
    if not d.is_dir():
        return idx
    for f in sorted(d.glob("*.json")):
        payload = load_json(f)
        if not isinstance(payload, dict):
            continue
        for fn in payload.get("functions") or []:
            fid = fn.get("id")
            if fid:
                idx[fid] = fn
    return idx


def load_overlay() -> dict[str, dict[str, str]]:
    """返回 {lib: {函数 id: briefZh}}"""
    out: dict[str, dict[str, str]] = {}
    if not OVERLAY_DIR.is_dir():
        return out
    for f in sorted(OVERLAY_DIR.glob("functions_*.json")):
        m = re.match(r"functions_([A-Za-z]+)_(\w+)\.json", f.name)
        lib = (m.group(1) if m else "hal").lower()
        payload = load_json(f)
        if not isinstance(payload, dict):
            continue
        bucket = out.setdefault(lib, {})
        for fid, patch in payload.items():
            if fid.startswith("_") or not isinstance(patch, dict):
                continue
            brief = patch.get("briefZh")
            if isinstance(brief, str) and brief.strip():
                bucket[fid] = brief.strip()
    return out


# exampleCode 里识别「像函数调用」的标识符
CALL_RE = re.compile(r"\b((?:HAL|LL)_[A-Za-z0-9_]+)\s*\(")
# 这些是 HAL/LL 里的宏或类型转换，不算函数
MACRO_ALLOW = {
    "HAL_MAX_DELAY", "LL_MAX_DELAY",
}
# 内核级 HAL API（stm32f1xx_hal.c/.h）：不属于任何外设，
# 因此不在 functions/*.json 的函数表里，但确实是官方接口，exampleCode 允许调用。
CORE_HAL_API = {
    "HAL_Init", "HAL_DeInit", "HAL_Delay", "HAL_GetTick", "HAL_IncTick",
    "HAL_SuspendTick", "HAL_ResumeTick", "HAL_GetHalVersion", "HAL_GetTickPrio",
    "HAL_GetTickFreq", "HAL_InitTick", "HAL_MspInit", "HAL_MspDeInit",
}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="HAL/LL 中文 overlay 覆盖率自检")
    ap.add_argument("--quiet", action="store_true", help="只打印汇总行")
    args = ap.parse_args(argv)

    errors = 0
    summary_lines: list[str] = []

    for lib in ("hal", "ll"):
        index = load_index(lib)
        overlay = load_overlay().get(lib, {})

        # ---- 3. overlay id 真实性
        bogus = sorted(set(overlay) - set(index))
        if bogus:
            errors += len(bogus)
            print(f"\n[错误] {lib}: overlay 里有 {len(bogus)} 个 id 在数据里不存在（拼写错误会让中文静默丢失）：")
            for b in bogus[:20]:
                print(f"    {b}")
            if len(bogus) > 20:
                print(f"    …… 另有 {len(bogus) - 20} 个")

        # ---- 1./2. 覆盖率
        total = len(index)
        covered = sum(1 for fid in index if fid in overlay)
        pct = covered / total * 100 if total else 100.0
        target = TARGETS[lib]
        status = "OK" if pct >= target else "未达标"
        if pct < target:
            errors += 1
        summary_lines.append(
            f"{lib.upper():4s} briefZh 覆盖 {covered:4d}/{total:4d} = {pct:5.1f}%  "
            f"(目标 {target:.0f}%)  {status}"
        )

        if not args.quiet and covered < total:
            by_periph: dict[str, list[str]] = {}
            for fid, fn in index.items():
                if fid not in overlay:
                    by_periph.setdefault(fn.get("peripheral") or "?", []).append(fid)
            if by_periph:
                print(f"\n[{lib}] 仍缺 briefZh 的函数（UI 会回退显示英文）：")
                for p in sorted(by_periph):
                    names = sorted(by_periph[p])
                    print(f"  {p}（{len(names)} 个）：{', '.join(names[:12])}"
                          + (" ……" if len(names) > 12 else ""))

        # ---- 4. exampleCode 里的 API 白名单校验
        known = set(index) | MACRO_ALLOW | CORE_HAL_API
        for f in sorted(OVERLAY_DIR.glob(f"functions_{lib.upper()}_*.json")):
            payload = load_json(f)
            if not isinstance(payload, dict):
                continue
            for fid, patch in payload.items():
                if not isinstance(patch, dict):
                    continue
                code = patch.get("exampleCode")
                if not isinstance(code, str) or not code:
                    continue
                for api in sorted(set(CALL_RE.findall(code))):
                    # 允许 HAL/LL 的内部宏（同前缀但不在函数表里的，多半是宏）
                    if api in known:
                        continue
                    if api.isupper() or "_IS_" in api or api.endswith("_CLK_ENABLE"):
                        continue
                    errors += 1
                    print(f"\n[错误] {f.name} / {fid}: exampleCode 里调用了不存在于函数表的 API：{api}")

    print("\n=== 覆盖率汇总 ===")
    for line in summary_lines:
        print("  " + line)

    # paramsZh 覆盖（仅统计 HAL 十大常用外设）
    core = ["GPIO", "RCC", "USART", "TIM", "SPI", "I2C", "ADC", "DMA", "FLASH", "PWR"]
    print("\n=== 参数中文说明覆盖（HAL 十大常用外设）===")
    for p in core:
        src = DATA_DIR / "functions" / "hal" / f"{p}.json"
        ov = OVERLAY_DIR / f"functions_HAL_{p}.json"
        if not src.is_file():
            continue
        payload = load_json(src) or {}
        patch = load_json(ov) if ov.is_file() else {}
        patch = patch if isinstance(patch, dict) else {}
        tot = got = 0
        for fn in payload.get("functions") or []:
            pzh = (patch.get(fn.get("id")) or {}).get("paramsZh") or {}
            for pr in fn.get("params") or []:
                tot += 1
                if pr.get("name") in pzh:
                    got += 1
        pct = got / tot * 100 if tot else 100.0
        print(f"  {p:6s} {got:3d}/{tot:3d} = {pct:5.1f}%")

    print()
    if errors:
        print(f"[结果] 发现 {errors} 处问题")
        return 1
    print("[结果] 全部检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

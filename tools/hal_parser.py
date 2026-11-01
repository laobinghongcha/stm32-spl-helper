#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HAL / LL 头文件与源文件解析器（STM32CubeF1）。

输入：STM32CubeF1 V1.8.7 的
    Drivers/STM32F1xx_HAL_Driver/Inc/*.h     （HAL 原型 + LL 内联函数 + 符号）
    Drivers/STM32F1xx_HAL_Driver/Src/*.c     （HAL 的 doxygen 注释在这里）

输出：内存结构（dataclass），由 build_multi_lib.py 编排成 JSON。

为什么必须同时读 .h 和 .c：
    ST 的惯例是**头文件只放裸原型**，`@brief` / `@param` / `@retval` 全部写在
    `.c` 里对应函数定义的上方。只读 .h 会得到一堆没有一句说明的函数。
    LL 库相反：函数是 `__STATIC_INLINE` 直接定义在 .h 里，注释也就在旁边。

设计原则（与 parse_spl.py 一致）：
1. 只搬运，不推测。拿不到的字段留空并记 warning，不编造。
2. 宽容：任何单个构造解析失败都只影响该构造，绝不抛异常中断整轮。
3. 稳定：同一输入两次运行输出逐字节一致（无时间戳、无随机、键序固定）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# 数据类型
# ---------------------------------------------------------------------------


@dataclass
class RawParam:
    """函数参数。"""

    name: str
    type: str
    desc_en: str = ""


@dataclass
class RawFunction:
    """一个 HAL_* / LL_* 函数。"""

    name: str
    return_type: str
    prototype: str
    params: list[RawParam] = field(default_factory=list)
    return_desc_en: str = ""
    brief_en: str = ""
    remarks: list[str] = field(default_factory=list)
    group_key: str = ""  # doxygen 分组名，如 GPIO_Exported_Functions_Group1
    group_title_en: str = ""  # 分组英文标题
    header_file: str = ""  # 定义/声明所在文件
    header_line: int = 0
    source_file: str = ""
    source_line: int = 0
    inline: bool = False
    deprecated: bool = False
    body: str = ""  # 函数体原文（用于抽取寄存器/相关函数）
    library: str = "hal"


@dataclass
class RawMember:
    name: str
    type: str
    value: str | None = None
    desc_en: str = ""
    line: int = 0


@dataclass
class RawSymbol:
    """宏 / 枚举值 / 枚举类型 / 结构体 / typedef。"""

    name: str
    kind: str  # macro / enum_value / enum_type / struct / typedef / unknown
    value: str | None = None
    value_kind: str | None = None
    function_like: bool = False
    params: list[str] = field(default_factory=list)
    members: list[RawMember] = field(default_factory=list)
    brief_en: str = ""
    defined_in: str = ""
    defined_line: int = 0
    visibility: str = "public"
    enum_type: str | None = None
    member_of: str | None = None
    library: str = "hal"
    group_key: str = ""


@dataclass
class HeaderDoc:
    """一个头文件/源文件的解析结果。"""

    path: Path
    functions: list[RawFunction] = field(default_factory=list)
    symbols: list[RawSymbol] = field(default_factory=list)
    groups: dict[str, str] = field(default_factory=dict)  # key -> 英文标题


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

_COMMENT_MULTI_RE = re.compile(r"/\*\*(?!/)(.*?)\*/", re.S)
_INLINE_COMMENT_RE = re.compile(r"/\*!?<([^*]*(?:\*(?!/)[^*]*)*)\*/", re.S)
_LINE_COMMENT_RE = re.compile(r"//[^\n]*")
_GROUP_RE = re.compile(
    r"@(?:addtogroup|defgroup)\s+([A-Za-z_]\w*)(?:[ \t]+([^\n*]*?))?[ \t]*$", re.M
)
_TAG_RE = re.compile(r"^[ \t*]*@(\w+)\b(.*)$")


def normalize_ws(text: str) -> str:
    """把多行注释压成单行，保留原有语义。"""
    text = text.replace("\r", "")
    text = re.sub(r"\s*\n\s*", " ", text)
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def strip_comments(text: str) -> str:
    """去掉注释，保留字符串字面量（ST 源码里注释里常含 "*/" 干扰）。"""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        two = text[i : i + 2]
        if two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif text[i] == "'":
            j = i + 1
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def line_of(text: str, pos: int) -> int:
    """字符偏移 → 1 基行号。"""
    return text.count("\n", 0, pos) + 1


def read_text(path: Path) -> str:
    """读源码：ST 文件是 UTF-8（无 BOM），但个别老文件带 BOM 或 GBK 噪声。"""
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:  # pragma: no cover - 兜底
        text = raw.decode("utf-8", errors="replace")
    return text.replace("\r\n", "\n").replace("\r", "")


def split_top_level(text: str, sep: str = ",") -> list[str]:
    """按顶层分隔符切分（忽略括号内的分隔符）。"""
    parts: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    last = "".join(cur)
    if last.strip():
        parts.append(last)
    return parts


# ---------------------------------------------------------------------------
# doxygen 注释解析
# ---------------------------------------------------------------------------


@dataclass
class DocBlock:
    brief: str = ""
    params: dict[str, str] = field(default_factory=dict)
    retval: str = ""
    notes: list[str] = field(default_factory=list)
    deprecated: bool = False
    raw: str = ""


def parse_doc_block(body: str) -> DocBlock:
    """解析一个 `/** ... */` 内部文本。

    只认 ST 实际用到的 tag：@brief @param @retval @note @warning @deprecated
    @arg（合并进当前 @param）。其余 tag（@rmtoll、@ref 等）忽略——F1 的
    HAL 源文件里没有 @rmtoll，LL 头文件里有，但那是给 CubeMX 用的映射表，
    与"这个函数碰了哪些寄存器"不是一回事，不能当成数据。
    """
    doc = DocBlock(raw=body)
    lines = body.split("\n")
    current_tag: str | None = None
    current_param: str | None = None
    buf: list[str] = []

    def flush() -> None:
        nonlocal buf
        text = normalize_ws(" ".join(buf))
        if current_tag == "brief":
            doc.brief = (doc.brief + " " + text).strip() if doc.brief else text
        elif current_tag in ("note", "warning"):
            if text:
                doc.notes.append(text)
        elif current_tag == "retval":
            doc.retval = (doc.retval + " " + text).strip() if doc.retval else text
        elif current_tag == "param" and current_param:
            prev = doc.params.get(current_param, "")
            doc.params[current_param] = (prev + " " + text).strip() if prev else text
        elif current_tag == "arg" and current_param:
            prev = doc.params.get(current_param, "")
            item = normalize_ws(text)
            doc.params[current_param] = f"{prev}; {item}".strip("; ") if prev else item
        buf = []

    for raw_line in lines:
        line = raw_line.strip()
        line = re.sub(r"^\*+", "", line).strip()
        m = _TAG_RE.match(line)
        if m:
            flush()
            tag = m.group(1)
            rest = m.group(2).strip()
            current_tag = tag
            current_param = None
            if tag == "param":
                pm = re.match(r"(__\w+__|\w+)\s*:?\s*(.*)$", rest)
                if pm:
                    current_param = pm.group(1)
                    rest = pm.group(2)
                else:
                    current_param = rest.split()[0] if rest.strip() else None
                    rest = rest[len(current_param or "") :].strip()
            if tag == "deprecated":
                doc.deprecated = True
            buf.append(rest)
            continue
        if line.startswith("@"):  # 未识别的 tag：结束当前 tag，丢弃
            flush()
            current_tag = None
            current_param = None
            continue
        if current_tag is None:
            continue
        buf.append(line)
    flush()
    return doc


def collect_doc_blocks(text: str) -> list[tuple[int, int, DocBlock]]:
    """返回 [(start, end, DocBlock)]，按位置升序。"""
    out: list[tuple[int, int, DocBlock]] = []
    for m in _COMMENT_MULTI_RE.finditer(text):
        out.append((m.start(), m.end(), parse_doc_block(m.group(1))))
    return out


def doc_for_position(
    blocks: list[tuple[int, int, DocBlock]], start: int
) -> DocBlock | None:
    """取紧贴在该位置之前的注释块（中间只允许空白）。

    注意 ST 的常见写法是：

        /**
          * @brief  ...
          * @retval None
          */
        void HAL_GPIO_Init(...)

    所以「紧贴」的判定是：注释结束到函数开始之间只有空白。
    """
    lo, hi = 0, len(blocks) - 1
    best: tuple[int, int, DocBlock] | None = None
    while lo <= hi:
        mid = (lo + hi) // 2
        if blocks[mid][0] < start:
            best = blocks[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    return best[2] if best else None


# ---------------------------------------------------------------------------
# 分组（doxygen @addtogroup / @defgroup）跟踪
# ---------------------------------------------------------------------------


def collect_groups(text: str) -> dict[str, str]:
    """收集文件内所有 doxygen 分组名与英文标题。

    标题的三种真实写法：
        @addtogroup GPIO_Exported_Functions_Group1 Initialization and ...
        @addtogroup UART_Exported_Functions_Group3            <- 没标题，
        /* Peripheral Control functions  ****************/       紧跟一行普通注释
        @defgroup GPIO_LL_EF_Port_Configuration Port Configuration
    """
    groups: dict[str, str] = {}
    for m in _GROUP_RE.finditer(text):
        key = m.group(1)
        title = normalize_ws(m.group(2) or "")
        if not title:
            # 找紧跟在该注释块结束后的 /* ... */ 单行注释
            end = text.find("*/", m.end())
            if end > 0:
                tail = text[end + 2 : end + 600]
                cm = re.search(r"/\*+([^*\n][^\n]*?)\*+/", tail)
                if cm:
                    cand = normalize_ws(cm.group(1))
                    if cand and not cand.startswith("@"):
                        title = cand
        groups.setdefault(key, title)
    return groups


def group_of(
    blocks: list[tuple[int, int, DocBlock]], text: str, pos: int
) -> tuple[str, str]:
    """取该位置之前最近一个分组声明，返回 (分组名, 分组英文标题)。"""
    best_key = ""
    best_pos = -1
    for m in _GROUP_RE.finditer(text, 0, pos):
        if m.start() > best_pos:
            best_pos = m.start()
            best_key = m.group(1)
    return best_key, ""


def group_title(blocks: list[tuple[int, int, DocBlock]], text: str, pos: int) -> str:
    """该位置所属分组的英文标题（分组声明后面若直接跟普通注释也一并取）。"""
    last: re.Match[str] | None = None
    for m in _GROUP_RE.finditer(text, 0, pos):
        last = m
    if last is None:
        return ""
    title = normalize_ws(last.group(2) or "")
    if title:
        return title
    end = text.find("*/", last.end())
    if end <= 0:
        return ""
    cm = re.search(r"/\*+([^*\n][^\n]*?)\*+/", text[end + 2 : end + 600])
    if cm:
        cand = normalize_ws(cm.group(1))
        if cand and not cand.startswith("@"):
            return cand
    return ""


# ---------------------------------------------------------------------------
# 函数原型解析
# ---------------------------------------------------------------------------

# 函数定义（.c）：返回类型 名字(参数) {   —— 参数里不含 ; { }，可跨行
_FUNC_DEF_RE = re.compile(
    r"(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*(?:[ \t]+[A-Za-z_][A-Za-z0-9_]*)*[ \t]*\*?[ \t]*)"
    r"\b([A-Za-z_]\w*)[ \t]*\(([^;{}]*)\)[ \t\n]*\{"
)

# LL 内联函数定义（.h）
_INLINE_DEF_RE = re.compile(
    r"(?m)^[ \t]*__STATIC_INLINE[ \t]+"
    r"([A-Za-z_][A-Za-z0-9_]*(?:[ \t]+[A-Za-z_][A-Za-z0-9_]*)*[ \t]*\*?[ \t]*)"
    r"\b([A-Za-z_]\w*)[ \t]*\(([^;{}]*)\)[ \t\n]*\{"
)

# 头文件里的函数声明：以 ; 结尾
_DECL_RE = re.compile(
    r"(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*(?:[ \t]+[A-Za-z_][A-Za-z0-9_]*)*[ \t]*\*?[ \t]*)"
    r"\b([A-Za-z_]\w*)[ \t]*\(([^;{}]*)\)[ \t\n]*;"
)

_NOT_FUNC_NAMES = frozenset(
    {
        "if",
        "for",
        "while",
        "switch",
        "sizeof",
        "return",
        "do",
        "else",
        "typedef",
        "assert_param",
    }
)


def _clean_type(text: str) -> str:
    text = normalize_ws(text)
    text = re.sub(r"\b(static|extern|inline|__INLINE|register)\b", "", text)
    text = re.sub(r"[ \t]+", " ", text).strip()
    # `GPIO_TypeDef  *` -> `GPIO_TypeDef *`
    text = re.sub(r"\s*\*+\s*", " *", text)
    return text.strip()


def parse_params(params_raw: str) -> list[RawParam]:
    """解析参数表。

    处理三种真实写法：
        GPIO_TypeDef *GPIOx, uint32_t GPIO_Pin
        void                       （无参）
        void (*Callback)(void)     （函数指针，一般出现在 typedef 里）
    """
    raw = normalize_ws(params_raw)
    if not raw or raw == "void":
        return []
    out: list[RawParam] = []
    for item in split_top_level(params_raw):
        item = normalize_ws(item)
        if not item or item == "void":
            continue
        # 函数指针参数：ret (*name)(args)
        fp = re.match(r"^(.+?)\(\s*\*\s*(\w+)\s*\)\s*\((.*)\)$", item, re.S)
        if fp:
            ret = _clean_type(fp.group(1))
            args = normalize_ws(fp.group(3)) or "void"
            out.append(RawParam(name=fp.group(2), type=f"{ret} (*)({args})"))
            continue
        # 数组参数：uint8_t pData[]
        arr = re.match(r"^(.+?)\b([A-Za-z_]\w*)\s*\[[^\]]*\]$", item, re.S)
        if arr:
            out.append(
                RawParam(name=arr.group(2), type=_clean_type(arr.group(1)) + " []")
            )
            continue
        # 普通参数：类型 + 名字（最后一段是名字）
        m = re.match(r"^(.+?)\s*\b([A-Za-z_]\w*)$", item, re.S)
        if m:
            typ = _clean_type(m.group(1))
            out.append(RawParam(name=m.group(2), type=typ))
        else:
            out.append(RawParam(name="", type=_clean_type(item)))
    return out


def build_prototype(ret_type: str, name: str, params: list[RawParam]) -> str:
    if not params:
        return f"{ret_type} {name}(void);"
    parts = []
    for p in params:
        if p.type.endswith(" []"):
            parts.append(f"{p.type[:-3]} {p.name}[]")
        else:
            parts.append(f"{p.type} {p.name}".strip())
    return f"{ret_type} {name}({', '.join(parts)});"


def _attach_param_docs(func: RawFunction, doc: DocBlock, warn=None) -> None:
    """把 @param 说明按参数名贴回去（大小写不敏感，容忍 ST 自身的笔误）。"""
    if not doc.params:
        return
    lower = {k.lower(): v for k, v in doc.params.items()}
    used: set[str] = set()
    for p in func.params:
        key = p.name.lower()
        if key in lower:
            p.desc_en = lower[key]
            used.add(key)
            continue
        stripped = key.strip("_")
        for cand, text in lower.items():
            if cand.strip("_") == stripped:
                p.desc_en = text
                used.add(cand)
                break
        else:
            if warn:
                warn(func.name, f"@param {p.name} 无对应说明")
    extra = [k for k in lower if k not in used]
    for k in extra:
        if warn:
            warn(func.name, f"注释里的 @param {k} 在原型里不存在")


# ---------------------------------------------------------------------------
# 符号解析：宏 / 枚举 / 结构体 / typedef
# ---------------------------------------------------------------------------


def _value_kind(value: str | None) -> str | None:
    if not value:
        return None
    v = value.strip()
    if re.fullmatch(r"\(?\s*(0[xX][0-9a-fA-F]+)[uUlL]*\s*\)?", v):
        return "hex"
    if re.fullmatch(r"\(?\s*\d+[uUlL]*\s*\)?", v):
        return "dec"
    if re.fullmatch(r'"[^"]*"', v):
        return "string"
    return "expression"


def parse_defines(text: str, header_name: str, library: str) -> list[RawSymbol]:
    """解析 #define（含多行续行与函数式宏）。"""
    out: list[RawSymbol] = []
    seen: set[str] = set()
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(
            r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)(\([^)\n]*\))?[ \t]*(.*)$", line
        )
        if not m:
            i += 1
            continue
        name, fn_params, value = m.group(1), m.group(2), m.group(3)
        start_line = i + 1
        while value.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            value = value.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        if name in seen:
            continue
        seen.add(name)

        # 值里的注释：先取行内 /*!< 说明，再从值里删掉所有注释
        desc = ""
        dm = _INLINE_COMMENT_RE.search(line)
        if dm:
            desc = normalize_ws(dm.group(1))
        value_clean = re.sub(r"/\*.*?\*/", "", value, flags=re.S)
        value_clean = re.sub(r"//.*$", "", value_clean).strip()

        out.append(
            RawSymbol(
                name=name,
                kind="macro",
                value=value_clean or None,
                value_kind=_value_kind(value_clean),
                function_like=fn_params is not None,
                params=(
                    [p.strip() for p in fn_params[1:-1].split(",") if p.strip()]
                    if fn_params
                    else []
                ),
                brief_en=desc,
                defined_in=header_name,
                defined_line=start_line,
                visibility="internal" if name.startswith("IS_") else "public",
                library=library,
            )
        )
    return out


_ENUM_RE = re.compile(
    r"typedef\s+enum\s*(?:[A-Za-z_]\w*\s*)?\{([^{}]*)\}\s*"
    r"([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;",
    re.S,
)
_ENUM_MEMBER_RE = re.compile(
    r"(?:^|,)\s*([A-Za-z_]\w*)\s*(?:=\s*([^,}]+?))?\s*(?=,|$)", re.S
)
# 真实写法（stm32f1xx_hal_tim.h:335）：
#
#   typedef struct __TIM_HandleTypeDef
#   #else
#   typedef struct
#   #endif /* USE_HAL_TIM_REGISTER_CALLBACKS */
#   {
#     ...
#   } TIM_HandleTypeDef;
#
# 中间夹了预处理器分支，原正则只允许 `typedef struct <tag> {` 紧邻，
# 于是整块漏掉 —— TIM/UART/I2C/SPI/ADC 这些最常用的句柄结构体全部缺失。
# 这里允许 typedef 与 `{` 之间夹任意预处理指令行。
_STRUCT_RE = re.compile(
    r"typedef\s+struct\s*(?:[A-Za-z_]\w*\s*)?"
    r"(?:[ \t]*#[^\n]*\n[ \t]*)*"
    r"\{([^{}]*)\}\s*"
    r"([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;",
    re.S,
)
_STRUCT_MEMBER_RE = re.compile(
    r"^\s*(?:const\s+)?([A-Za-z_][\w\s\*]*?)\s+"
    r"([A-Za-z_]\w*)\s*"
    r"(\[[^\]]*\])?\s*;",
    re.M,
)
_FUNC_PTR_TYPEDEF_RE = re.compile(
    r"typedef\s+(.+?)\(\s*\*\s*([A-Za-z_]\w*)\s*\)\s*\(([^;]*)\)\s*;", re.S
)
_PLAIN_TYPEDEF_RE = re.compile(
    r"^[ \t]*typedef\s+(?!enum|struct|union)([^;{}]+?)\s*;\s*$", re.M
)


def _doc_brief_before(text: str, blocks, pos: int) -> str:
    doc = doc_for_position(blocks, pos)
    return doc.brief if doc and doc.brief else ""


def parse_typedef_symbols(
    text: str, header_name: str, library: str
) -> list[RawSymbol]:
    """解析枚举、结构体、typedef 别名。"""
    out: list[RawSymbol] = []
    blocks = collect_doc_blocks(text)

    # ---- 枚举 ----
    for m in _ENUM_RE.finditer(text):
        body, names_raw = m.group(1), m.group(2)
        type_names = [n.strip() for n in names_raw.split(",") if n.strip()]
        if not type_names:
            continue
        base_line = line_of(text, m.start())
        brief = _doc_brief_before(text, blocks, m.start())
        members: list[RawMember] = []
        body_off = m.start(1)
        for em in _ENUM_MEMBER_RE.finditer(body):
            mname = em.group(1)
            if not mname:
                continue
            mline = line_of(text, body_off + em.start(1))
            mval = normalize_ws(em.group(2)) if em.group(2) else None
            # 行尾 /*!< 说明
            line_end = text.find("\n", body_off + em.end())
            if line_end < 0:
                line_end = len(text)
            seg = text[body_off + em.end() : line_end]
            desc = ""
            dm = _INLINE_COMMENT_RE.search(seg)
            if dm:
                desc = normalize_ws(dm.group(1))
            members.append(
                RawMember(name=mname, type="", value=mval, desc_en=desc, line=mline)
            )
            out.append(
                RawSymbol(
                    name=mname,
                    kind="enum_value",
                    value=mval,
                    value_kind=_value_kind(mval),
                    enum_type=type_names[0],
                    member_of=type_names[0],
                    brief_en=desc,
                    defined_in=header_name,
                    defined_line=mline,
                    library=library,
                )
            )
        for tname in type_names:
            out.append(
                RawSymbol(
                    name=tname,
                    kind="enum_type",
                    members=[RawMember(**vars(x)) for x in members],
                    brief_en=brief,
                    defined_in=header_name,
                    defined_line=base_line,
                    library=library,
                )
            )

    # ---- 结构体 ----
    for m in _STRUCT_RE.finditer(text):
        body, names_raw = m.group(1), m.group(2)
        type_names = [n.strip() for n in names_raw.split(",") if n.strip()]
        if not type_names:
            continue
        base_line = line_of(text, m.start())
        brief = _doc_brief_before(text, blocks, m.start())
        members: list[RawMember] = []
        body_off = m.start(1)
        for mm in _STRUCT_MEMBER_RE.finditer(body):
            mtype = _clean_type(mm.group(1))
            mname = mm.group(2)
            if mtype in ("typedef", "struct", "union", "}"):
                continue
            mline = line_of(text, body_off + mm.start(2))
            # 成员说明：本行后面的 /*!< ... */，可能跨多行
            line_end = text.find("\n", body_off + mm.end())
            if line_end < 0:
                line_end = len(text)
            tail = text[body_off + mm.end() : min(line_end + 800, len(text))]
            desc = ""
            dm = re.search(r"/\*!?<([^*]*(?:\*(?!/)[^*]*)*)\*/", tail, re.S)
            if dm and dm.start() < (line_end - (body_off + mm.end())) + 800:
                desc = normalize_ws(dm.group(1))
            members.append(
                RawMember(
                    name=mname,
                    type=mtype,
                    value=None,
                    desc_en=desc,
                    line=mline,
                )
            )
        for tname in type_names:
            out.append(
                RawSymbol(
                    name=tname,
                    kind="struct",
                    members=[RawMember(**vars(x)) for x in members],
                    brief_en=brief,
                    defined_in=header_name,
                    defined_line=base_line,
                    library=library,
                )
            )

    # ---- 函数指针 typedef ----
    for m in _FUNC_PTR_TYPEDEF_RE.finditer(text):
        ret = _clean_type(m.group(1))
        name = m.group(2)
        params_raw = normalize_ws(m.group(3)) or "void"
        out.append(
            RawSymbol(
                name=name,
                kind="typedef",
                value=f"{ret} (*)({params_raw})",
                value_kind="expression",
                function_like=True,
                params=[p.strip() for p in params_raw.split(",") if p.strip()],
                brief_en=_doc_brief_before(text, blocks, m.start()),
                defined_in=header_name,
                defined_line=line_of(text, m.start()),
                library=library,
            )
        )

    # ---- 普通 typedef 别名 ----
    covered = {s.name for s in out}
    for m in _PLAIN_TYPEDEF_RE.finditer(text):
        decl = normalize_ws(m.group(1))
        if "(" in decl:  # 已被函数指针规则收走
            continue
        # `__IO uint32_t` 之类的裸 typedef 少见；只收 "类型 名字" 形式
        dm = re.match(r"^(.+?)\s*\b([A-Za-z_]\w*)$", decl, re.S)
        if not dm:
            continue
        name = dm.group(2)
        if name in covered or name in _NOT_FUNC_NAMES:
            continue
        covered.add(name)
        out.append(
            RawSymbol(
                name=name,
                kind="typedef",
                value=_clean_type(dm.group(1)),
                value_kind="expression",
                brief_en=_doc_brief_before(text, blocks, m.start()),
                defined_in=header_name,
                defined_line=line_of(text, m.start()),
                library=library,
            )
        )
    return out


# ---------------------------------------------------------------------------
# 函数解析
# ---------------------------------------------------------------------------


def parse_header_declarations(
    text: str, header_name: str
) -> dict[str, tuple[int, str]]:
    """头文件里的函数声明 → {名字: (行号, 原型**原文**)}。

    原型必须是头文件里的**逐字原文**（只把跨行续行的缩进压成一个空格）。
    详情页要展示的和用户在 ST 头文件里看到的一致；重新拼装会把
    `GPIO_TypeDef  *GPIOx` 改成 `GPIO_TypeDef * GPIOx`，虽然语义相同，
    但用户对照头文件时会以为数据错了。
    """
    out: dict[str, tuple[int, str]] = {}
    for m in _DECL_RE.finditer(text):
        ret_raw, name, params_raw = m.groups()
        if name in _NOT_FUNC_NAMES:
            continue
        ret = _clean_type(ret_raw)
        if not ret or ret.endswith("="):
            continue
        raw_proto = text[m.start() : m.end()]
        # 只压平换行与行首缩进，不碰任何标点周围的空白
        raw_proto = re.sub(r"[ \t]*\n[ \t]*", " ", raw_proto).strip()
        if not raw_proto.endswith(";"):
            raw_proto += ";"
        out.setdefault(name, (line_of(text, m.start()), raw_proto))
    return out


def parse_hal_source(
    path: Path, warn: Any = None
) -> HeaderDoc:
    """解析一个 HAL .c 文件：函数定义 + doxygen 注释。

    分节标记在 .c 里（`@addtogroup XXX_Exported_Functions_GroupN`），
    所以分组信息也从这里取。
    """
    text = read_text(path)
    name = path.name
    doc = HeaderDoc(path=path)
    doc.groups = collect_groups(text)
    blocks = collect_doc_blocks(text)
    cleaned = strip_comments(text)
    offsets = _map_offsets(text, cleaned)

    for m in _FUNC_DEF_RE.finditer(cleaned):
        ret_raw, fname, params_raw = m.groups()
        if fname in _NOT_FUNC_NAMES:
            continue
        ret = _clean_type(ret_raw)
        if not ret or len(ret) > 120:
            continue
        params = parse_params(params_raw)
        if not params and normalize_ws(params_raw) not in ("", "void"):
            if warn:
                warn(fname, "参数表解析失败，已跳过")
            continue
        orig_pos = offsets[m.start()] if m.start() < len(offsets) else 0
        d = doc_for_position(blocks, orig_pos)
        f = RawFunction(
            name=fname,
            return_type=ret,
            prototype=build_prototype(ret, fname, params),
            params=params,
            brief_en=d.brief if d else "",
            return_desc_en=d.retval if d else "",
            remarks=list(d.notes) if d else [],
            deprecated=bool(d and d.deprecated),
            header_file=name,
            header_line=line_of(text, orig_pos),
            source_file=name,
            source_line=line_of(text, orig_pos),
            library="hal",
        )
        if d:
            _attach_param_docs(f, d, warn)
        f.group_key, _ = group_of(blocks, text, orig_pos)
        f.group_title_en = group_title(blocks, text, orig_pos)
        f.body = _extract_body(cleaned, m.end() - 1)
        doc.functions.append(f)
    return doc


def _extract_body(cleaned: str, brace_pos: int) -> str:
    """从 '{' 开始截取配平的函数体。"""
    depth = 0
    i = brace_pos
    n = len(cleaned)
    while i < n:
        ch = cleaned[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return cleaned[brace_pos : i + 1]
        i += 1
    return cleaned[brace_pos : min(brace_pos + 4000, n)]


def _map_offsets(orig: str, cleaned: str) -> list[int]:
    """去注释后文本的下标 → 原文下标。

    去注释时我们把每个注释块替换成一个空格，所以长度不再一致，
    但字符顺序保持一致；这里用双指针建立映射。
    """
    offsets = [0] * (len(cleaned) + 1)
    i = 0  # orig 指针
    j = 0  # cleaned 指针
    n, m = len(orig), len(cleaned)
    while j < m and i < n:
        offsets[j] = i
        if orig[i] == cleaned[j]:
            i += 1
            j += 1
            continue
        # cleaned 里的空格对应 orig 里的一段注释
        if cleaned[j] == " ":
            j += 1
            while i < n and orig[i] in " \t\n":
                i += 1
            if i < n and orig.startswith("/*", i):
                k = orig.find("*/", i + 2)
                i = n if k < 0 else k + 2
            elif i + 1 < n and orig.startswith("//", i):
                k = orig.find("\n", i)
                i = n if k < 0 else k
        else:
            i += 1
    while j < len(offsets):
        offsets[j] = i
        j += 1
    return offsets


def parse_ll_header(path: Path, warn: Any = None) -> HeaderDoc:
    """解析 LL 头文件：__STATIC_INLINE 函数 + 符号。"""
    text = read_text(path)
    name = path.name
    doc = HeaderDoc(path=path)
    doc.groups = collect_groups(text)
    blocks = collect_doc_blocks(text)

    for m in _INLINE_DEF_RE.finditer(text):
        ret_raw, fname, params_raw = m.groups()
        if fname in _NOT_FUNC_NAMES:
            continue
        ret = _clean_type(ret_raw)
        params = parse_params(params_raw)
        d = doc_for_position(blocks, m.start())
        f = RawFunction(
            name=fname,
            return_type=ret,
            prototype=build_prototype(ret, fname, params),
            params=params,
            brief_en=d.brief if d else "",
            return_desc_en=d.retval if d else "",
            remarks=list(d.notes) if d else [],
            deprecated=bool(d and d.deprecated),
            header_file=name,
            header_line=line_of(text, m.start()),
            source_file=name,
            source_line=line_of(text, m.start()),
            inline=True,
            library="ll",
        )
        if d:
            _attach_param_docs(f, d, warn)
        f.group_key, _ = group_of(blocks, text, m.start())
        f.group_title_en = group_title(blocks, text, m.start())
        f.body = _extract_body(text, m.end() - 1)
        doc.functions.append(f)
    return doc


def parse_hal_header(path: Path, warn: Any = None) -> HeaderDoc:
    """解析 HAL 头文件：只取符号与声明行号（注释在 .c 里）。"""
    text = read_text(path)
    name = path.name
    doc = HeaderDoc(path=path)
    doc.groups = collect_groups(text)
    doc.symbols = parse_defines(text, name, "hal") + parse_typedef_symbols(
        text, name, "hal"
    )
    return doc


def parse_ll_symbols(path: Path) -> HeaderDoc:
    """LL 头文件里的符号（宏 + 枚举 + 结构体）。"""
    text = read_text(path)
    name = path.name
    doc = HeaderDoc(path=path)
    doc.groups = collect_groups(text)
    doc.symbols = parse_defines(text, name, "ll") + parse_typedef_symbols(
        text, name, "ll"
    )
    return doc


# ---------------------------------------------------------------------------
# 从函数体抽取「相关函数 / 寄存器」
# ---------------------------------------------------------------------------

_CALL_RE = re.compile(r"\b(?:HAL|LL)_[A-Za-z0-9_]+\b")
_REG_ACCESS_RE = re.compile(r"\b([A-Za-z_]\w*)\s*->\s*([A-Za-z_]\w*)")


def extract_related(func: RawFunction, known: set[str]) -> list[str]:
    """函数体里调用到的其他 HAL/LL 函数（真实调用，不是猜测）。"""
    out: list[str] = []
    for m in _CALL_RE.finditer(func.body):
        nm = m.group(0)
        if nm == func.name or nm not in known:
            continue
        if nm not in out:
            out.append(nm)
    return out


def extract_registers(func: RawFunction) -> list[str]:
    """函数体里通过**外设指针**访问的寄存器成员。

    判定标准（两条都来自 HAL 的写法约定，不做文本猜测）：
      1. 基址是 `Instance`（HAL 句柄里的外设指针），或
      2. 基址是某个类型为 `Xxx_TypeDef *` 的参数（如 GPIOx / TIMx / hadc 的裸指针参数）。
    结构体参数（`GPIO_InitTypeDef *GPIO_Init`）访问的是**配置结构体成员**，
    不是寄存器，排除掉——否则 registers 里会混进 `GPIO_Init_Pin` 这种假条目。
    输出形如 GPIOx_BSRR / Instance_CR1，与 SPL 数据的命名习惯一致。
    """
    param_names = {p.name for p in func.params}
    type_of = {p.name: p.type for p in func.params}
    out: list[str] = []
    for m in _REG_ACCESS_RE.finditer(func.body):
        base, member = m.group(1), m.group(2)
        if member == "Instance":
            continue
        if base == "Instance":
            label = f"Instance_{member}"
        elif base in param_names and type_of[base].endswith("_TypeDef *"):
            label = f"{base}_{member}"
        else:
            continue
        if label not in out:
            out.append(label)
    return out

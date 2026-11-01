#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CMSIS 寄存器解析器：外设结构体（register map）+ 位定义宏（bit fields）。

输入：
    ...\\Drivers\\CMSIS\\Device\\ST\\STM32F1xx\\Include\\stm32f103xb.h
    ...\\Drivers\\CMSIS\\Include\\core_cm3.h      （NVIC/SCB/SysTick 等内核寄存器）

输出：每个「寄存器」一条记录，含
    name          寄存器名，如 GPIO_CRL / DMA_CCR1 / SCB_VTOR
    struct_name   所属结构体，如 GPIO_TypeDef
    peripheral    外设 id，如 GPIO
    expression    C 里真实可用的访问表达式，如 GPIOA->CRL
    offset        结构体内字节偏移（由前面成员宽度累加）
    bit_fields    该寄存器的位域宏（name / type / descEn / value）

命名规则（重要）：
    寄存器名 = `<结构体前缀>_<成员名>`，其中前缀取结构体名去掉 `_TypeDef`/`_Type`
    后再过一遍 ALIAS 表。别名只有一条是真需要的：`DMA_Channel` → `DMA`，
    因为 CMSIS 把 7 个通道写成 `DMA1_Channel1..7`，而寄存器名是 `DMA_CCR1..7`
    （见 ALIAS_STRUCT）。其余结构体去掉后缀就是寄存器前缀，不需要猜。

为什么「寄存器 = 结构体叶子成员」而不是「位定义宏的前缀」：
    stm32f103xb.h 里 `Bit definition for XXX register` 分节只有 290 个，
    结构体叶子成员只有 194 个，两者**不完全重合**：
      * BKP_DR11..DR42、CAN_TI0R..、USB_ADDR0_RX 只出现在位定义分节
      * OB_*、SPI_I2SCFGR、AFIO_EXTICR1..4 只在结构体里
    所以取**并集**：结构体给访问表达式与偏移，位定义分节给位域宏。

宽容原则：任何一段解析失败只丢这一段，记 warning，不中断。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------


@dataclass
class BitField:
    """一个位域宏。"""

    name: str
    type: str = ""  # "bits[1:0]" / "bit 7" / "0x0000000F"（无法判定时留空）
    value: str | None = None  # _Msk 表达式原文
    desc_en: str = ""  # /*!< ... */ 注释原文
    line: int = 0
    pos: int | None = None  # 低位位置（来自 X_Pos）
    mask: str = ""  # _Msk 表达式原文（与 value 同源，便于上层取用）
    aggregate: bool = True  # 是否代表整个位域（而非单个比特）


@dataclass
class Register:
    """一个寄存器。"""

    name: str
    struct_name: str
    peripheral: str
    expression: str = ""
    offset: int = 0
    desc_en: str = ""
    bit_fields: list[BitField] = field(default_factory=list)
    bit_defined: bool = False
    library: str = "reg"
    pma: bool = False  # True = USB 包缓冲区表项（地址运行期计算）


@dataclass
class StructMember:
    name: str
    type: str
    array_len: int | None = None
    desc_en: str = ""
    line: int = 0

    @property
    def is_sub_struct(self) -> bool:
        """成员类型本身是结构体（如 CAN 的 sTxMailBox[3]）。"""
        return self.type.endswith(("_TypeDef", "_Type"))


@dataclass
class StructDef:
    name: str
    brief_en: str = ""
    members: list[StructMember] = field(default_factory=list)


@dataclass
class RegisterSet:
    registers: list[Register] = field(default_factory=list)
    structs: dict[str, StructDef] = field(default_factory=dict)
    instances: dict[str, list[str]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

_INLINE_COMMENT_RE = re.compile(r"/\*!?<([^*]*(?:\*(?!/)[^*]*)*)\*/", re.S)
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "latin-1"):
        try:
            return raw.decode(enc).replace("\r\n", "\n").replace("\r", "")
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def normalize_ws(text: str) -> str:
    text = re.sub(r"\s*\n\s*", " ", text)
    return re.sub(r"[ \t]+", " ", text).strip()


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


# ---------------------------------------------------------------------------
# 结构体解析
# ---------------------------------------------------------------------------

_STRUCT_RE = re.compile(
    r"typedef\s+struct\s*(?:\w+\s*)?\{(?P<body>(?:[^{}]|\{[^{}]*\})*)\}\s*"
    r"(?P<names>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;",
    re.S,
)

# 成员： [__IO|__IOM|__IM|__OM|__I|__O|volatile]  类型  名字 [数组];
_MEMBER_RE = re.compile(
    r"(?m)^[ \t]*(?:(?P<qual>__IO|__IOM|__IM|__OM|__I|__O|volatile)\s+)?"
    r"(?P<type>[A-Za-z_]\w*(?:\s+[A-Za-z_]\w*)*)\s+"
    r"(?P<name>[A-Za-z_]\w*)\s*"
    r"(?:\[(?P<arr>[^\]]*)\])?\s*;",
)

_STRUCT_BRIEF_RE = re.compile(r"@brief\s+([^\n*]+)")

# 实例宏： #define GPIOA   ((GPIO_TypeDef *) GPIOA_BASE)
_INSTANCE_RE = re.compile(
    r"(?m)^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)[ \t]+"
    r"\(\s*\(\s*([A-Za-z_]\w*)\s*\*\s*\)\s*[A-Za-z_]\w*\s*\)"
)

# 结构体成员类型 → 寄存器名前缀的别名表。
# 只有 DMA_Channel 是真需要的：CMSIS 的 DMA 通道是 7 个实例，寄存器名去掉
# "Channel" 再带通道号（DMA_CCR1..7）。
ALIAS_STRUCT: dict[str, str] = {
    "DMA_Channel": "DMA",
}

# 只做「地址别名视图」的结构体：成员与主结构体重名同址，收录会造出重复寄存器。
# ADC_Common_TypeDef 就是 ADC1 地址 + 偏移视图（ADC12_COMMON），不单独收。
SKIP_STRUCTS: frozenset[str] = frozenset(
    {
        "ADC_Common_TypeDef",
        # CAN 的邮箱/过滤器子结构体：真正的寄存器名由位定义分节给出
        # （CAN_TI0R / CAN_F0R1 …），按成员名展开会得到 CAN_TIR 这种不存在的名字
        "CAN_TxMailBox_TypeDef",
        "CAN_FIFOMailBox_TypeDef",
        "CAN_FilterRegister_TypeDef",
    }
)

# 结构体 → 外设 id。键是去掉 _TypeDef/_Type 后的前缀。
STRUCT_TO_PERIPHERAL: dict[str, str] = {
    "ADC": "ADC",
    "BKP": "BKP",
    "CAN": "CAN",
    "CRC": "CRC",
    "DBGMCU": "DBGMCU",
    "DMA": "DMA",
    "DMA_Channel": "DMA",
    "EXTI": "EXTI",
    "FLASH": "FLASH",
    "OB": "FLASH",
    "GPIO": "GPIO",
    "AFIO": "GPIO",  # AFIO 是 GPIO 的复用功能寄存器组（SPL 里也归 GPIO 模块）
    "I2C": "I2C",
    "IWDG": "IWDG",
    "PWR": "PWR",
    "RCC": "RCC",
    "RTC": "RTC",
    "SPI": "SPI",
    "TIM": "TIM",
    "USART": "USART",
    "USB": "CMSIS",  # 本型号无 SPL/HAL USB 驱动，寄存器归到 CMSIS 器件头这一栏
    "WWDG": "WWDG",
    # 内核（core_cm3.h）：SPL 把它们放在 CORTEX 外设下，这里保持一致
    "SCB": "CORTEX",
    "NVIC": "CORTEX",
    "SysTick": "CORTEX",
    "SCnSCB": "CORTEX",
    "MPU": "CORTEX",
    "ITM": "CORTEX",
    "DWT": "CORTEX",
    "TPI": "CORTEX",
    "CoreDebug": "CORTEX",
}

# 只在 core_cm3.h 里的调试组件（ITM/DWT/TPI/CoreDebug）。
# 它们在 Cortex-M3 上是**真实存在**的寄存器（如 DWT->CYCCNT 是周期计数器），
# 也是本机头文件里唯一位定义齐全、可追溯到源码的部分，所以照样收录，
# 只在外设归属上统一算到 CORTEX，不另开外设条目。
CORE_DEBUG_STRUCTS: frozenset[str] = frozenset(
    {"ITM_Type", "DWT_Type", "TPI_Type", "CoreDebug_Type"}
)

# 位定义分节里、结构体没覆盖到的寄存器，按前缀补外设 id
_REGISTER_PREFIX_PERIPHERAL: dict[str, str] = {
    "ADC": "ADC",
    "AFIO": "GPIO",
    "BKP": "BKP",
    "CAN": "CAN",
    "CRC": "CRC",
    "DBGMCU": "DBGMCU",
    "DMA": "DMA",
    "EXTI": "EXTI",
    "FLASH": "FLASH",
    "GPIO": "GPIO",
    "I2C": "I2C",
    "IWDG": "IWDG",
    "OB": "FLASH",
    "PWR": "PWR",
    "RCC": "RCC",
    "RTC": "RTC",
    "SPI": "SPI",
    "TIM": "TIM",
    "USART": "USART",
    "USB": "CMSIS",
    "WWDG": "WWDG",
    "NVIC": "CORTEX",
    "SCB": "CORTEX",
    "SCnSCB": "CORTEX",
    "SysTick": "CORTEX",
    "MPU": "CORTEX",
    "ITM": "CORTEX",
    "DWT": "CORTEX",
    "TPI": "CORTEX",
    "CoreDebug": "CORTEX",
}


def peripheral_of_register(reg_name: str) -> str:
    head = reg_name.split("_")[0]
    return _REGISTER_PREFIX_PERIPHERAL.get(head, head)


def _eval_array_len(expr: str) -> int | None:
    expr = expr.strip()
    if not expr:
        return None
    if re.fullmatch(r"\d+[uUlL]*", expr):
        return int(expr.rstrip("uUlL"))
    m = re.fullmatch(r"(\d+)\s*[*]\s*(\d+)", expr)
    if m:
        return int(m.group(1)) * int(m.group(2))
    return None  # 表达式型（如 16 - 2）不猜


# CAN 的邮箱/过滤器寄存器名 ⇄ 子结构体成员的对应表。
#
# 依据是 stm32f103xb.h 自身：CAN_TypeDef 里 sTxMailBox[3] 的元素类型
# CAN_TxMailBox_TypeDef 有成员 TIR/TDTR/TDLR/TDHR，位定义分节把它们写成
# CAN_TI0R / CAN_TDT0R / CAN_TDL0R / CAN_TDH0R……（数字是邮箱号）。
# 所以这张表是**从源码里两套命名对出来的**，不是推测；build 时会校验
# 目标成员确实存在于对应结构体，不存在就告警并跳过。
CAN_SUBSTRUCT_MAP: dict[str, tuple[str, str]] = {
    # 位定义分节里的寄存器后缀 → (CAN_TypeDef 里的数组字段, 子结构体里的成员名)
    "TI": ("sTxMailBox", "TIR"),
    "TDT": ("sTxMailBox", "TDTR"),
    "TDL": ("sTxMailBox", "TDLR"),
    "TDH": ("sTxMailBox", "TDHR"),
    "RI": ("sFIFOMailBox", "RIR"),
    "RDT": ("sFIFOMailBox", "RDTR"),
    "RDL": ("sFIFOMailBox", "RDLR"),
    "RDH": ("sFIFOMailBox", "RDHR"),
}

_CAN_MAILBOX_RE = re.compile(r"^CAN_([A-Z]+)([0-9])R$")
_CAN_FILTER_RE = re.compile(r"^CAN_F(\d+)R([12])$")


def parse_structs(text: str, warn: Callable[[str, str], None]) -> dict[str, StructDef]:
    """解析所有 `typedef struct {...} Xxx;`。"""
    out: dict[str, StructDef] = {}
    for m in _STRUCT_RE.finditer(text):
        names = [n.strip() for n in m.group("names").split(",") if n.strip()]
        if not names:
            continue
        brief = ""
        bm = None
        for bm in _STRUCT_BRIEF_RE.finditer(text, max(0, m.start() - 1500), m.start()):
            brief = normalize_ws(bm.group(1))
        body_off = m.start("body")
        body = m.group("body")
        members: list[StructMember] = []
        for mm in _MEMBER_RE.finditer(body):
            mtype = normalize_ws(mm.group("type"))
            if mtype in ("typedef", "struct", "union"):
                continue
            arr = mm.group("arr")
            arr_len = _eval_array_len(arr) if arr is not None else None
            if arr is not None and arr_len is None:
                warn("reg", f"{names[0]}.{mm.group('name')} 数组长度无法求值：{arr}")
            # 成员说明：本行后面紧跟的 `/*!< ... */`。
            # stm32f103xb.h 与 core_cm3.h 都是这个写法
            #   `__IO uint32_t CRL;   /*!< ... */`
            #   `__IM  uint32_t CPUID; /*!< Offset: 0x000 (R/ )  CPUID Base Register */`
            line_end = body.find("\n", mm.end())
            if line_end < 0:
                line_end = len(body)
            tail = body[mm.end() : line_end]
            cm = re.search(r"/\*!?<([^*]*(?:\*(?!/)[^*]*)*)\*/", tail)
            desc = normalize_ws(cm.group(1)) if cm else ""
            # core_cm3.h 的注释前面缀了 `Offset: 0x00C (R/W)  `，去掉这段元信息
            desc = re.sub(r"^Offset:\s*0x[0-9A-Fa-f]+\s*\([^)]*\)\s*", "", desc)
            members.append(
                StructMember(
                    name=mm.group("name"),
                    type=mtype,
                    array_len=arr_len,
                    desc_en=desc,
                    line=line_of(text, body_off + mm.start("name")),
                )
            )
        for name in names:
            out[name] = StructDef(
                name=name,
                brief_en=brief,
                members=[StructMember(**vars(x)) for x in members],
            )
    return out


def parse_instances(text: str) -> dict[str, list[str]]:
    """实例宏 → {结构体类型: [实例名...]}，如 GPIO_TypeDef: [GPIOA..GPIOE]。"""
    out: dict[str, list[str]] = {}
    for m in _INSTANCE_RE.finditer(text):
        out.setdefault(m.group(2), []).append(m.group(1))
    return out


# ---------------------------------------------------------------------------
# 位定义分节解析
# ---------------------------------------------------------------------------

# /****  Bit definition for GPIO_CRL register  ****/
# 真实文件里有两处瑕点：分节名后多余空格（`DMA_CNDTR  register`）、
# 整行被写成 `/*!<****...` 形式（RCC_CIR）——正则都要能吃下。
_BIT_SECTION_RE = re.compile(
    r"/\*+!?<?\**\s*Bit\s+definition\s+for\s+([A-Za-z0-9_]+)\s+register",
)

_DEFINE_RE = re.compile(
    r"(?m)^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)(\([^)\n]*\))?[ \t]*([^\n]*)$"
)

# "MODE0[1:0] bits (...)" / "Bit 7" / "Bits 5:4"
_BIT_RANGE_DESC_RE = re.compile(r"\b([A-Za-z_]\w*)\[(\d+(?::\d+)?)\]\s*bits?\b", re.I)
_BIT_SINGLE_RE = re.compile(r"\bBits?\s+(\d+)\s*[:.]?\s*(\d+)?", re.I)


def _mask_bits(mask_text: str) -> tuple[int, int] | None:
    """从掩码字面值算出 (最低位, 位宽)；非连续掩码返回 None。

    只认两种 CMSIS 写法：
        (0x3UL << X_Pos)     —— 位移，位宽由常量决定
        (0x0000000FUL)       —— 直接给掩码
    散置掩码（`0x33333333` 这种覆盖多组位的）**不算**位域范围：
    它跨了 8 个 pin 的字段，报 `bits[15:0]` 是错的，交由调用方原样展示掩码。
    """
    v = _BLOCK_COMMENT_RE.sub("", mask_text or "").strip()
    m = re.match(
        r"\(?\s*(0[xX][0-9a-fA-F]+|\d+)[uUlL]*\s*<<\s*([A-Za-z_]\w*)(?:_Pos)?\s*\)?",
        v,
    )
    if m:
        const = int(m.group(1), 0)
        width = const.bit_length()
        # `0x3 << Pos` 这种常量必须是全 1 的连续掩码（3=0b11、0xF=0b1111）
        if const == (1 << width) - 1:
            return (-1, width)
        return None
    m = re.fullmatch(r"\(?\s*(0[xX][0-9a-fA-F]+|\d+)[uUlL]*\s*\)?", v)
    if m:
        value = int(m.group(1), 0)
        if value == 0:
            return None
        bit_count = value.bit_count()
        # 连续掩码：值 == (2^n - 1) << lo
        if value != ((1 << bit_count) - 1) << ((value & -value).bit_length() - 1):
            return None
        lo = (value & -value).bit_length() - 1
        return (lo, bit_count)
    return None


def _field_type(name: str, desc: str, pos: int | None, mask: str) -> str:
    """位域的 `type` 字段，形如 `bits[3:2]` / `bit 7` / `0x0000000F`。

    优先级（从最可靠到兜底）：
      1. `_Pos` 的数值 + `_Msk` 的位宽 → `bits[hi:lo]`（GPIO_CRL_MODE0 = bits[1:0]）
      2. 注释里的 `XXX[1:0] bits` / `Bit 7`
      3. `_Msk` 原始表达式
      4. 空
    """
    if pos is not None and pos >= 0:
        bits = _mask_bits(mask)
        if bits and bits[1] > 0:
            width = bits[1]
            if width == 1:
                return f"bit {pos}"
            return f"bits[{pos + width - 1}:{pos}]"
        # 散置掩码（如 GPIO_CRL_MODE = 0x33333333，横跨 8 个引脚字段）：
        # 报 bits[hi:lo] 是错的，原样给掩码。
        if mask and mask != f"{name}_Msk":
            return mask
        return f"bit {pos}"
    d = _BIT_RANGE_DESC_RE.search(desc or "")
    if d:
        rng = d.group(2)
        return f"bits[{rng}]" if ":" in rng else f"bit {rng}"
    m = _BIT_SINGLE_RE.search(desc or "")
    if m:
        hi, lo = m.group(1), m.group(2)
        return f"bits[{hi}:{lo}]" if lo else f"bit {hi}"
    if mask:
        bits = _mask_bits(mask)
        if bits and bits[1] > 0:
            lo, width = bits
            if lo >= 0:
                return f"bit {lo}" if width == 1 else f"bits[{lo + width - 1}:{lo}]"
        # 解析不出位宽（如 `GPIO_CRL_MODE_Msk` 这种散置掩码 0x33333333）：
        # 保留源码里的掩码原文，不猜范围。
        return mask
    if name.endswith("_Pos"):
        return "bit position"
    if name.endswith("_Msk"):
        return "mask"
    return ""


def _is_semantic_desc(text: str) -> bool:
    """该注释是不是**语义说明**（而不是 `0x0000FFFE` 这种纯掩码值）。"""
    s = (text or "").strip()
    if not s:
        return False
    return not re.fullmatch(r"0[xX][0-9a-fA-F]+", s)


def parse_bit_sections(
    text: str, warn: Callable[[str, str], None]
) -> dict[str, list[BitField]]:
    """按 "Bit definition for X register" 分节，抽出每节的位域宏。

    三种真实写法合成一条位域：
        #define X_Pos  (0U)                    位置
        #define X_Msk  (0x3UL << X_Pos)        掩码
        #define X      X_Msk                   对外别名
    `X_0` / `X_1` 这类拆位宏单独保留（HAL 里 GPIO_CRL_MODE0_1 是真在用的）。

    **只收真位域**：判定标准是这个宏能反推出位位置或掩码，即
      有 `_Pos` / 有 `_Msk` / 别名的值引用了本节的另一个宏。
    分节里还混着大量**字段取值常量**（`AFIO_EXTICR1_EXTI0_PA 0x00000000U`、
    `PWR_CR_PLS_LEV0`、`RCC_CFGR_SW_HSE`…），它们只是某个位域的候选值，
    不是独立的位域。把它们当位域塞进 params 会让 GPIO_CRL 这种寄存器多出
    上百条假位域——所以这里剔除，它们仍在 registers.json 的符号表里有据可查。
    """
    marks: list[tuple[int, str]] = [
        (m.start(), m.group(1)) for m in _BIT_SECTION_RE.finditer(text)
    ]
    if not marks:
        return {}

    sections: dict[str, list[tuple[str, str, str, int]]] = {}
    for m in _DEFINE_RE.finditer(text):
        name, fn_params, raw_value = m.group(1), m.group(2), m.group(3)
        if fn_params:
            continue
        owner = None
        for pos, reg in marks:
            if pos < m.start():
                owner = reg
            else:
                break
        if owner is None:
            continue
        # 注释就在值里：`(0xFFFFUL << X_Pos)   /*!< 0x0000FFFF */`
        cm = _INLINE_COMMENT_RE.search(raw_value)
        desc = normalize_ws(cm.group(1)) if cm else ""
        sections.setdefault(owner, []).append(
            (
                name,
                _BLOCK_COMMENT_RE.sub("", raw_value).strip(),
                desc,
                line_of(text, m.start()),
            )
        )

    out: dict[str, list[BitField]] = {}
    for reg, items in sections.items():
        pos_map: dict[str, int] = {}
        for name, value, _desc, _line in items:
            if name.endswith("_Pos"):
                mm = re.search(r"\(?\s*(\d+)[uUlL]*\s*\)?", value)
                if mm:
                    pos_map[name[: -len("_Pos")]] = int(mm.group(1))
        # 本节里所有带 _Pos/_Msk 的基名（真正的位域）
        bit_names = {
            n[: -len("_Pos")] for n, _v, _d, _l in items if n.endswith("_Pos")
        } | {n[: -len("_Msk")] for n, _v, _d, _l in items if n.endswith("_Msk")}

        def _mask_literal(raw: str) -> str:
            """把 `(0x3UL << X_Pos)` / `X_Msk` 这类掩码还原成可读字面值。

            能算就算出 0x00000003；算不出就原样返回，绝不猜。
            """
            v = _BLOCK_COMMENT_RE.sub("", raw or "").strip()
            m = re.match(
                r"\(?\s*(0[xX][0-9a-fA-F]+|\d+)[uUlL]*\s*<<\s*([A-Za-z_]\w*)(?:_Pos)?\s*\)?",
                v,
            )
            if m:
                base = int(m.group(1), 0)
                pos = pos_map.get(m.group(2).replace("_Pos", ""))
                if pos is not None:
                    return f"0x{base << pos:08X}"
            m2 = re.fullmatch(r"\(?\s*(0[xX][0-9a-fA-F]+|\d+)[uUlL]*\s*\)?", v)
            if m2:
                return f"0x{int(m2.group(1), 0):08X}"
            # 别名指向另一个掩码宏（`X = X_Msk`）：顺着查一次
            alias = re.fullmatch(r"([A-Za-z_]\w*)_Msk", v)
            if alias:
                inner = msk_expr.get(alias.group(1))
                if inner and inner != raw:
                    return _mask_literal(inner)
            return raw or ""

        msk_expr: dict[str, str] = {}
        for _n, _v, _d, _l in items:
            if _n.endswith("_Msk"):
                msk_expr[_n[: -len("_Msk")]] = _v

        def is_value_constant(name: str) -> bool:
            """是不是某个位域的**候选值常量**（不是位域本身）。

            CMSIS 也给候选值写了 `_Pos`/`_Msk`（便于按位或），所以只看有没有
            `_Msk` 区分不出来。可靠判据是名字：候选值总是「某个位域名 +
            **非数字**后缀」——
                `AFIO_EVCR_PIN_PX1`  = `AFIO_EVCR_PIN` + "_PX1" → 候选值
                `GPIO_CRL_MODE0_1`   = `GPIO_CRL_MODE0` + "_1"  → 拆位宏，保留
                `RCC_CFGR_PLLMULL3`  = `RCC_CFGR_PLLMULL` + "3" → 拆位宏，保留

            注意：判定前先剥掉 `_Pos` / `_Msk` 后缀。它们在**值**上是给字段用的
            （`GPIO_CRL_MODE1_Pos` 是 MODE1 的位置），不能当成 `GPIO_CRL_MODE`
            的候选值，否则 pos_map 会整片空掉、位域范围全算错。
            """
            base = re.sub(r"_(?:Pos|Msk)$", "", name)
            for parent in sorted(bit_names, key=len, reverse=True):
                if parent == base or not base.startswith(parent):
                    continue
                tail = base[len(parent) :]
                if re.fullmatch(r"_?\d+", tail):
                    continue  # 拆位宏，保留
                return True
            return False

        def is_aggregate(name: str) -> bool:
            """是否代表整个位域（而非其中单个比特）。

            判定：它自己是 `_Pos`/`_Msk` 的基名（= 真位域），且名字不带纯数字尾号。
            `GPIO_CRL_MODE0` → 整字段；`GPIO_CRL_MODE0_1` → 单比特。
            """
            if name not in bit_names:
                return False
            return not re.search(r"_\d+$", name)

        fields: dict[str, BitField] = {}
        order: list[str] = []

        def touch(key: str, line: int) -> BitField:
            bf = fields.get(key)
            if bf is None:
                bf = BitField(name=key, line=line)
                fields[key] = bf
                order.append(key)
            return bf

        for name, value, desc, line in items:
            if not value.strip():
                # 无值宏（`#define ADC_MULTIMODE_SUPPORT /*!< 特性开关 */`）：
                # 是器件特性开关，不是任何寄存器的位域。
                continue
            if is_value_constant(name):
                continue  # 候选值常量（PX1/HSE/CIRC…），不是位域
            if name.endswith("_Pos"):
                key = name[: -len("_Pos")]
                bf = touch(key, line)
                bf.pos = pos_map.get(key)
                if desc and not bf.desc_en:
                    bf.desc_en = desc
                continue
            if name.endswith("_Msk"):
                key = name[: -len("_Msk")]
                bf = touch(key, line)
                bf.pos = pos_map.get(key)
                bf.value = value
                bf.mask = value
                bf.line = line
                if desc and not bf.desc_en:
                    bf.desc_en = desc
                continue
            bf = touch(name, line)
            if bf.value is None:
                bf.value = value
                bf.mask = value
            # 别名行（`X = X_Msk /*!< 语义说明 */`）的注释才是人话，
            # `_Msk` 行的注释只是掩码值。优先级：语义 > 掩码值。
            if desc and _is_semantic_desc(desc):
                bf.desc_en = desc
            elif desc and not bf.desc_en:
                bf.desc_en = desc

        result: list[BitField] = []
        for key in order:
            bf = fields[key]
            bf.aggregate = is_aggregate(key)
            if not bf.aggregate and bf.pos is None:
                # 拆位宏 X_N 的位置 = 父位域位置 + N（CMSIS 的固定写法）
                m3 = re.match(r"^(.+?)_(\d+)$", key)
                if m3 and m3.group(1) in pos_map:
                    bf.pos = pos_map[m3.group(1)] + int(m3.group(2))
            literal = _mask_literal(bf.mask)
            bf.type = _field_type(bf.name, bf.desc_en, bf.pos, literal)
            if bf.aggregate:
                bf.type = f"{bf.type}（整个位域）" if bf.type else "整个位域"
            result.append(bf)
        # 稳定排序：聚合宏按源码顺序在前，拆位宏在后
        result.sort(key=lambda b: 0 if b.aggregate else 1)
        if result:
            out[reg] = result
    return out


# ---------------------------------------------------------------------------
# 寄存器集合构建
# ---------------------------------------------------------------------------

MEMBER_SIZE = 4  # 本文件所有外设寄存器都是 32 位；uint8_t/uint16_t 成员单独处理

# 数组寄存器展开上限：<= 该长度才逐个展开成 X1..Xn，
# 超过就只留一条 `X`（如 NVIC->IP[240] 是每个中断一个字节的优先级数组，
# 展开成 240 条既没用又把列表冲垮）。
MAX_ARRAY_EXPAND = 8

_SCALAR_SIZE = {
    "uint8_t": 1,
    "int8_t": 1,
    "uint16_t": 2,
    "int16_t": 2,
    "uint32_t": 4,
    "int32_t": 4,
}


def _member_size(m: StructMember) -> int:
    return _SCALAR_SIZE.get(m.type.replace("volatile ", "").strip(), MEMBER_SIZE)


def _register_prefix(struct_name: str) -> str:
    for suffix in ("_TypeDef", "_Type"):
        if struct_name.endswith(suffix):
            struct_name = struct_name[: -len(suffix)]
            break
    return ALIAS_STRUCT.get(struct_name, struct_name)


def build_registers(
    structs: dict[str, StructDef],
    instances: dict[str, list[str]],
    bit_map: dict[str, list[BitField]],
    warn: Callable[[str, str], None],
) -> list[Register]:
    """结构体叶子成员 + 位定义分节 → 寄存器列表（按外设名排序）。

    数组成员的两种处理（都来自源码事实，不做猜测）：
      * DMA_Channel_TypeDef 的 CCR/CNDTR/CPAR/CMAR：CMSIS 用 7 个实例宏
        （DMA1_Channel1..7）描述同一组寄存器，真实名字是 DMA_CCR1..7，
        所以按通道数展开，访问表达式逐通道给出。
      * 其余数组成员（NVIC->ISER[8]、AFIO->EXTICR[4]）：**不展开**，
        只留一条 `NVIC_ISER`，表达式写成 `NVIC->ISER[n]`——这与 SPL
        registers.json 的口径一致，也不会凭空造出 ISER1..8 这种不存在的名字。
        若位定义分节逐个写了 AFIO_EXTICR1..4，则由分节补出带下标的表达式。
    """
    regs: dict[str, Register] = {}
    array_expr: dict[str, str] = {}  # AFIO_EXTICR1 -> AFIO->EXTICR[0]
    instance_of: dict[str, str] = {}
    for stype, names in instances.items():
        if names:
            instance_of[stype] = sorted(names)[0]

    dma_channels = sorted(
        n
        for n in instances.get("DMA_Channel_TypeDef", [])
        if re.fullmatch(r"DMA1_Channel\d+", n)
    )
    dma_channel_count = len(dma_channels) or 7

    # ---- 1. 结构体叶子成员 → 寄存器 ----
    for sname, st in structs.items():
        if sname in SKIP_STRUCTS:
            continue
        base = sname
        for suffix in ("_TypeDef", "_Type"):
            if base.endswith(suffix):
                base = base[: -len(suffix)]
                break
        periph = STRUCT_TO_PERIPHERAL.get(base)
        if periph is None:
            warn("reg", f"结构体 {sname} 未映射到外设，寄存器名按前缀推断")
            periph = peripheral_of_register(base)
        prefix = _register_prefix(sname)
        instance = instance_of.get(sname, "")
        offset = 0
        for mem in st.members:
            if mem.is_sub_struct:
                # 子结构体（CAN 的邮箱/过滤器）：名字由位定义分节给出，这里不猜
                continue
            if mem.name.upper().startswith(("RESERVED", "RSERVED")):
                offset += _member_size(mem) * (mem.array_len or 1)
                continue
            if mem.name.startswith(("u8", "u16", "u32", "u64")):
                # `__IOM uint8_t u8;` 是与前一成员同址的按字节视图，不是新寄存器
                continue

            if base == "DMA_Channel":
                # 7 个通道实例共用同一组成员：DMA_CCR1..7 = DMA1_Channel1..7->CCR
                for ch in range(1, dma_channel_count + 1):
                    rname = f"{prefix}_{mem.name}{ch}"
                    regs.setdefault(
                        rname,
                        Register(
                            name=rname,
                            struct_name=sname,
                            peripheral=periph,
                            expression=f"DMA1_Channel{ch}->{mem.name}",
                            offset=0,
                            desc_en=mem.desc_en,
                        ),
                    )
                continue

            rname = f"{prefix}_{mem.name}"
            if mem.array_len is not None and mem.array_len <= MAX_ARRAY_EXPAND:
                # 小数组：每个下标在硬件上是独立的一个寄存器。
                # 命名按 ST 自己的习惯用 1 基（BKP_DR1..、AFIO_EXTICR1..4、
                # CAN_F0R1..），访问表达式用真实 C 下标 [i-1]。
                for i in range(1, mem.array_len + 1):
                    sub_name = f"{rname}{i}"
                    regs.setdefault(
                        sub_name,
                        Register(
                            name=sub_name,
                            struct_name=sname,
                            peripheral=periph,
                            expression=(
                                f"{instance}->{mem.name}[{i - 1}]" if instance else ""
                            ),
                            offset=offset + (i - 1) * _member_size(mem),
                            desc_en=mem.desc_en,
                        ),
                    )
                array_expr[rname] = f"{instance}->{mem.name}[n]" if instance else ""
            elif mem.array_len is not None:
                # 大数组（NVIC->IP[240]、CAN 过滤器）：只留一条模板条目
                regs.setdefault(
                    rname,
                    Register(
                        name=rname,
                        struct_name=sname,
                        peripheral=periph,
                        expression=f"{instance}->{mem.name}[n]" if instance else "",
                        offset=offset,
                        desc_en=mem.desc_en,
                    ),
                )
            else:
                regs.setdefault(
                    rname,
                    Register(
                        name=rname,
                        struct_name=sname,
                        peripheral=periph,
                        expression=f"{instance}->{mem.name}" if instance else "",
                        offset=offset,
                        desc_en=mem.desc_en,
                    ),
                )
            offset += _member_size(mem) * (mem.array_len or 1)

    # ---- 2. 位定义分节 → 位域 ----
    # DMA 的位定义分节写的是模板名（DMA_CCR），要落到 7 个带通道号的寄存器上
    dma_templates = {
        n for n in bit_map if re.fullmatch(r"DMA_(CCR|CNDTR|CPAR|CMAR)", n)
    }

    for rname, fields in bit_map.items():
        if rname in dma_templates:
            hit = 0
            for ch in range(1, dma_channel_count + 1):
                reg = regs.get(f"{rname}{ch}")
                if reg is not None:
                    reg.bit_fields = [BitField(**vars(b)) for b in fields]
                    reg.bit_defined = True
                    hit += 1
            if hit:
                continue  # 模板本身不单独成条目
        reg = regs.get(rname)
        if reg is None:
            # 分节里有、结构体里没有：多为数组元素的逐个写法（AFIO_EXTICR1..4）
            reg = Register(
                name=rname,
                struct_name="",
                peripheral=peripheral_of_register(rname),
                expression=array_expr.get(rname, ""),
            )
            regs[rname] = reg
        reg.bit_fields = [BitField(**vars(b)) for b in fields]
        reg.bit_defined = True

    # ---- 3. 描述兜底：优先用位域的语义注释 ----
    #
    # CMSIS 的注释有两种：语义说明（"Transmission Buffer Address 0"）和
    # 纯掩码值（"0x0000FFFE"）。后者对用户没信息量，不能当寄存器描述 ——
    # 之前 USB_ADDR0_TX 的 briefEn 就是 "0x0000FFFE"，等于没说。
    for reg in regs.values():
        if reg.desc_en:
            continue
        for bf in reg.bit_fields:
            cand = (bf.desc_en or "").strip()
            if not cand:
                continue
            if re.fullmatch(r"0[xX][0-9a-fA-F]+", cand):
                continue  # 只是掩码值，跳过
            reg.desc_en = cand
            break

    # ---- 4. 补访问表达式 ----
    _fill_expressions(regs, structs, instance_of, warn)

    return sorted(regs.values(), key=lambda r: (r.peripheral, r.name))


def _usb_pma_expression(name: str) -> str:
    """USB 包缓冲区表项的访问写法。

    CMSIS 头里 `USB_ADDR7_TX` / `USB_COUNT7_RX_1` 这些宏是给寄存器表**描述**
    用的，真正的 C 访问必须按 PMA 偏移算：
        #define USB_PMAADDR  (APB1PERIPH_BASE + 0x00006000UL)
        *(volatile uint32_t *)(USB_PMAADDR + 0x0020)
    表内偏移由 BTABLE 内容在运行期决定，所以这里写成带 `pma_off` 变量的形式，
    并在备注里说明，而不是硬编一个错的地址。
    """
    return f"*(volatile uint32_t *)(USB_PMAADDR + pma_off)  /* {name} */"


def _fill_expressions(
    regs: dict[str, Register],
    structs: dict[str, StructDef],
    instance_of: dict[str, str],
    warn: Callable[[str, str], None],
) -> None:
    """给没有表达式的寄存器补出 C 里真实可用的写法。

    三种真实缺口，全部有源码依据：
      1. CAN 的邮箱/过滤器寄存器：名字来自位定义分节，成员实际在
         `sTxMailBox[]` / `sFIFOMailBox[]` / `sFilterRegister[]` 子结构体里，
         按 CAN_SUBSTRUCT_MAP 对出 `CAN1->sTxMailBox[0].TIR`。
      2. OB（选项字节）寄存器：`OB_TypeDef` 有自己的实例宏 `OB`，但
         stm32f103xb.h 把位定义分节写成 FLASH_RDP / FLASH_USER…，
         两者是同一片地址（OB_BASE = FLASH_RDP 地址）。这里把 FLASH_* 的
         选项字节名指到 `OB->成员`，其余照旧。
      3. USB 的分块寄存器（USB_ADDR0_TX / USB_COUNT0_RX 等 PMA 表）：
         真实写法要按 `USB->BTABLE` 做地址偏移，没有单条成员访问表达式，
         留空并由上层如实标注，不硬编一个错的。
    """
    can_prefix = instance_of.get("CAN_TypeDef", "")
    can_struct = structs.get("CAN_TypeDef")
    can_members = {m.name: m for m in can_struct.members} if can_struct else {}
    ob_prefix = instance_of.get("OB_TypeDef", "")

    for reg in regs.values():
        if reg.expression:
            continue
        name = reg.name

        if can_prefix:
            m = _CAN_MAILBOX_RE.match(name)
            if m:
                tail, idx = m.group(1), int(m.group(2))
                pair = CAN_SUBSTRUCT_MAP.get(tail)
                if pair:
                    field, member = pair
                    sub = can_members.get(field)
                    sub_struct = structs.get(sub.type) if sub is not None else None
                    if sub_struct and any(s.name == member for s in sub_struct.members):
                        reg.expression = f"{can_prefix}->{field}[{idx}].{member}"
                        reg.struct_name = "CAN_TypeDef"
                        continue
                    warn("reg", f"{name} 的子结构体成员 {field}.{member} 不存在")
            m = _CAN_FILTER_RE.match(name)
            if m:
                bank, half = int(m.group(1)), int(m.group(2))
                sub = can_members.get("sFilterRegister")
                sub_struct = structs.get(sub.type) if sub is not None else None
                member = f"FR{half}"
                if sub_struct and any(s.name == member for s in sub_struct.members):
                    reg.expression = f"{can_prefix}->sFilterRegister[{bank}].{member}"
                    reg.struct_name = "CAN_TypeDef"
                    continue
                warn("reg", f"{name} 的过滤器成员 {member} 不存在")

        # 选项字节：FLASH_RDP → OB->RDP（同一片地址，OB 是它的结构体视图）
        if ob_prefix and name.startswith("FLASH_") and reg.struct_name == "":
            ob_struct = structs.get("OB_TypeDef")
            member = name[len("FLASH_") :]
            if ob_struct and any(s.name == member for s in ob_struct.members):
                reg.expression = f"{ob_prefix}->{member}"
                reg.struct_name = "OB_TypeDef"

    # ---- USB 的 PMA（包缓冲区）寄存器：没有固定地址，但照样成条目 ----
    #
    # USB_ADDR0_TX / USB_COUNT0_RX 这些是**包缓冲区描述表**的条目，
    # 地址 = USB_PMAADDR + (BTABLE 内容 + 端点偏移)，运行时由软件分配。
    # CMSIS 头里给它们定义了完整的位域宏，用户查 USB 端点缓冲配置时确实会
    # 找它们。所以**收录为条目**，但 prototype 写清真实访问方式而不是伪造
    # 一个 `USB->ADDR0_TX`（那样的 C 代码编译不过）：
    #     *(volatile uint32_t *)(USB_PMAADDR + offset)
    # offset 留成表达式（BTABLE 是运行期变量），这不是省略，是源码事实。
    usb_struct = structs.get("USB_TypeDef")
    usb_members = {m.name for m in usb_struct.members} if usb_struct else set()
    pma_count = 0
    for name, reg in regs.items():
        if not name.startswith("USB_") or reg.expression:
            continue
        if name[len("USB_") :] in usb_members:
            continue
        reg.expression = _usb_pma_expression(name)
        reg.pma = True
        pma_count += 1
    if pma_count:
        warn(
            "reg",
            f"USB 包缓冲区寄存器 {pma_count} 个：PMA 表项，地址需按 BTABLE 计算，"
            f"prototype 已写成 USB_PMAADDR 偏移形式",
        )


def parse_device_header(path: Path, warn: Callable[[str, str], None]) -> RegisterSet:
    """解析 stm32f103xb.h。"""
    text = read_text(path)
    structs = parse_structs(text, warn)
    instances = parse_instances(text)
    bit_map = parse_bit_sections(text, warn)
    regs = build_registers(structs, instances, bit_map, warn)
    return RegisterSet(registers=regs, structs=structs, instances=instances)


def parse_core_header(path: Path, warn: Callable[[str, str], None]) -> RegisterSet:
    """解析 core_cm3.h（NVIC / SCB / SysTick / ITM / DWT / TPI / MPU / CoreDebug）。

    CMSIS 内核头**没有** `Bit definition for` 分节（位域写在宏函数里），
    所以这里只产出寄存器本体，位域留空——由调用方在数据里如实反映空白，
    不编位域。
    """
    text = read_text(path)
    structs = parse_structs(text, warn)
    instances = parse_instances(text)
    regs = build_registers(structs, instances, {}, warn)
    return RegisterSet(registers=regs, structs=structs, instances=instances)

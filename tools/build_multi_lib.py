#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多库数据构建器：把 SPL（已有）+ HAL + LL + 寄存器 合成 v2 数据。

用法：
    python tools/build_multi_lib.py                     # 用默认本机 STM32CubeF1 路径
    python tools/build_multi_lib.py --cube-root "D:\\STM32Cube\\Repository\\STM32Cube_FW_F1_V1.8.7"
    python tools/build_multi_lib.py --only GPIO          # 只重建某个外设（调试用）
    python tools/build_multi_lib.py --dry-run            # 只解析不写盘

输入（全部本机，不联网）：
    <cube>/Drivers/STM32F1xx_HAL_Driver/Inc/*.h      HAL 原型 / LL 内联函数 / 符号
    <cube>/Drivers/STM32F1xx_HAL_Driver/Src/*.c      HAL 的 doxygen 注释与函数体
    <cube>/Drivers/CMSIS/Device/ST/STM32F1xx/Include/stm32f103xb.h
    <cube>/Drivers/CMSIS/Include/core_cm3.h
    assets/data/peripherals.json + manifest.json     （已有 SPL 数据，只扩展不重写）
    data/zh_overlay_hal/                             中文 overlay（契约 §7）

输出：
    assets/data/functions/hal/<外设>.json
    assets/data/functions/ll/<外设>.json
    assets/data/functions/reg/<外设>.json
    assets/data/symbols_hal.json
    assets/data/peripherals.json                     （扩展为 v2，SPL 内容原样保留）
    assets/data/manifest.json                        （schemaVersion=2）

设计约束（见 docs/contract_v2.md）：
    * 字段名一个都不改；函数 id 全局唯一（HAL_/LL_ 原样，reg 用 REG_ 前缀）
    * section id：新库严格 `<外设>@<库>#<序号>`；SPL 的旧 id（`GPIO#sec1`）保持原样，
      只补 `library: "spl"` 字段，避免动到已有数据（契约允许缺省视为 spl）
    * JSON 一律 UTF-8 无 BOM、ensure_ascii=False、indent=2、键序固定
    * 解析宽容：单个构造失败只记 warning，不中断
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hal_parser as HP  # noqa: E402
import reg_parser as RP  # noqa: E402

SCHEMA_VERSION = 2
DATA_VERSION = "2.0.0"
LIB_ORDER = ("spl", "hal", "ll", "reg")
LIB_ZH = {"spl": "标准库", "hal": "HAL 库", "ll": "LL 库", "reg": "寄存器"}

HAL_VERSION = "STM32Cube_FW_F1_V1.8.7"

DEFAULT_CUBE = Path(
    r"C:\Users\XT\STM32Cube\Repository\STM32Cube_FW_F1_V1.8.7"
)
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "assets" / "data"
OVERLAY_DIR = PROJECT_ROOT / "data" / "zh_overlay_hal"


# ---------------------------------------------------------------------------
# 警告收集
# ---------------------------------------------------------------------------


class Warn:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, where: str, msg: str) -> None:
        self.items.append(f"[{where}] {msg}")

    def dump(self, limit: int = 60) -> None:
        print(f"\n[build] 共 {len(self.items)} 条警告", file=sys.stderr)
        for it in self.items[:limit]:
            print(f"  ! {it}", file=sys.stderr)
        if len(self.items) > limit:
            print(f"  ... 其余 {len(self.items) - limit} 条略", file=sys.stderr)


W = Warn()


def warn(where: str, msg: str) -> None:
    W.add(where, msg)


# ---------------------------------------------------------------------------
# 外设映射：HAL/LL 模块 → peripherals.json 里的外设 id
# ---------------------------------------------------------------------------

# 模块名（stm32f1xx_hal_<模块>.h）→ (外设 id, 该模块的分组补充说明)
# 映射原则：
#   1) 有同名外设就直连（gpio→GPIO、rcc→RCC…）
#   2) 一个外设被多个模块覆盖时（uart/irda/smartcard 都是 USART 的工作模式），
#      全部归到该外设，用分组标题区分
#   3) 本型号（F103C8T6，中容量）没有的外设模块（eth/hcd/pcd…）跳过并告警，
#      不硬塞进别的外设
HAL_MODULE_MAP: dict[str, tuple[str, str]] = {
    "adc": ("ADC", ""),
    "adc_ex": ("ADC", "扩展"),
    "can": ("CAN", ""),
    "cec": ("CEC", ""),
    "cortex": ("CORTEX", ""),
    "crc": ("CRC", ""),
    "dac": ("DAC", ""),
    "dac_ex": ("DAC", "扩展"),
    "dma": ("DMA", ""),
    "dma_ex": ("DMA", "扩展"),
    "exti": ("EXTI", ""),
    "flash": ("FLASH", ""),
    "flash_ex": ("FLASH", "扩展"),
    "gpio": ("GPIO", ""),
    "gpio_ex": ("GPIO", "扩展"),
    "i2c": ("I2C", ""),
    "i2s": ("SPI", "I2S 模式"),
    "irda": ("USART", "IrDA 模式"),
    "iwdg": ("IWDG", ""),
    "mmc": ("SDIO", ""),
    "nand": ("FSMC", "NAND"),
    "nor": ("FSMC", "NOR"),
    "pccard": ("FSMC", "PC 卡"),
    "pwr": ("PWR", ""),
    "rcc": ("RCC", ""),
    "rcc_ex": ("RCC", "扩展"),
    "rtc": ("RTC", ""),
    "rtc_ex": ("RTC", "扩展"),
    "sd": ("SDIO", ""),
    "smartcard": ("USART", "智能卡模式"),
    "spi": ("SPI", ""),
    "tim": ("TIM", ""),
    "tim_ex": ("TIM", "扩展"),
    "uart": ("USART", "UART 模式"),
    "usart": ("USART", ""),
    "wwdg": ("WWDG", ""),
    # 公共定义（只提供类型与宏，没有函数）
    "def": ("MISC", "HAL 公共定义"),
    # HAL 核心模块（stm32f1xx_hal.h / .c）：
    # HAL_Init / HAL_Delay / HAL_GetTick / HAL_IncTick / HAL_GetUIDw0..2
    # 这些是天天要用的基础函数，之前因为文件名是 `hal` 而不是
    # `hal_<模块>`，被配对的 glob 整个漏掉，搜索结果里根本找不到。
    "": ("CORTEX", "HAL 核心"),
    "core": ("CORTEX", "HAL 核心"),
    # 本型号不适用：F103C8T6 无以太网、无 USB OTG（只有全速 USB device，HAL 未建模）
    "eth": ("", "本型号无以太网外设"),
    "hcd": ("", "本型号无 USB OTG 主机"),
    "pcd": ("", "本型号 USB device 未建外设条目"),
    "pcd_ex": ("", "本型号 USB device 未建外设条目"),
}

# LL 模块 → 外设 id。LL 头文件常把多个外设塞进一个文件（ll_bus / ll_system /
# ll_utils），这几支改按函数名前缀二次分流。
LL_MODULE_MAP: dict[str, str] = {
    "adc": "ADC",
    "crc": "CRC",
    "dac": "DAC",
    "dma": "DMA",
    "exti": "EXTI",
    "fsmc": "FSMC",
    "gpio": "GPIO",
    "i2c": "I2C",
    "iwdg": "IWDG",
    "pwr": "PWR",
    "rcc": "RCC",
    "rtc": "RTC",
    "spi": "SPI",
    "tim": "TIM",
    "usart": "USART",
    "wwdg": "WWDG",
    "cortex": "CORTEX",
    "bus": "RCC",  # LL_AHB1_GRP1_EnableClock… 实际都在 RCC 的时钟使能位上
    "system": "",  # 见 _ll_peripheral_of：按 LL_DBGMCU_ / LL_FLASH_ 前缀分流
    "utils": "MISC",  # LL_InitTick / LL_GetUID_* / LL_GetFlashSize
    # SDIO：F103C8T6 带这个外设。LL 层文件名是 `ll_sdmmc`（SD/MMC/SDIO
    # 共用一套寄存器访问函数），本芯片上的 SD 卡正是走 SDIO 控制器。
    "sdmmc": "SDIO",
}

LL_NAME_PREFIX_MAP: list[tuple[str, str]] = [
    ("LL_DBGMCU_", "DBGMCU"),
    ("LL_FLASH_", "FLASH"),
    ("LL_ADC_", "ADC"),
    ("LL_SYSTICK_", "CORTEX"),
    ("LL_HANDLER_", "CORTEX"),
    ("LL_MPU_", "CORTEX"),
    ("LL_LPM_", "CORTEX"),
    ("LL_APB1_GRP", "RCC"),
    ("LL_APB2_GRP", "RCC"),
    ("LL_AHB1_GRP", "RCC"),
]


def _ll_peripheral_of(module: str, func_name: str) -> str:
    base = LL_MODULE_MAP.get(module)
    if base:
        return base
    for prefix, periph in LL_NAME_PREFIX_MAP:
        if func_name.startswith(prefix):
            return periph
    return ""


# ---------------------------------------------------------------------------
# 分组标题中文化
# ---------------------------------------------------------------------------
#
# 只做"机械翻译"：命中的是 ST 自己的固定小节名，翻译不会引入事实错误；
# 未命中时保留英文原文（宁可英文，也不编一个像中文的东西）。
_TITLE_RULES: list[tuple[str, str]] = [
    (r"^Initialization and de-initialization", "初始化与反初始化"),
    (r"^Initialization and Start", "初始化与启动"),
    (r"^Initialization and Configuration", "初始化与配置"),
    (r"^Initialization and", "初始化"),
    (r"^IO operation", "IO 操作"),
    (r"^Input and Output operation", "输入输出操作"),
    (r"^Input and Output", "输入输出"),
    (r"^Input Output and memory control", "输入输出与存储控制"),
    (r"^Peripheral Control", "外设控制"),
    (r"^Peripheral State and Error", "外设状态与错误"),
    (r"^Peripheral State and Errors", "外设状态与错误"),
    (r"^Peripheral State", "外设状态"),
    (r"^Peripheral Abort", "传输中止管理"),
    (r"^Perioheral Abort", "传输中止管理"),
    (r"^Interrupts management", "中断管理"),
    (r"^Callback", "回调"),
    (r"^Configuration functions", "配置函数"),
    (r"^Configuration", "配置"),
    (r"^Control functions", "控制函数"),
    (r"^Control", "控制"),
    (r"^Data Access", "数据访问"),
    (r"^Data_Management", "数据管理"),
    (r"^DATA Management", "数据管理"),
    (r"^Data Management", "数据管理"),
    (r"^DMA Management", "DMA 管理"),
    (r"^DMA_Management", "DMA 管理"),
    (r"^DMA burst mode", "DMA 突发模式"),
    (r"^FLAG Management", "标志管理"),
    (r"^FLAG_Management", "标志管理"),
    (r"^FLAG management", "标志管理"),
    (r"^FLAG-Management", "标志管理"),
    (r"^FLAG management", "标志管理"),
    (r"^IT Management", "中断管理"),
    (r"^IT_Management", "中断管理"),
    (r"^IT-Management", "中断管理"),
    (r"^Interrupt Management", "中断管理"),
    (r"^EVENT-Management", "事件管理"),
    (r"^Event_Management", "事件管理"),
    (r"^Rising_Trigger_Management", "上升沿触发管理"),
    (r"^Falling_Trigger_Management", "下降沿触发管理"),
    (r"^Software_Interrupt_Management", "软件中断管理"),
    (r"^Port Configuration", "端口配置"),
    (r"^Time Base configuration", "时基配置"),
    (r"^Capture Compare configuration", "捕获比较配置"),
    (r"^Input channel configuration", "输入通道配置"),
    (r"^Output channel configuration", "输出通道配置"),
    (r"^Counter clock selection", "计数器时钟选择"),
    (r"^Break function configuration", "刹车功能配置"),
    (r"^Timer synchronisation", "定时器同步"),
    (r"^Advanced Configurations", "高级配置"),
    (r"^Clock", "时钟"),
    (r"^Get system and peripherals clocks", "系统与总线时钟频率"),
    (r"^HSE", "HSE 外部高速时钟"),
    (r"^HSI", "HSI 内部高速时钟"),
    (r"^LSE", "LSE 外部低速时钟"),
    (r"^LSI", "LSI 内部低速时钟"),
    (r"^PLL", "PLL 锁相环"),
    (r"^MCO", "MCO 时钟输出"),
    (r"^RTC", "RTC 时钟"),
    (r"^System", "系统"),
    (r"^Peripheral Clock Source", "外设时钟源"),
    (r"^ALARM", "闹钟"),
    (r"^Backup_Registers", "备份寄存器"),
    (r"^Calibration", "校准"),
    (r"^Tamper", "侵入检测"),
    (r"^Time$", "时间"),
    (r"^HANDLER", "中断向量与异常处理"),
    (r"^LOW POWER MODE", "低功耗模式"),
    (r"^MCU INFO", "芯片信息"),
    (r"^MPU", "MPU 内存保护"),
    (r"^SYSTICK", "SysTick 系统节拍"),
    (r"^HSE|^HSI", "时钟"),
    (r"^DBGMCU", "调试支持"),
    (r"^FLASH", "FLASH"),
    (r"^SYSTEM", "系统"),
    (r"^DELAY", "延时"),
    (r"^DEVICE ELECTRONIC SIGNATURE", "芯片电子签名"),
    (r"^AHB1", "AHB1 总线时钟"),
    (r"^APB1", "APB1 总线时钟"),
    (r"^APB2", "APB2 总线时钟"),
    (r"^Slave Select Pin", "片选引脚管理"),
    (r"^CRC Management", "CRC 校验管理"),
    (r"^NSS", "片选"),
    # ---- 具体外设的分节名（ST 里出现一次以上的才收）----
    (r"^Time Base functions", "时基（TIM_Base_InitTypeDef）"),
    (r"^Time Base", "时基"),
    (r"^Output Compare functions", "输出比较"),
    (r"^PWM functions", "PWM 输出"),
    (r"^Input Capture functions", "输入捕获"),
    (r"^One Pulse functions", "单脉冲输出"),
    (r"^Encoder functions", "编码器接口"),
    (r"^IRQ Handler and Callbacks", "中断服务与回调"),
    (r"^IRQ handler management", "中断服务函数"),
    (r"^Hall Sensor functions", "霍尔传感器接口"),
    (r"^Commutation", "换相事件"),
    (r"^Private Functions$", "内部实现函数（头文件可见，非用户接口）"),
    (r"^Private Functions", "内部实现函数"),
    (r"^Extended features functions", "扩展功能"),
    (r"^Extended functions", "扩展功能"),
    (r"^Advanced features", "高级功能"),
    (r"^State functions", "状态"),
    (r"^Features functions", "功能"),
    (r"^FLAG management", "标志管理"),
    (r"^Complementary", "互补输出"),
    (r"^Peripheral State and Errors", "外设状态与错误"),
    (r"^Peripheral State", "外设状态"),
]


# 库前缀：让用户在函数列表里一眼看出这条分组属于哪个库
# （SPL 保持原样不加前缀，因为它是最早的默认库，加前缀反而啰嗦）
LIB_TITLE_PREFIX = {
    "spl": "",
    "hal": "HAL ",
    "ll": "LL ",
    "reg": "",
}


def lib_title(library: str, title: str) -> str:
    """给分节标题加上库语境。

    - SPL：原样（`初始化与配置函数`）
    - HAL：`HAL 初始化与反初始化` / `HAL IO 操作`
    - LL：`LL 端口配置` / `LL 数据访问`
    - reg：标题本身就是寄存器分类，不再叠前缀
    """
    if not title:
        return title
    prefix = LIB_TITLE_PREFIX.get(library, "")
    if not prefix or title.startswith(prefix.strip()):
        return title
    return f"{prefix}{title}"


# 允许原样保留的英文缩写（外设名 / 总线名 / 常用技术缩写）。
# 检查口径见 check_section_titles()：4 个字母以上、不在白名单里的英文词
# 一律视为「没翻译」。
TITLE_ALLOWED_EN = frozenset(
    """
    GPIO RCC USART UART TIM SPI I2C ADC DMA FLASH PWR BKP IWDG WWDG RTC CRC CAN
    CEC DAC FSMC SDIO EXTI CORTEX CMSIS DBGMCU MISC LL HAL SPL NVIC IRQ USB
    ITM DWT TPI MPU SCB SYSTICK PVD POR PDR LSI LSE HSI HSE PLL PLLI2S PLL2 MCO
    CCx CCMR CCMR1 CCMR2
    AHB AHB1 AHB2 APB APB1 APB2
    IrDA NAND NOR PCCARD MMC I2S SD HDLC
    """.split()
)

# 分节标题的完整翻译表（**从 ST 的原始英文标题出发**，不是从已翻译结果出发）。
#
# 原则：ST 的小节名是固定词汇表，逐个对照即可；遇到表里没有的就保留英文并
# 在上面的检查里报出来，不会编一个像中文但语义偏的标题。
_TITLE_MAP: list[tuple[str, str]] = [
    # ---- 先放「小写开头的 ST 零碎写法」，避免被后面的宽规则吃掉 ----
    (r"^features functions", "扩展功能"),
    (r"features functions", "功能"),
    (r"flag management", "标志管理"),
    (r"flag_management", "标志管理"),
    # ---- 初始化 ----
    (r"^Initialization and de-initialization", "初始化与反初始化"),
    (r"^Initialization and Configuration", "初始化与配置"),
    (r"^Initialization and Start", "初始化与启动"),
    (r"^Initialization/de-initialization", "初始化与反初始化"),
    (r"^Initialization and", "初始化"),
    (r"^De-initialization", "反初始化"),
    (r"^Init", "初始化"),
    # ---- IO / 数据 ----
    (r"^IO operation", "IO 操作"),
    (r"^Input and Output operation", "输入输出操作"),
    (r"^Input Output and memory control", "输入输出与存储控制"),
    (r"^Input and Output", "输入输出"),
    (r"^Data Access", "数据访问"),
    (r"^Data Management", "数据管理"),
    (r"^Data_Management", "数据管理"),
    (r"^DATA Management", "数据管理"),
    (r"^Data access", "数据访问"),
    (r"^Operation on ADC hierarchical scope:\s*ADC instance", "ADC 实例操作"),
    (r"^Operation on ADC hierarchical scope:\s*group injected", "注入通道组操作"),
    (r"^Operation on ADC hierarchical scope:\s*group regular", "规则通道组操作"),
    (r"^Operation on ADC hierarchical scope", "ADC 分组操作"),
    (r"^Operation on DAC channels", "DAC 通道操作"),
    (r"^Operation on", "操作"),
    (r"^Execution", "执行控制"),
    (r"^Output Event configuration", "输出事件配置"),
    (r"^Alternate Function Remapping", "复用功能重映射"),
    (r"^AF_REMAPPING", "复用功能重映射"),
    (r"^EXTI external interrupt", "外部中断（EXTI）"),
    # ---- 外设控制 / 状态 ----
    (r"^Peripheral Control", "外设控制"),
    (r"^Peripheral State and Error", "外设状态与错误"),
    (r"^Peripheral State", "外设状态"),
    (r"^Peripheral errors", "外设错误处理"),
    (r"^Peripheral Abort", "传输中止管理"),
    (r"^Perioheral Abort", "传输中止管理"),
    (r"^Peripheral", "外设"),
    (r"^State functions", "状态"),
    (r"^Control functions", "控制函数"),
    (r"^Control", "控制"),
    (r"^Configuration functions", "配置函数"),
    (r"^Configuration", "配置"),
    (r"^Config", "配置"),
    # ---- 中断 / 回调 / 标志 ----
    (r"^Interrupts management", "中断管理"),
    (r"^IRQ Handler and Callbacks", "中断服务与回调"),
    (r"^IRQ handler management", "中断服务函数"),
    (r"^IRQ Handler", "中断服务函数"),
    (r"^Callback", "回调"),
    (r"^IT Management", "中断管理"),
    (r"^IT_Management", "中断管理"),
    (r"^IT management", "中断管理"),
    (r"^IT-Management", "中断管理"),
    (r"^IT management", "中断管理"),
    (r"^Interrupt Management", "中断管理"),
    (r"^FLAG Management", "标志管理"),
    (r"^FLAG_Management", "标志管理"),
    (r"^FLAG_management", "标志管理"),
    (r"^FLAG management", "标志管理"),
    (r"^FLAG-Management", "标志管理"),
    (r"^Flag_Management", "标志管理"),
    (r"^Flag management", "标志管理"),
    (r"^EVENT-Management", "事件管理"),
    (r"^Event_Management", "事件管理"),
    (r"^Event management", "事件管理"),
    (r"^Rising_Trigger_Management", "上升沿触发管理"),
    (r"^Falling_Trigger_Management", "下降沿触发管理"),
    (r"^Software_Interrupt_Management", "软件中断管理"),
    (r"^Trigger_Management", "触发管理"),
    # ---- DMA ----
    (r"^DMA burst mode", "DMA 突发模式"),
    (r"^DMA Management", "DMA 管理"),
    (r"^DMA_Management", "DMA 管理"),
    (r"^DMA management", "DMA 管理"),
    (r"^DMA", "DMA 管理"),
    # ---- 时钟 ----
    (r"^Get system and peripherals clocks", "系统与总线时钟频率"),
    (r"^Peripheral Clock Source", "外设时钟源"),
    (r"^HSE", "HSE 外部高速时钟"),
    (r"^HSI", "HSI 内部高速时钟"),
    (r"^LSE", "LSE 外部低速时钟"),
    (r"^LSI", "LSI 内部低速时钟"),
    (r"^PLL2", "PLL2 锁相环"),
    (r"^PLLI2S", "PLLI2S 锁相环"),
    (r"^PLL", "PLL 锁相环"),
    (r"^MCO", "MCO 时钟输出"),
    (r"^Clock", "时钟"),
    (r"^AHB1", "AHB1 总线时钟"),
    (r"^APB1", "APB1 总线时钟"),
    (r"^APB2", "APB2 总线时钟"),
    (r"^RTC", "RTC 时钟"),
    (r"^System", "系统"),
    # ---- 定时器 ----
    (r"^Time Base functions", "时基功能"),
    (r"^Time Base", "时基"),
    (r"^Output Compare functions", "输出比较功能"),
    (r"^Output Compare", "输出比较"),
    (r"^PWM functions", "PWM 输出功能"),
    (r"^PWM", "PWM 输出"),
    (r"^Input Capture functions", "输入捕获功能"),
    (r"^Input Capture", "输入捕获"),
    (r"^One Pulse functions", "单脉冲输出功能"),
    (r"^One Pulse", "单脉冲输出"),
    (r"^Encoder functions", "编码器接口功能"),
    (r"^Encoder", "编码器接口"),
    (r"^Hall Sensor", "霍尔传感器接口"),
    (r"^Commutation", "换相事件"),
    (r"^Break function configuration", "刹车功能配置"),
    (r"^Timer synchronisation", "定时器同步"),
    (r"^Capture Compare configuration", "捕获比较配置"),
    (r"^Input channel configuration", "输入通道配置"),
    (r"^Output channel configuration", "输出通道配置"),
    (r"^Counter clock selection", "计数器时钟选择"),
    # ---- RTC / 备份 ----
    (r"^ALARM", "闹钟"),
    (r"^Alarm functions", "闹钟功能"),
    (r"^Time and Date functions", "时间与日期功能"),
    (r"^Backup_Registers", "备份寄存器"),
    (r"^Backup Registers", "备份寄存器"),
    (r"^Calibration", "校准"),
    (r"^Tamper", "侵入检测"),
    (r"^Time$", "时间"),
    (r"^Time", "时间"),
    # ---- 内核 ----
    (r"^HANDLER", "中断向量与异常处理"),
    (r"^LOW POWER MODE", "低功耗模式"),
    (r"^MCU INFO", "芯片信息"),
    (r"^MPU", "MPU 内存保护"),
    (r"^SYSTICK", "SysTick 系统节拍"),
    (r"^DBGMCU", "调试支持"),
    (r"^FLASH", "FLASH 操作"),
    (r"^SYSTEM", "系统"),
    (r"^DELAY", "延时"),
    (r"^DEVICE ELECTRONIC SIGNATURE", "芯片电子签名"),
    # ---- 其它 ----
    (r"^Advanced Configurations", "高级配置"),
    (r"^Advanced Configuration", "高级配置"),
    (r"^Advanced features", "高级功能"),
    (r"^Extended features functions", "扩展功能"),
    (r"^Extended functions", "扩展功能"),
    (r"^Features functions", "功能"),
    (r"^Private Functions", "内部实现函数"),
    (r"^Public Functions", "公开接口函数"),
    (r"^Slave Select Pin", "片选引脚管理"),
    (r"^CRC Management", "CRC 校验管理"),
    (r"^NSS", "片选"),
    (r"^Exported Functions", "对外接口函数"),
    (r"^Exported", "对外接口"),
    # FLASH 的零碎小节（ST 在 flash_ex 里按操作分节）
    (r"^Programming operation", "编程操作功能"),
    (r"^Option Bytes Programming", "选项字节编程功能"),
    (r"^Erase operation", "擦除操作功能"),
    (r"^Erase functions", "擦除功能"),
    (r"^Check null pointer", "空指针检查"),
    (r"^Check the .* handle allocation", "句柄分配检查"),
    (r"^Compute line mask", "计算行掩码"),
    (r"^Reload IWDG counter", "重装看门狗计数器"),
    (r"^Reload", "重装"),
    (r"^FLASH", "FLASH 操作"),
]


def title_zh(en: str) -> str:
    """英文小节标题 → 中文标题（**输出里不带英文单词**，除白名单缩写）。

    处理顺序：
      1. 多模块拼接标题（`UART 模式｜IO 操作`）分段翻译；
      2. `Extended xxx` → 「扩展：xxx」，但**不再级联出双层「扩展：」**；
      3. 命中 `_TITLE_MAP`；
      4. 去掉开头的模块/外设词（`TIM `、`IrDA `、`ADC `）再试一次；
      5. 整串都是白名单缩写就原样；
      6. 仍未命中 → 返回「其他函数」，并记 warning 供人工补表。
         （不返回英文：契约要求 title 是中文字段，英文只留在 titleEn。）
    """
    text = (en or "").strip()
    if not text:
        return ""

    if "｜" in text:
        head, _, tail = text.partition("｜")
        return f"{head}｜{title_zh(tail)}"

    if text.startswith("扩展："):
        inner = text[len("扩展：") :]
        inner_zh = _translate_once(inner)
        if inner_zh.startswith("扩展："):
            return inner_zh
        return f"扩展：{inner_zh}"

    m = re.match(r"^Extended\s+(?:Timer\s+|Peripheral\s+)?(.+)$", text, re.I)
    if m:
        inner = m.group(1)
        if inner.lower().startswith("extended "):
            inner = inner[len("extended ") :]
        inner_zh = _translate_once(inner)
        if inner_zh.startswith("扩展"):
            return inner_zh  # 已经是「扩展功能」，不再叠前缀
        return f"扩展：{inner_zh}"

    return _translate_once(text)


# 出现在标题开头、但本身不承载语义的模块/限定词。
# 剥掉它们再翻译（`IrDA Initialization and ...` → `Initialization and ...`）。
_TITLE_MODULE_PREFIX = re.compile(
    r"^(?:"
    r"IrDA|SmartCard|Smartcard|UART|USART|ADC|DAC|NOR|NAND|PCCARD|MMC|SD|I2S|"
    r"Complementary|Extended|Timer|Peripheral|Advanced|Common|Basic|"
    r"[A-Za-z][A-Za-z0-9]{1,10}"
    r")\s+(.+)$"
)


def _translate_once(text: str) -> str:
    """单层翻译（不含扩展前缀处理）。"""
    for pattern, zh in _TITLE_MAP:
        if re.search(pattern, text):
            return zh

    # 剥掉开头的模块词/限定词再试：
    #   `TIM Time Base functions`        → `Time Base functions`
    #   `IrDA Initialization and ...`    → `Initialization and ...`
    #   `Complementary Output Compare ...` → `Output Compare ...`
    stripped = text
    for _ in range(3):  # 最多剥 3 层（`Extended Complementary PWM ...`）
        m = _TITLE_MODULE_PREFIX.match(stripped)
        if not m:
            break
        stripped = m.group(1)
        for pattern, zh in _TITLE_MAP:
            if re.search(pattern, stripped):
                return zh

    # 整串只有白名单缩写
    words = re.findall(r"[A-Za-z]{2,}", text)
    if words and all(w.upper() in TITLE_ALLOWED_EN for w in words):
        return text

    warn("title", f"分节标题未收录，暂用「其他函数」：{text!r}")
    return "其他函数"


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------


@dataclass
class LibSection:
    id: str
    title: str
    title_en: str
    library: str
    function_ids: list[str] = field(default_factory=list)


@dataclass
class BuildResult:
    functions: dict[str, dict[str, list[dict[str, Any]]]] = field(
        default_factory=dict
    )  # lib -> peripheral -> [func]
    symbols: list[dict[str, Any]] = field(default_factory=list)
    registers: list[dict[str, Any]] = field(default_factory=list)
    sections: dict[str, dict[str, list[LibSection]]] = field(
        default_factory=dict
    )  # lib -> peripheral -> sections
    files: dict[str, dict[str, dict[str, Any]]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# 函数条目构造
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


_FLAGS_TEMPLATE = {
    "deprecated": False,
    "isrSafe": False,
    "inline": False,
    "macroLike": False,
}


def make_function(
    *,
    fid: str,
    name: str,
    peripheral: str,
    library: str,
    section_id: str,
    prototype: str,
    return_type: str,
    params: list[dict[str, Any]],
    return_desc_en: str = "",
    brief_en: str = "",
    remarks: list[str] | None = None,
    header_line: int = 0,
    source_line: int = 0,
    defined_in: str = "",
    inline: bool = False,
    deprecated: bool = False,
    registers: list[str] | None = None,
    related: list[str] | None = None,
    symbol_refs: list[str] | None = None,
    example_code: str = "",
    macro_like: bool = False,
) -> dict[str, Any]:
    """按契约 §4 的字段顺序生成一个函数对象（键序固定，便于 diff）。"""
    return {
        "id": fid,
        "name": name,
        "peripheral": peripheral,
        "library": library,
        "sectionId": section_id,
        "prototype": prototype,
        "returnType": return_type,
        "params": params,
        "returnDescEn": return_desc_en,
        "returnDescZh": "",
        "briefEn": brief_en,
        "briefZh": "",
        "usageZh": "",
        "prerequisites": [],
        "registers": registers or [],
        "relatedFunctions": related or [],
        "remarks": remarks or [],
        "notesZh": [],
        "exampleCode": example_code,
        "exampleLanguage": "c",
        "symbolRefs": symbol_refs or [],
        "headerLine": header_line,
        "definedIn": defined_in,
        "sourceLine": source_line,
        "flags": {
            "deprecated": deprecated,
            "isrSafe": False,
            "inline": inline,
            "macroLike": macro_like,
        },
        "ai": None,
        "zhSource": "base",
    }


# ---------------------------------------------------------------------------
# HAL 解析
# ---------------------------------------------------------------------------


@dataclass
class HalModule:
    module: str  # gpio / gpio_ex / uart …
    peripheral: str  # GPIO / USART …
    note: str  # "扩展" / "UART 模式" …
    header: Path | None
    source: Path | None
    functions: list[HP.RawFunction] = field(default_factory=list)
    symbols: list[HP.RawSymbol] = field(default_factory=list)
    groups: dict[str, str] = field(default_factory=dict)
    declarations: dict[str, tuple[int, str]] = field(default_factory=dict)


def discover_hal_modules(inc: Path, src: Path) -> list[HalModule]:
    """扫描 Inc/ 与 Src/，按模块后缀配对 .h/.c。"""
    modules: dict[str, HalModule] = {}

    # ---- HAL 核心模块（stm32f1xx_hal.h / .c）----
    #
    # 它的文件名是 `stm32f1xx_hal` 而不是 `stm32f1xx_hal_<模块>`，
    # 所以下面那条 `stm32f1xx_hal_*.h` 的 glob 扫不到它。
    # 但它藏着 HAL_Init / HAL_Delay / HAL_GetTick / HAL_IncTick /
    # HAL_GetUIDw0..2 这些最基础的函数——查 HAL 的人一半时间在找它们，
    # 漏掉是不可接受的。这里显式收进来，外设归属记 CORTEX（它们操作的是
    # SysTick/NVIC 这类内核资源）。
    core_h = inc / "stm32f1xx_hal.h"
    core_c = src / "stm32f1xx_hal.c"
    if core_h.is_file():
        modules["core"] = HalModule(
            module="core",
            peripheral="CORTEX",
            note="HAL 核心",
            header=core_h,
            source=core_c if core_c.is_file() else None,
        )

    for h in sorted(inc.glob("stm32f1xx_hal_*.h")):
        mod = h.stem[len("stm32f1xx_hal_") :]
        if mod in ("conf_template",):
            continue
        periph, note = HAL_MODULE_MAP.get(mod, ("", "未映射模块"))
        if not periph:
            warn("hal", f"{h.name} 跳过：{note or '本型号无对应外设'}")
            continue
        modules[mod] = HalModule(
            module=mod,
            peripheral=periph,
            note=note,
            header=h,
            source=(src / f"stm32f1xx_hal_{mod}.c")
            if (src / f"stm32f1xx_hal_{mod}.c").is_file()
            else None,
        )
    # `hal_def.h` 不是外设模块（无函数），但它定义了 HAL_StatusTypeDef /
    # HAL_LockTypeDef / HAL_MAX_DELAY 这些被全库引用的类型与宏。
    # 单独收它的符号，外设归属记 MISC。
    def_h = inc / "stm32f1xx_hal_def.h"
    if def_h.is_file():
        mod = "def"
        periph, note = HAL_MODULE_MAP.get(mod, ("MISC", "HAL 公共定义"))
        modules[mod] = HalModule(
            module=mod,
            peripheral=periph or "MISC",
            note=note,
            header=def_h,
            source=None,
        )

    # 只有 .c 没有 .h 的模块（不存在，防御性处理）
    for c in sorted(src.glob("stm32f1xx_hal_*.c")):
        mod = c.stem[len("stm32f1xx_hal_") :]
        if mod not in modules:
            periph, note = HAL_MODULE_MAP.get(mod, ("", "未映射模块"))
            if not periph:
                warn("hal", f"{c.name} 跳过：{note or '本型号无对应外设'}")
                continue
            modules[mod] = HalModule(
                module=mod, peripheral=periph, note=note, header=None, source=c
            )
    return [modules[k] for k in sorted(modules)]


def collect_hal(inc: Path, src: Path) -> tuple[list[HalModule], list[HP.RawSymbol]]:
    """解析全部 HAL 模块，返回模块列表与 HAL 符号。"""
    modules = discover_hal_modules(inc, src)
    all_symbols: list[HP.RawSymbol] = []
    for m in modules:
        if m.header is not None:
            doc = HP.parse_hal_header(m.header, warn)
            m.symbols = doc.symbols
            m.groups.update(doc.groups)
            m.declarations = HP.parse_header_declarations(
                HP.read_text(m.header), m.header.name
            )
            all_symbols.extend(doc.symbols)
        if m.source is not None:
            doc = HP.parse_hal_source(m.source, warn)
            m.functions = doc.functions
            for k, v in doc.groups.items():
                m.groups.setdefault(k, v)
    return modules, all_symbols


def collect_ll(inc: Path) -> tuple[dict[str, list[HP.RawFunction]], list[HP.RawSymbol]]:
    """解析全部 LL 头文件。

    LL 是多外设混装头文件（ll_bus 同时管 RCC/GPIO/DMA 时钟位），所以
    函数按名分流到外设，而不是按文件。

    同名重复的定义是真实存在的：ST 用 `#if defined(...)` 给同一个函数名写
    两份实现，条件不同、**参数表也不同**（如 LL_USART_SetBaudRate 在
    OVER8=0/1 下分别是 3 参和 4 参，LL_ADC_DMA_GetRegAddr 只在
    ADC_MULTIMODE_SUPPORT 下存在）。数据里只能留一条，所以保留源码顺序里
    的**第一份**，其余记 warning——不合并、不猜哪份才是用户的那份。
    """
    by_periph: dict[str, list[HP.RawFunction]] = {}
    all_symbols: list[HP.RawSymbol] = []
    seen: dict[str, str] = {}
    for h in sorted(inc.glob("stm32f1xx_ll_*.h")):
        mod = h.stem[len("stm32f1xx_ll_") :]
        if mod == "usb":
            # USB 的 LL 层只覆盖 F102/F103 设备模式，且与 C8T6 的常用场景
            # 关系不大，本版不收。
            warn("ll", f"{h.name} 跳过：USB 不在收录范围（{mod}）")
            continue
        # 注意：`sdmmc` **不能跳**。STM32F103C8T6 带 SDIO 外设，
        # `stm32f1xx_ll_sdmmc.h` 就是 SDIO 的 LL 层，里面还定义了
        # `SDIO_InitTypeDef / SDIO_CmdInitTypeDef / SDIO_DataInitTypeDef`
        # ——HAL 的 hal_sd.h 只是 `#define SD_InitTypeDef SDIO_InitTypeDef`
        # 引用它们。早先这里和 usb 一起跳过，导致查 SD 相关函数时
        # 点开 SDIO_InitTypeDef 只能看到一个空壳宏、没有成员表。
        doc = HP.parse_ll_header(h, warn)
        sym_doc = HP.parse_ll_symbols(h)
        all_symbols.extend(sym_doc.symbols)
        for f in doc.functions:
            periph = _ll_peripheral_of(mod, f.name)
            if not periph:
                warn("ll", f"{f.name} 跳过：无法确定外设")
                continue
            if f.name in seen:
                warn(
                    "ll",
                    f"{f.name} 在 {h.name} 里有条件编译的多份定义"
                    f"（保留 {seen[f.name]}，忽略第 {f.header_line} 行这份）",
                )
                continue
            seen[f.name] = h.name
            by_periph.setdefault(periph, []).append(f)
    return by_periph, all_symbols


# ---------------------------------------------------------------------------
# 库 JSON 输出
# ---------------------------------------------------------------------------


def section_id_of(peripheral: str, library: str, index: int) -> str:
    return f"{peripheral}@{library}#sec{index}"


def group_sections(
    funcs: Iterable[dict[str, Any]], key_of: Any
) -> list[LibSection]:
    """按 key 保序分组，返回 LibSection 列表（id 稍后统一分配）。"""
    order: list[str] = []
    buckets: dict[str, list[str]] = {}
    for f in funcs:
        key = key_of(f)
        if key not in buckets:
            buckets[key] = []
            order.append(key)
        buckets[key].append(f["id"])
    out: list[LibSection] = []
    for key in order:
        title_en = key
        out.append(
            LibSection(
                id="",
                title=title_zh(title_en),
                title_en=title_en,
                library="",
                function_ids=buckets[key],
            )
        )
    return out


# ---------------------------------------------------------------------------
# 中文 overlay（契约 §7）
# ---------------------------------------------------------------------------


def load_overlay() -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    """读 data/zh_overlay_hal/。

    返回 (peripheral_patches, {外设: {函数 id: patch}})。
    """
    periph: dict[str, Any] = {}
    funcs: dict[str, dict[str, Any]] = {}
    if not OVERLAY_DIR.is_dir():
        return periph, funcs
    pfile = OVERLAY_DIR / "peripherals.json"
    if pfile.is_file():
        try:
            raw = json.loads(pfile.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                for k, v in raw.items():
                    if k.startswith("_") or not isinstance(v, dict):
                        continue
                    periph[k] = v
        except json.JSONDecodeError as exc:
            warn("overlay", f"{pfile.name} 解析失败：{exc}")
    for f in sorted(OVERLAY_DIR.glob("functions_*.json")):
        lib = "hal"
        m = re.match(r"functions_([A-Za-z]+)_(\w+)\.json", f.name)
        if m:
            lib = m.group(1).lower()
        try:
            raw = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            warn("overlay", f"{f.name} 解析失败：{exc}")
            continue
        if not isinstance(raw, dict):
            continue
        for fid, patch in raw.items():
            if fid.startswith("_") or not isinstance(patch, dict):
                continue
            patch = dict(patch)
            patch["_library"] = lib
            funcs.setdefault(fid, {}).update(patch)
    return periph, funcs


def apply_function_overlay(
    func: dict[str, Any], patch: dict[str, Any]
) -> bool:
    """把 overlay patch 合并进函数条目；返回是否真的改了东西。"""
    if not patch:
        return False
    touched = False
    scalar = ("briefZh", "usageZh", "exampleCode", "returnDescZh", "notesZh")
    for key in ("briefZh", "usageZh", "exampleCode", "returnDescZh"):
        val = patch.get(key)
        if isinstance(val, str) and val.strip():
            func[key] = val.strip()
            touched = True
    for key in ("notesZh", "prerequisites"):
        val = patch.get(key)
        if isinstance(val, list) and val:
            func[key] = [str(x).strip() for x in val if str(x).strip()]
            touched = True
    pzh = patch.get("paramsZh")
    if isinstance(pzh, dict) and pzh:
        for p in func["params"]:
            text = pzh.get(p["name"])
            if isinstance(text, str) and text.strip():
                p["descZh"] = text.strip()
                touched = True
    del scalar
    if touched:
        func["zhSource"] = "overlay"
    return touched


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def dump_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def _spl_symbol_names(out_dir: Path) -> set[str]:
    """读已有 SPL 数据的符号名（symbols.json + registers.json）。

    用来保证 symbols_hal.json 的 id 不与既有数据冲突。文件缺失时返回空集，
    构建照常进行（只是不做去重）。
    """
    names: set[str] = set()
    for fn_name in ("symbols.json", "registers.json"):
        path = out_dir / fn_name
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            warn("symbols", f"{fn_name} 解析失败，跳过去重依据")
            continue
        for s in data.get("symbols") or []:
            nm = s.get("name") or s.get("id")
            if isinstance(nm, str) and nm:
                names.add(nm)
    return names


def build(cube: Path, only: str | None) -> BuildResult:
    inc = cube / "Drivers" / "STM32F1xx_HAL_Driver" / "Inc"
    src = cube / "Drivers" / "STM32F1xx_HAL_Driver" / "Src"
    dev = cube / "Drivers" / "CMSIS" / "Device" / "ST" / "STM32F1xx" / "Include" / "stm32f103xb.h"
    core = cube / "Drivers" / "CMSIS" / "Include" / "core_cm3.h"
    for p, label in ((inc, "HAL Inc"), (src, "HAL Src"), (dev, "CMSIS 器件头")):
        if not p.exists():
            raise SystemExit(f"[build] 找不到 {label}：{p}")

    res = BuildResult()

    # ---- 1. HAL ----
    hal_modules, hal_symbols = collect_hal(inc, src)
    # ---- 2. LL ----
    ll_funcs, ll_symbols = collect_ll(inc)
    # ---- 3. 寄存器 ----
    dev_regs = RP.parse_device_header(dev, warn)
    core_regs = RP.parse_core_header(core, warn) if core.is_file() else RP.RegisterSet()

    hal_symbols_by_periph: dict[str, list[HP.RawSymbol]] = {}
    for s in hal_symbols:
        periph = _symbol_peripheral(s, hal_modules)
        if periph:
            hal_symbols_by_periph.setdefault(periph, []).append(s)
    ll_symbols_by_periph: dict[str, list[HP.RawSymbol]] = {}
    for s in ll_symbols:
        periph = _ll_symbol_peripheral(s, ll_funcs)
        if periph:
            ll_symbols_by_periph.setdefault(periph, []).append(s)

    # ---- 4. HAL 函数 → 契约 §4 ----
    #
    # 「公开函数」的判定只认一条事实：**该函数在对应头文件里声明过**。
    # ST 的 .c 里有大量 static 风格的工具函数（IRDA_WaitOnFlagUntilTimeout、
    # TIM_ITRxExternalClockConfig…），它们没进头文件、用户也调不到，
    # 收进 App 只会误导。这条规则同时天然滤掉了 `HAL_xxx_RegisterCallback`
    # 这种被 #if 包住、本配置下不存在的重载。
    hal_func_objs: dict[str, list[dict[str, Any]]] = {}
    for m in hal_modules:
        if only and m.peripheral != only:
            continue
        skipped_private = 0
        skipped_internal = 0
        for f in m.functions:
            if not f.prototype:
                warn("hal", f"{f.name} 原型为空，跳过")
                continue
            if m.declarations and f.name not in m.declarations:
                skipped_private += 1
                continue
            # 契约 §1：HAL 库收录的是「`HAL_*` 函数」。ST 在头文件里还导出了
            # 一批不带 HAL_ 前缀的**跨模块内部辅助函数**（FLASH_WaitForLastOperation、
            # TIM_Base_SetConfig、ADC_Enable、UART_Start_Receive_IT…），它们是给
            # 其它 HAL 模块用的，不是用户接口；而且其中 FLASH_WaitForLastOperation
            # 与 SPL 同名，会撞全局 id。两者都要求按前缀收紧。
            if not f.name.startswith("HAL_"):
                skipped_internal += 1
                continue
            sec_en = f.group_title_en or m.groups.get(f.group_key, "")
            if not sec_en:
                sec_en = (m.note or "").strip() or "其它函数"
            if m.note and m.note != "扩展":
                sec_en = f"{m.note}｜{sec_en}" if sec_en != "其它函数" else m.note
            params = [
                {"name": p.name, "type": p.type, "descEn": p.desc_en, "descZh": ""}
                for p in f.params
            ]
            decl_line, decl_proto = m.declarations.get(f.name, (0, ""))
            obj = make_function(
                fid=f.name,
                name=f.name,
                peripheral=m.peripheral,
                library="hal",
                section_id="__SECTION__:" + sec_en,
                prototype=decl_proto or f.prototype,
                return_type=f.return_type,
                params=params,
                return_desc_en=f.return_desc_en,
                brief_en=f.brief_en,
                remarks=f.remarks,
                header_line=decl_line or f.header_line,
                source_line=f.source_line,
                defined_in=m.header.name if m.header else m.source.name,
                inline=f.inline,
                deprecated=f.deprecated,
                registers=HP.extract_registers(f),
            )
            obj["_sec_en"] = sec_en
            obj["_raw"] = f
            hal_func_objs.setdefault(m.peripheral, []).append(obj)
        if skipped_private:
            warn(
                "hal",
                f"{m.source.name if m.source else m.module}: "
                f"{skipped_private} 个内部函数（头文件未声明）未收录",
            )
        if skipped_internal:
            warn(
                "hal",
                f"{m.source.name if m.source else m.module}: "
                f"{skipped_internal} 个非 HAL_ 前缀的跨模块辅助函数未收录",
            )

    # 相关函数 / 符号引用（需要全库函数名与符号名，故延后统一算）
    hal_names = {f["id"] for lst in hal_func_objs.values() for f in lst}
    hal_symbol_names = {s.name for s in hal_symbols}
    for periph, funcs in hal_func_objs.items():
        for obj in funcs:
            raw = obj.pop("_raw", None)
            if raw is not None:
                obj["relatedFunctions"] = HP.extract_related(raw, hal_names)
                obj["symbolRefs"] = _symbol_refs_of(raw, hal_symbol_names)
            sec_en = obj.pop("_sec_en", "")
            obj["_sec_en"] = sec_en

    # ---- 5. LL 函数 ----
    ll_func_objs: dict[str, list[dict[str, Any]]] = {}
    ll_names = {f.name for lst in ll_funcs.values() for f in lst}
    ll_symbol_names = {s.name for s in ll_symbols}
    for periph, funcs in ll_funcs.items():
        if only and periph != only:
            continue
        for f in funcs:
            params = [
                {"name": p.name, "type": p.type, "descEn": p.desc_en, "descZh": ""}
                for p in f.params
            ]
            sec_en = f.group_title_en or "LL 函数"
            obj = make_function(
                fid=f.name,
                name=f.name,
                peripheral=periph,
                library="ll",
                section_id="__SECTION__:" + sec_en,
                prototype=f.prototype,
                return_type=f.return_type,
                params=params,
                return_desc_en=f.return_desc_en,
                brief_en=f.brief_en,
                remarks=f.remarks,
                header_line=f.header_line,
                defined_in=f.header_file,
                inline=True,
                deprecated=f.deprecated,
                registers=HP.extract_registers(f),
                related=HP.extract_related(f, ll_names),
                symbol_refs=_symbol_refs_of(f, ll_symbol_names),
            )
            obj["_sec_en"] = sec_en
            ll_func_objs.setdefault(periph, []).append(obj)

    # ---- 6. reg 条目 ----
    reg_objs: dict[str, list[dict[str, Any]]] = {}
    flat_regs = list(dev_regs.registers) + list(core_regs.registers)
    seen_reg_names: set[str] = set()
    for r in sorted(flat_regs, key=lambda x: (x.peripheral, x.name)):
        if only and r.peripheral != only:
            continue
        if r.name in seen_reg_names:
            warn("reg", f"寄存器 {r.name} 重复，跳过后者")
            continue
        seen_reg_names.add(r.name)
        obj = _make_register_entry(r, dev_regs)
        if obj is None:
            continue
        reg_objs.setdefault(r.peripheral, []).append(obj)
    res.registers = [o for lst in reg_objs.values() for o in lst]

    # ---- 7. 符号 ----
    res.symbols = _build_symbols(hal_symbols, ll_symbols, hal_func_objs, ll_func_objs)
    res.symbols = _drop_spl_duplicate_symbols(
        res.symbols, _spl_symbol_names(DATA_DIR)
    )

    # ---- 8. 组装各库的分组与 section id ----
    res.functions["hal"] = hal_func_objs
    res.functions["ll"] = ll_func_objs
    res.functions["reg"] = reg_objs
    res.sections["hal"] = _assign_sections(hal_func_objs, "hal")
    res.sections["ll"] = _assign_sections(ll_func_objs, "ll")
    res.sections["reg"] = _assign_reg_sections(reg_objs)

    res._hal_modules = hal_modules  # type: ignore[attr-defined]
    res._hal_symbols_by_periph = hal_symbols_by_periph  # type: ignore[attr-defined]
    res._ll_symbols_by_periph = ll_symbols_by_periph  # type: ignore[attr-defined]
    res._regs = flat_regs  # type: ignore[attr-defined]
    return res


def _symbol_refs_of(func: HP.RawFunction, names: set[str]) -> list[str]:
    """函数原型 + 注释 + 函数体里出现的库内符号（关键词跳转白名单）。"""
    text = " ".join(
        [func.prototype, func.brief_en, func.return_desc_en]
        + [p.desc_en for p in func.params]
        + func.remarks
        + [func.body]
    )
    found: list[str] = []
    for token in re.findall(r"[A-Za-z_]\w+", text):
        if token in names and token not in found:
            found.append(token)
    return found


def _symbol_peripheral(sym: HP.RawSymbol, modules: list[HalModule]) -> str:
    """HAL 符号归属：用定义了它的头文件反查模块。"""
    for m in modules:
        if m.header is not None and m.header.name == sym.defined_in:
            return m.peripheral
    return ""


def _ll_symbol_peripheral(
    sym: HP.RawSymbol, ll_funcs: dict[str, list[HP.RawFunction]]
) -> str:
    """LL 符号归属：按前缀匹配已解析出的 LL 函数所在外设。"""
    for periph, funcs in ll_funcs.items():
        for f in funcs:
            if sym.name.startswith(f.name.split("_Set")[0].split("_Get")[0][:8]):
                pass
    # 更可靠：按符号名前缀与 LL 函数名前缀的最长公共部分
    best = ""
    best_len = 0
    for periph, funcs in ll_funcs.items():
        for f in funcs:
            parts = f.name.split("_")
            for n in range(len(parts), 1, -1):
                prefix = "_".join(parts[:n])
                if sym.name.startswith(prefix + "_") or sym.name == prefix:
                    if len(prefix) > best_len:
                        best_len = len(prefix)
                        best = periph
                    break
        if best_len >= 6:
            break
    return best


def _make_register_entry(r: RP.Register, dev_regs: RP.RegisterSet) -> dict[str, Any] | None:
    """把一个寄存器变成契约 §4.1 的「函数」条目。"""
    if not r.name:
        return None
    expression = _register_expression(r, dev_regs)
    if not expression:
        warn("reg", f"{r.name} 没有可用的访问表达式，跳过")
        return None
    params: list[dict[str, Any]] = []
    for bf in r.bit_fields:
        params.append(
            {
                "name": bf.name,
                "type": bf.type,
                "descEn": bf.desc_en,
                "descZh": "",
            }
        )
    example = _register_example(r, expression)
    remarks: list[str] = []
    if getattr(r, "pma", False):
        remarks.append(
            "USB 包缓冲区（PMA）表项：地址 = USB_PMAADDR + 由 USB_BTABLE "
            "寄存器给出的表内偏移，不是固定成员访问"
        )
    if r.struct_name:
        remarks.append(
            f"结构体成员 {r.struct_name}.{_member_name_of(r)}，偏移 0x{r.offset:02X}"
        )
    if not r.bit_fields:
        remarks.append("该寄存器在 CMSIS 头里没有位定义宏")
    return {
        "id": f"REG_{r.name}",
        "name": r.name,
        "peripheral": r.peripheral,
        "library": "reg",
        "sectionId": "__REG_SECTION__",
        "prototype": expression,
        "returnType": "uint32_t",
        "params": params,
        "returnDescEn": "Register value" if r.bit_fields else "",
        "returnDescZh": "",
        "briefEn": r.desc_en or _struct_brief_of(r, dev_regs),
        "briefZh": "",
        "usageZh": "",
        "prerequisites": [],
        "registers": [r.name],
        "relatedFunctions": [],
        "remarks": remarks,
        "notesZh": [],
        "exampleCode": example,
        "exampleLanguage": "c",
        # reg 条目的位域宏在 CMSIS 头里定义，契约 §5 的 symbols_hal.json 只收
        # HAL/LL 的宏与类型，两者不是同一个域。这里留空，位域名由 params 承载
        # （App 的寄存器详情页本来就是按 params 渲染位域表）。
        "symbolRefs": [],
        "headerLine": r.bit_fields[0].line if r.bit_fields else 0,
        "definedIn": "core_cm3.h" if r.peripheral == "CORTEX" else "stm32f103xb.h",
        "sourceLine": 0,
        "flags": {
            "deprecated": False,
            "isrSafe": False,
            "inline": False,
            "macroLike": True,
        },
        "ai": None,
        "zhSource": "base",
    }


def _struct_brief_of(r: RP.Register, dev_regs: RP.RegisterSet) -> str:
    sd = dev_regs.structs.get(r.struct_name)
    return sd.brief_en if sd is not None else ""


# 常见外设实例的访问表达式（C 里真实存在的宏，来自 stm32f103xb.h / core_cm3.h）
_INSTANCE_EXPR: dict[str, str] = {
    "GPIO": "GPIOA",
    "RCC": "RCC",
    "USART": "USART1",
    "TIM": "TIM2",
    "SPI": "SPI1",
    "I2C": "I2C1",
    "ADC": "ADC1",
    "DMA": "DMA1_Channel1",
    "FLASH": "FLASH",
    "PWR": "PWR",
    "RTC": "RTC",
    "IWDG": "IWDG",
    "WWDG": "WWDG",
    "CAN": "CAN1",
    "EXTI": "EXTI",
    "CRC": "CRC",
    "DBGMCU": "DBGMCU",
    "BKP": "BKP",
    "AFIO": "AFIO",
    "USB": "USB",
    "OB": "OB",
    "SCB": "SCB",
    "NVIC": "NVIC",
    "SysTick": "SysTick",
    "MPU": "MPU",
    "DWT": "DWT",
    "ITM": "ITM",
    "TPI": "TPI",
    "CoreDebug": "CoreDebug",
    "SCnSCB": "SCnSCB",
}


def _register_expression(r: RP.Register, dev_regs: RP.RegisterSet) -> str:
    """生成 prototype 的直接访问表达式。

    reg_parser 已经按结构体成员算好了表达式（`GPIOA->CRL`、`DMA1_Channel1->CCR`、
    `AFIO->EXTICR[0]`、`NVIC->ISER[n]`）。这里只做兜底：极少数只在位定义分节里
    出现、没有结构体归属的寄存器（CAN 的邮箱寄存器），按实例宏 + 成员名拼。
    """
    if r.expression:
        return r.expression
    base = _INSTANCE_EXPR.get(r.peripheral, "")
    member = _member_name_of(r)
    if not base or not member:
        return ""
    return f"{base}->{member}"


def _member_name_of(r: RP.Register) -> str:
    """寄存器名 → 结构体成员名（去掉前缀，保留数组/通道号前的部分）。"""
    head = r.name.split("_")[0]
    tail = r.name[len(head) + 1 :] if "_" in r.name else r.name
    return tail


def _register_example(r: RP.Register, expression: str) -> str:
    """契约 §4.1 要求「至少 2 行」的直接寄存器读写示例。

    要求：真能编译、真能读写，不编位含义。
    做法是按位域宏现成的东西拼：
        uint32_t v = GPIOA->CRL;        /* 读 */
        v &= ~GPIO_CRL_MODE0_Msk;       /* 清字段 */
        v |= GPIO_CRL_MODE_OUTPUT_PP;   /* 写字段（宏名由位域推导，不存在就不写） */
        GPIOA->CRL = v;                 /* 写回 */
    位域都没有时退化成整字读写两行，同样是有效示例。
    """
    if not expression:
        return ""
    if getattr(r, "pma", False):
        # PMA 表项：读写都得按 BTABLE 算偏移，示例照实写
        return "\n".join(
            [
                "uint32_t btable = USB->BTABLE;  /* 包缓冲表基址（相对 PMA 起始） */",
                f"uint16_t pma_off = (uint16_t)(btable + 0x0000u);  /* {r.name} 的表内偏移 */",
                "uint32_t v = *(volatile uint32_t *)(USB_PMAADDR + pma_off);  /* 读 */",
                "*(volatile uint32_t *)(USB_PMAADDR + pma_off) = v;  /* 写回 */",
            ]
        )
    expr = expression
    if expr.endswith("[n]"):
        expr = expr[:-3] + "[0]"

    field = next(
        (
            bf
            for bf in r.bit_fields
            if bf.aggregate and "bits" in (bf.type or "") or (bf.type or "").startswith("bit ")
        ),
        None,
    )
    if field is None:
        field = next((bf for bf in r.bit_fields if bf.aggregate), None)

    lines = [f"uint32_t v = {expr};  /* 读回当前值 */"]
    if field is not None:
        mask = f"{field.name}_Msk"
        lines.append(f"v &= ~{mask};  /* 先清掉 {field.name}：{field.type} */")
        lines.append(
            f"v |= (1u << {field.name}_Pos) & {mask};  /* 置位，实际取值看参考手册 */"
        )
    else:
        lines.append("v = 0x00000000u;  /* 该寄存器无位域宏，按整字写 */")
    lines.append(f"{expr} = v;  /* 写回 */")
    return "\n".join(lines)


def _assign_sections(
    funcs_by_periph: dict[str, list[dict[str, Any]]], library: str
) -> dict[str, list[LibSection]]:
    """给每个外设的函数分配 section（按英文分组标题合并），并回填 sectionId。"""
    out: dict[str, list[LibSection]] = {}
    for periph, funcs in funcs_by_periph.items():
        order: list[str] = []
        buckets: dict[str, list[dict[str, Any]]] = {}
        titles: dict[str, str] = {}
        for f in funcs:
            raw_key = f["sectionId"].replace("__SECTION__:", "")
            title = f.pop("_sec_en", "") or raw_key
            key = title or "其它函数"
            if key not in buckets:
                buckets[key] = []
                order.append(key)
                titles[key] = title
            buckets[key].append(f)
        sections: list[LibSection] = []
        for idx, key in enumerate(order, start=1):
            sid = section_id_of(periph, library, idx)
            sec = LibSection(
                id=sid,
                title=lib_title(library, title_zh(titles[key] or key)),
                title_en=titles[key] or key,
                library=library,
            )
            for f in buckets[key]:
                f["sectionId"] = sid
                sec.function_ids.append(f["id"])
            sections.append(sec)
        out[periph] = sections
    return out


_REG_DATA_RE = re.compile(
    r"(^|_)(DR|DATA|DHR|DOR|RDR|TDR|IDR|ODR|CNT|CNTR|CCR|CNDTR|CPAR|CMAR)(_|\d|$)"
    r"|_DR\d*$|_DHR\d+[A-Z]*$|_BTABLE$|_EP\d+R$"
)
_REG_STATUS_RE = re.compile(r"(^|_)(SR|CSR|ISR|IFCR|FLAG|PR|ISTR|ESR|MSR|TSR|RF\dR|IER|IMR|EMR|DIER|SR\d?)($|_)")


def _reg_section_of(name: str) -> tuple[int, str, str]:
    """契约 §4.1：`#sec1` 控制/状态、`#sec2` 数据、`#sec3` 其它。

    标题写成用户能分辨的寄存器类别（`控制寄存器` / `数据寄存器` /
    `状态寄存器` / `配置寄存器`），而不是笼统的「其它」。
    """
    if _REG_DATA_RE.search(name):
        return 2, "数据寄存器", "Data registers"
    if _REG_STATUS_RE.search(name):
        if re.search(r"(^|_)(SR|CSR|ISR|IFCR|ISTR)($|_)", name):
            return 1, "状态寄存器", "Status registers"
        return 1, "中断与标志寄存器", "Interrupt and flag registers"
    return 3, "配置与控制寄存器", "Configuration and control registers"


def _assign_reg_sections(
    reg_by_periph: dict[str, list[dict[str, Any]]]
) -> dict[str, list[LibSection]]:
    """给寄存器分节，**编号连续**从 `#sec1` 起。

    契约 §4.1 只规定语义分组（`#sec1` 控制/状态、`#sec2` 数据、`#sec3` 其它），
    但某个外设可能压根没有控制类寄存器（例如 GPIO 只有 CRL/CRH/IDR/ODR 与
    AFIO），照语义固定编号就会出现 `#sec2`、`#sec3` 而 `#sec1` 缺失的跳号，
    看着像漏数据。所以这里按**实际存在的分组**重新连续编号，
    保持语义分组的相对顺序（控制/状态 → 数据 → 其它）。
    """
    out: dict[str, list[LibSection]] = {}
    for periph, entries in reg_by_periph.items():
        buckets: dict[int, LibSection] = {}
        for e in entries:
            kind, zh, en = _reg_section_of(e["name"])
            sec = buckets.get(kind)
            if sec is None:
                sec = LibSection(id="", title=zh, title_en=en, library="reg")
                buckets[kind] = sec
            sec.function_ids.append(e["id"])
        ordered = [buckets[k] for k in sorted(buckets)]
        for seq, sec in enumerate(ordered, start=1):
            sec.id = section_id_of(periph, "reg", seq)
            for fid in sec.function_ids:
                for e in entries:
                    if e["id"] == fid:
                        e["sectionId"] = sec.id
                        break
        out[periph] = ordered
    return out


def _drop_spl_duplicate_symbols(
    symbols: list[dict[str, Any]], spl_names: set[str]
) -> list[dict[str, Any]]:
    """处理与 SPL 同名的 HAL/LL 符号。

    这里要区分两类重名，它们的最优处理方式完全相反：

    **一类：结构体 / 枚举类型（`*TypeDef`）——必须保留 HAL 版**
        `GPIO_InitTypeDef` 在两个库里**成员布局完全不同**：
            SPL:  GPIO_Pin / GPIO_Speed / GPIO_Mode
            HAL:  Pin / Mode / Pull / Speed
        查 HAL 函数时点开 `GPIO_InitTypeDef`，看到 SPL 那份是**错的**，
        会直接把人带沟里（照着 SPL 的字段名写 HAL 代码编译不过）。
        所以这类保留 HAL 定义，并把 id 改成 `库限定 id`（`GPIO_InitTypeDef@hal`），
        保证与 SPL 的 `GPIO_InitTypeDef` 在全局索引里不冲突；
        `name` 仍是原名（界面上仍显示 `GPIO_InitTypeDef`，与源码一致）。

    **二类：宏（取值不同但语义相近，如 `ADC_IT_EOC`）——保留 SPL 版**
        SPL: ((uint16_t)0x0220)     HAL: ADC_CR1_EOCIE
        这类有 300 多个，用户搜到哪个都能用（都是该寄存器的中断使能位），
        没必要让同名宏在结果里出现两次、把人绕晕。SPL 是既有数据也不动。

    返回：保留的符号列表。类型类的 id 已被改写成 `<name>@<lib>`。
    """
    kept: list[dict[str, Any]] = []
    rewritten: list[str] = []
    dropped: list[str] = []

    for s in symbols:
        name = s["name"]
        if name not in spl_names:
            kept.append(s)
            continue

        # 与 SPL 重名。类型定义保留本方（HAL/LL）这份，宏让给 SPL。
        if s.get("kind") in ("struct", "typedef", "enum_type"):
            lib = s.get("library") or "hal"
            new_id = f"{name}@{lib}"
            s = dict(s)
            s["id"] = new_id
            kept.append(s)
            rewritten.append(new_id)
        else:
            dropped.append(name)

    if rewritten:
        warn(
            "symbols",
            f"{len(rewritten)} 个 HAL/LL 类型与 SPL 同名但定义不同，"
            f"已用库限定 id 保留本方那份（如 {rewritten[0]}）："
            f"{', '.join(sorted(rewritten)[:6])} …",
        )
    if dropped:
        warn(
            "symbols",
            f"{len(dropped)} 个 HAL/LL 宏与 SPL 同名（取值不同），"
            f"保留 SPL 那份：{', '.join(sorted(dropped)[:8])} …",
        )
    return kept


def _build_symbols(
    hal_symbols: list[HP.RawSymbol],
    ll_symbols: list[HP.RawSymbol],
    hal_funcs: dict[str, list[dict[str, Any]]],
    ll_funcs: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    """生成 symbols_hal.json 的符号表（按契约 §5 字段顺序）。"""
    periph_of_file: dict[str, str] = {}
    for periph, funcs in hal_funcs.items():
        for f in funcs:
            periph_of_file.setdefault(f["definedIn"], periph)
    for periph, funcs in ll_funcs.items():
        for f in funcs:
            periph_of_file.setdefault(f["definedIn"], periph)

    used_by: dict[str, list[str]] = {}
    for lib_funcs in (hal_funcs, ll_funcs):
        for funcs in lib_funcs.values():
            for f in funcs:
                for ref in f["symbolRefs"]:
                    used_by.setdefault(ref, []).append(f["id"])

    out: list[dict[str, Any]] = []
    # 去重键用 (名字, 库)，而不是只用名字。
    #
    # 只用名字会误伤一种情况：`SDIO_InitTypeDef` 在 HAL 侧只是
    #     #define SDIO_InitTypeDef  SDIO_InitTypeDef  ← 实为宏别名
    # 而 LL 侧（stm32f1xx_ll_sdmmc.h）才是真正的结构体定义。
    # 按名字去重时，先遍历到的 HAL 宏会把这个名字占掉，LL 的结构体
    # 就永远进不来——查 SD 相关函数时点 `SDIO_InitTypeDef` 只能看到值、
    # 看不到成员，白丢一份真正的类型定义。
    # 同库内的同名重复仍然要去重（ST 有 #if 分支重复定义同一名字的情况）。
    seen: set[tuple[str, str]] = set()
    # 结构体/枚举/typedef 优先于同名的宏：类型定义的信息量更大，
    # 保住它比保住一个别名宏更有用。
    ordered_symbols = sorted(
        hal_symbols + ll_symbols,
        key=lambda s: 0 if s.kind in ("struct", "typedef", "enum_type") else 1,
    )
    for sym in ordered_symbols:
        key = (sym.name, sym.library)
        if key in seen:
            continue
        # 同一名字在**不同库**里出现是允许的（GPIO_InitTypeDef 在 SPL/HAL
        # 各有定义）；同库重复才丢。
        if any(k[0] == sym.name and k[1] == sym.library for k in seen):
            continue
        seen.add(key)
        periph = periph_of_file.get(sym.defined_in, "")
        if not periph:
            periph = _periph_of_header_file(sym.defined_in)
        if not periph:
            periph = _periph_of_symbol_name(sym.name)
        if not periph:
            warn("symbols", f"{sym.name}（{sym.defined_in}）归不到外设，标记为 MISC")
            periph = "MISC"
        out.append(
            {
                "id": sym.name,
                "name": sym.name,
                "kind": sym.kind,
                "library": sym.library,
                "peripheral": periph,
                "value": sym.value,
                "valueKind": _value_kind(sym.value),
                "members": [
                    {
                        "name": m.name,
                        "type": m.type or None,
                        "value": m.value,
                        "descEn": m.desc_en,
                        "descZh": "",
                        "line": m.line,
                    }
                    for m in sym.members
                ],
                "briefEn": sym.brief_en,
                "briefZh": "",
                "usageZh": "",
                "definedIn": sym.defined_in,
                "definedLine": sym.defined_line,
                "visibility": sym.visibility,
                "functionLike": sym.function_like,
                "params": sym.params,
                "usedBy": sorted(set(used_by.get(sym.name, []))),
                "relatedSymbols": [],
                "notesZh": [],
                "ai": None,
                "zhSource": "base",
                "registerName": None,
            }
        )
    return out


def _periph_of_header_file(header: str) -> str:
    """头文件名 → 外设 id。

    按 ST 的命名规律：`stm32f1xx_{hal,ll}_<模块>[_ex].h`，
    模块名走 HAL_MODULE_MAP / LL_MODULE_MAP。这是符号归属的最后一道
    兜底（首选是按定义文件里已解析出的函数反查）。
    """
    if not header:
        return ""
    m = re.match(r"^stm32f1xx_(hal|ll)_(\w+?)(?:_ex)?\.h$", header)
    if not m:
        return ""
    lib, mod = m.group(1), m.group(2)
    # `adc` 对应的文件也可能叫 adc_ex.h，去掉 _ex 后仍按 adc 查
    if lib == "hal":
        periph, _note = HAL_MODULE_MAP.get(mod, ("", ""))
        return periph
    periph = LL_MODULE_MAP.get(mod, "")
    return periph


def _periph_of_symbol_name(name: str) -> str:
    """没在函数文件里出现的符号，按名字前缀猜外设（仅用于分组展示）。"""
    for prefix, periph in (
        ("LL_ADC", "ADC"),
        ("LL_GPIO", "GPIO"),
        ("LL_TIM", "TIM"),
        ("LL_USART", "USART"),
        ("LL_SPI", "SPI"),
        ("LL_I2C", "I2C"),
        ("LL_DMA", "DMA"),
        ("LL_RCC", "RCC"),
        ("LL_EXTI", "EXTI"),
        ("LL_PWR", "PWR"),
        ("LL_RTC", "RTC"),
        ("LL_IWDG", "IWDG"),
        ("LL_WWDG", "WWDG"),
        ("LL_CRC", "CRC"),
        ("LL_DAC", "DAC"),
        ("LL_DBGMCU", "DBGMCU"),
        ("LL_SYSTICK", "CORTEX"),
        ("LL_", "CORTEX"),
        ("HAL_", "MISC"),
    ):
        if name.startswith(prefix):
            return periph
    return ""


# ---------------------------------------------------------------------------
# peripherals.json / manifest.json 扩展
# ---------------------------------------------------------------------------

PERIPHERAL_HEADER_SOURCE = {
    "hal": ("stm32f1xx_hal_{}.h", "stm32f1xx_hal_{}.c"),
    "ll": ("stm32f1xx_ll_{}.h", "stm32f1xx_ll_{}.c"),
    "reg": ("stm32f103xb.h", ""),
}

# 外设 id → (HAL 模块文件名主干, LL 模块文件名主干)
PERIPHERAL_MODULE = {
    "GPIO": ("gpio", "gpio"),
    "RCC": ("rcc", "rcc"),
    "USART": ("usart", "usart"),
    "TIM": ("tim", "tim"),
    "SPI": ("spi", "spi"),
    "I2C": ("i2c", "i2c"),
    "ADC": ("adc", "adc"),
    "DMA": ("dma", "dma"),
    "FLASH": ("flash", "system"),
    "PWR": ("pwr", "pwr"),
    "RTC": ("rtc", "rtc"),
    "IWDG": ("iwdg", "iwdg"),
    "WWDG": ("wwdg", "wwdg"),
    "CAN": ("can", ""),
    "EXTI": ("exti", "exti"),
    "CRC": ("crc", "crc"),
    "DAC": ("dac", "dac"),
    "CORTEX": ("cortex", "cortex"),
    "DBGMCU": ("", "system"),
    "MISC": ("", "utils"),
    "USB": ("", ""),
    "FSMC": ("", "fsmc"),
    "SDIO": ("", ""),
    "CEC": ("cec", ""),
    "BKP": ("", ""),
    "AFIO": ("", ""),
    "CMSIS": ("", ""),
}


def section_library(sid: str) -> str:
    """从 section id 的 `@<库>#` 段推导所属库（契约 §3 的唯一口径）。

    硬性要求：**不要**用默认值 `spl` 兜底。契约规定新库的 id 必须是
    `<外设>@<库>#<序号>`；只有 v1 遗留的 `GPIO#sec1` 没有 `@` 段，
    那种才是 spl。
    """
    m = re.search(r"@(\w+)#", sid or "")
    if m and m.group(1) in LIB_ORDER:
        return m.group(1)
    return "spl"


def _normalize_sections(raw_sections: Any) -> list[dict[str, Any]]:
    """把已有 sections 归一成 v2 形状，且**只保留 spl 的**（其余由本次重建）。

    这一步同时解决「重复运行不幂等」的问题：上一次跑出来的
    `GPIO@hal#sec1` 会被丢掉再重新生成，不会越跑越多。SPL 独有的旧 id
    （`GPIO#sec1`）原样保留，只补 `library` 字段。
    """
    out: list[dict[str, Any]] = []
    for s in raw_sections or []:
        if not isinstance(s, dict):
            continue
        sid = str(s.get("id", ""))
        if section_library(sid) != "spl":
            continue  # 新库的 section 每次重建
        # v1 的 `GPIO#sec1` → v2 的 `GPIO@spl#sec1`（只补 @<库> 段，序号不动）。
        # 已经是 `GPIO@spl#sec1` 的原样保留 —— 这段必须**幂等**，
        # 否则第二次运行会拼成 `GPIO@spl@spl#sec1`。
        m = re.match(r"^(.+?)(?:@spl)?#(sec\d+)$", sid)
        if m:
            sid = f"{m.group(1)}@spl#{m.group(2)}"
        sec = {
            "id": sid,
            "title": s.get("title", ""),
            "titleEn": s.get("titleEn", ""),
            "functionIds": [str(x) for x in (s.get("functionIds") or [])],
            "library": "spl",
        }
        out.append(sec)
    return out


def extend_peripherals(
    existing: dict[str, Any],
    res: BuildResult,
    overlay_periph: dict[str, Any],
) -> dict[str, Any]:
    """把 v1 peripherals.json 扩成 v2。

    SPL 部分**逐字节保留**（id / 标题 / functionIds 顺序都不动），只补一个
    `library: "spl"` 字段与 `libraries.spl` 元信息块；HAL/LL/reg 的分组
    每次全量重算，因此本函数对同一输入是幂等的（重复跑不会重复追加）。
    """
    raw_peripherals = existing.get("peripherals") or []
    by_id: dict[str, dict[str, Any]] = {}
    for p in raw_peripherals:
        pid = p.get("id")
        if isinstance(pid, str) and pid:
            by_id[pid] = p

    hal_funcs = res.functions.get("hal", {})
    ll_funcs = res.functions.get("ll", {})
    reg_funcs = res.functions.get("reg", {})
    hal_syms: dict[str, list[Any]] = res._hal_symbols_by_periph  # type: ignore[attr-defined]
    ll_syms: dict[str, list[Any]] = res._ll_symbols_by_periph  # type: ignore[attr-defined]

    # 只为「旧数据里没有、但确实抽到了内容」的外设补条目。
    # CORTEX 这种旧数据里已有的（SPL 侧有 314 个符号）不会重复补。
    for pid in sorted((set(hal_funcs) | set(ll_funcs) | set(reg_funcs)) - set(by_id)):
        warn("peripherals", f"{pid} 旧数据里没有条目，已补建（无 SPL 内容）")
        by_id[pid] = {
            "id": pid,
            "name": pid,
            "nameZh": PERIPHERAL_NAMES_ZH.get(pid, pid),
            "header": "",
            "source": "",
            "file": "",
            "orderIndex": PERIPHERAL_ORDER_FALLBACK.get(pid, 900),
            "introZh": "",
            "usageOverviewZh": "",
            "functionCount": 0,
            "symbolCount": 0,
            "tags": [],
            "sections": [],
        }

    out_peripherals: list[dict[str, Any]] = []
    for pid, raw in by_id.items():
        p = dict(raw)  # 顶层键顺序保持原样
        libs: dict[str, Any] = {}

        # ---- spl：完全沿用旧字段 ----
        if raw.get("file"):
            libs["spl"] = {
                "header": raw.get("header", ""),
                "source": raw.get("source", ""),
                "file": raw.get("file", ""),
                "functionCount": raw.get("functionCount", 0),
                "symbolCount": raw.get("symbolCount", 0),
                "introZh": raw.get("introZh", ""),
                "usageOverviewZh": raw.get("usageOverviewZh", ""),
                "usageSteps": [],
                "noteZh": "",
            }

        # ---- hal / ll / reg ----
        for lib, funcs in (("hal", hal_funcs), ("ll", ll_funcs), ("reg", reg_funcs)):
            lst = funcs.get(pid) or []
            if not lst:
                continue
            hdr_name, src_name = _module_files_of(pid, lib)
            if lib == "hal":
                sym_count = len(hal_syms.get(pid, []))
            elif lib == "ll":
                sym_count = len(ll_syms.get(pid, []))
            else:
                sym_count = len(lst)
            libs[lib] = {
                "header": hdr_name,
                "source": src_name,
                "file": f"functions/{lib}/{pid}.json",
                "functionCount": len(lst),
                "symbolCount": sym_count,
                "introZh": "",
                "usageOverviewZh": "",
                "usageSteps": [],
                "noteZh": "",
            }

        # overlay 的中文（顶层默认补到 hal，也可写 ll/reg 子键分别覆盖）
        patch = overlay_periph.get(pid) or {}
        default_lib = next(
            (lib for lib in ("hal", "ll", "reg") if lib in libs), ""
        )
        if default_lib and patch:
            _apply_lib_patch(libs[default_lib], patch)
        for lib in ("hal", "ll", "reg"):
            sub = patch.get(lib)
            if lib in libs and isinstance(sub, dict):
                _apply_lib_patch(libs[lib], sub)

        p["libraries"] = libs

        # 顶层字段取「主库」值（有 spl 就 spl，否则 ordered 里第一个）
        primary = "spl" if "spl" in libs else next(
            (lib for lib in LIB_ORDER if lib in libs), ""
        )
        if primary and primary != "spl":
            info = libs[primary]
            for key in ("header", "source", "file", "introZh", "usageOverviewZh"):
                if not p.get(key):
                    p[key] = info.get(key, "")
            for key in ("functionCount", "symbolCount"):
                if not p.get(key):
                    p[key] = info.get(key, 0)

        # ---- sections：旧 SPL 原样 + 新库全量重建 ----
        secs = _normalize_sections(raw.get("sections"))
        for lib in ("hal", "ll", "reg"):
            for sec in res.sections.get(lib, {}).get(pid, []):
                secs.append(
                    {
                        "id": sec.id,
                        "title": sec.title,
                        "titleEn": sec.title_en,
                        "functionIds": list(sec.function_ids),
                        "library": lib,
                    }
                )
        p["sections"] = secs
        out_peripherals.append(p)

    # 保持首页排序：orderIndex 升序，未定义者排后面
    out_peripherals.sort(
        key=lambda x: (x.get("orderIndex") or 1000, str(x.get("id", "")))
    )
    return {"schemaVersion": SCHEMA_VERSION, "peripherals": out_peripherals}


def _apply_lib_patch(info: dict[str, Any], patch: dict[str, Any]) -> None:
    for key in ("introZh", "usageOverviewZh", "noteZh", "header", "source"):
        val = patch.get(key)
        if isinstance(val, str) and val.strip():
            info[key] = val.strip()
    steps = patch.get("usageSteps")
    if isinstance(steps, list) and steps:
        info["usageSteps"] = [str(s).strip() for s in steps if str(s).strip()]


def _module_files_of(pid: str, lib: str) -> tuple[str, str]:
    mod = PERIPHERAL_MODULE.get(pid, ("", ""))
    if lib == "hal":
        stem = mod[0]
        if stem:
            return f"stm32f1xx_hal_{stem}.h", f"stm32f1xx_hal_{stem}.c"
        return "", ""
    if lib == "ll":
        stem = mod[1]
        if stem:
            return f"stm32f1xx_ll_{stem}.h", f"src/stm32f1xx_ll_{stem}.c"
        return "", ""
    return "stm32f103xb.h", ""


PERIPHERAL_NAMES_ZH = {
    "AFIO": "复用功能 IO",
    "USB": "通用串行总线",
}
PERIPHERAL_ORDER_FALLBACK = {"AFIO": 20, "USB": 21}


def build_manifest(
    existing: dict[str, Any],
    res: BuildResult,
    periphs: dict[str, Any],
    generated_at: str,
) -> dict[str, Any]:
    """生成 v2 manifest。

    统计口径（**按最终落盘的 peripherals.json 数**，不从旧 manifest 抄）：
      * libraryFunctionCounts.spl = 各外设 libraries.spl.functionCount 之和
        —— 也就是旧数据里登记的 SPL 函数总数（488）。之前只数了新三库，
        导致 spl 恒为 0，是这里漏掉的。
      * hal/ll/reg = 实际写进 functions/<lib>/ 的条数
      * symbolCount = 各库符号之和；spl 取旧数据 apiSymbolCount +
        registerSymbolCount（SPL 的符号拆在两个文件里，合计才是全量）
    """
    lib_func = {"spl": 0, "hal": 0, "ll": 0, "reg": 0}
    for p in periphs.get("peripherals") or []:
        for lib, info in (p.get("libraries") or {}).items():
            if lib in lib_func and isinstance(info, dict):
                lib_func[lib] += int(info.get("functionCount") or 0)
    # 以实际生成的函数条目为准（reg 的 functionCount == 条目数，
    # hal/ll 与函数文件条数一致；若不一致下面的自检会报出来）
    for lib in ("hal", "ll", "reg"):
        actual = sum(len(v) for v in res.functions.get(lib, {}).values())
        if actual != lib_func[lib]:
            warn(
                "manifest",
                f"{lib} 的 functionCount 合计 {lib_func[lib]} 与实际条目 {actual} 不符，"
                f"以实际条目为准",
            )
            lib_func[lib] = actual

    old_stats = dict(existing.get("stats") or {})
    spl_sym = int(old_stats.get("apiSymbolCount") or 0) + int(
        old_stats.get("registerSymbolCount") or 0
    )
    if spl_sym == 0:
        spl_sym = int(old_stats.get("symbolCount") or 0)
    lib_sym = {
        "spl": spl_sym,
        "hal": len([s for s in res.symbols if s.get("library") == "hal"]),
        "ll": len([s for s in res.symbols if s.get("library") == "ll"]),
        "reg": lib_func["reg"],
    }

    stats = old_stats
    stats["peripheralCount"] = len(periphs.get("peripherals") or [])
    stats["functionCount"] = sum(lib_func.values())
    stats["symbolCount"] = sum(lib_sym.values())
    stats["libraryFunctionCounts"] = lib_func
    stats["librarySymbolCounts"] = lib_sym

    files = dict(existing.get("files") or {})
    files["symbolsHal"] = "symbols_hal.json"

    return {
        "schemaVersion": SCHEMA_VERSION,
        "dataVersion": DATA_VERSION,
        "splVersion": existing.get("splVersion", "STM32F10x_StdPeriph_Lib_V3.5.0"),
        "halVersion": HAL_VERSION,
        "defaultChipId": existing.get("defaultChipId", "stm32f103c8t6"),
        "generatedAt": generated_at,
        "generator": "tools/build_multi_lib.py",
        "stats": stats,
        "files": files,
        "functionDirs": {
            "spl": "functions/",
            "hal": "functions/hal/",
            "ll": "functions/ll/",
            "reg": "functions/reg/",
        },
    }


# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------


def _migrate_spl_section_ids(out_dir: Path) -> None:
    """把 SPL 函数文件里的 `GPIO#sec1` 就地改成 `GPIO@spl#sec1`。

    只改 sectionId 一个字段，其余字段（含键顺序）原样保留。
    已经是 `@spl` 形式的跳过，所以重复运行是幂等的。
    """
    fn_dir = out_dir / "functions"
    if not fn_dir.is_dir():
        return
    changed = 0
    for f in sorted(fn_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            warn("migrate", f"{f.name} 解析失败，跳过：{exc}")
            continue
        funcs = data.get("functions")
        if not isinstance(funcs, list):
            continue
        touched = False
        for fn in funcs:
            sid = fn.get("sectionId")
            if not isinstance(sid, str) or "@" in sid:
                continue
            m = re.match(r"^(.+?)(?:@spl)?#(sec\d+)$", sid)
            if m:
                new_sid = f"{m.group(1)}@spl#{m.group(2)}"
                if new_sid != sid:
                    fn["sectionId"] = new_sid
                    touched = True
        if touched:
            dump_json(f, data)
            changed += 1
    if changed:
        print(f"[build] SPL sectionId 迁移：{changed} 个函数文件", file=sys.stderr)


def self_check(res: BuildResult, periphs: dict[str, Any], out_dir: Path) -> int:
    """契约硬性检查；返回错误条数。"""
    errors: list[str] = []

    # 1. 函数 id 全局唯一
    seen: dict[str, str] = {}
    for lib, by_periph in res.functions.items():
        for pid, funcs in by_periph.items():
            for f in funcs:
                fid = f["id"]
                if fid in seen:
                    errors.append(f"函数 id 重复：{fid}（{seen[fid]} 与 {lib}/{pid}）")
                else:
                    seen[fid] = f"{lib}/{pid}"

    # 2. sectionId 都能查到 / 函数都挂上了 section
    periph_by_id = {p["id"]: p for p in periphs["peripherals"]}
    for lib, by_periph in res.functions.items():
        for pid, funcs in by_periph.items():
            p = periph_by_id.get(pid)
            if p is None:
                errors.append(f"{lib}/{pid} 没有对应的外设条目")
                continue
            sec_ids = {
                s["id"] for s in p.get("sections", []) if s.get("library") == lib
            }
            for f in funcs:
                if f["sectionId"] not in sec_ids:
                    errors.append(
                        f"{lib}/{pid} 的 {f['id']} 指向不存在的 section {f['sectionId']}"
                    )
            listed = {
                fid
                for s in p.get("sections", [])
                if s.get("library") == lib
                for fid in s["functionIds"]
            }
            missing = {f["id"] for f in funcs} - listed
            if missing:
                errors.append(f"{lib}/{pid} 有 {len(missing)} 个函数没进任何 section")

    # 3. library 字段与目录一致 / reg 的 id 前缀
    for lib, by_periph in res.functions.items():
        for pid, funcs in by_periph.items():
            for f in funcs:
                if f["library"] != lib:
                    errors.append(f"{f['id']} 的 library={f['library']}，应在 {lib}")
                if lib == "reg" and not f["id"].startswith("REG_"):
                    errors.append(f"reg 条目 id 缺 REG_ 前缀：{f['id']}")
                if lib == "reg" and len(f.get("exampleCode", "").split("\n")) < 2:
                    errors.append(f"reg 条目 {f['id']} 的示例不足 2 行")

    # 4. section title 必须是中文（白名单专有名词除外）
    #
    # 必须按**完整标识词**匹配，不能用 `[A-Za-z]{4,}`：
    # 前者会把 `PLLI2S` 截成 `PLLI`、把 `IrDA` 大小写拆开，造成假阳性。
    allowed = {w.upper() for w in TITLE_ALLOWED_EN}
    for p in periphs["peripherals"]:
        for s in p.get("sections") or []:
            title = str(s.get("title") or "")
            for token in re.findall(r"[A-Za-z][A-Za-z0-9]{3,}", title):
                if token.upper() in allowed:
                    continue
                errors.append(
                    f"{p['id']} 的 {s['id']} 标题里有未翻译的英文：{token!r}（{title}）"
                )

    # 5. reg 的 section 编号必须从 #sec1 连续
    for p in periphs["peripherals"]:
        reg_idxs = sorted(
            int(m.group(1))
            for s in (p.get("sections") or [])
            if s.get("library") == "reg"
            for m in [re.search(r"#sec(\d+)$", str(s.get("id", "")))]
            if m
        )
        if reg_idxs and reg_idxs != list(range(1, len(reg_idxs) + 1)):
            errors.append(f"{p['id']} 的 reg 分节编号不连续：{reg_idxs}")

    # 6. 落盘文件能被 json.load 读回
    for lib in ("hal", "ll", "reg"):
        for pid in res.functions.get(lib, {}):
            path = out_dir / "functions" / lib / f"{pid}.json"
            if not path.is_file():
                errors.append(f"缺文件 {path}")
                continue
            try:
                json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                errors.append(f"{path} 不是合法 JSON：{exc}")

    for e in errors[:40]:
        print(f"  X {e}", file=sys.stderr)
    if len(errors) > 40:
        print(f"  ... 其余 {len(errors) - 40} 条略", file=sys.stderr)
    return len(errors)


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="构建 HAL/LL/寄存器 多库数据")
    ap.add_argument("--cube-root", default=str(DEFAULT_CUBE), help="STM32CubeF1 根目录")
    ap.add_argument("--data", default=str(DATA_DIR), help="assets/data 目录")
    ap.add_argument("--only", default=None, help="只重建某个外设（如 GPIO）")
    ap.add_argument("--dry-run", action="store_true", help="只解析，不写盘")
    ap.add_argument(
        "--generated-at",
        default=None,
        help="manifest 的 generatedAt（默认当前时间，便于 diff 时可固定）",
    )
    args = ap.parse_args(argv)

    cube = Path(args.cube_root)
    out_dir = Path(args.data)
    generated_at = args.generated_at or _dt.datetime.now().astimezone().replace(
        microsecond=0
    ).isoformat()

    periph_path = out_dir / "peripherals.json"
    manifest_path = out_dir / "manifest.json"
    if not periph_path.is_file() or not manifest_path.is_file():
        raise SystemExit(f"[build] 缺少已有的 {periph_path} 或 {manifest_path}")
    existing_periphs = load_json(periph_path)
    existing_manifest = load_json(manifest_path)

    print("[build] 解析 HAL/LL/CMSIS …", file=sys.stderr)
    res = build(cube, args.only)
    overlay_periph, overlay_funcs = load_overlay()
    print(f"[build] 中文 overlay：{len(overlay_periph)} 个外设、{len(overlay_funcs)} 个函数", file=sys.stderr)

    # 应用函数 overlay
    touched = 0
    for lib in ("hal", "ll", "reg"):
        for funcs in res.functions.get(lib, {}).values():
            for f in funcs:
                patch = overlay_funcs.get(f["id"])
                if patch and patch.get("_library", lib) == lib:
                    if apply_function_overlay(f, patch):
                        touched += 1
    print(f"[build] overlay 命中函数 {touched} 个", file=sys.stderr)

    periphs = extend_peripherals(existing_periphs, res, overlay_periph)
    manifest = build_manifest(existing_manifest, res, periphs, generated_at)

    if args.dry_run:
        print("[build] dry-run：不写盘", file=sys.stderr)
        _print_stats(res, periphs, manifest)
        return 0

    # ---- SPL 函数文件里的 sectionId 迁到 @spl 形式 ----
    #
    # 契约要求 section id 统一为 <外设>@<库>#<序号>。SPL 是既有数据，函数体
    # 内容一个字节都不动，只把 sectionId 从 `GPIO#sec1` 改成 `GPIO@spl#sec1`，
    # 与 peripherals.json 里的分组 id 对齐（否则详情页按 sectionId 反查会落空）。
    if not args.only:
        _migrate_spl_section_ids(out_dir)

    # 写盘
    for lib in ("hal", "ll", "reg"):
        for pid, funcs in res.functions.get(lib, {}).items():
            dump_json(
                out_dir / "functions" / lib / f"{pid}.json",
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "peripheral": pid,
                    "library": lib,
                    "functions": funcs,
                },
            )
    dump_json(out_dir / "symbols_hal.json", {"schemaVersion": SCHEMA_VERSION, "symbols": res.symbols})
    dump_json(periph_path, periphs)
    dump_json(manifest_path, manifest)

    errs = self_check(res, periphs, out_dir)
    W.dump()
    _print_stats(res, periphs, manifest)
    if errs:
        print(f"\n[build] 自检发现 {errs} 条错误", file=sys.stderr)
        return 1
    print("\n[build] 自检通过。", file=sys.stderr)
    return 0


def _print_stats(res: BuildResult, periphs: dict[str, Any], manifest: dict[str, Any]) -> None:
    print("\n=== 统计 ===")
    for lib in LIB_ORDER:
        funcs = sum(len(v) for v in res.functions.get(lib, {}).values()) if lib != "spl" else manifest["stats"]["libraryFunctionCounts"]["spl"]
        periph_count = (
            len(res.functions.get(lib, {})) if lib != "spl" else len([p for p in periphs["peripherals"] if "spl" in (p.get("libraries") or {})])
        )
        syms = manifest["stats"]["librarySymbolCounts"].get(lib, 0)
        print(f"  {lib:4s} {LIB_ZH[lib]}: {periph_count:3d} 个外设, {funcs:5d} 个函数, {syms:5d} 个符号")
    print(f"  寄存器条目: {len(res.registers)} 个")
    print(f"  HAL/LL 符号: {len(res.symbols)} 个")
    print(f"  外设条目: {len(periphs['peripherals'])} 个")
    print(f"  manifest functionCount={manifest['stats']['functionCount']} symbolCount={manifest['stats']['symbolCount']}")


if __name__ == "__main__":
    raise SystemExit(main())

# 数据结构契约 v2（多库支持）

> 本文件是 Lead 与各执行者之间的**唯一接口契约**。任何实现都不得自行改动字段名。
> 权威 HAL/LL/CMSIS 源码位于：
> - HAL/LL: `C:\Users\XT\STM32Cube\Repository\STM32Cube_FW_F1_V1.8.7\Drivers\STM32F1xx_HAL_Driver\Inc`
> - CMSIS:  `C:\Users\XT\STM32Cube\Repository\STM32Cube_FW_F1_V1.8.7\Drivers\CMSIS\Device\ST\STM32F1xx\Include\stm32f103xb.h`

## 1. 库标识（library）

| id | 中文名 | 英文名 | 说明 |
|---|---|---|---|
| `spl` | 标准库 | SPL | STM32F10x_StdPeriph_Lib V3.5.0（已有数据） |
| `hal` | HAL 库 | HAL | STM32CubeF1 V1.8.7 `stm32f1xx_hal_*.h` 的 `HAL_*` 函数 |
| `ll`  | LL 库 | LL | 同包 `stm32f1xx_ll_*.h` 的 `LL_*` / `__STATIC_INLINE` 函数 |
| `reg` | 寄存器直驱 | REG | CMSIS 寄存器结构体 + 位定义宏，`GPIOA->ODR = ...` 这种写法 |

顺序固定为 `spl, hal, ll, reg`。

## 2. assets 目录结构

```
assets/data/
  manifest.json                         # schemaVersion = 2
  peripherals.json                      # 扩展见 §3
  symbols.json                          # SPL 符号（保持不变）
  symbols_hal.json                      # 新增：HAL/LL 符号（§5）
  registers.json                        # 已有，保持不变
  compile_errors.json                   # 保持不变
  pinout_f103c8t6.json                  # 保持不变
  chips/stm32f103c8t6.json              # 保持不变
  functions/                            # SPL，已有，保持不变
    ADC.json … WWDG.json
  functions/hal/GPIO.json …             # 新增，§4
  functions/ll/GPIO.json …              # 新增，§4
  functions/reg/GPIO.json …             # 新增，§4
```

## 3. peripherals.json（schemaVersion 2）

在原有一项上**新增** `libraries` 字段；原有 `header/source/file/introZh/usageOverviewZh/functionCount/symbolCount` 保留，
取「主库」值（有 spl 就取 spl，否则取 hal）以免破坏旧代码。

```jsonc
{
  "id": "GPIO",
  "name": "GPIO",
  "nameZh": "通用输入输出",
  "orderIndex": 1,
  "tags": ["常用", "基础"],

  // ---- 新增 ----
  "libraries": {
    "spl": {
      "header": "stm32f10x_gpio.h",
      "source": "stm32f10x_gpio.c",
      "file": "functions/GPIO.json",
      "functionCount": 18,
      "symbolCount": 115,
      "introZh": "……",
      "usageOverviewZh": "① ……；② ……",
      "usageSteps": ["RCC_APB2PeriphClockCmd 使能 GPIOx 时钟", "……"],
      "noteZh": "可空"
    },
    "hal": { …同上结构，file 为 "functions/hal/GPIO.json"… },
    "ll":  { … },
    "reg": { … }
  },

  // ---- 原有 ----
  "header": "stm32f10x_gpio.h",
  "source": "stm32f10x_gpio.c",
  "file": "functions/GPIO.json",
  "introZh": "……",
  "usageOverviewZh": "……",
  "functionCount": 18,
  "symbolCount": 115,

  "sections": [
    {
      "id": "GPIO@spl#sec1",
      "title": "初始化与配置函数",
      "titleEn": "Initialization and Configuration functions",
      "library": "spl",              // 新增，缺省视为 "spl"
      "functionIds": ["GPIO_DeInit", "GPIO_Init"]
    },
    {
      "id": "GPIO@hal#sec1",
      "library": "hal",
      "title": "初始化与配置",
      "titleEn": "Initialization and Configuration",
      "functionIds": ["HAL_GPIO_Init", "HAL_GPIO_DeInit"]
    }
  ]
}
```

**id 规则**：section id 必须是 `<外设>@<库>#<序号>`。函数 id 必须**全局唯一**，
因此 HAL 函数用原样 `HAL_GPIO_Init`、LL 用 `LL_GPIO_SetPinMode`、reg 用 `REG_GPIO_CRL`（`REG_` 前缀），
SPL 保持原名（`GPIO_Init`）。三类天然不会冲突。

## 4. functions/<库>/<外设>.json

与现有 SPL 函数文件**同构**，只多两个字段 `library` 与 `definedIn`：

```jsonc
{
  "schemaVersion": 2,
  "peripheral": "GPIO",
  "library": "hal",
  "functions": [
    {
      "id": "HAL_GPIO_Init",
      "name": "HAL_GPIO_Init",
      "peripheral": "GPIO",
      "library": "hal",                    // 新增
      "sectionId": "GPIO@hal#sec1",
      "prototype": "void HAL_GPIO_Init(GPIO_TypeDef *GPIOx, GPIO_InitTypeDef *GPIO_Init);",
      "returnType": "void",
      "params": [ {"name":"GPIOx","type":"GPIO_TypeDef *","descEn":"…","descZh":"…"} ],
      "returnDescEn": "None",
      "returnDescZh": "",
      "briefEn": "Initializes the GPIOx peripheral according to the specified parameters in the GPIO_Init.",
      "briefZh": "",
      "usageZh": "",
      "prerequisites": [],
      "registers": [],
      "relatedFunctions": ["HAL_GPIO_DeInit"],
      "remarks": [],
      "notesZh": [],
      "exampleCode": "",
      "exampleLanguage": "c",
      "symbolRefs": [],
      "headerLine": 228,
      "definedIn": "stm32f1xx_hal_gpio.h", // 新增
      "sourceLine": 0,
      "flags": {"deprecated":false,"isrSafe":false,"inline":false,"macroLike":false},
      "ai": null,
      "zhSource": "base"
    }
  ]
}
```

### 4.1 reg 库的特殊约定

reg 库的「函数」条目代表**一个寄存器**：

- `id` = `REG_<寄存器名>`，如 `REG_GPIO_CRL`
- `name` = 寄存器名，如 `GPIO_CRL`
- `prototype` = 直接访问表达式，如 `GPIOA->CRL`
- `returnType` = `uint32_t`
- `params` = 每个位域一项：`name` 是宏名（如 `GPIO_CRL_MODE0`），`type` 填位域描述
  （如 `bits[1:0]`），`descEn` 填 `/*!< … */` 注释，`descZh` 留空由 overlay 补
- `briefEn` / `briefZh` 描述该寄存器用途
- `exampleCode` 给出一段**至少 2 行**的直接寄存器读写示例
- `flags.macroLike = true`
- `sectionId` = `<外设>@reg#sec1`（按寄存器分组：`#sec1` 控制/状态，`#sec2` 数据，`#sec3` 其它）

## 5. symbols_hal.json

HAL/LL 用到的宏、枚举、结构体，供关键词跳转：

```jsonc
{"schemaVersion":2,"symbols":[
  {"id":"GPIO_InitTypeDef","name":"GPIO_InitTypeDef","kind":"struct","library":"hal",
   "peripheral":"GPIO","value":null,"valueKind":null,
   "members":[{"name":"Pin","type":"uint32_t","value":null,"descEn":"","descZh":"","line":0}],
   "briefEn":"","briefZh":"","usageZh":"","definedIn":"stm32f1xx_hal_gpio.h","definedLine":45,
   "visibility":"public","functionLike":false,"params":[],"usedBy":[],
   "relatedSymbols":[],"notesZh":[],"ai":null,"zhSource":"base","registerName":null}
]}
```
`kind` 取值沿用现有枚举：`macro / enum_value / enum_type / struct / typedef / unknown`。

## 6. manifest.json（schemaVersion 2）

```jsonc
{
  "schemaVersion": 2,
  "dataVersion": "2.0.0",
  "splVersion": "STM32F10x_StdPeriph_Lib_V3.5.0",
  "halVersion": "STM32Cube_FW_F1_V1.8.7",
  "defaultChipId": "stm32f103c8t6",
  "generatedAt": "…",
  "generator": "tools/build_multi_lib.py",
  "stats": {
    "peripheralCount": 25, "functionCount": 488, "symbolCount": 7337,
    "pinCount": 48, "compileErrorCount": 15,
    "libraryFunctionCounts": {"spl":488,"hal":0,"ll":0,"reg":0},
    "librarySymbolCounts":  {"spl":7337,"hal":0,"ll":0,"reg":0}
  },
  "files": {
    "peripherals": "peripherals.json",
    "functions": "functions/",
    "symbols": "symbols.json",
    "symbolsHal": "symbols_hal.json",
    "registers": "registers.json",
    "pinout": "pinout_f103c8t6.json",
    "compileErrors": "compile_errors.json",
    "chips": "chips/"
  },
  "functionDirs": {
    "spl": "functions/",
    "hal": "functions/hal/",
    "ll":  "functions/ll/",
    "reg": "functions/reg/"
  }
}
```

## 7. 中文 overlay 约定（HAL/LL）

放在 `data/zh_overlay_hal/`：

```
data/zh_overlay_hal/
  peripherals.json          # {"GPIO": {"introZh":"…","usageOverviewZh":"…","usageSteps":[…]}, …}
  functions_HAL_<外设>.json  # {"HAL_GPIO_Init": {"briefZh":"…","usageZh":"…","notesZh":[…],
                            #   "paramsZh":{"GPIOx":"…"},"exampleCode":"…","prerequisites":[…]}, …}
```

合并脚本按 `id` 覆盖上面这些字段；没覆盖到的字段保留解析出的英文值。

## 8. 「使用总览」分行渲染规则

数据里 `usageOverviewZh` 可能是：
- 已分行的（含 `\n`），或
- 单行用 `①②③…` / `1)` / `(1)` / `第一步` 分隔的长句

统一由 `lib/utils/usage_steps.dart` 的 `splitUsageSteps(String raw)` 切成 `List<UsageStep>`：

```dart
class UsageStep { final String marker; final String text; }
// marker 形如 "①" / "1." / ""（无编号）
```

切分规则（按优先级）：
1. 若文本含 `\n`，先按行切；
2. 每行若以 `①-⑳ | ⑴-⒇ | 1) | 1. | (1) | （1） | 第N步` 开头，且该行内还出现其他同类标记，继续在标记前切；
3. 去掉行首的引导语（如「标准调用顺序：」「两类用法：」）单独作为 `marker=""` 的首项；
4. 结果去空行、去首尾空白。

**渲染要求**：每个序号**另起一行**、序号**顶格**（左侧 padding 为 0），
正文与序号之间留一个空格；续行按序号的视觉宽度做悬挂缩进。

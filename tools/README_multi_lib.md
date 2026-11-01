# build_multi_lib.py —— HAL / LL / 寄存器 数据构建器

把**已有的 SPL 数据**（`assets/data/`，schemaVersion 1）与新抽取的 **HAL / LL / 寄存器**
数据合并成契约 v2（`docs/contract_v2.md`）。

```powershell
cd D:\dsh_work\stm32-helper-v2
python tools\build_multi_lib.py                 # 全量构建
python tools\build_multi_lib.py --dry-run       # 只解析不写盘，看统计
python tools\build_multi_lib.py --only GPIO     # 只重建某个外设
python tools\build_multi_lib.py --generated-at "2026-10-28T00:40:00+08:00"   # 固定时间戳，便于 diff
```

只用标准库，无需 pip 安装任何东西。

## 输入（全部本机，**不联网**）

| 来源 | 用途 |
|---|---|
| `<cube>/Drivers/STM32F1xx_HAL_Driver/Inc/stm32f1xx_hal_*.h` | HAL 函数原型、宏/枚举/结构体符号 |
| `<cube>/Drivers/STM32F1xx_HAL_Driver/Src/stm32f1xx_hal_*.c` | HAL 的 doxygen 注释、函数体（抽 relatedFunctions / registers） |
| `<cube>/Drivers/STM32F1xx_HAL_Driver/Inc/stm32f1xx_ll_*.h` | LL 的 `__STATIC_INLINE` 函数 + 符号 |
| `<cube>/Drivers/CMSIS/Device/ST/STM32F1xx/Include/stm32f103xb.h` | 外设寄存器结构体 + 位定义宏 |
| `<cube>/Drivers/CMSIS/Include/core_cm3.h` | NVIC / SCB / SysTick 等内核寄存器 |
| `assets/data/peripherals.json`、`manifest.json` | 已有 SPL 数据（**只扩展，不重写**） |
| `data/zh_overlay_hal/` | 中文 overlay（契约 §7） |

默认 `<cube>` = `C:\Users\XT\STM32Cube\Repository\STM32Cube_FW_F1_V1.8.7`，
可用 `--cube-root` 指定。

## 输出

```
assets/data/
  manifest.json              schemaVersion=2，含 libraryFunctionCounts / librarySymbolCounts / functionDirs
  peripherals.json           v2：每项新增 libraries{spl,hal,ll,reg}，sections 带 library 字段
  symbols_hal.json           HAL/LL 的宏、枚举、结构体（契约 §5）
  functions/hal/<外设>.json   HAL_ 函数
  functions/ll/<外设>.json    LL_ 函数
  functions/reg/<外设>.json   每个条目 = 一个寄存器
```

JSON 一律 UTF-8 无 BOM、`ensure_ascii=False`、`indent=2`、键序固定（便于 diff）。

## 三个模块

| 文件 | 职责 |
|---|---|
| `tools/hal_parser.py` | 解析 HAL `.h`/`.c` 与 LL `.h`：函数原型、`@brief/@param/@retval/@note`、分组、符号（宏/枚举/结构体/typedef） |
| `tools/reg_parser.py` | 解析 CMSIS 结构体与位定义：寄存器、偏移、访问表达式、位域（位置/掩码/注释） |
| `tools/build_multi_lib.py` | 编排：模块映射 → 函数/符号/寄存器 → 分组 → 合并 overlay → 写盘 → 自检 |

## 当前统计（F103C8T6 / CubeF1 V1.8.7）

| 库 | 外设 | 函数 | 符号 |
|---|---:|---:|---:|
| spl | 25 | 488 | 7337 |
| hal | 21 | 776 | 3320 |
| ll | 19 | 1137 | 1663 |
| reg | 20 | 472 | 472 |

寄存器 472 个，位域 3167 条（100% 有位置信息，94.5% 有 ST 原文说明）。

## 解析时踩到的真实坑（改脚本时别退化）

1. **HAL 注释不在头文件里**。ST 的惯例是 `.h` 只放裸原型，`@brief/@param/@retval`
   全在 `.c` 的函数定义上方，所以必须两个文件都读。
2. **头文件里有内部函数**。`.c` 里定义了但 `.h` 没声明的（`IRDA_WaitOnFlagUntilTimeout`、
   `TIM_Base_SetConfig` 等，共 200+ 个）一律不收录——用户调不到，收进来只会误导。
3. **非 `HAL_` 前缀的跨模块辅助函数也不收**。`FLASH_WaitForLastOperation`、
   `ADC_Enable`、`UART_Start_Receive_IT` 这类 ST 在头文件里导出、但给其它 HAL 模块
   内部用的函数，不符合契约 §1「HAL 库收录 `HAL_*`」的口径；而且
   `FLASH_WaitForLastOperation` 与 SPL 同名，会造成 function id 冲突。
4. **LL 有同名多份定义**。`LL_USART_SetBaudRate` 在 `#if defined(USART_CR1_OVER8)`
   下有两份实现（3 参 / 4 参），`LL_ADC_DMA_GetRegAddr` 只在
   `ADC_MULTIMODE_SUPPORT` 下存在。数据里保留**源码顺序的第一份**并记 warning，
   不合并、不挑。
5. **寄存器名有三套体系**，必须取并集：
   - 结构体叶子成员（194 个）：给访问表达式与偏移
   - `Bit definition for X register` 分节（290 个）：给位域宏
   - 两者不完全重合：`OB_*`/`SPI_I2SCFGR` 只在结构体里，
     `CAN_TI0R`/`CAN_F0R1` 只在分节里。
6. **数组寄存器不能瞎展开**。
   - `DMA_Channel_TypeDef` 的 4 个成员 × 7 个实例宏 = `DMA_CCR1..7`，按通道展开。
   - `NVIC->ISER[8]`、`AFIO->EXTICR[4]` 这类数组，展开成 `X1..Xn`（1 基，ST 习惯），
     表达式写 `NVIC->ISER[0]`。
   - `NVIC->IP[240]` 这种超长数组只留一条 `NVIC_IP`，表达式 `NVIC->IP[n]`，
     否则一个 CORTEX 页会多出 240 条没注释的条目。
7. **位定义分节里混着「字段取值常量」**。`AFIO_EVCR_PIN_PX1`、`RCC_CFGR_SW_HSE`、
   `DMA_CCR_CIRC` 不是位域，是某个位域的候选值。CMSIS 也给它们写了 `_Pos`/`_Msk`，
   所以只看后缀区分不出来；判据是名字 = 「某个位域名 + **非数字**后缀」。
   同节的 `GPIO_CRL_MODE0_1`（纯数字后缀）是拆位宏，要保留。
8. **`_Msk` 表达式有两种**。`(0x3UL << X_Pos)` 能算出连续位域 `bits[1:0]`；
   `0x33333333` 是散置掩码（横跨 8 个引脚字段），报 `bits[15:0]` 是错的，
   原样展示掩码。
9. **USB 包缓冲区寄存器没有固定地址**。`USB_ADDR0_TX` / `USB_COUNT0_RX` 是 PMA 表项，
   地址 = `USB_PMAADDR` + 运行期计算的偏移，**不存在** `USB->ADDR0_TX` 这种成员。
   prototype 写成 `*(volatile uint32_t *)(USB_PMAADDR + pma_off)` 并在 remarks 说明，
   不硬编一个编译不过的表达式。
10. **CMSIS 注释有两类**。`/*!< Transmission Buffer Address 0 */` 是语义说明，
    `/*!< 0x0000FFFE */` 只是掩码值；寄存器描述必须取前者，否则 briefEn 全是十六进制。
11. **生成必须幂等**。`extend_peripherals()` 每次运行都会丢弃上次生成的 HAL/LL/reg
    sections 再重建；SPL 的 `GPIO#sec1` 迁移成 `GPIO@spl#sec1` 的正则也带
    `(?:@spl)?`，否则第二次会拼成 `GPIO@spl@spl#sec1`。

## reg 库为什么是 472 个，而 registers.json 是 443 个

`registers.json`（SPL 时代的产物）按**位定义宏的前缀**统计，得 443 个「寄存器名」；
本构建器按**CMSIS 结构体的叶子成员 + 位定义分节并集**统计，得 472 个。
两边口径不同，具体差异：

### SPL 有、本构建器没有的 180 个 → 均不属于 STM32F103

经逐个核对 `stm32f103xb.h`，以下 117 个名字在**本型号的头文件里根本不存在**：

| 前缀 | 数量 | 说明 |
|---|---:|---|
| BKP_DR11..DR42 | 32 | 大容量/互联型才有的备份寄存器（C8T6 只有 DR1~DR10） |
| FSMC_* | 27 | F103C8T6 无 FSMC 外设（100/144 脚型号才有） |
| SDIO_* | 19 | C8T6 无 SDIO 外设 |
| DAC_* | 14 | C8T6（LQFP48）无 DAC 引脚 |
| NVIC_PRI0..7 | 13 | SPL 的旧命名；CMSIS 用 `NVIC->IP[]` 数组表示 |
| CEC_* | 7 | C8T6 无 CEC 外设 |
| RCC_CFGR2 / SCB_afsr 等 | 4 | F105/F107 互联系列专有 |

这些是 `registers.json` 从**全系列**头文件归并时带进来的，本型号用不到，
故不生成 reg 条目（它们的名字仍可在 `registers.json` 里查到）。

其余 63 个是 USB PMA 表项 —— **已全部收录**（见坑 9），现在共 472 条。

### 本构建器有、SPL 没有的 145 个

- 内核寄存器：`DWT_*`(20)、`ITM_*`(20)、`TPI_*`(17)、`MPU_*`(11)、
  `CoreDebug_*`(4)、`SCnSCB_*`(2)、`SCB_*` 补充(17)、`NVIC_*` 补充(42)
  —— `core_cm3.h` 里有完整定义，SPL 只收录了常用的几个。
- `OB_*`(8)：选项字节，SPL 归在 `FLASH_*` 名下；这里用 `OB->XXX` 访问。
- `DMA_CCR4`、`GPIO_IDR`、`RCC_CIR`、`TIM_OR`：SPL 的位定义分节里漏掉的 4 个。

## 中文 overlay（契约 §7）

`data/zh_overlay_hal/` 下：

- `peripherals.json`：顶层键是外设 id，值写到该外设的 **HAL 库**；
  要单独给 LL/reg 写就用 `"ll": {...}` / `"reg": {...}` 子键。
- `functions_HAL_<外设>.json`：键是函数 id，值可含
  `briefZh / usageZh / notesZh / paramsZh / exampleCode / prerequisites / returnDescZh`。

合并规则：**空值不覆盖**（空串、空数组、null 都视为「未提供」），
被覆盖到的函数 `zhSource` 置为 `overlay`。

### 怎么维护

HAL/LL 的中文全部在 `data/zh_overlay_hal/` 里，**不要直接改 `assets/data/`**
（那是 `build_multi_lib.py` 的产物，重跑会被覆盖）。改完 overlay 后必须重跑构建：

```powershell
python tools\build_multi_lib.py            # 重新生成 assets/data
python tools\check_zh_coverage.py          # 核对覆盖率与一致性
```

各文件分工：

| 文件 | 内容 | 现状 |
|---|---|---|
| `peripherals.json` | 每个外设的 `introZh` / `usageOverviewZh` / `usageSteps` / `noteZh`；HAL 版写在顶层，LL 版写在 `"ll"` 子键 | 21 个外设（HAL）+ 18 个外设（LL） |
| `functions_HAL_*.json` | HAL 函数的中文说明 + 参数说明 + 示例代码 | 776 个函数 |
| `functions_LL_*.json` | LL 函数的中文说明（LL 粒度细，brief 一行即可） | 1137 个函数 |

新增或修改条目时：

1. 只写**有把握**的字段。拿不准就留空——UI 会回退显示 ST 英文原文，
   显示英文比显示错误中文好。
2. 函数 id 必须与 `assets/data/functions/<库>/<外设>.json` 里的 `id` 完全一致
   （拼错不会报错，只会静默丢失）。`check_zh_coverage.py` 第 3 项检查就会抓这个。
3. `exampleCode` 里只调用真实存在的 API。HAL/LL 的函数白名单取自
   `assets/data/functions/{hal,ll}/*.json` 的 id 全集，另加内核级的
   `HAL_Init` / `HAL_Delay` / `HAL_GetTick` 等（它们在 `stm32f1xx_hal.c` 里，
   不属于任何外设，所以不在函数表里）。`check_zh_coverage.py` 第 4 项检查会报出编造的接口。
4. `paramsZh` 的键必须与函数 `prototype` 里的形参名一致，否则该参数的中文不会生效。

### 术语约定

保持一致，避免同一概念出现多种译法：

| 英文 | 中文 | 英文 | 中文 |
|---|---|---|---|
| Peripheral | 外设 | Handle | 句柄 |
| Channel | 通道 | Blocking mode | 阻塞模式 |
| Interrupt | 中断 | Polling | 轮询 |
| Callback | 回调 | Transmit | 发送 |
| Enable | 使能 | Receive | 接收 |
| Disable | 失能 | Configure | 配置 |
| Initialize | 初始化 | Deinitialize | 反初始化 |
| Transfer | 传输 | Conversion | 转换 |
| Threshold | 阈值 | Prescaler | 预分频 |

另外：

- `__HAL_RCC_xxx_CLK_ENABLE()` 一律译成「使能 xxx 时钟」。
- 不要写「该函数用于……」这类空话，要说清**干什么**和**什么情况下用**。
- HAL 的说明可以写长（调用顺序、坑、和 SPL 的差异），LL 的一行即可。

### 覆盖率目标与自检

```powershell
python tools\check_zh_coverage.py           # 完整报告
python tools\check_zh_coverage.py --quiet    # 只看汇总
```

检查四项：briefZh 覆盖率（HAL ≥ 95%、LL ≥ 85%）、缺失清单（按库/外设分组）、
overlay id 是否真实存在、exampleCode 里是否出现不存在的 API。有问题时退出码非 0。

当前实际覆盖率：**HAL 776/776 = 100%、LL 1137/1137 = 100%**；
HAL 十大常用外设（GPIO/RCC/USART/TIM/SPI/I2C/ADC/DMA/FLASH/PWR）的
参数中文说明 100% 覆盖。

> 注：HAL 函数总数以 `build_multi_lib.py` 当前解析结果为准（曾从 804 变为 776，
> 因为 `stm32f1xx_hal_usart.c` 里 17 个未在头文件声明的内部函数不再收录）。
> overlay 是按键名匹配的，重跑构建后 `check_zh_coverage.py` 会告诉你有没有新增缺口。

## 自检

脚本结尾会跑契约硬性检查，任一失败即非零退出：

1. 所有 function id 全局唯一
2. 每个 `sectionId` 都能在同库的 sections 里找到，且每个函数都挂进了某个 section
3. 每个 functions 条目的 `library` 与所在目录一致；reg 条目 id 带 `REG_` 前缀且示例 ≥ 2 行
4. 落盘文件都能被 `json.load` 读回

另外建议跑一遍完整校验（数据层 + 契约 v2 断言）：

```powershell
python tools\validate_data.py --data assets\data
```

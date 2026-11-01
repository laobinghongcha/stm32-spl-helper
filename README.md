# STM32 库函数助手

STM32F103C8T6 的**离线函数查阅工具**。一套 App 同时收录标准库、HAL 库、LL 库与寄存器手册，
按外设浏览、全文搜索、点哪查哪，**完全离线**（不申请网络权限）。

Flutter 开发，Android 7.0+，安装包约 57 MB，数据全部内置。

---

## 为什么做这个

查 STM32 函数时最常见的三个麻烦：

- **一个函数散在三个地方**：标准库的头文件、HAL 的 `.h`、还有直接写寄存器的参考手册。
  想对比 `GPIO_Init` 和 `HAL_GPIO_Init` 要先打开三个窗口。
- **英文注释看不懂**：ST 的 `@brief` 一句 "Initializes the GPIOx peripheral according to
  the specified parameters" 信息量很低，真正该说的「必须先开时钟」「结构体要自己填满」都没有。
- **查了就忘，忘了再查**：收藏夹里一堆链接，回头找不到上次那个坑。

所以做了这个：**四套库放一起、每个函数配中文说明和可运行示例、支持收藏与笔记**。

---

## 功能

### 一、四套库并存，随时对比

| 库 | 代表写法 | 收录函数 |
|---|---|---:|
| 标准库 SPL | `GPIO_Init(GPIOA, &init)` | 488 |
| HAL 库 | `HAL_GPIO_Init(GPIOA, &init)` | 801 |
| LL 库 | `LL_GPIO_SetPinMode(...)` | 1137 |
| 寄存器直驱 | `GPIOA->CRL = ...` | 472 个寄存器 |

合计 **2898 个函数**，另有 3167 条位域定义、12830 个符号。

同一个外设下可以**按库切换**查看，每个函数行尾带库徽标（SPL 蓝 / HAL 绿 / LL 橙 / REG 紫），
扫一眼就知道这行是哪个库的写法。

> 典型场景：想知道 CubeMX 生成的 `HAL_UART_Init` 和学过的标准库 `USART_Init`
> 差在哪 —— 进「USART」外设，两个库来回切一下就有答案。

### 二、函数详情：一次看全

每个函数给 10 个区块，从上到下按「读代码的顺序」排：

| 区块 | 内容 |
|---|---|
| 函数原型 | 逐字来自 ST 头文件，可横向滚动、可一键复制 |
| 参数 | 每个参数的类型 + 中文说明 + 取值范围 |
| 返回值 | `void` / `HAL_StatusTypeDef` / `FlagStatus` 等，带中文解释 |
| 使用说明 | 什么时候调用、调用顺序、和别的库差在哪 |
| 前置条件 | 「必须先开时钟」这类硬要求，单独列出来 |
| 涉及的寄存器 | 这个函数实际动哪些寄存器，可展开看位域 |
| 最小示例 | 复制就能编译的 C 片段 |
| 注意事项 | 常见坑，比如「忘了开时钟会静默失效」 |
| 相关函数 | 一键跳转 |
| 位域表 | 寄存器库专有：`GPIO_CRL_MODE0 = bits[1:0]` |

**中文说明是核心**。HAL + LL 的 1938 个函数全部有中文简述，十大常用外设的每个参数也有中文解释。
不是机翻，是对着源码写的——比如 `HAL_GPIO_Init` 会明确告诉你
「HAL 不会替你填结构体默认值，未赋值的字段是栈上随机值」。

### 三、关键词点击跳转

函数原型、参数表、示例代码里出现的**任何库内名字**都能点：

```
void HAL_GPIO_Init(GPIO_TypeDef *GPIOx, GPIO_InitTypeDef *GPIO_Init);
                     ↑ 可点                    ↑ 可点
```

点 `GPIO_InitTypeDef` 会打开结构体定义，看到 `Pin / Mode / Pull / Speed` 四个字段。

**同名类型会自动区分**：`GPIO_InitTypeDef` 在 HAL 和标准库里是两个不同的结构体
（HAL 是 `Pin/Mode/Pull/Speed`，标准库是 `GPIO_Pin/GPIO_Speed/GPIO_Mode`）。
在 HAL 函数里点它，打开的是 HAL 那份；详情页底部还有「看标准库的」一键切换，方便对比。

### 四、全局搜索

一个搜索框搜五类内容，结果按类型分组：

| 类型 | 例子 |
|---|---|
| 函数 | `HAL_UART_Transmit`、`GPIO_Init` |
| 符号 | `GPIO_MODE_OUTPUT_PP`、`ADC_HandleTypeDef` |
| 外设 | `USART`、`TIM` |
| 引脚 | `PA9`、`PC13` |
| 编译错误 | `undefined reference to` |

匹配规则做了几处优化：

- **前缀优先**：搜 `GPIO_In` 时 `GPIO_Init` 排第一
- **缩写容错**：搜 `uart` 能搜到 `USART_*`（USART 里不含 uart 子串，按子序列匹配）
- **中文可搜**：搜「串口」「定时器」也能命中
- **按库过滤**：设置里关掉某个库后，搜索结果自动只留启用的库

### 五、使用总览逐条分行

每个外设顶部有「使用总览」，说明这个外设的标准调用顺序。
每个序号**另起一行、序号顶格**，多行正文悬挂缩进对齐：

```
① 使能 GPIOx 时钟（忘了这步，后面的配置会静默失效）
② 填 GPIO_InitTypeDef 三个字段
③ GPIO_Init 写入配置
④ 用 GPIO_SetBits / GPIO_ResetBits 操作电平
```

不再挤成一整段——调用顺序本身就是有先后关系的，排开才看得懂。

### 六、收藏 / 最近查看 / 笔记

- **收藏**：常用的十几个函数钉住，按类型筛选
- **最近查看**：自动记录，找「刚才看过的那个」很快
- **笔记**：给任意函数/符号写自己的备注，可导出为 Markdown

### 七、引脚速查

48 脚 LQFP48 封装的完整引脚表：

- 按管脚号看：每个脚的主功能、复用功能、是否 5V 容忍、注意事项
- 按功能反查：想知道「USART1_TX 在哪个脚」，直接搜功能名
- 按外设看：列出某个外设占用了哪些引脚

### 八、编译错误速查

15 类最常见的编译/链接/下载错误，每条含报错原文、中文解释、产生原因、
逐步排查方法、相关代码示例。

---

## 离线保证

APP **未声明 `INTERNET` 权限**。这不是"代码里没写网络请求"这种自觉约定，
而是 Android 层面的硬约束——没有该权限，任何 socket 连接都会直接抛异常。

所有数据（约 13.8 MB JSON）随 APK 打包，断网、飞行模式下功能完全不受影响。

---

## 下载安装

到 **[Releases](../../releases)** 页面下载最新的 `stm32-helper-*.apk`。

| 项目 | 值 |
|---|---|
| 包名 | `io.github.laobinghongcha.stm32helper` |
| 最低系统 | Android 7.0（API 24） |
| 目标 SDK | 36 |
| 安装包 | 约 57 MB |

安装时需在系统设置里允许「安装未知来源应用」。
每个 Release 附带 `SHA256SUMS.txt`，下载后可核对完整性：

```powershell
Get-FileHash .\stm32-helper-2.0.3.apk -Algorithm SHA256   # Windows
sha256sum stm32-helper-2.0.3.apk                          # macOS / Linux
```

> APK 不进仓库：单包约 57 MB，提交进 Git 会让仓库体积失控，
> 且历史里的二进制无法真正删除（只能重写历史）。统一由 Releases 分发。

APK 使用自签名证书（`CN=STM32 Helper`）签发，未上架任何应用商店。

---

## 数据来源

| 库 | 来源 | 版本 |
|---|---|---|
| 标准库 SPL | STM32F10x_StdPeriph_Lib | V3.5.0 |
| HAL / LL | STM32CubeF1 固件包 | V1.8.7 |
| 寄存器 | CMSIS `stm32f103xb.h` | — |
| 引脚 | ST 数据手册 DS5319 Table 5 | — |

函数原型与英文注释逐字来自 ST 官方头文件，由 `tools/build_multi_lib.py` 自动解析生成，
不经手工转录，避免抄错。

---

## 自己构建

环境要求：Flutter 3.47+、JDK 17、Android SDK 36 + 34、NDK 28.2、CMake 3.22。

```powershell
flutter pub get
flutter analyze        # 应为 No issues found
flutter test           # 510 个测试应全部通过
flutter build apk --release
```

更详细的环境搭建与常见坑见 [`docs/build_env.md`](docs/build_env.md)。
发版流程见 [`docs/RELEASING.md`](docs/RELEASING.md)。

> **改数据后必须重跑生成脚本**，否则会重演历史上的事故：
>
> ```powershell
> python tools\build_multi_lib.py       # 重新生成 assets/data
> python tools\validate_data.py --data assets\data
> python tools\check_zh_coverage.py
> ```
>
> 还有一个容易踩的坑：`pubspec.yaml` 里 assets 的**目录声明不递归**。
> 新增数据子目录必须逐个列出，否则文件不会打进 APK，
> 界面表现为「某库函数全是 0」。`test/asset_bundle_test.dart` 会拦住这类问题。

---

## 项目结构

```
lib/
├── models/     数据模型（函数、符号、外设、引脚…）
├── data/       资源加载（分层 + 缓存）、搜索索引、本地数据库
├── pages/      12 个页面
├── providers/  Riverpod 状态
├── widgets/    通用组件（代码块、关键词文本、库徽标…）
└── utils/      主题、高亮、使用总览切分
assets/data/    打包进 APK 的数据（13.8 MB）
data/           中文说明源文件（不进 APK）
tools/          数据生成、校验、发版脚本
docs/           架构与构建文档
test/           510 个测试
```

---

## 许可

代码与中文说明以 [MIT](LICENSE) 许可开源。

内置数据中的函数原型、英文注释与寄存器定义版权归 **STMicroelectronics** 所有，
详见 [LICENSE](LICENSE) 末尾的第三方声明。

---

## 已知限制

- **只支持 STM32F103C8T6**。引脚数据、芯片能力（哪些外设可用）都是按这颗芯片做的。
  其他 F103 型号可以当函数手册用，但引脚表不适用。
- **不含 USB、以太网**。F103C8T6 的 USB 设备模式与 HAL 建模差异较大，本版未收录。
- **包名带 `laobinghongcha`**，是从上游仓库延续的命名，不代表与作者本人有隶属关系。

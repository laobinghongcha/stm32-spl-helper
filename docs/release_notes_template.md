# 发布说明模板

> 用法：发新版前复制本文件为 `.release_notes_v<版本>.md`，按下面各节填写。
> 填完删掉本段说明和所有 `<...>` 占位符。

---

# STM32 库函数助手 v<版本号>

<一句话说明这个版本最重要的变化。Release 列表里只显示开头几行，
最该说的放这里。>

## 下载

| 文件 | 大小 | 说明 |
|---|---|---|
| `stm32-helper-<版本号>.apk` | <大小> MB | 安装包（Android 7.0+） |
| `SHA256SUMS.txt` | — | 完整性校验值 |

```powershell
# Windows 核对
Get-FileHash .\stm32-helper-<版本号>.apk -Algorithm SHA256
# macOS / Linux
sha256sum stm32-helper-<版本号>.apk
```

安装时需在系统设置里允许「安装未知来源应用」。

> 升级提示：
> - 同签名且 versionCode 递增 → 可直接覆盖升级
> - 包名变更 → 需先卸载（会丢收藏与笔记，提醒用户先导出）

## 本版变化

### 新增

- <功能点，写清楚"用户能做什么"，不要写"重构了 xxx 模块">

### 修复

- <bug：现象 / 原因 / 修法。现象写用户视角看到的，不要写内部术语>

### 变更

- <行为变化、界面调整、依赖升级等>

## 验证

- `flutter analyze` → No issues found
- `flutter test` → <N> 个全过
- 从构建好的 APK 解包核对：hal <N> / ll <N> / reg <N> 个函数文件
- 中文说明：HAL <N>/<N>、LL <N>/<N>

## 功能概览

| 库 | 代表写法 | 函数数 |
|---|---|---:|
| 标准库 SPL | `GPIO_Init(GPIOA, &init)` | 488 |
| HAL 库 | `HAL_GPIO_Init(GPIOA, &init)` | 801 |
| LL 库 | `LL_GPIO_SetPinMode(...)` | 1137 |
| 寄存器直驱 | `GPIOA->CRL = ...` | 472 个寄存器 |

合计 **2898 个函数**，另含 3167 条位域定义、12830 个符号。

- 外设页按库切换，函数行尾带库徽标
- 函数详情 10 个区块（原型 / 参数 / 返回值 / 使用说明 / 前置条件 /
  涉及寄存器 / 示例 / 注意事项 / 相关函数 / 位域表）
- 关键词点击跳转，同名类型自动按库区分并可一键对比
- 全局搜索五类内容，支持缩写与中文
- 使用总览逐条分行、序号顶格
- 收藏 / 最近查看 / 笔记（可导出 Markdown）
- 引脚速查、编译错误速查

**完全离线**：未申请 `INTERNET` 权限，断网可用。

## 数据来源

函数原型与英文注释逐字来自 ST 官方头文件：

- 标准库：STM32F10x_StdPeriph_Lib V3.5.0
- HAL / LL：STM32CubeF1 V1.8.7
- 寄存器：CMSIS `stm32f103xb.h`
- 引脚：ST DS5319 Table 5

版权归 STMicroelectronics 所有，详见仓库 `LICENSE` 末尾的第三方声明。

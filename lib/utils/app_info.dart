/// 应用元信息。
///
/// 集中放一处，避免版本号散落在设置页、关于页、导出文件名里各写一遍
/// （改版本时最容易漏掉这种"同一个值写三处"的地方）。
///
/// 与 `pubspec.yaml` 的 `version:` 手动保持一致——不引入
/// `package_info_plus`，那会为了读一个版本号多一个原生插件依赖。
library;

/// 应用显示名
const String appName = 'STM32 库函数助手';

/// 应用版本（对应 pubspec 的 version 前缀）
///
/// 注意：改 pubspec 的 version 时必须同步改这里，
/// `test/settings_test.dart` 有一条测试专门比对两者，不匹配就会失败。
/// 递增版本号请用 `tools/release.ps1`——它会同时维护 versionCode
/// 并回读 APK 校验，避免漏改导致新包装不上。
const String appVersion = '2.0.3';

/// Android 包名
const String appPackageName = 'io.github.laobinghongcha.stm32helper';

/// 目标芯片
const String targetChip = 'STM32F103C8T6';

/// 数据来源库
const String splVersion = 'STM32F10x_StdPeriph_Lib_V3.5.0';

/// HAL / LL 数据来源
const String halVersion = 'STM32Cube_FW_F1_V1.8.7';

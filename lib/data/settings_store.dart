import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置（主题模式 / 代码字号 / 显示开关 / 函数库过滤）。
///
/// 存 shared_preferences 而不是 sqflite：这些都是标量（[enabledLibraries]
/// 序列化成 StringList 存放），没有查询与关联的需求，键值存储更轻
/// （这也是阶段 0 定的方案）。
///
/// 与收藏/笔记分开的原因：那些是"用户数据"，需要按类型/时间检索；
/// 这些是"配置"，只按 key 读一次。
class AppSettings {
  /// 主题模式
  final ThemeMode themeMode;

  /// 代码块字号
  final double codeFontSize;

  /// 首页是否只显示本型号支持的外设
  final bool onlySupported;

  /// 要显示哪些函数库，取值是 [LibraryKind] 的 raw 字符串
  /// （`spl` / `hal` / `ll` / `reg`）。
  ///
  /// 用 `Set<String>` 而不是 `Set<LibraryKind>`：设置层刻意不认识 models 层
  /// （models 正由别人改造，且 raw 字符串是契约 §1 里定死的持久化值）。
  /// 页面侧用 `libraryVisibleProvider('hal')` 拿 bool，provider 负责映射。
  ///
  /// 不变式：**至少有一个库**。空集合会让整个 App 看不到任何函数，
  /// 无法通过 UI 自己救回来，所以 [SettingsStore.load] 读到空就回退默认。
  final Set<String> enabledLibraries;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.codeFontSize = 13.0,
    this.onlySupported = false,
    this.enabledLibraries = defaultLibraries,
  });

  /// 四库全开（默认值）。
  ///
  /// 顺序固定 `spl, hal, ll, reg`（契约 §1），虽然 Set 本身无序，
  /// 但序列化成 List 持久化时按这个顺序写，diff 才稳定。
  static const Set<String> defaultLibraries = <String>{'spl', 'hal', 'll', 'reg'};

  /// 库的显示顺序（与 [defaultLibraries] 一致，供设置页遍历）
  static const List<String> libraryOrder = <String>['spl', 'hal', 'll', 'reg'];

  /// 代码字号的取值范围（与设置页的 Slider 一致）。
  ///
  /// 在这里定义而不是在页面里，是为了让"读到的值"也能被同一套边界约束：
  /// 万一 prefs 里存了一个 100（手改文件、旧版本写坏），
  /// 直接用它渲染代码块会把布局撑爆。
  static const double minCodeFontSize = 10.0;
  static const double maxCodeFontSize = 20.0;

  /// 默认值，也是"恢复默认"按钮的目标值
  static const AppSettings defaults = AppSettings();

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? codeFontSize,
    bool? onlySupported,
    Set<String>? enabledLibraries,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        codeFontSize: codeFontSize ?? this.codeFontSize,
        onlySupported: onlySupported ?? this.onlySupported,
        enabledLibraries: enabledLibraries ?? this.enabledLibraries,
      );

  /// 某个库是否启用。
  bool isLibraryEnabled(String raw) => enabledLibraries.contains(raw);

  /// 是否四库全开。
  bool get allLibrariesEnabled =>
      enabledLibraries.length >= defaultLibraries.length &&
      enabledLibraries.containsAll(defaultLibraries);

  /// 是否一个库都没启用（正常流程下不会是 true，见 [SettingsStore.load] 的兜底）。
  bool get noLibraryEnabled => enabledLibraries.isEmpty;

  /// 切换单个库，返回新的设置。
  ///
  /// 不做"至少留一个"的拦截——那是 UI 的职责（要弹 SnackBar 说明原因），
  /// 这里保持成纯函数，测试才好写。
  AppSettings withLibrary(String raw, bool on) {
    final next = <String>{...enabledLibraries};
    if (on) {
      next.add(raw);
    } else {
      next.remove(raw);
    }
    return copyWith(enabledLibraries: next);
  }

  /// 全开 / 全关。
  AppSettings withAllLibraries({required bool on}) =>
      copyWith(enabledLibraries: on ? defaultLibraries : <String>{});

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.codeFontSize == codeFontSize &&
      other.onlySupported == onlySupported &&
      other.enabledLibraries.length == enabledLibraries.length &&
      other.enabledLibraries.containsAll(enabledLibraries);

  @override
  int get hashCode => Object.hash(
        themeMode,
        codeFontSize,
        onlySupported,
        // Set 没有稳定 hashCode，用「有序拼接」代替：
        // 同一组库无论插入顺序如何都得到同一个值，== / hashCode 才自洽。
        Object.hashAll(
          libraryOrder.where(enabledLibraries.contains),
        ),
      );

  @override
  String toString() => 'AppSettings(${themeMode.name}, $codeFontSize, '
      'onlySupported=$onlySupported, '
      'libs=[${libraryOrder.where(enabledLibraries.contains).join(",")}])';
}

/// 设置的读写。
class SettingsStore {
  static const String _kThemeMode = 'settings.theme_mode';
  static const String _kCodeFontSize = 'settings.code_font_size';
  static const String _kOnlySupported = 'settings.only_supported';
  static const String _kEnabledLibraries = 'settings.enabled_libraries';

  /// 读取全部设置。任何一项缺失或非法都退回默认值，不抛异常——
  /// 设置读失败不该让整个 App 起不来。
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();

    final themeRaw = prefs.getString(_kThemeMode);
    final theme = _themeModeFromRaw(themeRaw) ?? AppSettings.defaults.themeMode;

    final sizeRaw = prefs.getDouble(_kCodeFontSize);
    final size = sizeRaw == null
        ? AppSettings.defaults.codeFontSize
        : clampFontSize(sizeRaw);

    final onlySupported =
        prefs.getBool(_kOnlySupported) ?? AppSettings.defaults.onlySupported;

    final libs = _librariesFromRaw(prefs.getStringList(_kEnabledLibraries));

    return AppSettings(
      themeMode: theme,
      codeFontSize: size,
      onlySupported: onlySupported,
      enabledLibraries: libs,
    );
  }

  /// 保存全部设置。
  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, settings.themeMode.name);
    await prefs.setDouble(
      _kCodeFontSize,
      clampFontSize(settings.codeFontSize),
    );
    await prefs.setBool(_kOnlySupported, settings.onlySupported);
    await prefs.setStringList(
      _kEnabledLibraries,
      normalizeLibraries(settings.enabledLibraries),
    );
  }

  /// 把字号夹到合法区间。
  static double clampFontSize(double v) {
    if (v.isNaN) return AppSettings.defaults.codeFontSize;
    if (v < AppSettings.minCodeFontSize) return AppSettings.minCodeFontSize;
    if (v > AppSettings.maxCodeFontSize) return AppSettings.maxCodeFontSize;
    return v;
  }

  /// 把任意一组库标识规整成「合法值 + 固定顺序 + 非空」。
  ///
  /// - 丢掉不认识的字符串（`'spi'`、`''`、旧版本残留）；
  /// - 按 [AppSettings.libraryOrder] 排序，保证落盘的 List 是稳定顺序；
  /// - 结果为空时回退全开——用户误操作清空后不该什么都看不到。
  static List<String> normalizeLibraries(Iterable<String>? raw) {
    if (raw == null) return _ordered(AppSettings.defaultLibraries);
    final valid = raw
        .map((e) => e.trim().toLowerCase())
        .where(AppSettings.defaultLibraries.contains)
        .toSet();
    if (valid.isEmpty) return _ordered(AppSettings.defaultLibraries);
    return _ordered(valid);
  }

  static List<String> _ordered(Iterable<String> libs) => AppSettings.libraryOrder
      .where(libs.contains)
      .toList(growable: false);

  /// 存储里的 StringList → Set；缺失/空/全非法一律回退全开。
  static Set<String> _librariesFromRaw(List<String>? raw) {
    if (raw == null) return AppSettings.defaultLibraries;
    final valid = raw
        .map((e) => e.trim().toLowerCase())
        .where(AppSettings.defaultLibraries.contains)
        .toSet();
    // 读到空集合：可能是用户手改文件、旧版本写坏、或误操作全关。
    // 回退成全开，至少让 App 可用，而不是打开就是一片空白。
    if (valid.isEmpty) return AppSettings.defaultLibraries;
    return valid;
  }

  /// 字符串 → ThemeMode；无法识别返回 null。
  static ThemeMode? _themeModeFromRaw(String? raw) {
    if (raw == null) return null;
    for (final m in ThemeMode.values) {
      if (m.name == raw) return m;
    }
    return null;
  }
}

/// 主题模式的中文名（设置页与关于页共用）。
String themeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return '跟随系统';
    case ThemeMode.dark:
      return '强制深色';
    case ThemeMode.light:
      return '强制浅色';
  }
}

/// 主题模式的完整说明（设置页副标题用）。
String themeModeDescription(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return '跟随系统设置';
    case ThemeMode.dark:
      return '始终使用深色主题';
    case ThemeMode.light:
      return '始终使用浅色主题';
  }
}

/// 函数库键 → 中文短名（设置页与筛选提示共用）。
///
/// 只是显示文案；真正的库元信息在 `lib/models/library_kind.dart`，
/// 但设置层不依赖 models（见 [AppSettings.enabledLibraries] 的说明）。
String libraryLabelZh(String raw) {
  switch (raw) {
    case 'spl':
      return '标准库';
    case 'hal':
      return 'HAL 库';
    case 'll':
      return 'LL 库';
    case 'reg':
      return '寄存器直驱';
    default:
      return raw;
  }
}

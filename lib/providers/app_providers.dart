import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asset_repository.dart';
import '../data/search_index.dart';
import '../data/settings_store.dart';
import '../models/spl_data.dart';
import '../models/symbol_item.dart';
import '../utils/symbol_matcher.dart';

/// 全局数据仓库单例。
final assetRepositoryProvider = Provider<AssetRepository>((ref) {
  return AssetRepository();
});

/// 首屏核心数据（异步加载一次，全局共享）。
///
/// 页面用 `ref.watch(splDataProvider)` 拿到 `AsyncValue<SplData>`，
/// 用 `.when(data:, loading:, error:)` 处理三态——加载失败时显示友好提示，
/// 不会白屏（需求：assets 加载失败要有友好提示）。
final splDataProvider = FutureProvider<SplData>((ref) async {
  final repo = ref.watch(assetRepositoryProvider);
  return repo.loadCore();
});

/// 内存搜索索引。
///
/// 核心数据未就绪时返回 null——调用方应先 `ref.watch(splDataProvider)`
/// 确认数据已加载（搜索页本来就要处理加载态），再取索引。
final searchIndexProvider = Provider<SearchIndex?>((ref) {
  final data = ref.watch(splDataProvider).valueOrNull;
  if (data == null) return null;
  return SearchIndex.build(data);
});

/// 符号匹配器：给 KeywordText / CodeBlock 判断哪些词可点击。
///
/// 从核心数据构建，覆盖全部 API 符号与已加载的函数。
/// 函数是全局的（488 个），但函数详情是按需加载的，
/// 所以这里用外设的 functionIds 反查函数名——它们已经在 peripherals.json 里。
final symbolMatcherProvider = Provider<SymbolMatcher?>((ref) {
  final data = ref.watch(splDataProvider).valueOrNull;
  if (data == null) return null;

  // 函数名来自外设的分组信息（首屏就有，不必等函数详情加载）
  final functionNames = <String>{};
  for (final p in data.peripherals) {
    functionNames.addAll(p.allFunctionIds);
  }
  // 已加载的函数详情也补进去（可能包含宏式函数）
  for (final f in data.functions) {
    functionNames.add(f.id);
  }

  return SymbolMatcher(
    functions: functionNames,
    // SPL 与 HAL/LL 的符号都要收：只给 SPL 的话，HAL 函数页正文里的
    // `GPIO_InitTypeDef`、`HAL_StatusTypeDef` 这些类型名全点不动。
    symbols: <String>[
      ...data.symbols.map((s) => s.name),
      ...data.halSymbols.map((s) => s.name),
    ],
  );
});

/// 寄存器位定义符号（2.7 MB，按需加载）。
///
/// 只有展开"寄存器位域说明"时才需要，不拖慢首屏。
final registerSymbolsProvider = FutureProvider<List<SymbolItem>>((ref) async {
  final repo = ref.watch(assetRepositoryProvider);
  return repo.loadRegisterSymbols();
});

/// 当前芯片规格（从核心数据里取，避免页面重复判空）。
final chipSpecProvider = Provider((ref) {
  return ref.watch(splDataProvider).valueOrNull?.chip;
});

/// 首页排序方式。
enum HomeSortMode {
  /// 按使用频率（orderIndex）
  frequency('按常用度'),

  /// 按字母序
  alphabetical('按字母序');

  final String labelZh;

  const HomeSortMode(this.labelZh);
}

/// 首页排序方式状态。
///
/// 这一项**有意不持久化**：它只是浏览时的临时排序偏好，
/// 而持久化的都放在 [settingsProvider] 里（主题/字号/过滤开关）。
final homeSortModeProvider =
    StateProvider<HomeSortMode>((ref) => HomeSortMode.frequency);

/// 设置存储单例。
final settingsStoreProvider = Provider<SettingsStore>((ref) {
  return SettingsStore();
});

/// 应用设置（主题模式 / 代码字号 / 仅显示支持的外设）。
///
/// 阶段 9 起持久化到 shared_preferences：这三项都是用户会调的偏好，
/// 重启后应该保持。用 AsyncNotifier 而不是 FutureProvider 是因为它们可写。
///
/// 读取失败时**退回默认值而不是抛异常**——设置读不出来不该让 App 起不来。
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  SettingsStore get _store => ref.read(settingsStoreProvider);

  @override
  Future<AppSettings> build() async {
    try {
      return await _store.load();
    } catch (e) {
      debugPrint('[Settings] 读取设置失败，使用默认值：$e');
      return AppSettings.defaults;
    }
  }

  /// 改主题模式
  Future<void> setThemeMode(ThemeMode mode) =>
      _update((s) => s.copyWith(themeMode: mode));

  /// 改代码字号（会自动夹到合法区间）
  Future<void> setCodeFontSize(double size) =>
      _update((s) => s.copyWith(codeFontSize: SettingsStore.clampFontSize(size)));

  /// 改"仅显示本型号支持的外设"
  Future<void> setOnlySupported(bool value) =>
      _update((s) => s.copyWith(onlySupported: value));

  /// 开关某一个函数库（`spl` / `hal` / `ll` / `reg`）。
  ///
  /// 认识的库之外的值直接忽略——避免上游传了个拼错的 raw 之后，
  /// 设置里多出一个永远不会生效的项。
  Future<void> setLibraryEnabled(String raw, bool on) async {
    final key = raw.trim().toLowerCase();
    if (!AppSettings.defaultLibraries.contains(key)) {
      debugPrint('[Settings] 忽略未知函数库标识：$raw');
      return;
    }
    await _update((s) => s.withLibrary(key, on));
  }

  /// 四库全开 / 全关。
  ///
  /// 全关会得到空集合；[SettingsStore.load] 会把空集合回退成全开，
  /// 所以 UI 侧必须拦住"关掉最后一个"，否则重启后设置又变回全开，
  /// 表现为"关不掉"。设置页的"全部启用"开关负责这层拦截。
  Future<void> setAllLibraries(bool on) =>
      _update((s) => s.withAllLibraries(on: on));

  /// 恢复默认设置
  Future<void> resetToDefaults() async {
    await _store.save(AppSettings.defaults);
    state = const AsyncData(AppSettings.defaults);
  }

  /// 统一的"改一项 → 落盘 → 刷新 state"。
  ///
  /// 先更新 state 再落盘：UI 立刻响应，不等磁盘。
  /// 落盘失败时只打日志——设置写不进去也不该让界面卡住或报错打断用户。
  Future<void> _update(AppSettings Function(AppSettings) change) async {
    final current = state.valueOrNull ?? AppSettings.defaults;
    final next = change(current);
    state = AsyncData(next);
    try {
      await _store.save(next);
    } catch (e) {
      debugPrint('[Settings] 保存设置失败：$e');
    }
  }
}

/// 应用设置 provider。
final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// 主题模式（从设置里取，未加载完时跟随系统）。
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.themeMode ??
      AppSettings.defaults.themeMode;
});

/// 代码字号（从设置里取，未加载完时用默认值）。
final codeFontSizeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.codeFontSize ??
      AppSettings.defaults.codeFontSize;
});

/// 首页"仅显示本型号支持的外设"开关（从设置里取）。
final onlySupportedProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.onlySupported ??
      AppSettings.defaults.onlySupported;
});

/// 当前启用（要显示）的函数库集合，元素是 raw 字符串
/// （`spl` / `hal` / `ll` / `reg`，见契约 §1）。
///
/// 用 `Set<String>` 而不是 `Set<LibraryKind>`：设置层不依赖 models 层，
/// 页面侧如果要 LibraryKind 可自己 `LibraryKind.fromRaw(...)` 映射。
///
/// 设置还没加载完时给"全开"——首屏不该因为读设置慢而闪一下空列表。
final enabledLibrariesProvider = Provider<Set<String>>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.enabledLibraries ??
      AppSettings.defaults.enabledLibraries;
});

/// 某个库是否要显示。`libraryVisibleProvider('hal')`。
///
/// 列表/详情/搜索页都用它做过滤，保证"关掉某个库"在一个地方定义、
/// 全站一致。family 的 key 是 raw 字符串。
final libraryVisibleProvider = Provider.family<bool, String>((ref, raw) {
  return ref.watch(enabledLibrariesProvider).contains(raw.trim().toLowerCase());
});

/// 是否有任一库可用（正常流程恒为 true，设置页用它兜住"全关"）。
final hasAnyLibraryProvider = Provider<bool>((ref) {
  return ref.watch(enabledLibrariesProvider).isNotEmpty;
});

/// 搜索是否包含内部断言宏（IS_* 共 350 个，默认不返回）。
///
/// 不持久化：这是"这次搜索要不要放宽范围"的一次性选择。
final includeInternalSymbolsProvider =
    StateProvider<bool>((ref) => false);

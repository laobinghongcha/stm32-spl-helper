/// 函数库种类（四库并行）。
///
/// App 从「只有标准库」扩成 `spl / hal / ll / reg` 四库后，同一个外设下会并存
/// `GPIO_Init`（SPL）、`HAL_GPIO_Init`（HAL）、`LL_GPIO_SetPinMode`（LL）
/// 与 `REG_GPIO_CRL`（寄存器）。凡是"按库区分"的地方——外设详情页的库切换条、
/// 函数列表行尾徽标、函数详情页的定位条、设置页的库开关——都必须以本枚举
/// 为唯一口径，禁止在别处写裸字符串 "hal"。
///
/// [ordered] 是全局固定的展示顺序（契约 §1：`spl, hal, ll, reg`），
/// 排序一律用它，不要用 `LibraryKind.values` 之外的顺序。
enum LibraryKind {
  /// 标准外设库 STM32F10x_StdPeriph_Lib V3.5.0
  spl('spl', '标准库', 'SPL'),

  /// HAL 库 STM32CubeF1
  hal('hal', 'HAL 库', 'HAL'),

  /// LL 库（与 HAL 同包）
  ll('ll', 'LL 库', 'LL'),

  /// 寄存器直驱（CMSIS 结构体 + 位定义宏）
  reg('reg', '寄存器', 'REG');

  /// JSON 里的原始字符串，也是缓存键 / 设置项的存储值
  final String raw;

  /// 中文显示名，如「标准库」
  final String labelZh;

  /// 三字母短名，用于徽标（全大写，等宽字体下宽度稳定）
  final String shortEn;

  const LibraryKind(this.raw, this.labelZh, this.shortEn);

  /// 固定展示顺序：标准库 → HAL → LL → 寄存器。
  static const List<LibraryKind> ordered = <LibraryKind>[spl, hal, ll, reg];

  /// 从 JSON 字符串解析；缺失或无法识别时回退到 [spl]。
  ///
  /// 为什么回退而不是报错：v1 数据（只有标准库）里根本没有 `library` 字段，
  /// 解析时缺字段必须当成标准库，否则老数据一条都读不出来。
  static LibraryKind fromRaw(String? raw) {
    if (raw == null || raw.isEmpty) return LibraryKind.spl;
    for (final lib in LibraryKind.values) {
      if (lib.raw == raw) return lib;
    }
    return LibraryKind.spl;
  }

  /// 从 JSON 字符串解析；无法识别时返回 null（用于区分"没写"与"写错了"）。
  static LibraryKind? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final lib in LibraryKind.values) {
      if (lib.raw == raw) return lib;
    }
    return null;
  }

  /// 从 section id 推断所属库：`GPIO@hal#sec1` → [hal]。
  ///
  /// 契约 §3 规定 section id 必须是 `<外设>@<库>#<序号>`。老数据（v1）
  /// 的 id 形如 `GPIO#sec1`，没有 `@` 段，此时返回 null 由调用方回退。
  static LibraryKind? fromSectionId(String sectionId) {
    final at = sectionId.indexOf('@');
    if (at < 0) return null;
    final hash = sectionId.indexOf('#', at + 1);
    final raw = hash < 0
        ? sectionId.substring(at + 1)
        : sectionId.substring(at + 1, hash);
    return tryParse(raw);
  }

  /// 在 [ordered] 里的序号，越小越靠前（排序用）。
  int get orderIndex => ordered.indexOf(this);
}

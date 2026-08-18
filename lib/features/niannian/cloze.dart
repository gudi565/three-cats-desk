/// Cloze 填空卡渲染与解析（C2，Anki 机制三猫版，2026-08-17）。
///
/// Anki 的 cloze：`{{c1::文字}}` 语法，同一段文字的多个挖空各生成一张卡（siblings）。
/// 三猫 v1 简化：一个挖空一张卡（卖家产卡时控制），但完整支持渲染。
class Cloze {
  Cloze._();

  static final _clozeRe = RegExp(r'\{\{c(\d+)::(.+?)\}\}');

  /// front 里的挖空是否合法（至少一个 {{cN::…}}）。
  static bool isValid(String front) => _clozeRe.hasMatch(front);

  /// 正面显示：挖空处替换为 [… цвета]（下划线占位）。
  static String renderFront(String front) {
    return front.replaceAllMapped(_clozeRe, (m) => '［……］');
  }

  /// 背面显示：完整原文 + 被挖词高亮标记（**加粗**，Markdown 友好）。
  static String renderBack(String front) {
    return front.replaceAllMapped(
        _clozeRe, (m) => '**${m.group(2)}**');
  }

  /// 提取全部挖空词（评分提示/统计用）。
  static List<String> answers(String front) => [
        for (final m in _clozeRe.allMatches(front)) m.group(2)!,
      ];
}

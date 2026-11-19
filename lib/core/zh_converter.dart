import 'package:pure_music/core/zh_converter_data.dart';

/// 简繁转换工具
/// 使用字符映射表实现繁体->简体和简体->繁体的转换
/// 适用于歌词文本与搜索文本的简繁转换
class ZhConverter {
  static const Map<String, String> _tradToSimple = zhTradToSimpleData;

  static final Map<String, String> _simpleToTrad = _buildReverseMap();

  static Map<String, String> _buildReverseMap() {
    final map = <String, String>{};
    for (final entry in _tradToSimple.entries) {
      // const map 字面量保序，顺序即 OpenCC 数据文件顺序；同一简体字只取
      // 第一个遇到的繁体，避免末位候选覆盖后影响简转繁首选。
      map.putIfAbsent(entry.value, () => entry.key);
    }
    return map;
  }

  static String toSimple(String text) {
    if (text.isEmpty) return text;
    final buffer = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      buffer.write(_tradToSimple[char] ?? char);
    }
    return buffer.toString();
  }

  static String toTraditional(String text) {
    if (text.isEmpty) return text;
    final buffer = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      buffer.write(_simpleToTrad[char] ?? char);
    }
    return buffer.toString();
  }

  static String convert(String text, ZhConversionMode mode) {
    return switch (mode) {
      ZhConversionMode.none => text,
      ZhConversionMode.traditionalToSimplified => toSimple(text),
      ZhConversionMode.simplifiedToTraditional => toTraditional(text),
    };
  }
}

enum ZhConversionMode {
  none,
  traditionalToSimplified,
  simplifiedToTraditional,
}

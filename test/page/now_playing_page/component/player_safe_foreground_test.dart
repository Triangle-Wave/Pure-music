import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/mesh_gradient_background.dart';

void main() {
  test('empty palette keeps the foreground unchanged', () {
    const foreground = Color(0xFF7E57C2);
    expect(
      resolvePlayerSafeForeground(
        foreground: foreground,
        palette: const [],
        brightness: Brightness.light,
      ),
      foreground,
    );
  });

  test('readable foreground is kept unchanged', () {
    expect(
      resolvePlayerSafeForeground(
        foreground: Colors.black,
        palette: const [Color(0xFFF2D9E8)],
        brightness: Brightness.light,
      ),
      Colors.black,
    );
  });

  test('weak contrast uses a minimal Color.lerp blend', () {
    const foreground = Color(0xFF9C4DA5);
    final result = resolvePlayerSafeForeground(
      foreground: foreground,
      palette: const [Color(0xFFEFD3E4)],
      brightness: Brightness.light,
    );
    expect(result, isNot(foreground));
    final candidates = [
      for (var step = 1; step <= 32; step++)
        Color.lerp(foreground, Colors.black, step / 32)!,
      for (var step = 1; step <= 32; step++)
        Color.lerp(foreground, Colors.white, step / 32)!,
    ];
    expect(candidates, contains(result));
  });
}

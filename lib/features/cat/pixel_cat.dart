import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cat_provider.dart';

/// 程序化 8-bit 像素猫（Phase 1a）。
///
/// 设计依据：06_UI设计素材/猫互动系统设计.md 方案 C（PixelCatView）。
/// 用 CustomPainter + 网格像素矩阵画猫，零外部资源、零新依赖。
/// 按 CatMood 切表情/动画：idle 呼吸、happy 跳+心、sleepy 飘 zZ、thinking 歪头、encouraging 心。
///
/// 1a 只做「能看见猫在动、复习后心情变化」这一最小反馈，不做撸猫/喂猫交互（留 1b）。
/// reduceMotion 友好：动画都很短（呼吸 1.6s / 跳 400ms），无剧烈闪烁。
class PixelCat extends StatefulWidget {
  final CatMood mood;
  final double size; // 猫占的逻辑像素边长
  final Color? accent; // 5 猫 5 色；念念默认青蓝

  const PixelCat({
    super.key,
    required this.mood,
    this.size = 96,
    this.accent,
  });

  @override
  State<PixelCat> createState() => _PixelCatState();
}

class _PixelCatState extends State<PixelCat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value; // 0..1 ping-pong
        // happy：上下小幅跳动；其它：呼吸缩放。
        final isHappy = widget.mood == CatMood.happy ||
            widget.mood == CatMood.encouraging;
        final dy = isHappy ? -math.sin(t * math.pi) * widget.size * 0.06 : 0.0;
        final scale = isHappy
            ? 1.0
            : 1.0 + math.sin(t * math.pi) * 0.03; // 呼吸 ±3%
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale,
            child: CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _PixelCatPainter(
                mood: widget.mood,
                accent: widget.accent ?? const Color(0xFF3E8EAA),
                blink: t > 0.94, // 偶发眨眼
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 像素猫画师。用 13×13 网格定义身体像素，再叠表情。
class _PixelCatPainter extends CustomPainter {
  final CatMood mood;
  final Color accent;
  final bool blink;

  _PixelCatPainter({
    required this.mood,
    required this.accent,
    required this.blink,
  });

  // 13×13 网格。1=身体(accent)，2=耳廓深色，3=眼，4=鼻/嘴，0=空。
  // 这是只坐着的猫，正面。
  static const _body = <List<int>>[
    //        0  1  2  3  4  5  6  7  8  9 10 11 12
    [0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0], // 0 耳尖
    [0, 0, 0, 0, 2, 1, 2, 0, 2, 1, 2, 0, 0], // 1 耳
    [0, 0, 0, 0, 2, 1, 1, 1, 1, 1, 2, 0, 0], // 2 耳基/头顶
    [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0], // 3 头宽
    [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], // 4
    [0, 1, 3, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1], // 5 眼行
    [0, 1, 1, 1, 1, 1, 4, 1, 1, 1, 1, 1, 1], // 6 鼻行
    [0, 1, 1, 1, 1, 4, 4, 4, 1, 1, 1, 1, 1], // 7 嘴行
    [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0], // 8 下巴
    [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0], // 9 身上
    [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0], // 10 身
    [0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0], // 11 腿缝
    [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0], // 12 脚
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final grid = _body.length; // 13
    final px = size.width / grid;
    // 像素之间留 1px 缝营造 8-bit 锯齿感。
    final pixel = Rect.fromLTWH(0, 0, px * 0.92, px * 0.92);
    final dark = _darken(accent, 0.32);
    final eyeColor = const Color(0xFF1B1B2F);
    final mouthColor = const Color(0xFFD65A7A);

    // 思考态：整体歪头（绕中心旋转 6°）。
    canvas.save();
    if (mood == CatMood.thinking) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate(0.1);
      canvas.translate(-size.width / 2, -size.height / 2);
    }

    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < grid; x++) {
        final v = _body[y][x];
        if (v == 0) continue;
        final paint = Paint()..color = _colorFor(v, accent, dark, eyeColor, mouthColor);
        canvas.drawRect(pixel.shift(Offset(x * px + px * 0.04, y * px + px * 0.04)), paint);
      }
    }

    // 眨眼：在眼行(5)盖一层 accent 把眼盖掉，留一条横线。
    if (blink) {
      final eyeRow = 5;
      final paint = Paint()..color = accent;
      for (final ex in [1, 10]) {
        canvas.drawRect(
          pixel.shift(Offset(ex * px + px * 0.04, eyeRow * px + px * 0.04 + px * 0.3)),
          paint,
        );
      }
    }

    // 心情叠层。
    _drawMoodOverlay(canvas, size, px);
    canvas.restore();
  }

  Color _colorFor(int v, Color accent, Color dark, Color eye, Color mouth) {
    switch (v) {
      case 1:
        return accent;
      case 2:
        return dark;
      case 3:
        return eye;
      case 4:
        return mouth;
      default:
        return accent;
    }
  }

  /// 心情专属叠层：happy/encouraging 飘心、sleepy 飘 zZ。
  void _drawMoodOverlay(Canvas canvas, Size size, double px) {
    if (mood == CatMood.happy || mood == CatMood.encouraging) {
      // 右上角小心心。
      final heartPaint = Paint()..color = const Color(0xFFE0506E);
      final cx = size.width - px * 1.5;
      final cy = px * 1.5;
      _drawHeart(canvas, Offset(cx, cy), px * 0.9, heartPaint);
    } else if (mood == CatMood.sleepy) {
      // 右上角 zZ。
      final tp = TextStyle(
        fontWeight: FontWeight.w900,
        fontSize: px * 1.4,
        color: const Color(0xFF6B7A8F),
        fontFamilyFallback: const ['monospace'],
      );
      _drawText(canvas, 'z', Offset(size.width - px * 2.2, 0), tp);
      _drawText(canvas, 'Z', Offset(size.width - px * 1.0, px * 1.2),
          tp.copyWith(fontSize: px * 1.0));
    }
  }

  void _drawHeart(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path();
    path.moveTo(c.dx, c.dy + r * 0.3);
    path.cubicTo(c.dx, c.dy, c.dx - r, c.dy, c.dx - r, c.dy - r * 0.4);
    path.cubicTo(c.dx - r, c.dy - r, c.dx, c.dy - r, c.dx, c.dy - r * 0.3);
    path.cubicTo(c.dx, c.dy - r, c.dx + r, c.dy - r, c.dx + r, c.dy - r * 0.4);
    path.cubicTo(c.dx + r, c.dy, c.dx, c.dy, c.dx, c.dy + r * 0.3);
    canvas.drawPath(path, paint);
  }

  void _drawText(Canvas canvas, String s, Offset o, TextStyle style) {
    final sp = TextPainter(text: TextSpan(text: s, style: style))
      ..textDirection = TextDirection.ltr
      ..layout();
    sp.paint(canvas, o);
  }

  Color _darken(Color c, double f) {
    // dart:ui 新 API：Color 直接 .withValues 取 0..1 浮点分量。
    return c.withValues(
      red: (c.r * (1 - f)).clamp(0.0, 1.0),
      green: (c.g * (1 - f)).clamp(0.0, 1.0),
      blue: (c.b * (1 - f)).clamp(0.0, 1.0),
      alpha: c.a,
    );
  }

  @override
  bool shouldRepaint(covariant _PixelCatPainter old) =>
      old.mood != mood || old.accent != accent || old.blink != blink;
}

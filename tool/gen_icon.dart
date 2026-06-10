// dart run tool/gen_icon.dart
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

const _bg    = (r: 13,  g: 14,  b: 31);   // #0D0E1F
const _white = (r: 255, g: 255, b: 255);
const _red   = (r: 229, g: 57,  b: 53);   // #E53935

void main() {
  _save(_drawIcon(1024),       'assets/branding/icon_1024.png');
  _save(_drawForeground(1024), 'assets/branding/icon_fg_1024.png');
  // ignore: avoid_print
  print('✓ icon_1024.png\n✓ icon_fg_1024.png');
}

img.Image _drawIcon(int size) {
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: _rgb(_bg));
  _drawDesign(canvas, size);
  return canvas;
}

img.Image _drawForeground(int size) {
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));
  _drawDesign(canvas, size);
  return canvas;
}

void _drawDesign(img.Image canvas, int size) {
  final s = size / 1024.0;
  final w = _rgb(_white);
  final r = _rgb(_red);

  // ── Mic capsule (rounded rect) ─────────────────────────────────────────────
  // Rect body
  img.fillRect(
    canvas,
    x1: (392 * s).round(), y1: (300 * s).round(),
    x2: (632 * s).round(), y2: (540 * s).round(),
    color: w,
  );
  // Top cap
  img.fillCircle(canvas, x: (512 * s).round(), y: (300 * s).round(), radius: (120 * s).round(), color: w);
  // Bottom cap
  img.fillCircle(canvas, x: (512 * s).round(), y: (540 * s).round(), radius: (120 * s).round(), color: w);

  // ── Mic arc (thick arc drawn as filled circles along path) ─────────────────
  const arcCx = 512.0, arcCy = 540.0, arcR = 240.0;
  const arcThick = 26;
  for (int deg = 0; deg <= 180; deg += 2) {
    final rad = deg * math.pi / 180;
    final ax = arcCx + arcR * math.cos(math.pi - rad);
    final ay = arcCy + arcR * math.sin(math.pi - rad);
    img.fillCircle(canvas, x: (ax * s).round(), y: (ay * s).round(), radius: (arcThick * s).round(), color: w);
  }

  // ── Stem ───────────────────────────────────────────────────────────────────
  _thickLine(canvas, 512, 780, 512, 830, 26, s, w);

  // ── Base foot ──────────────────────────────────────────────────────────────
  _thickLine(canvas, 342, 830, 682, 830, 26, s, w);

  // ── Red recording dot (top-right) ──────────────────────────────────────────
  img.fillCircle(canvas, x: (726 * s).round(), y: (226 * s).round(), radius: (90 * s).round(), color: r);
}

void _thickLine(img.Image canvas, int x1, int y1, int x2, int y2, int half, double s, img.Color color) {
  final steps = math.max((x2 - x1).abs(), (y2 - y1).abs());
  for (int i = 0; i <= steps; i++) {
    final t = steps == 0 ? 0.0 : i / steps;
    final cx = (x1 + (x2 - x1) * t) * s;
    final cy = (y1 + (y2 - y1) * t) * s;
    img.fillCircle(canvas, x: cx.round(), y: cy.round(), radius: (half * s).round(), color: color);
  }
}

img.Color _rgb(({int r, int g, int b}) c) => img.ColorRgb8(c.r, c.g, c.b);
void _save(img.Image image, String path) => File(path).writeAsBytesSync(img.encodePng(image));

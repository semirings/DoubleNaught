import 'dart:typed_data';
import 'dart:ui' as ui;

/// Crops a PNG to a rectangle and re-encodes it as a PNG.
///
/// Needed because SegForge's segment cutouts are full-canvas RGBA images —
/// original pixels inside the mask, transparent everywhere else — rather than
/// sub-images. Cropping to the segment's bounding box turns one into the
/// "sub-image cutout" the Seg Forge node's `crop_bytes` column is specified to
/// hold, instead of a full-size image repeated once per segment.
///
/// Returns null when [bytes] will not decode or when [rect] does not overlap
/// the image, so callers can omit the cell rather than emit a broken one.
Future<Uint8List?> cropPng(Uint8List bytes, ui.Rect rect) async {
  ui.Image? source;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    source = (await codec.getNextFrame()).image;

    // Clamp to the image: SegForge's boxes come from model output and can sit
    // fractionally outside the canvas.
    final bounds = ui.Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    final src = rect.intersect(bounds);
    if (src.isEmpty || src.width < 1 || src.height < 1) return null;

    final width = src.width.round();
    final height = src.height.round();
    final dst = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(source, src, dst, ui.Paint());
    final cropped = await recorder.endRecording().toImage(width, height);
    try {
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      cropped.dispose();
    }
  } catch (_) {
    // A cutout that will not decode is a missing cell, not a node failure.
    return null;
  } finally {
    source?.dispose();
  }
}

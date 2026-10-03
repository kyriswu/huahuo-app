import 'dart:io';

import 'package:image/image.dart' as image;

const _defaultCrop = _Crop(left: 0, top: 177, right: 1179, bottom: 2454);
const _defaultMaeThreshold = 2.5;
const _defaultDeltaThreshold = 12.0;
const _defaultRatioThreshold = .0075;

Future<void> main(List<String> args) async {
  try {
    final options = _PixelDiffOptions.parse(args);
    if (options.showHelp) {
      stdout.writeln(_usage);
      return;
    }

    final expected = await _readImage(options.expectedPath!);
    final actual = await _readImage(options.actualPath!);
    _validateDimensions(expected, actual, options.crop);

    final metrics = _compare(expected, actual, options.crop, options.delta);
    if (options.diffOutput != null) {
      await _writeDifferenceImage(
        expected,
        actual,
        options.crop,
        options.diffOutput!,
      );
    }
    final maePassed = metrics.mae <= options.mae;
    final ratioPassed = metrics.aboveDeltaRatio <= options.ratio;

    stdout.writeln('V3 pixel diff');
    stdout.writeln('Expected: ${options.expectedPath}');
    stdout.writeln('Actual:   ${options.actualPath}');
    stdout.writeln('Size:     ${expected.width}x${expected.height}');
    stdout.writeln('Crop:     ${options.crop}');
    stdout.writeln(
      'MAE:      ${metrics.mae.toStringAsFixed(4)} '
      '(threshold <= ${options.mae.toStringAsFixed(4)})',
    );
    stdout.writeln(
      'Pixels above delta ${options.delta.toStringAsFixed(2)}: '
      '${metrics.aboveDeltaPixels}/${metrics.pixelCount} '
      '(${(metrics.aboveDeltaRatio * 100).toStringAsFixed(4)}%, '
      'threshold <= ${(options.ratio * 100).toStringAsFixed(4)}%)',
    );
    if (options.diffOutput != null) {
      stdout.writeln('Difference image: ${options.diffOutput}');
    }

    if (maePassed && ratioPassed) {
      stdout.writeln('PASS');
      return;
    }

    stderr.writeln('FAIL: visual thresholds exceeded.');
    exitCode = 1;
  } on _UsageException catch (error) {
    stderr.writeln('error: ${error.message}');
    stderr.writeln(_usage);
    exitCode = 2;
  } on FileSystemException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 2;
  }
}

Future<image.Image> _readImage(String path) async {
  final bytes = await File(path).readAsBytes();
  final decoded = image.decodeImage(bytes);
  if (decoded == null) {
    throw FormatException('Could not decode image: $path');
  }
  return decoded;
}

void _validateDimensions(image.Image expected, image.Image actual, _Crop crop) {
  if (expected.width != actual.width || expected.height != actual.height) {
    throw FormatException(
      'Image dimensions differ: expected ${expected.width}x${expected.height}, '
      'actual ${actual.width}x${actual.height}.',
    );
  }
  if (crop.left < 0 ||
      crop.top < 0 ||
      crop.right > expected.width ||
      crop.bottom > expected.height) {
    throw FormatException(
      'Crop $crop is outside ${expected.width}x${expected.height}.',
    );
  }
}

_PixelMetrics _compare(
  image.Image expected,
  image.Image actual,
  _Crop crop,
  double deltaThreshold,
) {
  var totalRgbError = 0.0;
  var aboveDeltaPixels = 0;

  for (var y = crop.top; y < crop.bottom; y++) {
    for (var x = crop.left; x < crop.right; x++) {
      final expectedPixel = expected.getPixel(x, y);
      final actualPixel = actual.getPixel(x, y);
      final redDelta = (expectedPixel.r - actualPixel.r).abs().toDouble();
      final greenDelta = (expectedPixel.g - actualPixel.g).abs().toDouble();
      final blueDelta = (expectedPixel.b - actualPixel.b).abs().toDouble();

      totalRgbError += redDelta + greenDelta + blueDelta;
      if ([redDelta, greenDelta, blueDelta].reduce(_max) > deltaThreshold) {
        aboveDeltaPixels++;
      }
    }
  }

  final pixelCount = crop.width * crop.height;
  return _PixelMetrics(
    mae: totalRgbError / (pixelCount * 3),
    aboveDeltaPixels: aboveDeltaPixels,
    pixelCount: pixelCount,
  );
}

Future<void> _writeDifferenceImage(
  image.Image expected,
  image.Image actual,
  _Crop crop,
  String outputPath,
) async {
  final difference = image.Image(
    width: crop.width,
    height: crop.height,
    numChannels: 4,
  );

  for (var y = crop.top; y < crop.bottom; y++) {
    for (var x = crop.left; x < crop.right; x++) {
      final expectedPixel = expected.getPixel(x, y);
      final actualPixel = actual.getPixel(x, y);
      final red = ((expectedPixel.r - actualPixel.r).abs() * 4)
          .clamp(0, 255)
          .toInt();
      final green = ((expectedPixel.g - actualPixel.g).abs() * 4)
          .clamp(0, 255)
          .toInt();
      final blue = ((expectedPixel.b - actualPixel.b).abs() * 4)
          .clamp(0, 255)
          .toInt();
      difference.setPixelRgba(
        x - crop.left,
        y - crop.top,
        red,
        green,
        blue,
        255,
      );
    }
  }

  final encoded = image.encodePng(difference);
  await File(outputPath).writeAsBytes(encoded, flush: true);
}

double _max(double first, double second) => first > second ? first : second;

final class _PixelMetrics {
  const _PixelMetrics({
    required this.mae,
    required this.aboveDeltaPixels,
    required this.pixelCount,
  });

  final double mae;
  final int aboveDeltaPixels;
  final int pixelCount;

  double get aboveDeltaRatio => aboveDeltaPixels / pixelCount;
}

final class _PixelDiffOptions {
  const _PixelDiffOptions({
    required this.expectedPath,
    required this.actualPath,
    required this.crop,
    required this.mae,
    required this.delta,
    required this.ratio,
    this.diffOutput,
    this.showHelp = false,
  });

  final String? expectedPath;
  final String? actualPath;
  final _Crop crop;
  final double mae;
  final double delta;
  final double ratio;
  final String? diffOutput;
  final bool showHelp;

  factory _PixelDiffOptions.parse(List<String> args) {
    if (args.contains('--help') || args.contains('-h')) {
      return const _PixelDiffOptions(
        expectedPath: null,
        actualPath: null,
        crop: _defaultCrop,
        mae: _defaultMaeThreshold,
        delta: _defaultDeltaThreshold,
        ratio: _defaultRatioThreshold,
        showHelp: true,
      );
    }

    final values = <String, String>{};
    for (var index = 0; index < args.length; index += 2) {
      final option = args[index];
      if (!const <String>{
        '--expected',
        '--actual',
        '--crop',
        '--mae',
        '--delta',
        '--ratio',
        '--diff-output',
      }.contains(option)) {
        throw _UsageException('Unknown option "$option".');
      }
      if (index + 1 >= args.length) {
        throw _UsageException('Missing value for "$option".');
      }
      if (values.containsKey(option)) {
        throw _UsageException('Option "$option" was supplied more than once.');
      }
      values[option] = args[index + 1];
    }

    final expectedPath = values['--expected'];
    final actualPath = values['--actual'];
    if (expectedPath == null || actualPath == null) {
      throw const _UsageException('Both --expected and --actual are required.');
    }

    final crop = values.containsKey('--crop')
        ? _Crop.parse(values['--crop']!)
        : _defaultCrop;
    return _PixelDiffOptions(
      expectedPath: expectedPath,
      actualPath: actualPath,
      crop: crop,
      mae: _parseNonNegativeDouble(
        values['--mae'],
        '--mae',
        _defaultMaeThreshold,
      ),
      delta: _parseNonNegativeDouble(
        values['--delta'],
        '--delta',
        _defaultDeltaThreshold,
      ),
      ratio: _parseNonNegativeDouble(
        values['--ratio'],
        '--ratio',
        _defaultRatioThreshold,
      ),
      diffOutput: values['--diff-output'],
    );
  }
}

double _parseNonNegativeDouble(String? value, String name, double fallback) {
  if (value == null) {
    return fallback;
  }
  final parsed = double.tryParse(value);
  if (parsed == null || !parsed.isFinite || parsed < 0) {
    throw _UsageException('$name must be a non-negative finite number.');
  }
  return parsed;
}

final class _Crop {
  const _Crop({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  factory _Crop.parse(String value) {
    final parts = value.split(',');
    if (parts.length != 4) {
      throw const _UsageException('--crop must be left,top,right,bottom.');
    }
    final values = <int>[];
    for (final part in parts) {
      final parsed = int.tryParse(part.trim());
      if (parsed == null) {
        throw const _UsageException('--crop values must be integers.');
      }
      values.add(parsed);
    }
    final crop = _Crop(
      left: values[0],
      top: values[1],
      right: values[2],
      bottom: values[3],
    );
    if (crop.left < 0 || crop.top < 0 || crop.width <= 0 || crop.height <= 0) {
      throw const _UsageException(
        '--crop must describe a non-empty positive rectangle.',
      );
    }
    return crop;
  }

  @override
  String toString() => '$left,$top,$right,$bottom';
}

final class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}

const _usage = '''Usage:
  dart run tool/v3_pixel_diff.dart \\
    --expected <image-path> \\
    --actual <image-path> \\
    [--crop left,top,right,bottom] \\
    [--mae 2.5] [--delta 12] [--ratio .0075] \\
    [--diff-output <image-path>]

The default crop is 0,177,1179,2454 and is interpreted as left,top,right,bottom.
MAE uses RGB channels. A pixel is above delta when any RGB channel exceeds it.''';

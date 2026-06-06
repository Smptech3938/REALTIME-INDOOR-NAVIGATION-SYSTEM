import 'dart:isolate';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

late List<CameraDescription> cams;

class NavConfig {
  static const List<String> labels = [
    "corridoor", "entrance", "room 101", "room 113", "stairs"
  ];

  static const Map<String, String> labelToNode = {
    "entrance": "A",
    "corridoor": "B",
    "room 101": "C",
    "room 113": "D",
    "stairs": "E",
    "junction": "J",
  };

  static const Map<String, Offset> coords = {
    'A': Offset(0.15, 0.55), // Entrance
    'B': Offset(0.45, 0.52), // Corridor center
    'J': Offset(0.68, 0.52), // Junction (shift slightly left)
    'C': Offset(0.68, 0.38), // Room 101 (ALIGN above J)
    'D': Offset(0.68, 0.78), // Room 113 (ALIGN below J)
    'E': Offset(0.48, 0.25), // Stairs (slightly centered)
  };

  static const Map<String, Map<String, int>> g = {
    'A': {'B': 5},              // Entrance
    'B': {'A': 5, 'E': 3, 'J': 4}, // Corridor to junction
    'J': {'B': 4, 'C': 3, 'D': 3}, // Junction splits
    'C': {'J': 3},              // Room 101 (UP)
    'D': {'J': 3},              // Room 113 (DOWN)
    'E': {'B': 3},              // Stairs
  };
}

class ImageParams {
  final int width;
  final int height;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  ImageParams({
    required this.width, required this.height,
    required this.yPlane, required this.uPlane, required this.vPlane,
    required this.yRowStride, required this.uvRowStride, required this.uvPixelStride,
  });
}

Future<List<List<List<List<double>>>>> processImageFast(ImageParams params) async {
  var inputBuffer = List.generate(
      1, (_) => List.generate(224, (_) => List.generate(224, (_) => [0.0, 0.0, 0.0])));

  double scaleX = params.width / 224.0;
  double scaleY = params.height / 224.0;

  for (int y = 0; y < 224; y++) {
    int srcY = (y * scaleY).toInt();
    for (int x = 0; x < 224; x++) {
      int srcX = (x * scaleX).toInt();
      int uvRow = srcY ~/ 2;
      int uvCol = srcX ~/ 2;
      int uvIndex = (uvRow * params.uvRowStride) + (uvCol * params.uvPixelStride);

      int yp = params.yPlane[srcY * params.yRowStride + srcX];
      int up = params.uPlane[uvIndex.clamp(0, params.uPlane.length - 1)];
      int vp = params.vPlane[uvIndex.clamp(0, params.vPlane.length - 1)];

      int r = (yp + 1.402 * (vp - 128)).round();
      int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
      int b = (yp + 1.772 * (up - 128)).round();

      inputBuffer[0][y][x][0] = r.clamp(0, 255) / 255.0;
      inputBuffer[0][y][x][1] = g.clamp(0, 255) / 255.0;
      inputBuffer[0][y][x][2] = b.clamp(0, 255) / 255.0;
    }
  }
  return inputBuffer;
}

class PredictionFilter {
  final int windowSize;
  final double confidenceThreshold;
  final Queue<String> _history = Queue<String>();

  PredictionFilter({this.windowSize = 6, this.confidenceThreshold = 0.65});

  String? getStablePrediction(String newLabel, double confidence) {
    if (confidence >= confidenceThreshold) {
      _history.addLast(newLabel);
      if (_history.length > windowSize) _history.removeFirst();
    }
    return _getMajorityLabel();
  }

  String? _getMajorityLabel() {
    if (_history.isEmpty) return null;
    final counts = <String, int>{};
    for (final label in _history) counts[label] = (counts[label] ?? 0) + 1;

    var majorityLabel = _history.last;
    var maxCount = 0;
    counts.forEach((label, count) {
      if (count > maxCount) {
        maxCount = count;
        majorityLabel = label;
      }
    });
    if (maxCount >= (windowSize / 2).ceil()) return majorityLabel;
    return null;
  }
}

class FindLocationScreen extends StatefulWidget {
  const FindLocationScreen({super.key});
  @override
  State<FindLocationScreen> createState() => _FindLocationScreenState();
}

class _FindLocationScreenState extends State<FindLocationScreen> {
  late CameraController c;
  Timer? timer;
  late Interpreter interpreter;
  bool isModelLoaded = false;
  bool isProcessing = false;
  late List outputBuffer;
  double lastConfidence = 0.0;

  late String start;
  late String end;
  List<String> path = [];

  int stableCount = 0;
  String? lastDetectedNode;
  String lastDirectionOutput = "Move Forward";
  int directionStableCount = 0;

  final PredictionFilter _predictionFilter = PredictionFilter();
  final textRecognizer = TextRecognizer();
  DateTime lastOCRRun = DateTime.now();
  bool isOCRRunning = false;
  String? ocrDetectedNode;
  int frameSkip = 0;

  Future<String> runOCR(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation90deg,
        format: InputImageFormat.yuv420,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );

    final recognizedText = await textRecognizer.processImage(inputImage);
    return recognizedText.text;
  }

  @override
  void initState() {
    super.initState();

    start = NavConfig.coords.keys.first;
    end = NavConfig.coords.keys.length > 1 ? NavConfig.coords.keys.elementAt(1) : start;
    outputBuffer = List.generate(1, (_) => List.filled(NavConfig.labels.length, 0.0));

    c = CameraController(cams.first, ResolutionPreset.low);
    Future.delayed(const Duration(milliseconds: 500), () async {
      await c.initialize();
      if (!mounted) return;
      await c.setFlashMode(FlashMode.off);
      setState(() {});

      await c.startImageStream((image) async {
        frameSkip++;
        if (frameSkip % 3 != 0) return;

        if (!isProcessing && isModelLoaded) {
          isProcessing = true;
          await runRealtimeInference(image);
          isProcessing = false;
          return;
        }

        if (isOCRRunning) return;

        final now = DateTime.now();
        if (now.difference(lastOCRRun).inMilliseconds < 2000) {
          return;
        }
        lastOCRRun = now;
        isOCRRunning = true;

        try {
          final text = await runOCR(image);
          if (text.trim().isNotEmpty) {
            print("OCR TEXT: $text");
          }

          String clean = text.toLowerCase().trim();
          String? detectedNode;

          if (clean.contains("corridoor") || clean.contains("corridor")) detectedNode = "B";
          else if (clean.contains("101")) detectedNode = "C";
          else if (clean.contains("113")) detectedNode = "D";
          else if (clean.contains("entrance") || clean.contains("main")) detectedNode = "A";
          else if (clean.contains("stairs")) detectedNode = "E";

          ocrDetectedNode = detectedNode;
        } catch (e) {
          print(e);
        }

        isOCRRunning = false;
      });
    });

    loadModel().then((_) {
      path = aStar(start, end);
    });
  }

  Future<void> loadModel() async {
    interpreter = await Interpreter.fromAsset('assets/models/best_float32.tflite');
    isModelLoaded = true;
  }

  Future<void> runRealtimeInference(CameraImage image) async {
    if (!mounted) return;

    final ImageParams params = ImageParams(
      width: image.width,
      height: image.height,
      yPlane: Uint8List.fromList(image.planes[0].bytes),
      uPlane: Uint8List.fromList(image.planes[1].bytes),
      vPlane: Uint8List.fromList(image.planes[2].bytes),
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
    );

    var remoteInputBuffer = await processImageFast(params);

    if (!mounted) return;

    interpreter.run(remoteInputBuffer, outputBuffer);

    int maxIndex = 0;
    double maxValue = outputBuffer[0][0];

    for (int i = 1; i < NavConfig.labels.length; i++) {
      if (outputBuffer[0][i] > maxValue) {
        maxValue = outputBuffer[0][i];
        maxIndex = i;
      }
    }

    String detected = NavConfig.labels[maxIndex];
    lastConfidence = maxValue;

    String? visionNode = NavConfig.labelToNode[detected];
    String? finalNode = visionNode;

    if (ocrDetectedNode != null) {
      if (ocrDetectedNode == visionNode) {
        maxValue = 0.7;
      } else if (maxValue < 0.5) {
        finalNode = ocrDetectedNode;
        maxValue = 0.5;
        lastConfidence = maxValue;
      }
    }

    if (mounted) {
      setState(() {});
    }

    String? detectedNode = finalNode;

    if (detectedNode == null || !NavConfig.g.containsKey(detectedNode)) return;

    if (lastDetectedNode == detectedNode) {
      stableCount++;
    } else {
      lastDetectedNode = detectedNode;
      stableCount = 1;
    }

    if (stableCount >= 2 && maxValue > 0.5) {
      if (mounted) {
        setState(() {
          int currentIndex = path.indexOf(start);
          int detectedIndex = path.indexOf(detectedNode!);

          if (path.contains(detectedNode)) {
            if (detectedIndex == currentIndex || detectedIndex == currentIndex + 1) {
              if (start != detectedNode) {
                start = detectedNode!;
                path = aStar(start, end);

                if (path.length > 1) {
                  lastDirectionOutput = getMappedDirection(path[0], path[1]);
                }
              }
            }
          } else if (stableCount >= 8) {
            if (start != detectedNode) {
              start = detectedNode!;
              path = aStar(start, end);

              if (path.length > 1) {
                lastDirectionOutput = getMappedDirection(path[0], path[1]);
              }
            }
          }

          String newDirection = "Finding path...";
          String current = path.isNotEmpty ? path[0] : start;
          String? next = path.length > 1 ? path[1] : null;

          if (next != null) {
            newDirection = getMappedDirection(current, next);
          }

          if (newDirection != lastDirectionOutput) {
            directionStableCount++;
            if (directionStableCount > 2) {
              lastDirectionOutput = newDirection;
            }
          } else {
            directionStableCount = 0;
          }
        });
      }
    }
  }

  String getLabelFromNode(String node) {
    return NavConfig.labelToNode.entries
        .firstWhere((e) => e.value == node,
        orElse: () => const MapEntry("", ""))
        .key;
  }

  String getMappedDirection(String current, String next) {
    if (!NavConfig.coords.containsKey(current) || !NavConfig.coords.containsKey(next)) {
      return "Move Forward";
    }

    final c = NavConfig.coords[current]!;
    final n = NavConfig.coords[next]!;

    double dx = n.dx - c.dx;
    double dy = n.dy - c.dy;

    if (dx.abs() > dy.abs()) {
      return dx > 0 ? "Turn Right" : "Turn Left";
    } else {
      return "Go Straight";
    }
  }

  String getDisplayDirection() {
    if (start == end && stableCount >= 5) {
      return "✅ Reached";
    }
    return lastDirectionOutput;
  }

  List<String> aStar(String s, String e) {
    if (s == e) return [s];
    var open = [s];
    var came = <String, String?>{};
    var gScore = {s: 0};

    while (open.isNotEmpty) {
      open.sort((a, b) => gScore[a]!.compareTo(gScore[b]!));
      var cur = open.removeAt(0);

      if (cur == e) {
        var p = [cur];
        while (came.containsKey(cur) && came[cur] != null) {
          cur = came[cur]!;
          p.insert(0, cur);
        }
        return p;
      }

      if (NavConfig.g[cur] == null) continue;

      for (final n in NavConfig.g[cur]!.keys) {
        var t = gScore[cur]! + NavConfig.g[cur]![n]!;
        if (!gScore.containsKey(n) || t < gScore[n]!) {
          came[n] = cur;
          gScore[n] = t;
          if (!open.contains(n)) open.add(n);
        }
      }
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    if (!c.value.isInitialized) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        title: const Text("Find Location"),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          CameraPreview(c),
          Container(color: Colors.black26),

          Positioned(
            top: 16, left: 16, right: 16,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.95),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
              ),
              child: Text(
                getDisplayDirection(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: const BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("📍 You are near: ${getLabelFromNode(start).replaceAll('_', ' ').toUpperCase()}",
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500)),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      const Text("Destination: ", style: TextStyle(color: Colors.white70, fontSize: 16)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<String>(
                          dropdownColor: Colors.black87,
                          isExpanded: true,
                          value: end,
                          items: NavConfig.coords.keys.where((n) => n != 'J').map((n) =>
                              DropdownMenuItem(value: n,
                                  child: Text(getLabelFromNode(n).replaceAll('_', ' ').toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)))
                          ).toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setState(() {
                                end = v;
                                path = aStar(start, end);
                                directionStableCount = 0;
                                if (start != end && path.length > 1) {
                                  lastDirectionOutput = getMappedDirection(start, path[1]);
                                } else {
                                  lastDirectionOutput = "✅ Reached";
                                }
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    try {
      if (c.value.isStreamingImages) {
        c.stopImageStream();
      }
    } catch (e) {}
    c.dispose();
    interpreter.close();
    textRecognizer.close();
    super.dispose();
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'find_location_screen.dart'; // To access NavConfig

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  String start = NavConfig.coords.keys.first;
  String end = NavConfig.coords.keys.last;
  List<String> path = [];

  @override
  void initState() {
    super.initState();
    path = _aStar(start, end);
  }

  List<String> _aStar(String s, String e) {
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

  String _getLabelFromNode(String node) {
    return NavConfig.labelToNode.entries
        .firstWhere((e) => e.value == node, orElse: () => const MapEntry("", ""))
        .key;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Floor Map"),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black, // Sleek dark mode map background
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              boundaryMargin: const EdgeInsets.all(100),
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 🖼 Floor plan (dark styled)
                    Opacity(
                      opacity: 0.9,
                      child: ColorFiltered(
                        colorFilter: const ColorFilter.mode(
                          Colors.black26,
                          BlendMode.darken,
                        ),
                        child: SvgPicture.asset(
                          "assets/maps/floor.svg",
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    // 🧭 Overlay (your existing painter)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: MapPainter(
                          path: path,
                          start: start,
                          end: end,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Colors.white12, blurRadius: 10)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text("Start: ", style: TextStyle(color: Colors.white70, fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<String>(
                        dropdownColor: Colors.black87,
                        isExpanded: true,
                        value: start,
                        items: NavConfig.coords.keys.where((n) => n != 'J').map((n) => DropdownMenuItem(
                            value: n,
                            child: Text(_getLabelFromNode(n).replaceAll('_', ' ').toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              start = v;
                              path = _aStar(start, end);
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text("End: ", style: TextStyle(color: Colors.white70, fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButton<String>(
                        dropdownColor: Colors.black87,
                        isExpanded: true,
                        value: end,
                        items: NavConfig.coords.keys.where((n) => n != 'J').map((n) => DropdownMenuItem(
                            value: n,
                            child: Text(_getLabelFromNode(n).replaceAll('_', ' ').toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              end = v;
                              path = _aStar(start, end);
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}

class MapPainter extends CustomPainter {
  final List<String> path;
  final String start;
  final String end;

  MapPainter({required this.path, required this.start, required this.end});

  String getLabel(String node) {
    return NavConfig.labelToNode.entries
        .firstWhere((e) => e.value == node,
        orElse: () => MapEntry(node, ""))
        .key
        .replaceAll("_", " ");
  }

  Offset getScaled(Offset p, Size size) {
    return Offset(p.dx * size.width, p.dy * size.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    final pathPaint = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final defaultNodePaint = Paint()..color = Colors.blueAccent..style = PaintingStyle.fill;
    final startNodePaint = Paint()..color = Colors.greenAccent..style = PaintingStyle.fill;
    final endNodePaint = Paint()..color = Colors.redAccent..style = PaintingStyle.fill;
    final pathNodePaint = Paint()..color = Colors.cyanAccent..style = PaintingStyle.fill;

    // 1. Draw all edges
    for (var node in NavConfig.g.keys) {
      if (!NavConfig.coords.containsKey(node)) continue;
      final startOffset = getScaled(NavConfig.coords[node]!, size);
      for (var neighbor in NavConfig.g[node]!.keys) {
        if (!NavConfig.coords.containsKey(neighbor)) continue;
        final endOffset = getScaled(NavConfig.coords[neighbor]!, size);
        canvas.drawLine(startOffset, endOffset, edgePaint);
      }
    }

    // 2. Draw active path
    if (path.length > 1) {
      for (int i = 0; i < path.length - 1; i++) {
        final p1 = NavConfig.coords[path[i]];
        final p2 = NavConfig.coords[path[i + 1]];
        if (p1 != null && p2 != null) {
          canvas.drawLine(getScaled(p1, size), getScaled(p2, size), pathPaint);
        }
      }
    }

    // 3. Draw nodes
    for (var node in NavConfig.coords.keys) {
      final offset = getScaled(NavConfig.coords[node]!, size);
      bool isPathNode = path.contains(node);

      Paint currentPaint = defaultNodePaint;
      double currentRadius = 8;

      if (node == start) {
        currentPaint = startNodePaint;
        currentRadius = 12;
      } else if (node == end) {
        currentPaint = endNodePaint;
        currentRadius = 12;
      } else if (isPathNode) {
        currentPaint = pathNodePaint;
        currentRadius = 10;
      }

      canvas.drawCircle(offset, currentRadius, currentPaint);

      // Draw node label (skip for internal junction)
      if (node != 'J') {
        var textPainter = TextPainter(
          text: TextSpan(
            text: getLabel(node).toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
        );

        textPainter.layout(maxWidth: 80);
        textPainter.paint(
          canvas,
          Offset(offset.dx - 30, offset.dy + 12),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.path != path || oldDelegate.start != start || oldDelegate.end != end;
  }
}

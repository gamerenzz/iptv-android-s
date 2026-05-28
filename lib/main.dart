import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';
import 'dart:async';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: IPTVTesterHome(),
  ));
}

class Channel {
  String name;
  String url;
  String status;
  String delay;
  String resolution;
  String sourceName;

  Channel({
    required this.name,
    required this.url,
    required this.sourceName,
    this.status = "待测",
    this.delay = "-",
    this.resolution = "-",
  });
}

class IPTVTesterHome extends StatefulWidget {
  const IPTVTesterHome({super.key});

  @override
  State<IPTVTesterHome> createState() => _IPTVTesterHomeState();
}

class _IPTVTesterHomeState extends State<IPTVTesterHome> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _filterController = TextEditingController();
  final TextEditingController _delayController = TextEditingController();

  List<Channel> _allChannels = [];
  List<Channel> _visibleChannels = [];

  bool _isDownloading = false;
  bool _isTesting = false;

  String _statusText = "等待导入数据...";
  String _selectedSourceInfo = "尚未选中任何频道";

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadSavedUrls();
  }

  Future<void> _loadSavedUrls() async {
    final prefs = await SharedPreferences.getInstance();

    String? saved = prefs.getString("saved_urls");

    if (saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    } else {
      _urlController.text =
          "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u";
    }
  }

  Future<void> _saveUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("saved_urls", _urlController.text);
  }

  Future<void> _startBatchDownload() async {
    if (_isDownloading) return;

    await _saveUrls();

    setState(() {
      _isDownloading = true;
      _statusText = "开始下载...";
      _allChannels.clear();
      _visibleChannels.clear();
    });

    List<String> urls = _urlController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith("http"))
        .toSet()
        .toList();

    if (urls.isEmpty) {
      setState(() {
        _isDownloading = false;
        _statusText = "没有有效URL";
      });
      return;
    }

    int success = 0;

    final directory = await getTemporaryDirectory();

    List<Future> tasks = [];

    for (String url in urls) {
      tasks.add(_downloadSingle(url, directory.path).then((ok) {
        if (ok) success++;
      }));
    }

    await Future.wait(tasks);

    setState(() {
      _visibleChannels = List.from(_allChannels);

      _isDownloading = false;

      _statusText =
          "下载完成 成功 $success/${urls.length} 频道 ${_allChannels.length}";
    });
  }

  Future<bool> _downloadSingle(String url, String dir) async {
    try {
      final uri = Uri.parse(url);

      final response = await http.get(
        uri,
        headers: {
          "User-Agent": "Mozilla/5.0",
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return false;
      }

      String fileName =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : "playlist.m3u";

      String path = "$dir/$fileName";

      final file = File(path);

      await file.writeAsBytes(response.bodyBytes);

      _parseFile(response.body, fileName);

      return true;
    } catch (_) {
      return false;
    }
  }

  void _parseFile(String content, String sourceName) {
    List<String> lines = content.split('\n');

    String tempName = "未知频道";

    for (String line in lines) {
      line = line.trim();

      if (line.startsWith("#EXTINF")) {
        final match = RegExp(r',([^,]+)$').firstMatch(line);

        if (match != null) {
          tempName = match.group(1)!.trim();
        }
      } else if (line.isNotEmpty && !line.startsWith("#")) {
        if (line.contains(",")) {
          List<String> parts = line.split(",");

          if (parts.length >= 2) {
            _allChannels.add(
              Channel(
                name: parts[0].trim(),
                url: parts[1].trim(),
                sourceName: sourceName,
              ),
            );
          }
        } else {
          _allChannels.add(
            Channel(
              name: tempName,
              url: line,
              sourceName: sourceName,
            ),
          );

          tempName = "未知频道";
        }
      }
    }
  }

  void _onFilterChanged() {
    _debounce?.cancel();

    _debounce = Timer(
      const Duration(milliseconds: 300),
      _applyFilter,
    );
  }

  void _applyFilter() {
    String kw = _filterController.text.trim();

    int? maxDelay = int.tryParse(_delayController.text.trim());

    List<String> keywords = kw
        .split(RegExp(r'[,，\s]+'))
        .map(normalizeText)
        .where((e) => e.isNotEmpty)
        .toList();

    setState(() {
      _visibleChannels = _allChannels.where((ch) {
        bool textMatch = true;

        if (keywords.isNotEmpty) {
          textMatch = keywords.any(
            (k) => normalizeText(ch.name).contains(k),
          );
        }

        bool delayMatch = true;

        if (maxDelay != null) {
          if (ch.status != "在线") {
            delayMatch = false;
          } else {
            int? d = int.tryParse(ch.delay);

            if (d == null || d > maxDelay) {
              delayMatch = false;
            }
          }
        }

        return textMatch && delayMatch;
      }).toList();

      _statusText = "筛选 ${_visibleChannels.length} 个频道";
    });
  }

  String normalizeText(String text) {
    text = text.toLowerCase();

    text = text.replaceAll(
      RegExp(r'[\s\-_#\[\]\(\)（）【】]'),
      '',
    );

    return text;
  }

  Future<void> _startTest() async {
    if (_isTesting || _visibleChannels.isEmpty) return;

    setState(() {
      _isTesting = true;
      _statusText = "开始测速...";
    });

    const concurrency = 10;

    List<Channel> targets = List.from(_visibleChannels);

    for (int i = 0; i < targets.length; i += concurrency) {
      if (!_isTesting) break;

      int end = (i + concurrency < targets.length)
          ? i + concurrency
          : targets.length;

      List<Future> futures = [];

      for (int j = i; j < end; j++) {
        futures.add(_testSingleChannel(targets[j]));
      }

      await Future.wait(futures);

      setState(() {});
    }

    setState(() {
      _isTesting = false;
      _statusText = "测速完成";
    });
  }

  Future<void> _testSingleChannel(Channel ch) async {
    Stopwatch sw = Stopwatch()..start();

    try {
      final client = HttpClient();

      client.connectionTimeout = const Duration(seconds: 3);

      final request = await client.getUrl(Uri.parse(ch.url));

      request.headers.set("User-Agent", "Mozilla/5.0");

      final response = await request.close();

      sw.stop();

      ch.delay = sw.elapsedMilliseconds.toString();

      if (response.statusCode == 200) {
        ch.status = "在线";

        ch.resolution = await _detectResolution(ch.url);
      } else {
        ch.status = "HTTP ${response.statusCode}";
      }

      client.close();
    } catch (_) {
      ch.status = "离线";
    }
  }

  Future<String> _detectResolution(String url) async {
    try {
      if (!url.toLowerCase().contains(".m3u8")) {
        return "未知";
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {
          "User-Agent": "Mozilla/5.0",
        },
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode != 200) {
        return "未知";
      }

      String body = response.body;

      final match = RegExp(
        r'RESOLUTION=(\d+)x(\d+)',
      ).firstMatch(body);

      if (match == null) {
        return "未知";
      }

      int width = int.parse(match.group(1)!);
      int height = int.parse(match.group(2)!);

      String res = "${width}x$height";

      if (height >= 1080) {
        return "1080p ($res)";
      }

      if (height >= 720) {
        return "720p ($res)";
      }

      return "标清 ($res)";
    } catch (_) {
      return "未知";
    }
  }

  void _copyUrl(Channel ch) {
    Clipboard.setData(
      ClipboardData(text: ch.url),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("已复制 ${ch.name}"),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _clearFilterText() {
    _filterController.clear();

    _delayController.clear();

    _applyFilter();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("IPTV测速工具"),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _urlController,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "每行一个M3U地址",
              ),
            ),
          ),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _startBatchDownload,
                child: const Text("下载导入"),
              ),
              ElevatedButton(
                onPressed: _startTest,
                child: const Text("开始测速"),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isTesting = false;
                  });
                },
                child: const Text("停止"),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filterController,
                    onChanged: (_) => _onFilterChanged(),
                    decoration: const InputDecoration(
                      hintText: "关键词过滤",
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _delayController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _onFilterChanged(),
                    decoration: const InputDecoration(
                      hintText: "最大延迟",
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _clearFilterText,
                  icon: const Icon(Icons.refresh),
                )
              ],
            ),
          ),

          Container(
            width: double.infinity,
            color: Colors.grey[200],
            padding: const EdgeInsets.all(8),
            child: Text(
              _statusText,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          Expanded(
            child: ListView.builder(
              itemCount: _visibleChannels.length > 500
                  ? 500
                  : _visibleChannels.length,
              itemBuilder: (context, index) {
                final ch = _visibleChannels[index];

                return GestureDetector(
                  onDoubleTap: () => _copyUrl(ch),
                  onTap: () {
                    setState(() {
                      _selectedSourceInfo = ch.sourceName;
                    });
                  },
                  child: Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  ch.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                ch.sourceName,
                                style: const TextStyle(
                                  color: Colors.blue,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 4),

                          Text(
                            ch.url,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),

                          const SizedBox(height: 4),

                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "状态:${ch.status}",
                                style: TextStyle(
                                  color: ch.status == "在线"
                                      ? Colors.green
                                      : Colors.red,
                                ),
                              ),
                              Text("延迟:${ch.delay}ms"),
                              Text("分辨率:${ch.resolution}"),
                            ],
                          )
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          Container(
            width: double.infinity,
            color: Colors.blue[50],
            padding: const EdgeInsets.all(8),
            child: Text(
              "来源: $_selectedSourceInfo",
              style: const TextStyle(
                color: Colors.blue,
                fontWeight: FontWeight.bold,
              ),
            ),
          )
        ],
      ),
    );
  }
}

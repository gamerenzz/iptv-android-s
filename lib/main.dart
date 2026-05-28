import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 导入官方标准的 FFprobe 接口
import 'package:ffmpeg_kit_flutter_full_gpl/ffprobe_kit.dart';

import 'dart:io';
import 'dart:async';
import 'dart:convert';

// --- 全局忽略 SSL 证书错误 ---
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  HttpOverrides.global = MyHttpOverrides();

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
  bool isSelected;

  Channel({
    required this.name,
    required this.url,
    required this.sourceName,
    this.status = "待测",
    this.delay = "-",
    this.resolution = "-",
    this.isSelected = true, // 导入默认勾选
  });
}

enum SortType {
  none,
  name,
  delay,
  resolution,
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
  final List<String> _logs = [];

  bool _isDownloading = false;
  bool _isTesting = false;

  String _statusText = "等待导入数据...";
  String _selectedSourceInfo = "尚未选中频道";

  Timer? _debounce;

  SortType _currentSort = SortType.none;
  bool _isAscending = true;

  // 限制同时最多只有 2 个原生 FFprobe 核心在后台解析视频，防止发热或卡死
  final SimpleSemaphore _resSemaphore = SimpleSemaphore(2); 

  @override
  void initState() {
    super.initState();
    _loadSavedUrls();
    _addLog("系统初始化完成 (原生 FFmpeg 画质探测版)");
  }

  void _addLog(String msg) {
    setState(() {
      String time =
          DateTime.now().toLocal().toString().substring(11, 19);
      _logs.insert(0, "[$time] $msg");
      if (_logs.length > 80) {
        _logs.removeLast();
      }
    });
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
      _statusText = "开始强制下载...";
      _allChannels.clear();
      _visibleChannels.clear();
      _logs.clear();
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
      _addLog("错误: 没有读取到有效的链接");
      return;
    }

    _addLog("准备并发强制下载 ${urls.length} 个链接");
    int success = 0;
    final directory = await getTemporaryDirectory();
    List<Future> tasks = [];

    for (String url in urls) {
      tasks.add(
        _downloadSingle(url, directory.path).then((ok) {
          if (ok) success++;
        }),
      );
    }

    await Future.wait(tasks);

    setState(() {
      _visibleChannels = List.from(_allChannels);
      _applySort();
      _isDownloading = false;
      _statusText =
          "下载完成 成功 $success/${urls.length} 共 ${_allChannels.length} 个频道";
    });
    _addLog("下载任务结束");
  }

  Future<bool> _downloadSingle(String url, String dir) async {
    _addLog("-> 请求: $url");
    try {
      final uri = Uri.parse(url);
      final response = await http.get(
        uri,
        headers: {
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
          "Cache-Control": "no-cache", 
          "Pragma": "no-cache"
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        _addLog("<- 失败 HTTP ${response.statusCode}");
        return false;
      }

      String fileName =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : "playlist.m3u";

      final file = File("$dir/$fileName");
      await file.writeAsBytes(response.bodyBytes);
      _parseFile(response.body, fileName);
      _addLog("<- 成功导入: $fileName");
      return true;
    } catch (e) {
      _addLog("<- 异常: ${e.toString().split(':').last}");
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
    _debounce = Timer(const Duration(milliseconds: 300), _applyFilter);
  }

  void _applyFilter() {
    String kw = _filterController.text.trim();
    int? maxDelay = int.tryParse(_delayController.text.trim());
    List<String> keywords = kw.split(RegExp(r'[,，\s]+')).map(normalizeText).where((e) => e.isNotEmpty).toList();

    setState(() {
      _visibleChannels = _allChannels.where((ch) {
        bool textMatch = true;
        if (keywords.isNotEmpty) {
          textMatch = keywords.any((k) => normalizeText(ch.name).contains(k));
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

      _applySort();
      _statusText = "筛选 ${_visibleChannels.length} 个频道";
    });
  }

  String normalizeText(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[\s\-_#\[\]\(\)（）【】]'), '');
  }

  void _triggerSort(SortType type) {
    setState(() {
      if (_currentSort == type) {
        _isAscending = !_isAscending;
      } else {
        _currentSort = type;
        _isAscending = true;
      }
      _applySort();
    });
  }

  void _applySort() {
    if (_currentSort == SortType.none) return;

    _visibleChannels.sort((a, b) {
      int result = 0;
      if (_currentSort == SortType.name) {
        result = a.name.compareTo(b.name);
      } else if (_currentSort == SortType.delay) {
        int delayA = int.tryParse(a.delay) ?? (_isAscending ? 999999 : -1);
        int delayB = int.tryParse(b.delay) ?? (_isAscending ? 999999 : -1);
        result = delayA.compareTo(delayB);
      } else if (_currentSort == SortType.resolution) {
        int resA = _parseResValue(a.resolution);
        int resB = _parseResValue(b.resolution);
        result = resA.compareTo(resB);
      }
      return _isAscending ? result : -result;
    });
  }

  int _parseResValue(String res) {
    if (res.contains("4K")) return 2160;
    final match = RegExp(r'(\d+)p').firstMatch(res);
    if (match != null) {
      return int.tryParse(match.group(1) ?? "0") ?? 0;
    }
    if (res.contains("标清")) return 480;
    return 0;
  }

  String _getSortIcon(SortType type) {
    if (_currentSort != type) return "";
    return _isAscending ? " ▲" : " ▼";
  }

  void _selectAll(bool select) {
    setState(() {
      for (var ch in _visibleChannels) {
        ch.isSelected = select;
      }
    });
  }

  void _deleteSelected() {
    setState(() {
      _allChannels.removeWhere((ch) => ch.isSelected);
      _applyFilter();
    });
    _addLog("已删除选中的频道");
  }

  // --- 联动重构：支持毫秒级进度显示的并发测速 ---
  Future<void> _startTest() async {
    List<Channel> targets = _visibleChannels.where((ch) => ch.isSelected).toList();
    if (_isTesting || targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先勾选需要测速的频道")));
      return;
    }

    int total = targets.length;
    int tested = 0;

    setState(() {
      _isTesting = true;
      _statusText = "测速进度: 0 / $total";
    });
    _addLog("开始并发测速（已启用302自适应重定向和1KB极速缓存解析）");

    // 用于封装并执行单个渠道任务，执行完后立刻原子级增加已测数，并在UI上实现毫秒级进度刷新
    Future<void> _runWithProgress(Channel ch) async {
      await _testSingleChannel(ch);
      tested++;
      setState(() {
        _statusText = "测速中: $tested / $total";
      });
    }

    const concurrency = 25; // 并发 25 线程测速
    for (int i = 0; i < targets.length; i += concurrency) {
      if (!_isTesting) {
        _addLog("测速任务已被手动停止");
        break;
      }
      int end = (i + concurrency < targets.length) ? i + concurrency : targets.length;
      List<Future> futures = [];
      for (int j = i; j < end; j++) {
        futures.add(_runWithProgress(targets[j])); // 运行带有即时状态回传的任务
      }
      await Future.wait(futures);
      setState(() => _applySort());
    }

    setState(() {
      _isTesting = false;
      _statusText = "测速完成，共测速 $tested 个频道";
    });
  }

  Future<void> _testSingleChannel(Channel ch) async {
    Stopwatch sw = Stopwatch()..start();
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 4);

      final request = await client.getUrl(Uri.parse(ch.url));
      request.headers.set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
      request.headers.set("Range", "bytes=0-1023"); // 1KB 截断限制

      final response = await request.close();
      List<int> bytes = [];

      await for (var chunk in response.timeout(const Duration(seconds: 4))) {
        bytes.addAll(chunk);
        if (bytes.length >= 1024) break;
      }

      sw.stop();
      ch.delay = sw.elapsedMilliseconds.toString();

      if (response.statusCode == 200 || response.statusCode == 206) {
        ch.status = "在线";
        
        // --- 核心：多线程信号量限制。只有测速成功在线的，才排队进入原生 FFprobe 深度探测画质（同时最多 2 个） ---
        await _resSemaphore.acquire();
        try {
          ch.resolution = await _detectResolutionNative(ch.url);
        } finally {
          _resSemaphore.release();
        }
      } else {
        ch.status = "HTTP ${response.statusCode}";
        ch.delay = "-";
        ch.resolution = "-";
      }
    } catch (_) {
      ch.status = "离线";
      ch.delay = "-";
      ch.resolution = "-";
    } finally {
      client?.close(force: true);
    }
  }

  // --- 调用原生平台 FFprobe 极速探测分辨率 ---
  Future<String> _detectResolutionNative(String url) async {
    try {
      String targetUrl = url;
      // 智能无后缀暗示
      if (!url.toLowerCase().contains(".m3u8") && !url.toLowerCase().contains(".ts")) {
        targetUrl = "$url#.m3u8";
      }

      // 在后台静默运行 FFprobe，限制 probesize 为 150KB 以内，分析时间限制在 1 秒以内
      final session = await FFprobeKit.execute(
        "-v error -user_agent 'Mozilla/5.0' -probesize 150000 -analyzeduration 1000000 -allowed_extensions ALL -protocol_whitelist 'file,http,https,tcp,tls,crypto' -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 '$targetUrl'"
      );
      
      final output = await session.getOutput();
      if (output != null && output.trim().isNotEmpty) {
        final match = RegExp(r'(\d+)x(\d+)').firstMatch(output);
        if (match != null) {
          int width = int.parse(match.group(1)!);
          int height = int.parse(match.group(2)!);
          String resStr = "${width}x$height";
          
          if (height >= 2160) return "4K ($resStr)";
          if (height >= 1080) return "1080p ($resStr)";
          if (height >= 720) return "720p ($resStr)";
          return "标清 ($resStr)";
        }
      }
    } catch (_) {}
    return "未知";
  }

  void _copyUrl(String url, String name) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已复制 $name"), duration: const Duration(seconds: 1)),
    );
  }

  void _copyAllLogs() {
    Clipboard.setData(ClipboardData(text: _logs.join("\n")));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("已复制所有调试日志"), duration: const Duration(seconds: 1)),
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
        title: const Text("IPTV 测速工具 (FFmpeg终极版)", style: TextStyle(fontSize: 18)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: TextField(
              controller: _urlController,
              maxLines: 3,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "每行一个 M3U 订阅地址",
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green[50]),
                child: const Text("开始测速", style: TextStyle(color: Colors.green)),
              ),
              ElevatedButton(
                onPressed: () => setState(() => _isTesting = false),
                child: const Text("停止"),
              ),
            ],
          ),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filterController,
                    onChanged: (_) => _onFilterChanged(),
                    decoration: const InputDecoration(hintText: "关键词过滤", isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _delayController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _onFilterChanged(),
                    decoration: const InputDecoration(hintText: "限迟", isDense: true),
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
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => _selectAll(true),
                  style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 4)),
                  child: const Text("全选", style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () => _selectAll(false),
                  style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 4)),
                  child: const Text("反选", style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: _deleteSelected,
                  style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 4)),
                  child: const Text("删除", style: TextStyle(fontSize: 12, color: Colors.red)),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => _triggerSort(SortType.name),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Text("名称${_getSortIcon(SortType.name)}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => _triggerSort(SortType.delay),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Text("延迟${_getSortIcon(SortType.delay)}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => _triggerSort(SortType.resolution),
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Text("分辨率${_getSortIcon(SortType.resolution)}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),

          Container(
            width: double.infinity,
            color: Colors.grey[100],
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              _statusText,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),

          Expanded(
            child: ListView.builder(
              itemCount: _visibleChannels.length > 500 ? 500 : _visibleChannels.length,
              itemBuilder: (context, index) {
                final ch = _visibleChannels[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                    leading: Checkbox(
                      value: ch.isSelected,
                      onChanged: (v) {
                        setState(() {
                          ch.isSelected = v ?? false;
                        });
                      },
                    ),
                    
                    // --- 核心优化A：将来源（ch.sourceName）直接以高亮浅蓝显示在标题右侧，免去点击查看的步骤 ---
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            ch.name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          ch.sourceName,
                          style: const TextStyle(color: Colors.blue, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ch.url,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.grey, fontSize: 10),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              "状态: ${ch.status}  ",
                              style: TextStyle(
                                fontSize: 11,
                                color: ch.status == "在线" ? Colors.green : Colors.red,
                              ),
                            ),
                            Text("延迟: ${ch.delay} ms  ", style: const TextStyle(fontSize: 11)),
                            Expanded(
                              child: Text(
                                "分辨率: ${ch.resolution}",
                                style: const TextStyle(fontSize: 10, color: Colors.blueGrey),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        )
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, color: Colors.blue),
                      onPressed: () => _copyUrl(ch.url, ch.name),
                    ),
                    onTap: () {
                      setState(() {
                        _selectedSourceInfo = ch.sourceName;
                      });
                    },
                  ),
                );
              },
            ),
          ),

          ExpansionTile(
            title: const Text("调试日志面板 (点击展开)", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            collapsedBackgroundColor: Colors.grey[50],
            children: [
              Container(
                height: 120,
                width: double.infinity,
                color: Colors.black87,
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(8),
                      child: SelectableText(
                        _logs.join("\n"),
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: "monospace"),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        icon: const Icon(Icons.copy_all, color: Colors.white),
                        tooltip: "复制全部日志",
                        onPressed: _copyAllLogs,
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),

          // 底部来源
          Container(
            width: double.infinity,
            color: Colors.blue[50],
            padding: const EdgeInsets.all(6),
            child: Text(
              "当前选中频道来源: $_selectedSourceInfo",
              style: const TextStyle(color: Colors.blue, fontSize: 11, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          )
        ],
      ),
    );
  }
}

// --- 信号量类定义 ---
class SimpleSemaphore {
  final int maxConcurrent;
  int _running = 0;
  final List<Completer<void>> _queue = [];

  SimpleSemaphore(this.maxConcurrent);

  Future<void> acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    return completer.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.complete();
    } else {
      _running--;
    }
  }
}

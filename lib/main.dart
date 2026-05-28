import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';
import 'dart:async';

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
  bool isSelected; // 新增：复选框选中状态

  Channel({
    required this.name,
    required this.url,
    required this.sourceName,
    this.status = "待测",
    this.delay = "-",
    this.resolution = "-",
    this.isSelected = false,
  });
}

// 排序枚举
enum SortType { none, name, delay, resolution }

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

  // 排序状态
  SortType _currentSort = SortType.none;
  bool _isAscending = true;

  @override
  void initState() {
    super.initState();
    _loadSavedUrls();
    _addLog("系统初始化完成，已忽略 SSL 校验");
  }

  void _addLog(String msg) {
    setState(() {
      String time = DateTime.now().toLocal().toString().substring(11, 19);
      _logs.insert(0, "[$time] $msg");
      if (_logs.length > 80) _logs.removeLast();
    });
  }

  Future<void> _loadSavedUrls() async {
    final prefs = await SharedPreferences.getInstance();
    String? saved = prefs.getString("saved_urls");
    if (saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    } else {
      _urlController.text = "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u";
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

    _addLog("准备并发下载 ${urls.length} 个链接");
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
      _applySort(); // 下载完成后应用默认排序
      _isDownloading = false;
      _statusText = "下载完成 成功 $success/${urls.length}，共 ${_allChannels.length} 个频道";
    });
    _addLog("下载任务结束");
  }

  Future<bool> _downloadSingle(String url, String dir) async {
    _addLog("-> 请求: $url");
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri, headers: {"User-Agent": "Mozilla/5.0"}).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        _addLog("<- 失败 HTTP ${response.statusCode}");
        return false;
      }
      String fileName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : "playlist.m3u";
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
        if (match != null) tempName = match.group(1)!.trim();
      } else if (line.isNotEmpty && !line.startsWith("#")) {
        if (line.contains(",")) {
          List<String> parts = line.split(",");
          if (parts.length >= 2) {
            _allChannels.add(Channel(name: parts[0].trim(), url: parts[1].trim(), sourceName: sourceName, isSelected: true));
          }
        } else {
          _allChannels.add(Channel(name: tempName, url: line, sourceName: sourceName, isSelected: true));
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
            if (d == null || d > maxDelay) delayMatch = false;
          }
        }
        return textMatch && delayMatch;
      }).toList();
      _applySort();
      _statusText = "筛选 ${_visibleChannels.length} 个频道";
    });
  }

  String normalizeText(String text) {
    text = text.toLowerCase().replaceAll(RegExp(r'[\s\-_#\[\]\(\)（）【】]'), '');
    return text;
  }

  // --- 智能排序逻辑 ---
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
        // 延迟排序：将未知或超时转为极大值垫底
        int delayA = int.tryParse(a.delay) ?? (_isAscending ? 999999 : -1);
        int delayB = int.tryParse(b.delay) ?? (_isAscending ? 999999 : -1);
        result = delayA.compareTo(delayB);
      } else if (_currentSort == SortType.resolution) {
        // 分辨率排序：按纵向像素大小对比
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
    if (match != null) return int.tryParse(match.group(1) ?? "0") ?? 0;
    if (res.contains("标清")) return 480;
    return 0; // 未知
  }

  String _getSortIcon(SortType type) {
    if (_currentSort != type) return "";
    return _isAscending ? " ▲" : " ▼";
  }

  // --- 全选与反选逻辑 ---
  void _selectAll(bool select) {
    setState(() {
      for (var ch in _visibleChannels) {
        ch.isSelected = select;
      }
    });
  }

  // --- 测速逻辑 (仅测试被选中的) ---
  Future<void> _startTest() async {
    List<Channel> targets = _visibleChannels.where((ch) => ch.isSelected).toList();
    
    if (_isTesting || targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先勾选需要测速的频道")));
      return;
    }

    setState(() {
      _isTesting = true;
      _statusText = "开始测速 ${targets.length} 个选中源...";
    });
    _addLog("启动并发测速，目标数量: ${targets.length}");

    const concurrency = 10;
    for (int i = 0; i < targets.length; i += concurrency) {
      if (!_isTesting) {
        _addLog("测速已被手动停止");
        break;
      }
      int end = (i + concurrency < targets.length) ? i + concurrency : targets.length;
      List<Future> futures = [];
      for (int j = i; j < end; j++) {
        futures.add(_testSingleChannel(targets[j]));
      }
      await Future.wait(futures);
      setState(() => _applySort()); // 测完一批后重新排序（如果开启了排序）
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
      ch.delay = "-";
      ch.resolution = "-";
    }
  }

  Future<String> _detectResolution(String url) async {
    try {
      if (!url.toLowerCase().contains(".m3u8")) return "未知";
      final response = await http.get(Uri.parse(url), headers: {"User-Agent": "Mozilla/5.0"}).timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return "未知";
      
      final match = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(response.body);
      if (match == null) return "未知";

      int width = int.parse(match.group(1)!);
      int height = int.parse(match.group(2)!);
      String res = "${width}x$height";

      if (height >= 1080) return "1080p ($res)";
      if (height >= 720) return "720p ($res)";
      return "标清 ($res)";
    } catch (_) {
      return "未知";
    }
  }

  void _copyUrl(String url, String name) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已复制: $name"), duration: const Duration(seconds: 1)),
    );
  }

  void _copyAllLogs() {
    Clipboard.setData(ClipboardData(text: _logs.join("\n")));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("已复制所有调试日志"), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("IPTV 测速与抓源工具", style: TextStyle(fontSize: 18))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: TextField(
              controller: _urlController,
              maxLines: 3,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "每行一个M3U/TXT地址"),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: _startBatchDownload, child: const Text("下载导入")),
              ElevatedButton(onPressed: _startTest, style: ElevatedButton.styleFrom(backgroundColor: Colors.green[50]), child: const Text("测速勾选项", style: TextStyle(color: Colors.green))),
              ElevatedButton(onPressed: () => setState(() => _isTesting = false), child: const Text("停止")),
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
                    decoration: const InputDecoration(hintText: "关键词", isDense: true),
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
                IconButton(onPressed: () {
                  _filterController.clear();
                  _delayController.clear();
                  _applyFilter();
                }, icon: const Icon(Icons.refresh))
              ],
            ),
          ),
          
          // --- 新增：操作栏 (全选 + 排序) ---
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                TextButton(onPressed: () => _selectAll(true), child: const Text("全选")),
                TextButton(onPressed: () => _selectAll(false), child: const Text("反选")),
                const Spacer(),
                InkWell(onTap: () => _triggerSort(SortType.name), child: Padding(padding: const EdgeInsets.all(4.0), child: Text("名称${_getSortIcon(SortType.name)}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)))),
                const SizedBox(width: 8),
                InkWell(onTap: () => _triggerSort(SortType.delay), child: Padding(padding: const EdgeInsets.all(4.0), child: Text("延迟${_getSortIcon(SortType.delay)}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)))),
                const SizedBox(width: 8),
                InkWell(onTap: () => _triggerSort(SortType.resolution), child: Padding(padding: const EdgeInsets.all(4.0), child: Text("分辨率${_getSortIcon(SortType.resolution)}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)))),
              ],
            ),
          ),
          
          // --- 频道列表 ---
          Expanded(
            child: ListView.builder(
              itemCount: _visibleChannels.length > 500 ? 500 : _visibleChannels.length,
              itemBuilder: (context, index) {
                final ch = _visibleChannels[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                    // 复选框
                    leading: Checkbox(
                      value: ch.isSelected,
                      onChanged: (val) => setState(() => ch.isSelected = val ?? false),
                    ),
                    title: Text(ch.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ch.url, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text("状态:${ch.status}  ", style: TextStyle(fontSize: 11, color: ch.status == "在线" ? Colors.green : Colors.red)),
                            Text("延迟:${ch.delay}  ", style: const TextStyle(fontSize: 11)),
                            Text("分辨率:${ch.resolution}", style: const TextStyle(fontSize: 11)),
                          ],
                        )
                      ],
                    ),
                    // 复制按钮
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, color: Colors.blue),
                      onPressed: () => _copyUrl(ch.url, ch.name),
                    ),
                    onTap: () => setState(() => _selectedSourceInfo = ch.sourceName),
                  ),
                );
              },
            ),
          ),

          // --- 调试日志面板 ---
          ExpansionTile(
            title: const Text("调试日志面板 (点击展开)", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            collapsedBackgroundColor: Colors.grey[100],
            children: [
              Container(
                height: 150,
                width: double.infinity,
                color: Colors.black87,
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(8),
                      // 支持文字长按选取复制
                      child: SelectableText(
                        _logs.join("\n"),
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: "monospace"),
                      ),
                    ),
                    // 右上角全选复制按钮
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

          // 底部状态
          Container(
            width: double.infinity,
            color: Colors.blue[50],
            padding: const EdgeInsets.all(6),
            child: Text(" $_statusText | 选中源: $_selectedSourceInfo", style: const TextStyle(color: Colors.blue, fontSize: 11, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
          )
        ],
      ),
    );
  }
}

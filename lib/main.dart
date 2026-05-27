import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

void main() {
  runApp(const MaterialApp(
    home: IPTVTesterHome(),
    debugShowCheckedModeBanner: false,
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
    this.status = "待测",
    this.delay = "-",
    this.resolution = "-",
    required this.sourceName,
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

  // 读取历史记忆 URL
  Future<void> _loadSavedUrls() async {
    final prefs = await SharedPreferences.getInstance();
    String? saved = prefs.getString("saved_urls");
    if (saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    } else {
      _urlController.text = "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u\n";
    }
  }

  // 保存 URL 历史
  Future<void> _saveUrls() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("saved_urls", _urlController.text);
  }

  // 1. 批量下载逻辑（多线程并行）
  Future<void> _startBatchDownload() async {
    if (_isDownloading) return;
    await _saveUrls();

    setState(() {
      _isDownloading = true;
      _statusText = "开始批量下载中...";
      _allChannels.clear();
      _visibleChannels.clear();
    });

    List<String> urls = _urlController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.startsWith("http://") || e.startsWith("https://"))
        .toList();

    // 智能去重
    urls = urls.toSet().toList();

    if (urls.isEmpty) {
      setState(() {
        _isDownloading = false;
        _statusText = "无有效输入链接";
      });
      return;
    }

    int successCount = 0;
    final directory = await getTemporaryDirectory();

    // 并行下载，最大并发设置为 4
    await Future.forEach<String>(urls, (url) async {
      try {
        final uri = Uri.parse(url);
        String fileName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : "playlist.m3u";
        int idx = urls.indexOf(url) + 1;
        String localName = "${idx}_$fileName";
        String localPath = "${directory.path}/$localName";

        final response = await http.get(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final file = File(localPath);
          await file.writeAsBytes(response.bodyBytes);
          _parseFile(response.body, localName);
          successCount++;
        }
      } catch (_) {}
    });

    setState(() {
      _isDownloading = false;
      _statusText = "下载完成 (成功 $successCount/${urls.length})，加载 ${_allChannels.length} 频道";
      _visibleChannels = List.from(_allChannels);
    });
  }

  void _parseFile(String content, String sourceName) {
    List<String> lines = content.split('\n');
    String tempName = "未知频道";
    
    // 兼容 M3U 和 TXT 格式
    for (var line in lines) {
      line = line.trim();
      if (line.startsWith("#EXTINF")) {
        final match = RegExp(r',([^,]+)$').firstMatch(line);
        if (match != null) {
          tempName = match.group(1)!.trim();
        }
      } else if (line.isNotEmpty && !line.startsWith("#")) {
        if (line.contains(",")) {
          var parts = line.split(',');
          if (parts.length >= 2) {
            _allChannels.add(Channel(
              name: parts[0].trim(),
              url: parts[1].trim(),
              sourceName: sourceName,
            ));
          }
        } else {
          _allChannels.add(Channel(
            name: tempName,
            url: line,
            sourceName: sourceName,
          ));
          tempName = "未知频道";
        }
      }
    }
  }

  // 双重过滤防抖
  void _onFilterChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _applyFilter();
    });
  }

  void _applyFilter() {
    String kw = _filterController.text.trim();
    String delayStr = _delayController.text.trim();
    int? maxDelay = int.tryParse(delayStr);

    List<String> keywords = kw.split(RegExp(r'[,，\s]+')).map((e) => normalize_text(e)).where((e) => e.isNotEmpty).toList();

    setState(() {
      _visibleChannels = _allChannels.where((ch) {
        bool textMatch = true;
        if (keywords.isNotEmpty) {
          textMatch = keywords.any((k) => normalize_text(ch.name).contains(k));
        }

        bool delayMatch = true;
        if (maxDelay != null) {
          if (ch.status != "在线") {
            delayMatch = false;
          } else {
            int? chDelay = int.tryParse(ch.delay);
            if (chDelay == null || chDelay > maxDelay) {
              delayMatch = false;
            }
          }
        }
        return textMatch && delayMatch;
      }).toList();

      _statusText = "筛选出 ${_visibleChannels.length} 个结果";
    });
  }

  String normalize_text(String text) {
    text = text.toLowerCase();
    text = text.replaceAll(RegExp(r'[\s\-_#\[\]\(\)（）【】]'), '');
    // 简繁互通精简版
    var trad = ["無", "綫", "線", "體", "國", "粵", "臺", "東", "衛", "翡", "翠", "育", "影", "戲", "劇"];
    var simp = ["无", "线", "线", "体", "国", "粤", "台", "东", "卫", "翡", "翠", "育", "影", "戏", "剧"];
    for (int i = 0; i < trad.length; i++) {
      text = text.replaceAll(trad[i], simp[i]);
    }
    return text;
  }

  // 2. 测速与 FFprobe 分辨率检测
  Future<void> _startTest() async {
    if (_isTesting || _visibleChannels.isEmpty) return;

    setState(() {
      _isTesting = true;
      _statusText = "正在进行测速...";
    });

    // 并发测试，限制最大并发 10 线程
    int concurrency = 10;
    List<Channel> targets = List.from(_visibleChannels);

    for (int i = 0; i < targets.length; i += concurrency) {
      if (!_isTesting) break;
      int end = (i + concurrency < targets.length) ? i + concurrency : targets.length;
      List<Future> futures = [];
      for (int j = i; j < end; j++) {
        futures.add(_testSingleChannel(targets[j]));
      }
      await Future.wait(futures);
    }

    setState(() {
      _isTesting = false;
      _statusText = "测试完成";
    });
  }

  Future<void> _testSingleChannel(Channel ch) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http.get(Uri.parse(ch.url)).timeout(const Duration(seconds: 3));
      stopwatch.stop();
      if (response.statusCode == 200) {
        ch.delay = stopwatch.elapsedMilliseconds.toString();
        ch.status = "在线";
        ch.resolution = await _detectResolution(ch.url);
      } else {
        ch.status = "HTTP ${response.statusCode}";
      }
    } catch (_) {
      ch.status = "离线";
    }
    setState(() {});
  }

  Future<String> _detectResolution(String url) async {
    try {
      String targetUrl = url;
      if (!url.toLowerCase().contains(".m3u8") && !url.toLowerCase().contains(".ts")) {
        targetUrl = "$url#.m3u8"; // 强行暗示 HLS 协议
      }

      // 极限参数：限制读 150KB 缓存，最多解析 1.0 秒
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
          if (height >= 1080) return "1080p ($resStr)";
          if (height >= 720) return "720p ($resStr)";
          return "标清 ($resStr)";
        }
      }
    } catch (_) {}
    return "未知";
  }

  void _copyUrl(Channel ch) {
    Clipboard.setData(ClipboardData(text: ch.url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已复制: ${ch.name} 的播放地址"), duration: const Duration(seconds: 1)),
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
      appBar: AppBar(title: const Text("IPTV 测速与溯源 (安卓极速版)")),
      body: Column(
        children: [
          // 导入区
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _urlController,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "请输入在线 URL (每行一个)",
              ),
            ),
          ),
          // 按钮控制行
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: _startBatchDownload, child: const Text("并行下载导入")),
              ElevatedButton(onPressed: _startTest, child: const Text("测速选中源")),
              ElevatedButton(onPressed: () => setState(() => _isTesting = false), child: const Text("停止测速")),
            ],
          ),
          // 过滤区
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filterController,
                    onChanged: (_) => _onFilterChanged(),
                    decoration: const InputDecoration(hintText: "关键词"),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _delayController,
                    onChanged: (_) => _onFilterChanged(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: "最大延迟"),
                  ),
                ),
                IconButton(onPressed: _clearFilterText, icon: const Icon(Icons.refresh))
              ],
            ),
          ),
          // 状态条
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_statusText, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          // 表格列表
          Expanded(
            child: ListView.builder(
              itemCount: _visibleChannels.length > 500 ? 500 : _visibleChannels.length, // 安卓限制仅极速渲染前500条
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
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(ch.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              Text(ch.sourceName, style: const TextStyle(color: Colors.blue, fontSize: 12)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(ch.url, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text("状态: ${ch.status}", style: TextStyle(color: ch.status == "在线" ? Colors.green : Colors.red)),
                              Text("延迟: ${ch.delay} ms"),
                              Text("分辨率: ${ch.resolution}"),
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
          // 底部溯源栏
          Container(
            color: Colors.blue[50],
            width: double.infinity,
            padding: const EdgeInsets.all(8.0),
            child: Text("当前选中频道来源: $_selectedSourceInfo", style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }
}

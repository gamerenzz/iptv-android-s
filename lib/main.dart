import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';
import 'dart:async';
import 'dart:convert';

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
    this.isSelected = true,
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
  State<IPTVTesterHome> createState() =>
      _IPTVTesterHomeState();
}

class _IPTVTesterHomeState
    extends State<IPTVTesterHome> {

  final TextEditingController _urlController =
      TextEditingController();

  final TextEditingController _filterController =
      TextEditingController();

  final TextEditingController _delayController =
      TextEditingController();

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

  @override
  void initState() {
    super.initState();

    _loadSavedUrls();

    _addLog("系统初始化完成");
  }

  void _addLog(String msg) {
    setState(() {
      String time =
          DateTime.now()
              .toLocal()
              .toString()
              .substring(11, 19);

      _logs.insert(0, "[$time] $msg");

      if (_logs.length > 80) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _loadSavedUrls() async {
    final prefs =
        await SharedPreferences.getInstance();

    String? saved =
        prefs.getString("saved_urls");

    if (saved != null &&
        saved.trim().isNotEmpty) {
      _urlController.text = saved;
    } else {
      _urlController.text =
          "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u";
    }
  }

  Future<void> _saveUrls() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      "saved_urls",
      _urlController.text,
    );
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

      return;
    }

    int success = 0;

    final directory =
        await getTemporaryDirectory();

    List<Future> tasks = [];

    for (String url in urls) {
      tasks.add(
        _downloadSingle(
          url,
          directory.path,
        ).then((ok) {
          if (ok) success++;
        }),
      );
    }

    await Future.wait(tasks);

    setState(() {
      _visibleChannels =
          List.from(_allChannels);

      _applySort();

      _isDownloading = false;

      _statusText =
          "下载完成 成功 $success/${urls.length} 共 ${_allChannels.length} 个频道";
    });
  }

  Future<bool> _downloadSingle(
    String url,
    String dir,
  ) async {
    try {
      final uri = Uri.parse(url);

      final response = await http.get(
        uri,
        headers: {
          "User-Agent": "Mozilla/5.0",
        },
      ).timeout(
        const Duration(seconds: 15),
      );

      if (response.statusCode != 200) {
        return false;
      }

      String fileName =
          uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : "playlist.m3u";

      final file = File("$dir/$fileName");

      await file.writeAsBytes(
        response.bodyBytes,
      );

      _parseFile(response.body, fileName);

      return true;
    } catch (_) {
      return false;
    }
  }

  void _parseFile(
    String content,
    String sourceName,
  ) {
    List<String> lines =
        content.split('\n');

    String tempName = "未知频道";

    for (String line in lines) {
      line = line.trim();

      if (line.startsWith("#EXTINF")) {
        final match =
            RegExp(r',([^,]+)$')
                .firstMatch(line);

        if (match != null) {
          tempName =
              match.group(1)!.trim();
        }
      } else if (
          line.isNotEmpty &&
          !line.startsWith("#")) {

        if (line.contains(",")) {

          List<String> parts =
              line.split(",");

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
    String kw =
        _filterController.text.trim();

    int? maxDelay =
        int.tryParse(
            _delayController.text.trim());

    List<String> keywords = kw
        .split(RegExp(r'[,，\s]+'))
        .map(normalizeText)
        .where((e) => e.isNotEmpty)
        .toList();

    setState(() {
      _visibleChannels =
          _allChannels.where((ch) {

        bool textMatch = true;

        if (keywords.isNotEmpty) {
          textMatch = keywords.any(
            (k) => normalizeText(
              ch.name,
            ).contains(k),
          );
        }

        bool delayMatch = true;

        if (maxDelay != null) {
          if (ch.status != "在线") {
            delayMatch = false;
          } else {
            int? d =
                int.tryParse(ch.delay);

            if (d == null ||
                d > maxDelay) {
              delayMatch = false;
            }
          }
        }

        return textMatch && delayMatch;

      }).toList();

      _applySort();

      _statusText =
          "筛选 ${_visibleChannels.length} 个频道";
    });
  }

  String normalizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll(
          RegExp(
            r'[\s\-_#\[\]\(\)（）【】]',
          ),
          '',
        );
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
    if (_currentSort == SortType.none) {
      return;
    }

    _visibleChannels.sort((a, b) {

      int result = 0;

      if (_currentSort ==
          SortType.name) {

        result =
            a.name.compareTo(b.name);

      } else if (_currentSort ==
          SortType.delay) {

        int delayA =
            int.tryParse(a.delay) ??
                999999;

        int delayB =
            int.tryParse(b.delay) ??
                999999;

        result =
            delayA.compareTo(delayB);

      } else if (_currentSort ==
          SortType.resolution) {

        int resA =
            _parseResValue(
                a.resolution);

        int resB =
            _parseResValue(
                b.resolution);

        result =
            resA.compareTo(resB);
      }

      return _isAscending
          ? result
          : -result;
    });
  }

  int _parseResValue(String res) {

    if (res.contains("4K")) {
      return 2160;
    }

    final match =
        RegExp(r'(\d+)p')
            .firstMatch(res);

    if (match != null) {
      return int.tryParse(
            match.group(1) ?? "0",
          ) ??
          0;
    }

    if (res.contains("标清")) {
      return 480;
    }

    return 0;
  }

  String _getSortIcon(SortType type) {
    if (_currentSort != type) {
      return "";
    }

    return _isAscending
        ? " ▲"
        : " ▼";
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
      _allChannels.removeWhere(
        (ch) => ch.isSelected,
      );

      _applyFilter();
    });
  }

  Future<void> _startTest() async {

    List<Channel> targets =
        _visibleChannels
            .where((ch) => ch.isSelected)
            .toList();

    if (_isTesting ||
        targets.isEmpty) {
      return;
    }

    setState(() {
      _isTesting = true;

      _statusText =
          "开始测速 ${targets.length} 个频道...";
    });

    const concurrency = 12;

    for (
      int i = 0;
      i < targets.length;
      i += concurrency
    ) {

      if (!_isTesting) break;

      int end =
          (i + concurrency <
                  targets.length)
              ? i + concurrency
              : targets.length;

      List<Future> futures = [];

      for (int j = i; j < end; j++) {
        futures.add(
          _testSingleChannel(
            targets[j],
          ),
        );
      }

      await Future.wait(futures);

      setState(() {});
    }

    setState(() {
      _isTesting = false;

      _statusText = "测速完成";
    });
  }

  Future<void> _testSingleChannel(
    Channel ch,
  ) async {

    Stopwatch sw = Stopwatch()
      ..start();

    HttpClient? client;

    try {

      client = HttpClient();

      client.connectionTimeout =
          const Duration(seconds: 4);

      final request =
          await client.getUrl(
        Uri.parse(ch.url),
      );

      request.headers.set(
        "User-Agent",
        "Mozilla/5.0",
      );

      request.headers.set(
        "Range",
        "bytes=0-1023",
      );

      final response =
          await request.close();

      List<int> bytes = [];

      await for (var chunk
          in response.timeout(
        const Duration(seconds: 4),
      )) {

        bytes.addAll(chunk);

        if (bytes.length >= 1024) {
          break;
        }
      }

      sw.stop();

      ch.delay =
          sw.elapsedMilliseconds
              .toString();

      if (response.statusCode == 200 ||
          response.statusCode == 206) {

        ch.status = "在线";

        String body = "";

        try {
          body = utf8.decode(bytes);
        } catch (_) {}

        ch.resolution =
            _parseResolutionFromContent(
          body,
        );

      } else {

        ch.status =
            "HTTP ${response.statusCode}";

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

  String _parseResolutionFromContent(
    String body,
  ) {

    if (!body.contains("#EXTM3U")) {
      return "未知";
    }

    final match = RegExp(
      r'RESOLUTION=(\d+)[xX](\d+)',
      caseSensitive: false,
    ).firstMatch(body);

    if (match == null) {
      return "单层流";
    }

    int width =
        int.parse(match.group(1)!);

    int height =
        int.parse(match.group(2)!);

    String res =
        "${width}x$height";

    if (height >= 2160) {
      return "4K ($res)";
    }

    if (height >= 1080) {
      return "1080p ($res)";
    }

    if (height >= 720) {
      return "720p ($res)";
    }

    return "标清 ($res)";
  }

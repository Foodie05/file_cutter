import 'dart:io';
import 'package:file_cutter/logic/file_cutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const FileCutterApp());
}

class FileCutterApp extends StatelessWidget {
  const FileCutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Cutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  // Define method channel for native communication
  static const platform = MethodChannel('com.example.file_cutter/file_open');
  
  // Use ValueNotifiers to pass file paths to tabs
  final ValueNotifier<List<String>?> _splitFileNotifier = ValueNotifier<List<String>?>(null);
  final ValueNotifier<List<String>?> _mergeFileNotifier = ValueNotifier<List<String>?>(null);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    // Set up method call handler
    platform.setMethodCallHandler(_handleMethodCall);
    
    // Notify native side that Flutter is ready and check for startup files
    _checkStartupFiles();
  }

  Future<void> _checkStartupFiles() async {
    try {
      // 1. Notify we are ready
      await platform.invokeMethod('notifyReady');
      
      // 2. Ask for any pending files
      final dynamic result = await platform.invokeMethod('getStartupFiles');
      if (result != null && result is List && result.isNotEmpty) {
        final List<String> filePaths = result.cast<String>();
        _handleOpenedFiles(filePaths);
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to get startup files: '${e.message}'.");
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'openFiles') {
      final List<dynamic> args = call.arguments as List<dynamic>;
      final List<String> filePaths = args.cast<String>();
      _handleOpenedFiles(filePaths);
    } else if (call.method == 'openFile') {
      final String filePath = call.arguments as String;
      _handleOpenedFiles([filePath]);
    }
  }

  void _handleOpenedFiles(List<String> filePaths) {
    if (filePaths.isEmpty) return;

    final fchFiles = filePaths.where((path) => path.toLowerCase().endsWith('.fch')).toList();
    final otherFiles = filePaths.where((path) => !path.toLowerCase().endsWith('.fch')).toList();

    if (fchFiles.isNotEmpty) {
      // Switch to Merge tab
      _tabController.animateTo(1);
      // Update notifier to trigger merge tab logic
      _mergeFileNotifier.value = fchFiles;
    } else if (otherFiles.isNotEmpty) {
      // Switch to Split tab
      _tabController.animateTo(0);
      _splitFileNotifier.value = otherFiles;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _splitFileNotifier.dispose();
    _mergeFileNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Cutter'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.cut), text: '切分 (Split)'),
            Tab(icon: Icon(Icons.merge_type), text: '合并 (Merge)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          SplitTab(fileNotifier: _splitFileNotifier),
          MergeTab(fileNotifier: _mergeFileNotifier),
        ],
      ),
    );
  }
}

class SplitTab extends StatefulWidget {
  final ValueNotifier<List<String>?>? fileNotifier;
  const SplitTab({super.key, this.fileNotifier});

  @override
  State<SplitTab> createState() => _SplitTabState();
}

class _SplitTabState extends State<SplitTab> {
  List<String> _selectedFilePaths = [];
  final TextEditingController _sizeController = TextEditingController(text: "10");
  double _progress = 0.0;
  bool _isProcessing = false;
  String _statusMessage = "";
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.fileNotifier?.addListener(_onFileNotifierChanged);
    // If there is already a value, handle it
    if (widget.fileNotifier?.value != null) {
      _onFileNotifierChanged();
    }
  }

  @override
  void dispose() {
    widget.fileNotifier?.removeListener(_onFileNotifierChanged);
    _sizeController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add("[${DateTime.now().toString().split('.').first}] $message");
    });
    // Scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onFileNotifierChanged() {
    final paths = widget.fileNotifier?.value;
    if (paths != null && paths.isNotEmpty) {
      setFiles(paths);
      // Show dialog after a short delay to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) showSplitDialog();
      });
      // Reset notifier so we don't re-trigger on rebuilds if not intended
      widget.fileNotifier?.value = null; 
    }
  }

  void setFiles(List<String> paths) {
    setState(() {
      for (var path in paths) {
        if (!_selectedFilePaths.contains(path)) {
          _selectedFilePaths.add(path);
          _addLog("已添加文件: $path");
        } else {
          _addLog("文件已存在: $path");
        }
      }
      if (_selectedFilePaths.isEmpty) {
        _statusMessage = "未选择文件 (No file selected)";
      } else if (_selectedFilePaths.length == 1) {
        _statusMessage = "已选择: ${p.basename(_selectedFilePaths[0])}";
      } else {
        _statusMessage = "已选择 ${_selectedFilePaths.length} 个文件";
      }
      _progress = 0.0;
    });
  }
  
  void showSplitDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("设置切分大小 (Set Split Size)"),
          content: TextField(
            controller: _sizeController,
            decoration: const InputDecoration(
              labelText: "大小 (MB)",
              border: OutlineInputBorder(),
              suffixText: "MB"
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消 (Cancel)"),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _startSplit();
              },
              child: const Text("开始切分 (Start)"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);

    if (result != null && result.paths.isNotEmpty) {
      setFiles(result.paths.whereType<String>().toList());
    }
  }

  Future<void> _startSplit() async {
    if (_selectedFilePaths.isEmpty) {
      _showError("请先选择文件 (Please select a file first)");
      return;
    }

    final double sizeMB = double.tryParse(_sizeController.text) ?? 0;
    if (sizeMB <= 0) {
      _showError("无效的大小 (Invalid size)");
      return;
    }

    final int sizeBytes = (sizeMB * 1000 * 1000).floor();

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusMessage = "处理中... (Processing...)";
      _logs.clear();
    });
    _addLog("开始批量任务: 切分文件 (${_selectedFilePaths.length}个)");
    _addLog("输入大小: $sizeMB MB ($sizeBytes bytes)");

    try {
      String? outputDir;
      if (Platform.isMacOS) {
        // Explicitly ask for output directory to grant permission
        String? selectedDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "请授权输出文件夹 (Authorize Output Folder)",
          initialDirectory: p.dirname(_selectedFilePaths[0]),
        );
        if (selectedDir == null) {
          _showError("已取消 (Cancelled)");
          setState(() {
            _isProcessing = false;
          });
          _addLog("用户取消了目录选择");
          return;
        }
        outputDir = selectedDir;
        _addLog("输出目录: $outputDir");
      }

      final cutter = FileCutter();
      List<String> allCreatedFiles = [];

      for (int i = 0; i < _selectedFilePaths.length; i++) {
        final filePath = _selectedFilePaths[i];
        final fileName = p.basename(filePath);
        _addLog("--- 正在处理第 ${i + 1}/${_selectedFilePaths.length} 个文件: $fileName ---");
        
        final List<String> createdFiles = await cutter.splitFile(
          File(filePath),
          sizeBytes,
          (fileProgress) {
            setState(() {
              // Overall progress: (completed files + current file progress) / total files
              _progress = (i + fileProgress) / _selectedFilePaths.length;
              _statusMessage = "切分中 ($fileName)... ${(fileProgress * 100).toStringAsFixed(1)}%";
            });
          },
          outputDir: outputDir,
          onLog: _addLog,
        );
        allCreatedFiles.addAll(createdFiles);

        // Delete original file if successful
        try {
          final originalFile = File(filePath);
          if (await originalFile.exists()) {
            _addLog("正在删除源文件: $filePath");
            await originalFile.delete();
            _addLog("源文件删除成功");
          }
        } catch (e) {
          _addLog("源文件删除失败: $e");
        }
      }

      setState(() {
        _statusMessage = "批量切分完成! (Batch split complete!)";
        _progress = 1.0;
        _selectedFilePaths = []; 
      });
      _addLog("切分流程全部完成");
      
      if (mounted) {
        _showSplitCompleteDialog(allCreatedFiles);
      }
    } catch (e) {
      _showError("错误: $e");
      _addLog("错误发生: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _showSplitCompleteDialog(List<String> createdFiles) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("切分完成 (Split Complete)"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("源文件已替换为以下分片文件:\n(Source file replaced with the following parts:)"),
                const SizedBox(height: 10),
                ...createdFiles.map((name) => Text("• $name", style: const TextStyle(fontFamily: 'monospace'))),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("确定 (OK)"),
            ),
          ],
        );
      },
    );
  }
  
  void _showError(String message) {
    setState(() => _statusMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
  
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _pickFile,
            icon: const Icon(Icons.folder_open),
            label: const Text("选择文件 (Select Files)"),
          ),
          const SizedBox(height: 10),
          if (_selectedFilePaths.isEmpty)
            const Text("未选择文件 (No file selected)"),
          if (_selectedFilePaths.isNotEmpty)
            Container(
              height: 100,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                itemCount: _selectedFilePaths.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    title: Text(p.basename(_selectedFilePaths[index])),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: _isProcessing ? null : () {
                        setState(() {
                          _selectedFilePaths.removeAt(index);
                          if (_selectedFilePaths.isEmpty) {
                             _statusMessage = "";
                          } else {
                             _statusMessage = "已选择 ${_selectedFilePaths.length} 个文件";
                          }
                        });
                      },
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _sizeController,
            decoration: const InputDecoration(
              labelText: "切分大小 (MB)",
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            enabled: !_isProcessing,
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _startSplit,
            icon: const Icon(Icons.cut),
            label: const Text("开始切分 (Start Split)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          if (_isProcessing || _progress > 0) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 10),
          ],
          Text(_statusMessage),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                controller: _logScrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Text(
                    _logs[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MergeTab extends StatefulWidget {
  final ValueNotifier<List<String>?>? fileNotifier;
  const MergeTab({super.key, this.fileNotifier});

  @override
  State<MergeTab> createState() => _MergeTabState();
}

class _MergeTabState extends State<MergeTab> {
  List<String> _selectedFilePaths = [];
  double _progress = 0.0;
  bool _isProcessing = false;
  String _statusMessage = "";
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.fileNotifier?.addListener(_onFileNotifierChanged);
    if (widget.fileNotifier?.value != null) {
      _onFileNotifierChanged();
    }
  }

  @override
  void dispose() {
    widget.fileNotifier?.removeListener(_onFileNotifierChanged);
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add("[${DateTime.now().toString().split('.').first}] $message");
    });
    // Scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onFileNotifierChanged() {
    final paths = widget.fileNotifier?.value;
    if (paths != null && paths.isNotEmpty) {
      setFiles(paths);
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) showMergeConfirmationDialog();
      });
      widget.fileNotifier?.value = null;
    }
  }

  void showMergeConfirmationDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("恢复文件 (Recover Files)"),
          content: Text("是否恢复 ${_selectedFilePaths.length} 个文件?\n(Do you want to recover these files?)"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消 (Cancel)"),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _startMerge();
              },
              child: const Text("开始恢复 (Start)"),
            ),
          ],
        );
      },
    );
  }
  
  void setFiles(List<String> paths) {
    setState(() {
      for (var path in paths) {
        if (!_selectedFilePaths.contains(path)) {
          _selectedFilePaths.add(path);
          _addLog("已添加文件: $path");
        } else {
          _addLog("文件已存在: $path");
        }
      }
      if (_selectedFilePaths.isEmpty) {
        _statusMessage = "未选择文件 (No file selected)";
      } else if (_selectedFilePaths.length == 1) {
        _statusMessage = "已选择: ${p.basename(_selectedFilePaths[0])}";
      } else {
        _statusMessage = "已选择 ${_selectedFilePaths.length} 个文件";
      }
      _progress = 0.0;
    });
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['fch'],
      allowMultiple: true,
    );

    if (result != null && result.paths.isNotEmpty) {
      setFiles(result.paths.whereType<String>().toList());
    }
  }

  Future<void> _startMerge() async {
    if (_selectedFilePaths.isEmpty) {
      _showError("请选择 .fch 文件 (Please select .fch files)");
      return;
    }

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusMessage = "处理中... (Processing...)";
      _logs.clear();
    });
    _addLog("开始批量任务: 合并文件 (${_selectedFilePaths.length}个)");

    try {
      String? outputDir;
      if (Platform.isMacOS) {
        // Explicitly ask for output directory to grant permission
        String? selectedDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "请授权输出文件夹 (Authorize Output Folder)",
          initialDirectory: p.dirname(_selectedFilePaths[0]),
        );
        if (selectedDir == null) {
           _showError("已取消 (Cancelled)");
           setState(() {
            _isProcessing = false;
          });
          _addLog("用户取消了目录选择");
          return;
        }
        outputDir = selectedDir;
        _addLog("输出目录: $outputDir");
      }

      final cutter = FileCutter();
      int successCount = 0;

      for (int i = 0; i < _selectedFilePaths.length; i++) {
        final filePath = _selectedFilePaths[i];
        final fileName = p.basename(filePath);
        _addLog("--- 正在处理第 ${i + 1}/${_selectedFilePaths.length} 个文件: $fileName ---");
        
        final List<String> processedFiles = await cutter.mergeFile(
          File(filePath),
          (fileProgress) {
            setState(() {
              _progress = (i + fileProgress) / _selectedFilePaths.length;
              _statusMessage = "合并中 ($fileName)... ${(fileProgress * 100).toStringAsFixed(1)}%";
            });
          },
          outputDir: outputDir,
          onLog: _addLog,
        );

        // Delete processed files (fch and fct files)
        _addLog("正在清理源文件...");
        int deletedCount = 0;
        for (String pFile in processedFiles) {
          try {
            final file = File(pFile);
            if (await file.exists()) {
              await file.delete();
              deletedCount++;
            }
          } catch (e) {
            _addLog("删除失败 ($pFile): $e");
          }
        }
        _addLog("源文件清理完成，共删除 $deletedCount 个文件");
        successCount++;
      }

      setState(() {
        _statusMessage = "合并完成! (Merge complete!)";
        _progress = 1.0;
        _selectedFilePaths = []; // Clear selection
      });
      _addLog("合并流程全部完成");
      _showSuccess("批量合并完成! (Batch merge complete!)");
    } catch (e) {
      _showError("错误: $e");
      _addLog("错误发生: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _showError(String message) {
    setState(() => _statusMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _pickFile,
            icon: const Icon(Icons.folder_open),
            label: const Text("选择 .fch 文件 (Select .fch Files)"),
          ),
          const SizedBox(height: 10),
          if (_selectedFilePaths.isEmpty)
            const Text("未选择文件 (No file selected)"),
          if (_selectedFilePaths.isNotEmpty)
            Container(
              height: 100,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                itemCount: _selectedFilePaths.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    title: Text(p.basename(_selectedFilePaths[index])),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: _isProcessing ? null : () {
                        setState(() {
                          _selectedFilePaths.removeAt(index);
                          if (_selectedFilePaths.isEmpty) {
                             _statusMessage = "";
                          } else {
                             _statusMessage = "已选择 ${_selectedFilePaths.length} 个文件";
                          }
                        });
                      },
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _startMerge,
            icon: const Icon(Icons.merge_type),
            label: const Text("开始合并 (Start Merge)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          if (_isProcessing || _progress > 0) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 10),
          ],
          Text(_statusMessage),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                controller: _logScrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Text(
                    _logs[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

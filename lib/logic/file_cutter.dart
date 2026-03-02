import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}

class FileCutter {
  static const int _bufferSize = 1024 * 1024; // 1MB buffer
  static const String _magic = "FCT\x01"; // Version 1

  Future<List<String>> splitFile(File sourceFile, int maxSizeBytes, Function(double) onProgress, {String? outputDir, Function(String)? onLog}) async {
    final fileSize = await sourceFile.length();
    final sourceName = p.basename(sourceFile.path);
    final sourceDir = outputDir ?? p.dirname(sourceFile.path);
    
    onLog?.call("开始切分: $sourceName, 大小: ${fileSize} bytes");
    onLog?.call("目标切分大小: ${maxSizeBytes} bytes");

    // Calculate source hash
    onLog?.call("正在计算源文件哈希...");
    final sourceHash = await _calculateFileHash(sourceFile);
    onLog?.call("源文件哈希: $sourceHash");
    final stats = await sourceFile.stat();

    // Calculate chunks
    // Payload size = maxSizeBytes - estimated_header_size.
    // Let's estimate header size as 4KB.
    final int estimatedHeaderSize = 4096;
    final int payloadSize = maxSizeBytes - estimatedHeaderSize;
    
    if (payloadSize <= 0) {
      throw Exception("Split size is too small to contain header.");
    }

    final int totalParts = (fileSize / payloadSize).ceil();
    onLog?.call("预计分片数量: $totalParts, 每个分片Payload大小: $payloadSize bytes");
    
    // Pass 1: Calculate hashes for each chunk payload (without writing temp files)
    List<String> partHashes = [];
    List<String> partNames = [];
    
    // Determine filenames
    String baseNameNoExt = p.basenameWithoutExtension(sourceName);
    
    partNames.add("$baseNameNoExt.fch");
    for (int i = 1; i < totalParts; i++) {
      partNames.add(".${baseNameNoExt}_tail_$i.fct");
    }

    onLog?.call("正在计算分片哈希 (Pass 1)...");
    final sourceRaf = await sourceFile.open(mode: FileMode.read);
    
    try {
      for (int i = 0; i < totalParts; i++) {
        int currentPartSize = 0;
        var digestSink = DigestSink();
        var hashSink = sha256.startChunkedConversion(digestSink);
        
        int targetSize = (i == totalParts - 1) ? (fileSize - (i * payloadSize)) : payloadSize;
        
        while (currentPartSize < targetSize) {
          int toRead = _bufferSize;
          if (currentPartSize + toRead > targetSize) {
            toRead = targetSize - currentPartSize;
          }
          
          List<int> buffer = await sourceRaf.read(toRead);
          if (buffer.isEmpty) break;
          
          hashSink.add(buffer);
          currentPartSize += buffer.length;
          
          // Progress update (0% - 50%)
          double totalProgress = (i * payloadSize + currentPartSize) / fileSize;
          onProgress(totalProgress * 0.5);
        }
        
        hashSink.close();
        partHashes.add(digestSink.value.toString());
        onLog?.call("分片 ${i + 1}/$totalParts 哈希计算完成: ${digestSink.value}");
      }
    } finally {
      await sourceRaf.close();
    }
    
    // Step 2: Create Manifest
    Map<String, dynamic> manifest = {
      "source_name": sourceName,
      "source_hash": sourceHash,
      "created_at": stats.changed.toIso8601String(),
      "modified_at": stats.modified.toIso8601String(),
      "total_parts": totalParts,
      "parts": List.generate(totalParts, (index) => {
        "index": index,
        "name": partNames[index],
        "hash": partHashes[index]
      })
    };
    
    String manifestJson = jsonEncode(manifest);
    List<int> manifestBytes = utf8.encode(manifestJson);
    int manifestLen = manifestBytes.length;
    onLog?.call("Manifest生成完成, 大小: $manifestLen bytes");
    
    // Step 3: Write final files (Pass 2)
    onLog?.call("正在写入分片文件 (Pass 2)...");
    // Re-open source file
    final sourceRaf2 = await sourceFile.open(mode: FileMode.read);
    
    try {
      for (int i = 0; i < totalParts; i++) {
        String partName = partNames[i];
        String fullPath = p.join(sourceDir, partName);
        onLog?.call("写入分片 ${i + 1}/$totalParts: $partName");
        File finalPart = File(fullPath);
        IOSink sink = finalPart.openWrite();
        
        // Write Header
        sink.add(utf8.encode(_magic));
        
        ByteData lenData = ByteData(4);
        lenData.setUint32(0, manifestLen, Endian.big);
        sink.add(lenData.buffer.asUint8List());
        
        sink.add(manifestBytes);
        
        // Write Payload
        int targetSize = (i == totalParts - 1) ? (fileSize - (i * payloadSize)) : payloadSize;
        int currentPartSize = 0;
        
        while (currentPartSize < targetSize) {
          int toRead = _bufferSize;
          if (currentPartSize + toRead > targetSize) {
            toRead = targetSize - currentPartSize;
          }
          
          List<int> buffer = await sourceRaf2.read(toRead);
          if (buffer.isEmpty) break;
          
          sink.add(buffer);
          currentPartSize += buffer.length;

          // Progress update (50% - 100%)
          double totalProgress = (i * payloadSize + currentPartSize) / fileSize;
          onProgress(0.5 + totalProgress * 0.5);
        }
        
        await sink.flush();
        await sink.close();
      }
      onLog?.call("所有分片写入完成");
    } finally {
      await sourceRaf2.close();
    }

    return partNames;
  }

  Future<List<String>> mergeFile(File headerFile, Function(double) onProgress, {String? outputDir, Function(String)? onLog}) async {
    onLog?.call("开始合并: ${p.basename(headerFile.path)}");
    // 1. Read Header
    final raf = await headerFile.open(mode: FileMode.read);
    
    // Read Magic
    List<int> magicBytes = await raf.read(utf8.encode(_magic).length);
    String magic = utf8.decode(magicBytes);
    if (magic != _magic) {
      await raf.close();
      throw Exception("无效的文件格式或版本不匹配 (Invalid file format or version mismatch)");
    }
    
    // Read Meta Length
    List<int> lenBytes = await raf.read(4);
    int metaLen = ByteData.sublistView(Uint8List.fromList(lenBytes)).getUint32(0, Endian.big);
    
    // Read Meta
    List<int> metaBytes = await raf.read(metaLen);
    String metaJson = utf8.decode(metaBytes);
    Map<String, dynamic> manifest = jsonDecode(metaJson);
    
    await raf.close();
    
    // 2. Validate and Collect Parts
    String sourceName = manifest["source_name"];
    String originalHash = manifest["source_hash"];
    List<dynamic> parts = manifest["parts"];
    
    String dir = p.dirname(headerFile.path);
    String targetDir = outputDir ?? dir;
    String outputPath = p.join(targetDir, sourceName);
    File outputFile = File(outputPath);
    onLog?.call("目标输出文件: $outputPath");
    onLog?.call("分片总数: ${parts.length}");

    IOSink sink = outputFile.openWrite();
    List<String> processedFiles = [headerFile.path]; // Include header file itself

    try {
      for (int i = 0; i < parts.length; i++) {
        var partInfo = parts[i];
        String partName = partInfo["name"];
        String expectedHash = partInfo["hash"];
        
        String partPath = p.join(dir, partName);
        File partFile = File(partPath);
        if (!await partFile.exists()) {
          throw Exception("缺失分片文件: $partName (Missing part: $partName)");
        }
        
        // Add to list for potential deletion later
        if (partFile.absolute.path != headerFile.absolute.path) {
           processedFiles.add(partPath);
        }
        
        onLog?.call("处理分片 ${i + 1}/${parts.length}: $partName");
        final partRaf = await partFile.open(mode: FileMode.read);
        
        try {
          // Verify Magic
          List<int> pMagicBytes = await partRaf.read(utf8.encode(_magic).length);
          String pMagic = utf8.decode(pMagicBytes);
          if (pMagic != _magic) {
            throw Exception("分片文件损坏 (Part file corrupted): $partName");
          }

          // Read Len
          List<int> pLenBytes = await partRaf.read(4);
          int pMetaLen = ByteData.sublistView(Uint8List.fromList(pLenBytes)).getUint32(0, Endian.big);
          // Skip Meta
          await partRaf.read(pMetaLen);
          
          // Now we are at payload
          var digestSink = DigestSink();
          var hashSink = sha256.startChunkedConversion(digestSink);
          
          int bufferSize = 1024 * 1024;
          while (true) {
            List<int> chunk = await partRaf.read(bufferSize);
            if (chunk.isEmpty) break;
            
            hashSink.add(chunk);
            sink.add(chunk);
          }
          
          hashSink.close();
          
          if (digestSink.value.toString() != expectedHash) {
            throw Exception("哈希校验失败: $partName (Hash mismatch for part $partName)");
          }
        } finally {
          await partRaf.close();
        }
        
        onProgress((i + 1) / parts.length);
      }
      
      await sink.flush();
    } catch (e) {
      await sink.close();
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      rethrow;
    }
    await sink.close();
    
    // Final verification of full file
    onLog?.call("正在校验还原文件完整性...");
    String restoredHash = await _calculateFileHash(outputFile);
    if (restoredHash != originalHash) {
      throw Exception("还原文件完整性校验失败 (Restored file hash mismatch)");
    }
    onLog?.call("还原文件校验成功!");
    return processedFiles;
  }

  Future<String> _calculateFileHash(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }
}

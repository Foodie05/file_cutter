import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  
  var methodChannel: FlutterMethodChannel?
  var pendingFiles: [String]?
  var isFlutterReady: Bool = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
    methodChannel = FlutterMethodChannel(name: "com.example.file_cutter/file_open",
                                          binaryMessenger: controller.engine.binaryMessenger)
    
    methodChannel?.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "getStartupFiles" {
        result(self?.pendingFiles)
        self?.pendingFiles = nil
      } else if call.method == "notifyReady" {
        self?.isFlutterReady = true
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    
    super.applicationDidFinishLaunching(notification)
    NSApp.servicesProvider = self
  }
  
  @objc func handleFileCutterService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    var files: [String] = []
    
    // 1. Try to read URLs (modern approach)
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
        for url in urls {
            if url.isFileURL {
                files.append(url.path)
            }
        }
    }
    
    // 2. Try to read legacy filenames if no URLs found or as supplement
    // Using propertyList for NSFilenamesPboardType
    if files.isEmpty {
        if let legacyFiles = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
             for file in legacyFiles {
                 if !files.contains(file) {
                     files.append(file)
                 }
             }
        }
    }

    // 3. Try to read plain text as file path (sometimes happens)
    if files.isEmpty {
        if let text = pasteboard.string(forType: .string) {
            // Check if the text looks like a file path
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: path) {
                files.append(path)
            }
        }
    }
    
    if !files.isEmpty {
      processFiles(files)
    } else {
        NSLog("FileCutter Service: No valid files found in pasteboard. Types available: \(pasteboard.types?.description ?? "nil")")
        // Optionally set error
        error.pointee = "No valid files found."
    }
  }

  // Handle modern file opening (macOS 10.13+)
  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.map { $0.path }
    processFiles(files)
  }

  // Handle legacy openFiles
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    processFiles(filenames)
    sender.reply(toOpenOrPrint: .success)
  }
  
  // Handle legacy openFile
  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    processFiles([filename])
    return true
  }
  
  private func processFiles(_ files: [String]) {
    if isFlutterReady, let channel = methodChannel {
      channel.invokeMethod("openFiles", arguments: files)
    } else {
      if pendingFiles == nil {
        pendingFiles = files
      } else {
        pendingFiles?.append(contentsOf: files)
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

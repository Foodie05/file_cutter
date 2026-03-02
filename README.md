# FileCutter

A powerful and easy-to-use file splitting and merging tool for macOS, built with Flutter.

## Features

*   **File Splitting**: Split large files into smaller chunks based on custom sizes (e.g., 100MB, 1GB).
*   **File Merging**: Restore original files from split chunks using the generated `.fch` (File Cutter Header) file.
*   **Batch Processing**: Support for selecting and processing multiple files simultaneously.
*   **Drag & Drop**: Drag files directly into the app to start processing.
*   **Direct Opening**: Double-click `.fch` files to automatically open FileCutter and prepare for merging.
*   **Auto-Cleanup**: Automatically deletes source files after a successful split or merge operation to save disk space.
*   **Real-time Logs**: View detailed progress and operation logs directly within the app.

## Usage

### Splitting Files
1.  Open the **Split** tab.
2.  Click "Select Files" or drag files into the window. You can select multiple files.
3.  Choose a split size (e.g., 100MB).
4.  Click "Start Split".
5.  The app will generate `.fch` (header) and `.fct` (content) files in the same directory.
6.  *Note: The original files will be deleted upon successful completion.*

### Merging Files
1.  Open the **Merge** tab.
2.  Click "Select Files" or drag `.fch` files into the window.
3.  Click "Start Merge".
4.  The app will verify all chunks and restore the original file.
5.  *Note: The `.fch` and `.fct` chunk files will be deleted upon successful completion.*

## Known Issues

*   **Right-click Service Support**: The "Use FileCutter to split file" service in the macOS Finder context menu (Right-click > Services) currently has imperfect support. In some cases, the selected file path may not be correctly passed to the application. We are working on a fix for this in future updates.

## Development

This project is a Flutter application.

1.  Ensure you have Flutter installed.
2.  Run `flutter pub get` to install dependencies.
3.  Run `flutter run -d macos` to start the app in debug mode.

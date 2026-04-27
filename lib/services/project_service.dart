import 'dart:io';
import 'package:file_picker/file_picker.dart' ;

class ProjectService {
  static final ProjectService _instance = ProjectService._internal();
  factory ProjectService() => _instance;
  ProjectService._internal();

  String? _currentPath;

  String get currentPath => _currentPath ?? Directory.current.path;

  Future<String?> pickProjectFolder() async {
    return await FilePicker.getDirectoryPath();
  }

  void setProjectFolder(String path) {
    _currentPath = path;
  }
}

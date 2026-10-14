import 'dart:async';
import 'dart:io';

import 'package:hisvpn/common/common.dart';
import 'package:hisvpn/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class AppPath {
  static AppPath? _instance;
  Completer<Directory> dataDir = Completer();
  late final Future<Directory?> _downloadDir = downloadDirectory();
  Completer<Directory> tempDir = Completer();
  Completer<Directory> cacheDir = Completer();
  late String appDirPath;

  @visibleForTesting
  static Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory;

  @visibleForTesting
  static Future<Directory> Function() temporaryDirectory =
      getTemporaryDirectory;

  @visibleForTesting
  static Future<Directory> Function() cacheDirectory =
      getApplicationCacheDirectory;

  @visibleForTesting
  static Future<Directory?> Function() downloadDirectory =
      getDownloadsDirectory;

  AppPath._internal() {
    appDirPath = join(dirname(Platform.resolvedExecutable));
    _resolveDataDir().then((value) {
      dataDir.complete(value);
    });
    temporaryDirectory().then((value) {
      tempDir.complete(value);
    });
    cacheDirectory().then((value) {
      cacheDir.complete(value);
    });
  }

  /// On iOS the home directory must live in the App Group container so the
  /// NetworkExtension tunnel process reads the same database, profiles and
  /// config.yaml the app writes. Everywhere else keeps the support dir.
  static void _copyTree(String from, String to) {
    final src = Directory(from);
    Directory(to).createSync(recursive: true);
    for (final entity in src.listSync()) {
      final target = join(to, basename(entity.path));
      if (entity is Directory) {
        _copyTree(entity.path, target);
      } else if (entity is File) {
        entity.copySync(target);
      }
    }
  }

  Future<Directory> _resolveDataDir() async {
    final fallback = await supportDirectory();
    if (!Platform.isIOS) {
      return fallback;
    }
    try {
      final groupPath = await const MethodChannel('$packageName/app')
          .invokeMethod<String>('appGroupPath');
      if (groupPath == null || groupPath.isEmpty) {
        return fallback;
      }
      final groupDir = Directory(groupPath);
      await groupDir.create(recursive: true);
      // One-shot migration from the pre-tunnel sandbox layout so existing
      // subscriptions and settings survive the move. We COPY, never move:
      // rename across container boundaries can fail with EXDEV and a failed
      // move would leave the source in a half-moved state, silently dropping
      // profiles and hiding the start button. Copying keeps the sandbox copy
      // intact as a fallback.
      if (groupDir.listSync().isEmpty &&
          fallback.existsSync() &&
          fallback.listSync().isNotEmpty) {
        for (final entity in fallback.listSync()) {
          try {
            final target = join(groupPath, basename(entity.path));
            if (entity is Directory) {
              _copyTree(entity.path, target);
            } else if (entity is File) {
              entity.copySync(target);
            }
          } catch (_) {
            // A single unreadable entry must not abort the whole migration.
          }
        }
      }
      return groupDir;
    } catch (_) {
      return fallback;
    }
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(executableDirPath, 'HISVPNCore$executableExtension');
  }

  String get helperPath {
    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  Future<String> get downloadDirPath async {
    final directory = await _downloadDir;
    return directory?.path ?? await homeDirPath;
  }

  Future<String> get homeDirPath async {
    final directory = await dataDir.future;
    return directory.path;
  }

  Future<String> get databasePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'database.sqlite');
  }

  Future<String> get tempFilePath async {
    final mTempDir = await tempDir.future;
    return join(mTempDir.path, 'temp$uniqueId');
  }

  Future<String> get lockFilePath async {
    final homeDirPath = await appPath.homeDirPath;
    return join(homeDirPath, 'HISVPN.lock');
  }

  Future<String> get configFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'config.yaml');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'shared_preferences.json');
  }

  Future<String> get profilesPath async {
    final directory = await dataDir.future;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String fileName) async {
    return join(await profilesPath, '$fileName.yaml');
  }

  Future<String> get scriptsDirPath async {
    final path = await homeDirPath;
    return join(path, 'scripts');
  }

  Future<String> getScriptPath(String fileName) async {
    final path = await scriptsDirPath;
    return join(path, '$fileName.js');
  }

  Future<String> get providerCacheRootPath async {
    final directory = await homeDirPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderCachePath(
    ProviderKind kind,
    String fileName,
  ) async {
    return join(
      await providerCacheRootPath,
      providerCacheDirectoryName(kind),
      fileName,
    );
  }

  Future<String> getProvidersRootPath() async {
    final directory = await profilesPath;
    return join(directory, providersDirectoryName);
  }

  Future<String> getProviderDirPath(int profileId, String type) async {
    final directory = await getProvidersRootPath();
    return join(directory, profileId.toString(), type);
  }

  Future<void> ensureProviderDirs(int profileId) async {
    for (final type in const [
      proxiesProviderDirectoryName,
      rulesProviderDirectoryName,
    ]) {
      final directory = Directory(await getProviderDirPath(profileId, type));
      if (await directory.exists()) {
        continue;
      }
      await directory.create(recursive: true);
    }
  }

  Future<String> get tempPath async {
    final directory = await tempDir.future;
    return directory.path;
  }
}

final appPath = AppPath();

String getBackupFileName() {
  return '${appName}_backup_${DateTime.now().show}.zip';
}

String get logFileName {
  return '${appName}_${DateTime.now().show}.log';
}

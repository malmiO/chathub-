import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart' as path;
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LocalDatabase {
  Database? _database;
  bool get isOpen => _database?.isOpen ?? false;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final String _dbPasswordKey = 'chatgroups_db_password';

  Future<void> initDatabase() async {
    try {
      var databasesPath = await getDatabasesPath();
      print('DB path: $databasesPath');
      String dbPath = path.join(databasesPath, 'group_chat_messages.db');

      // Check if password already stored
      String? password = await _secureStorage.read(key: _dbPasswordKey);

      if (password == null) {
        // Generate a strong random password
        password = base64UrlEncode(
          List<int>.generate(
            32,
            (i) => DateTime.now().millisecondsSinceEpoch % 256,
          ),
        );
        await _secureStorage.write(key: _dbPasswordKey, value: password);
      }

      _database = await openDatabase(
        dbPath,
        version: 6, // Incremented version
        onCreate: (Database db, int version) async {
          await db.execute('''
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              filePath TEXT,
              content TEXT,
              type TEXT,
              isMe INTEGER,
              status TEXT,
              createdAt TEXT,
              tempId TEXT,
              serverId TEXT  
            )
          ''');
          await db.execute('''
            CREATE TABLE groups (
              id TEXT PRIMARY KEY,
              name TEXT,
              profile_pic TEXT,
              members TEXT,
              last_message TEXT,
              last_message_time TEXT,
              unread_count INTEGER,
              is_typing INTEGER
            )
          ''');
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          if (oldVersion < 3) {
            await db.execute('ALTER TABLE messages ADD COLUMN tempId TEXT');
          }
          if (oldVersion < 4) {
            await db.execute('ALTER TABLE messages ADD COLUMN filePath TEXT');
          }
          if (oldVersion < 5) {
            await db.execute('ALTER TABLE messages ADD COLUMN serverId TEXT');
          }
          if (oldVersion < 6) {
            await db.execute('''
              CREATE TABLE groups (
                id TEXT PRIMARY KEY,
                name TEXT,
                profile_pic TEXT,
                members TEXT,
                last_message TEXT,
                last_message_time TEXT,
                unread_count INTEGER,
                is_typing INTEGER
              )
            ''');
          }
        },
      );
      print('Database initialized successfully');
    } catch (e) {
      print('Error initializing database: $e');
    }
  }

  Future<void> insertMediaMessage({
    required String filePath,
    required String content,
    required String type,
    required int isMe,
    required String status,
    required String createdAt,
    required String tempId,
    String? serverId,
  }) async {
    await _database?.insert('messages', {
      'filePath': filePath,
      'content': content,
      'type': type,
      'isMe': isMe,
      'status': status,
      'createdAt': createdAt,
      'tempId': tempId,
      'serverId': serverId,
    });
  }

  Future<void> insertTextMessage({
    required String content,
    required int isMe,
    required String status,
    required String createdAt,
    required String tempId,
    String? serverId,
  }) async {
    await _database?.insert('messages', {
      'content': content,
      'type': 'text',
      'isMe': isMe,
      'status': status,
      'createdAt': createdAt,
      'tempId': tempId,
      'serverId': serverId,
    });
  }

  Future<void> updateMessageStatus({
    required String tempId,
    required String status,
    String? content,
    String? serverId,
  }) async {
    Map<String, dynamic> values = {'status': status};
    if (content != null) values['content'] = content;
    if (serverId != null) values['serverId'] = serverId;

    await _database?.update(
      'messages',
      values,
      where: 'tempId = ?',
      whereArgs: [tempId],
    );
  }

  Future<void> updateMessage({
    required String whereColumn,
    required String whereValue,
    required Map<String, dynamic> values,
  }) async {
    await _database?.update(
      'messages',
      values,
      where: '$whereColumn = ?',
      whereArgs: [whereValue],
    );
  }

  Future<List<Map<String, dynamic>>> getMessages() async {
    return await _database?.query('messages') ?? [];
  }

  Future<void> close() async {
    await _database?.close();
  }

  Future<int> deleteMessage(String id) async {
    return await _database?.delete(
          'messages',
          where: 'tempId = ? OR serverId = ?',
          whereArgs: [id, id],
        ) ??
        0;
  }

  Future<void> replaceGroups(List<Map<String, dynamic>> groups) async {
    if (!isOpen) {
      print('Database is not open, cannot replace groups');
      return;
    }
    await _database?.transaction((txn) async {
      await txn.delete('groups');
      for (var group in groups) {
        try {
          await txn.insert('groups', {
            'id': group['group_id']?.toString(),
            'name': group['name'] ?? 'Unnamed Group',
            'profile_pic': group['profile_pic'],
            'members': json.encode(group['members'] ?? []),
            'last_message': group['last_message'],
            'last_message_time': group['last_message_time'],
            'unread_count': group['unread_count'] ?? 0,
            'is_typing': (group['is_typing'] ?? false) ? 1 : 0,
          });
        } catch (e) {
          print('Error inserting group ${group['group_id']}: $e');
          continue; // Skip problematic group
        }
      }
    });
  }

  Future<List<Map<String, dynamic>>> getGroups() async {
    final List<Map<String, dynamic>>? result = await _database?.query('groups');
    return result?.map((map) {
          return {
            'group_id': map['id'],
            'name': map['name'],
            'profile_pic': map['profile_pic'],
            'members': json.decode(map['members']),
            'last_message': map['last_message'],
            'last_message_time': map['last_message_time'],
            'unread_count': map['unread_count'],
            'is_typing': map['is_typing'] == 1,
          };
        }).toList() ??
        [];
  }
}

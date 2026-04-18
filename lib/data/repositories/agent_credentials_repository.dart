import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/agent_credentials.dart';

class AgentCredentialsRepository {
  static const String tableName = 'agent_credentials';

  static final AgentCredentialsRepository _instance =
      AgentCredentialsRepository._internal();

  factory AgentCredentialsRepository() {
    return _instance;
  }

  AgentCredentialsRepository._internal();

  static AgentCredentialsRepository get instance => _instance;

  Future<AgentCredentials?> getCredentials() async {
    final db = await AppDatabase.instance.database;
    final result = await db.query(tableName, limit: 1);
    if (result.isEmpty) {
      return null;
    }
    return AgentCredentials.fromMap(result.first);
  }

  Future<void> saveCredentials(AgentCredentials credentials) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now();
    final data = {
      'id': 'agent_creds',
      'hf_token': credentials.hfToken,
      'local_key': credentials.localKey,
      'updated_at': now.millisecondsSinceEpoch,
    };

    await db.insert(
      tableName,
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearCredentials() async {
    final db = await AppDatabase.instance.database;
    await db.delete(tableName);
  }
}

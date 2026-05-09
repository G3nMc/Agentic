# PostgreSQL Migration Guide

## Overview
This document outlines the steps to migrate from SQLite to PostgreSQL for the chat storage system.

## Current State
The application currently uses SQLite with the following schema:

1. `settings` - Key/value application settings
2. `models` - Saved HF model IDs
3. `conversations` - Conversation metadata
4. `messages` - Individual chat messages
5. `backend_settings` - Backend configuration
6. `local_server_configs` - Local server configurations
7. `agent_credentials` - API credentials
8. `context_summaries` - Conversation context summaries

## Migration Steps

### 1. Add PostgreSQL Dependencies
Add the following dependencies to `pubspec.yaml`:

```yaml
dependencies:
  postgres: ^2.0.0
```

### 2. Create PostgreSQL Connection Service
Create `lib/data/database/postgres_database.dart`:

```dart
import 'package:postgres/postgres.dart';

class PostgresDatabase {
  static final PostgresDatabase instance = PostgresDatabase._();
  
  late PostgreSQLConnection _connection;
  
  PostgresDatabase._();
  
  Future<void> connect(String host, int port, String database, String username, String password) async {
    _connection = PostgreSQLConnection(host, port, database, username: username, password: password);
    await _connection.open();
    
    // Create tables if they don't exist
    await _createTables();
  }
  
  Future<void> _createTables() async {
    // Create settings table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key VARCHAR(255) PRIMARY KEY,
        value TEXT
      )
    ''');
    
    // Create models table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS models (
        id VARCHAR(255) PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        created_at BIGINT NOT NULL
      )
    ''');
    
    // Create conversations table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id VARCHAR(255) PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        model_id VARCHAR(255),
        backend VARCHAR(50),
        created_at BIGINT NOT NULL,
        updated_at BIGINT NOT NULL,
        group_id VARCHAR(255)
      )
    ''');
    
    // Create indexes
    await _connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_conversations_updated_at 
      ON conversations(updated_at DESC)
    ''');
    
    // Create messages table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id VARCHAR(255) PRIMARY KEY,
        conversation_id VARCHAR(255) NOT NULL,
        role VARCHAR(20) NOT NULL,
        content TEXT NOT NULL,
        created_at BIGINT NOT NULL,
        agent VARCHAR(50),
        response_time_ms INTEGER,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    
    // Create indexes
    await _connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conversation 
      ON messages(conversation_id, created_at ASC)
    ''');
    
    // Create backend_settings table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS backend_settings (
        id VARCHAR(255) PRIMARY KEY,
        value TEXT
      )
    ''');
    
    // Create local_server_configs table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS local_server_configs (
        model_id VARCHAR(255) PRIMARY KEY,
        python_code TEXT NOT NULL,
        host VARCHAR(255) NOT NULL DEFAULT 'localhost',
        port INTEGER NOT NULL DEFAULT 5000,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        created_at BIGINT NOT NULL
      )
    ''');
    
    // Create agent_credentials table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS agent_credentials (
        id VARCHAR(255) PRIMARY KEY,
        hf_token TEXT,
        local_key TEXT,
        updated_at BIGINT
      )
    ''');
    
    // Create context_summaries table
    await _connection.execute('''
      CREATE TABLE IF NOT EXISTS context_summaries (
        conversation_id VARCHAR(255) PRIMARY KEY,
        summary_text TEXT NOT NULL,
        created_at BIGINT NOT NULL,
        updated_at BIGINT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
  }
  
  PostgreSQLConnection get connection => _connection;
  
  Future<void> close() async {
    await _connection.close();
  }
}
```

### 3. Update Repository Classes
Update each repository class to use PostgreSQL instead of SQLite. For example, `conversation_repository.dart`:

```dart
import '../database/postgres_database.dart';
import '../models/conversation.dart';

class ConversationRepository {
  ConversationRepository._();

  static final ConversationRepository instance = ConversationRepository._();

  Future<List<Conversation>> listRecent({int limit = 20}) async {
    final result = await PostgresDatabase.instance.connection.query(
      'SELECT * FROM conversations ORDER BY updated_at DESC LIMIT @limit',
      substitutionValues: {'limit': limit},
    );
    
    return result.map((row) => Conversation.fromMap(_rowToMap(row))).toList();
  }
  
  Future<Conversation?> getById(String id) async {
    final result = await PostgresDatabase.instance.connection.query(
      'SELECT * FROM conversations WHERE id = @id',
      substitutionValues: {'id': id},
    );
    
    if (result.isEmpty) return null;
    return Conversation.fromMap(_rowToMap(result.first));
  }
  
  Future<void> save(Conversation conversation) async {
    await PostgresDatabase.instance.connection.execute(
      '''
      INSERT INTO conversations (id, title, model_id, backend, created_at, updated_at, group_id)
      VALUES (@id, @title, @modelId, @backend, @createdAt, @updatedAt, @groupId)
      ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title,
        model_id = EXCLUDED.model_id,
        backend = EXCLUDED.backend,
        updated_at = EXCLUDED.updated_at,
        group_id = EXCLUDED.group_id
      ''',
      substitutionValues: {
        'id': conversation.id,
        'title': conversation.title,
        'modelId': conversation.modelId,
        'backend': conversation.backend,
        'createdAt': conversation.createdAt,
        'updatedAt': conversation.updatedAt,
        'groupId': conversation.groupId,
      },
    );
  }
  
  // Helper method to convert row to map
  Map<String, dynamic> _rowToMap(Row row) {
    return {
      'id': row['id'],
      'title': row['title'],
      'model_id': row['model_id'],
      'backend': row['backend'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'group_id': row['group_id'],
    };
  }
}
```

### 4. Update App Initialization
Update the app initialization to connect to PostgreSQL:

```dart
// In main.dart or app initialization
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Connect to PostgreSQL
  await PostgresDatabase.instance.connect(
    'localhost',
    5432,
    'hf_chat_db',
    'username',
    'password',
  );
  
  runApp(MyApp());
}
```

## Benefits of PostgreSQL Migration

1. **Scalability**: PostgreSQL can handle much larger datasets than SQLite
2. **Concurrent Access**: Better handling of concurrent reads/writes
3. **Advanced Features**: Support for complex queries, triggers, and stored procedures
4. **Replication**: Built-in support for replication and high availability
5. **Performance**: Better optimization for complex queries

## Considerations

1. **Deployment Complexity**: Requires PostgreSQL server setup
2. **Network Latency**: Database calls will have network latency
3. **Migration Strategy**: Need to migrate existing SQLite data to PostgreSQL
4. **Connection Management**: Need to handle connection pooling and failures
import 'dart:async';
import 'dart:io';

import 'package:dbmigrator/dbmigrator.dart';
import 'package:postgres/postgres.dart';

class PostgresMigrator with Migratable {
  PostgresMigrator({required Connection connection, required this.options}) : _conn = connection;

  final Connection _conn;
  final PsqlMigrationOptions options;

  @override
  PsqlMigrationOptions get migrationOptions => options;

  /// The schema-qualified and properly quoted version table name.
  String get versionTable => '"${options.schema}"."${options.versionTable}"';

  /// SQLSTATE codes of transient connection/server-availability errors.
  static const _retryableCodes = {
    '08000', // connection_exception
    '08001', // sqlclient_unable_to_establish_sqlconnection
    '08003', // connection_does_not_exist
    '08004', // sqlserver_rejected_establishment_of_sqlconnection
    '08006', // connection_failure
    '08007', // transaction_resolution_unknown
    '08P01', // protocol_violation
    '53300', // too_many_connections
    '57P01', // admin_shutdown
    '57P02', // crash_shutdown
    '57P03', // cannot_connect_now
    '57P04', // database_dropped
    '58030', // io_error
    '55P03', // lock_not_available (e.g. lock_timeout)
  };

  // Deadlocks (40P01) and serialization failures (40001) are deliberately not retried:
  // statements run inside a transaction that is already aborted by the error (25P02),
  // so retrying a single statement can never succeed. Query cancellation (57014) is
  // not retried either, as a statement that timed out would simply time out again.

  @override
  bool isRetryable(Object error) {
    // Checked first: the driver's query-cancelled (57014) exception is both a ServerException and a TimeoutException
    if (error is ServerException) {
      // Decide by SQLSTATE only. FATAL/PANIC severity alone is not enough, since it also covers
      // non-transient errors such as authentication failures (28xxx) or a missing database (3D000).
      return _retryableCodes.contains(error.code);
    }

    if (error is SocketException || error is TimeoutException || error is HandshakeException) return true;

    if (error is PgException) {
      // Client-side errors (e.g. closed connection): search for specific keywords in the message
      final msg = error.message.toLowerCase();
      return msg.contains('connection') &&
          (msg.contains('closed') || msg.contains('terminated') || msg.contains('reset') || msg.contains('broken'));
    }

    return false;
  }

  @override
  Future<void> acquireLock() async {
    final deadline = DateTime.now().add(options.timeout);

    while (true) {
      final result = await _conn.execute(
        Sql.named('SELECT pg_try_advisory_lock(hashtext(@lock_key))'),
        parameters: {'lock_key': options.lockKey},
        timeout: options.timeout,
      );
      if (result.first.first == true) return;

      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Could not acquire migration lock "${options.lockKey}"', options.timeout);
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Future<void> releaseLock() async {
    final result = await _conn.execute(
      Sql.named('SELECT pg_advisory_unlock(hashtext(@lock_key))'),
      parameters: {'lock_key': options.lockKey},
      timeout: options.timeout,
    );
    if (result.first.first != true) {
      throw StateError('Migration lock "${options.lockKey}" was not held by this session');
    }
  }

  @override
  Future<void> transaction(Future<dynamic> Function(TxSession ctx) fn) async {
    await _conn.runTx((ctx) async {
      // Make unqualified names in migration files resolve against the configured schema
      await ctx.execute('SET LOCAL search_path TO "${options.schema}", public', queryMode: QueryMode.simple);
      return await fn(ctx);
    });
  }

  @override
  Future<dynamic> execute(Object obj, {Map<String, dynamic> params = const {}, dynamic ctx}) async {
    // A null context means we are not inside a transaction
    if (ctx != null && ctx is! TxSession) throw ArgumentError('ctx is not a TxSession instance');
    if (obj is! String) throw ArgumentError('obj has to be a String');

    final session = (ctx as TxSession?) ?? _conn;
    if (params.isNotEmpty) {
      await session.execute(Sql.named(obj), parameters: params);
    } else {
      // Simple query mode allows migration files to contain multiple statements
      await session.execute(obj, queryMode: QueryMode.simple);
    }
  }

  @override
  Future<({String version, String checksum})?> queryVersion() async {
    try {
      final result = await _conn.execute(
        'SELECT version, checksum FROM $versionTable ORDER BY id DESC LIMIT 1',
        timeout: options.timeout,
      );
      if (result.isEmpty) return (version: '', checksum: '');

      final row = result.first.toColumnMap();
      return (version: row['version'] as String? ?? '', checksum: row['checksum'] as String? ?? '');
    } on ServerException catch (e) {
      // Only a missing table (or schema) means the version table has to be created
      if (e.code != '42P01' && e.code != '3F000') rethrow;
    }

    try {
      // Runs as one implicit transaction (simple query mode)
      await _conn.execute(
        """CREATE SCHEMA IF NOT EXISTS "${options.schema}";
           CREATE TABLE IF NOT EXISTS $versionTable (
             id           BIGSERIAL PRIMARY KEY,
             version      VARCHAR NOT NULL,
             checksum     VARCHAR NOT NULL,
             started_at   TIMESTAMP WITH TIME ZONE NOT NULL,
             completed_at TIMESTAMP WITH TIME ZONE NOT NULL,
             direction    VARCHAR NOT NULL CHECK (direction IN ('up', 'down')),
             comments     VARCHAR
           );
           CREATE INDEX IF NOT EXISTS "idx_${options.versionTable}_version" ON $versionTable (version);""",
        queryMode: QueryMode.simple,
      );
    } on ServerException catch (e) {
      // Tolerate concurrent creation: duplicate schema/object, or pg_type unique violation
      if (!const {'23505', '42P06', '42P07'}.contains(e.code)) rethrow;
    }

    return (version: '', checksum: '');
  }

  @override
  Future<void> saveVersion({required MigrationResult result, dynamic ctx, String? comment}) async {
    if (ctx != null && ctx is! TxSession) throw ArgumentError('ctx is not a TxSession instance');

    final sql = """INSERT INTO $versionTable (version, checksum, started_at, completed_at, direction, comments)
           VALUES (@version, @checksum, @started_at, @completed_at, @direction, @comments)""";

    await ((ctx as TxSession?) ?? _conn).execute(
      Sql.named(sql),
      parameters: {
        'version': result.toVersion,
        'checksum': result.checksum,
        'started_at': result.started.toUtc(),
        'completed_at': result.completed.toUtc(),
        'direction': result.direction == MigrationDirection.down ? 'down' : 'up',
        'comments': comment,
      },
      timeout: options.timeout,
    );
  }
}

class PsqlMigrationOptions extends MigrationOptions {
  /// [schema] and [versionTable] must be proper PostgreSQL identifier names (they are double-quoted but not escaped).
  /// [versionTable] is limited to 51 characters, so that the derived index name fits PostgreSQL's 63-byte limit.
  PsqlMigrationOptions({
    required super.path,
    String schema = 'public',
    super.filesPattern,
    super.directoryBased,
    String versionTable = '_version',
    super.retries,
    super.retryDelay,
    super.timeout,
    super.checksums,
    super.encoding,
    super.lockKey,
  }) : super(
         schema: schema.trim().isEmpty ? throw ArgumentError.value(schema, 'schema', 'must not be empty') : schema,
         versionTable: versionTable.trim().isEmpty
             ? throw ArgumentError.value(versionTable, 'versionTable', 'must not be empty')
             : versionTable.length > 51
             ? throw ArgumentError.value(versionTable, 'versionTable', 'must not exceed 51 characters')
             : versionTable,
       );
}

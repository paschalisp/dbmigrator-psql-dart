import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dbmigrator/dbmigrator.dart';
import 'package:postgres/postgres.dart';

class PostgresMigrator with Migratable {
  PostgresMigrator({required Connection connection, required this.options}) : _conn = connection;

  final Connection _conn;
  final PsqlMigrationOptions options;

  @override
  PsqlMigrationOptions get migrationOptions => options;

  String get versionTable =>
      options.schema.isNotEmpty ? '${options.schema}.${options.versionTable}' : options.versionTable;

  @override
  bool isRetryable(Object error) {
    if (error is SocketException) return true;

    if (error is PgException) {
      // Treat "fatal+"-severity errors as connection-related.
      if ([Severity.fatal, Severity.panic].contains(error.severity)) return true;

      // Try evaluating by error code
      if (error is ServerException) {
        return const {
          '08000', // connection_exception
          '08003', // connection_does_not_exist
          '08006', // connection_failure
          '53300', // too_many_connections
          '57P01', //	admin_shutdown
          '57P02', //	crash_shutdown
          '57P03', //	cannot_connect_now
          '58030', //	io_error
          '40P01', // deadlock_detected
          '40001', // serialization_failure
          '55P03', // lock_not_available
          '57014', // query_canceled (includes lock_timeout)
        }.contains(error.code);
      }

      // Lastly, try by searching for specific keywords in the error message
      final msg = error.message.toLowerCase();
      if (msg.contains('connection') &&
          (msg.contains('closed') || msg.contains('terminated') || msg.contains('reset') || msg.contains('broken'))) {
        return true;
      }
    }

    return false;
  }

  @override
  Future<void> acquireLock() async {
    await _conn.execute(
      Sql.named('SELECT pg_advisory_lock(@lock_key:bigint)'),
      parameters: {'lock_key': _advisoryLockKey(options.lockKey)},
    );
  }

  @override
  Future<void> releaseLock() async {
    await _conn.execute(
      Sql.named('SELECT pg_advisory_unlock(@lock_key:bigint)'),
      parameters: {'lock_key': _advisoryLockKey(options.lockKey)},
    );
  }

  @override
  Future<void> transaction(Future<dynamic> Function(TxSession ctx) fn) async {
    await _conn.runTx(fn);
  }

  @override
  Future<dynamic> execute(Object obj, {Map<String, dynamic> params = const {}, dynamic ctx}) async {
    if (ctx == null || ctx is! TxSession) throw ArgumentError('ctx is not a TxSession instance');
    if (params.isNotEmpty && obj is! String) throw ArgumentError('when params are given, then obj has to be a string');

    if (params.isNotEmpty) {
      await ctx.execute(Sql.named(obj as String), parameters: params);
    } else {
      await ctx.execute(obj);
    }
  }

  @override
  Future<({String version, String checksum})?> queryVersion() async {
    try {
      final sql = 'SELECT version, checksum FROM $versionTable ORDER BY id DESC LIMIT 1';
      final result = await _conn.execute(sql);
      final row = result.isEmpty ? {} : result.first.toColumnMap();

      return (version: row['version'] as String? ?? '', checksum: row['checksum'] as String? ?? '');
    } catch (e) {
      if (!isRetryable(e)) {
        String sql =
            """
            CREATE TABLE IF NOT EXISTS ${options.schema}.${options.versionTable} (
                 id           BIGSERIAL PRIMARY KEY,
                 version      VARCHAR NOT NULL,
                 checksum     VARCHAR NOT NULL,
                 started_at   TIMESTAMP WITH TIME ZONE NOT NULL,
                 completed_at TIMESTAMP WITH TIME ZONE NOT NULL,
                 direction    VARCHAR NOT NULL CHECK (direction IN ('up', 'down')),
                 comments     VARCHAR
            )
        """;
        await _conn.execute(sql);

        sql =
            """
            CREATE INDEX IF NOT EXISTS idx_${options.versionTable}_version ON ${options.schema}.${options.versionTable} (version);
            """;
        await _conn.execute(sql);

        return (version: Migratable.minVersion, checksum: '');
      }

      rethrow;
    }
  }

  @override
  Future<void> saveVersion({required MigrationResult result, dynamic ctx, String? comment}) async {
    if (ctx == null || ctx is! TxSession) throw ArgumentError('ctx is not a TxSession instance');

    final sql =
        """INSERT INTO ${options.schema}.${options.versionTable} (version, checksum, started_at, completed_at, direction, comments)
           VALUES (@version, @checksum, @started_at, @completed_at, @direction, @comments)""";

    await ctx.execute(
      Sql.named(sql),
      parameters: {
        'version': result.toVersion,
        'checksum': result.checksum,
        'started_at': result.started,
        'completed_at': result.completed,
        'direction': result.direction == MigrationDirection.down ? 'down' : 'up',
        'comments': comment,
      },
      timeout: options.timeout,
    );
  }

  // region Internal methods
  int _advisoryLockKey(String input) {
    final digest = sha256.convert(utf8.encode(input)).bytes;
    // Take first 8 bytes as signed 64-bit integer
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | digest[i];
    }
    return value;
  }

  // endregion
}

class PsqlMigrationOptions extends MigrationOptions {
  PsqlMigrationOptions({
    required super.path,
    super.filesPattern,
    super.directoryBased,
    super.schema = 'public',
    super.versionTable,
    super.retries,
    super.retryDelay,
    super.timeout,
    super.checksums,
    super.encoding,
  }) : assert(schema.isNotEmpty, 'schema must not be empty'),
       assert(versionTable.isNotEmpty, 'version table must not be empty');
}

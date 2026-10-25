import 'dart:async';
import 'dart:io';

import 'package:dbmigrator/dbmigrator.dart';
import 'package:dbmigrator_psql/dbmigrator_psql.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  defineTests('File-based migrations execution', dir: './test/migrations/file-based', directoryBased: false);
  defineTests('Directory-based migrations execution', dir: './test/migrations/dir-based', directoryBased: true);
}

void defineTests(String name, {required String dir, required bool directoryBased}) {
  String file(String version, String direction) =>
      directoryBased ? '$version/$direction.sql' : '$version.$direction.sql';
  PsqlMigrationOptions opts({String schema = 'public', String versionTable = '_version', Duration? timeout}) =>
      PsqlMigrationOptions(
        path: dir,
        directoryBased: directoryBased,
        schema: schema,
        versionTable: versionTable,
        timeout: timeout ?? const Duration(seconds: 15),
      );

  group(name, () {
    late final Connection conn;

    Future<Connection> open() => Connection.open(
      Endpoint(host: 'localhost', port: 5932, database: 'test_db', username: 'test', password: 'test'),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );

    setUpAll(() async => conn = await open());

    setUp(() async {
      await conn.execute('''
        DROP SCHEMA IF EXISTS "My-Schema" CASCADE;
        DROP TABLE IF EXISTS public._version;
        DROP TABLE IF EXISTS public.table1;
        DROP TABLE IF EXISTS public.table2;
        DROP TABLE IF EXISTS public.table3;
      ''', queryMode: QueryMode.simple);
    });

    tearDown(() async {
      await conn.execute('''
        DROP SCHEMA IF EXISTS "My-Schema" CASCADE;
        DROP TABLE IF EXISTS public._version;
        DROP TABLE IF EXISTS public.table1;
        DROP TABLE IF EXISTS public.table2;
        DROP TABLE IF EXISTS public.table3;
      ''', queryMode: QueryMode.simple);
    });

    tearDownAll(() async {
      await conn.close();
    });

    test('Executes the correct upgrade migration files', () async {
      final res = await conn.migrator(options: opts()).migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(
        res.files.names(),
        containsAllInOrder([
          for (final v in ['0.0.1', '1.0.0', '1.1.0', '2.0.0']) file(v, 'up'),
        ]),
      );
    });

    test('Upgrading to the last version creates all tables with the subsequent changes', () async {
      await conn.migrator(options: opts()).migrate(version: '2.0.0');

      await expectLater(conn.execute('SELECT id, col1, col2, col3 FROM public.table1'), completes);
      await expectLater(conn.execute('SELECT id, col1, col2, col3 FROM public.table2'), completes);
      await expectLater(conn.execute('SELECT id, col3 FROM public.table3'), completes);
    });

    test('Downgrading from the last version alters all tables accordingly', () async {
      final options = opts();
      // Upgrade to latest schema
      await conn.migrator(options: options).migrate(version: '2.0.0');
      // Downgrade back to 1.0.0
      final res = await conn.migrator(options: options).migrate(version: '1.0.0');

      expect(res.direction, MigrationDirection.down);
      expect(res.files.names(), containsAllInOrder([file('2.0.0', 'down'), file('1.1.0', 'down')]));

      await expectLater(conn.execute('SELECT id, col1 FROM public.table1'), completes);
      await expectLater(conn.execute('SELECT id, col1 FROM public.table2'), completes);

      await expectLater(conn.execute('SELECT id, col1, col2 FROM public.table1'), throwsA(isA<ServerException>()));
      await expectLater(conn.execute('SELECT id, col1, col2 FROM public.table2'), throwsA(isA<ServerException>()));
      await expectLater(conn.execute('SELECT * FROM public.table3'), throwsA(isA<ServerException>()));
    });

    test('Invalid options throw ArgumentError', () {
      expect(() => PsqlMigrationOptions(path: dir, versionTable: 'a' * 52), throwsArgumentError);
      expect(() => PsqlMigrationOptions(path: dir, versionTable: ''), throwsArgumentError);
      expect(() => PsqlMigrationOptions(path: dir, versionTable: ' '), throwsArgumentError);
      expect(() => PsqlMigrationOptions(path: dir, schema: ''), throwsArgumentError);
    });

    test('Quoted names work and a missing schema is created', () async {
      await conn.execute('DROP SCHEMA IF EXISTS "My-Schema" CASCADE', queryMode: QueryMode.simple);
      final options = opts(schema: 'My-Schema', versionTable: 'Order');
      final res = await conn.migrator(options: options).migrate(version: '1.0.0');
      expect(res.direction, MigrationDirection.up);

      final rows = await conn.execute('SELECT count(*) FROM "My-Schema"."Order"');
      expect(rows.first.first, greaterThan(0));
      await conn.execute('DROP SCHEMA "My-Schema" CASCADE', queryMode: QueryMode.simple);
    });

    test('queryVersion returns an empty version for new and empty tables', () async {
      await conn.execute('DROP TABLE IF EXISTS public._version', queryMode: QueryMode.simple);
      final migrator = conn.migrator(options: opts());
      expect((await migrator.queryVersion())!.version, '');
      expect((await migrator.queryVersion())!.version, '');
      await conn.execute('DROP TABLE IF EXISTS public._version', queryMode: QueryMode.simple);
    });

    test('queryVersion rethrows errors other than undefined table', () async {
      final migrator = conn.migrator(options: opts());
      await conn.execute('DROP TABLE IF EXISTS public._version', queryMode: QueryMode.simple);
      await conn.execute('CREATE TABLE public._version (id int)', queryMode: QueryMode.simple);
      await expectLater(
        migrator.queryVersion(),
        throwsA(isA<ServerException>().having((e) => e.code, 'code', '42703')),
      );
      await conn.execute('DROP TABLE public._version', queryMode: QueryMode.simple);
    });

    test('isRetryable decides by SQLSTATE', () async {
      final migrator = conn.migrator(options: opts());
      Object? serverError;
      try {
        await conn.execute('SELECT 1/0');
      } catch (e) {
        serverError = e;
      }
      expect(serverError, isA<ServerException>());
      expect(migrator.isRetryable(serverError!), isFalse); // division_by_zero
      expect(migrator.isRetryable(TimeoutException('x')), isTrue);
      expect(migrator.isRetryable(StateError('x')), isFalse);
    });

    test('Lock times out when held elsewhere; unlock reports a missing lock', () async {
      final other = await open();
      addTearDown(other.close);
      final options = opts(timeout: const Duration(seconds: 1));
      final holder = other.migrator(options: options);
      final waiter = conn.migrator(options: options);

      await holder.acquireLock();
      await expectLater(waiter.acquireLock(), throwsA(isA<TimeoutException>()));
      await expectLater(waiter.releaseLock(), throwsStateError);
      await holder.releaseLock();
      await waiter.acquireLock();
      await waiter.releaseLock();
    });

    // Creates a temporary migrations directory from {version: {direction: sql}}
    Future<String> fixture(Map<String, Map<String, String>> versions) async {
      final tmp = await Directory.systemTemp.createTemp('psql_migr_');
      addTearDown(() => tmp.delete(recursive: true));
      for (final v in versions.entries) {
        for (final d in v.value.entries) {
          final f = File('${tmp.path}/${directoryBased ? '${v.key}/${d.key}.sql' : '${v.key}.${d.key}.sql'}');
          await f.create(recursive: true);
          await f.writeAsString(d.value);
        }
      }
      return tmp.path;
    }

    PsqlMigrationOptions fopts(String path, {String schema = 'public'}) => PsqlMigrationOptions(
      path: path,
      directoryBased: directoryBased,
      schema: schema,
      timeout: const Duration(seconds: 15),
    );

    test('Migrating to the current version is a no-op', () async {
      final migrator = conn.migrator(options: opts());
      await migrator.migrate(version: '1.0.0');
      final res = await migrator.migrate(version: '1.0.0');
      expect(res.files, isEmpty);
      final rows = await conn.execute('SELECT count(*) FROM public._version');
      expect(rows.first.first, 1);
    });

    test('A failing SQL file rolls back the whole transaction and saves no version', () async {
      final path = await fixture({
        '1.0.0': {'up': 'CREATE TABLE public.table1 (id int);', 'down': 'DROP TABLE public.table1;'},
        '1.1.0': {
          'up': 'CREATE TABLE public.table2 (id int); SELECT * FROM public.missing_table;',
          'down': 'SELECT 1;',
        },
      });
      await expectLater(conn.migrator(options: fopts(path)).migrate(version: '1.1.0'), throwsA(isA<MigrationError>()));
      await expectLater(conn.execute('SELECT 1 FROM public.table1'), throwsA(isA<ServerException>()));
      await expectLater(conn.execute('SELECT 1 FROM public.table2'), throwsA(isA<ServerException>()));
      final rows = await conn.execute('SELECT count(*) FROM public._version');
      expect(rows.first.first, 0);
    });

    test('Step-down downgrade to an intermediate version', () async {
      final migrator = conn.migrator(options: opts());
      await migrator.migrate(version: '2.0.0');
      final res = await migrator.migrate(version: '1.0.0');
      expect(res.direction, MigrationDirection.down);
      expect((await migrator.queryVersion())!.version, '1.0.0');
      await expectLater(conn.execute('SELECT id, col1 FROM public.table1'), completes);
      await expectLater(conn.execute('SELECT col2 FROM public.table1'), throwsA(isA<ServerException>()));
    });

    test('Checksum mismatch after a file is edited', () async {
      final path = await fixture({
        '1.0.0': {'up': 'CREATE TABLE public.table1 (id int);', 'down': 'DROP TABLE public.table1;'},
      });
      final migrator = conn.migrator(options: fopts(path));
      await migrator.migrate(version: '1.0.0');
      final up = File('$path/${file('1.0.0', 'up')}');
      await up.writeAsString('CREATE TABLE public.table1 (id int, extra int);');
      await expectLater(migrator.migrate(version: '1.0.0'), throwsA(isA<MigrationChecksumMismatchError>()));
    });

    test('The version table stores direction, checksum and UTC timestamps', () async {
      final migrator = conn.migrator(options: opts());
      await migrator.migrate(version: '1.0.0');
      await migrator.migrate(version: '0.0.1');
      final rows = await conn.execute(
        'SELECT version, direction, checksum, started_at, completed_at FROM public._version ORDER BY id',
      );
      expect(rows.map((r) => r[0]), ['1.0.0', '0.0.1']);
      expect(rows.map((r) => r[1]), ['up', 'down']);
      for (final r in rows) {
        expect(r[2] as String, isNotEmpty);
        expect((r[3] as DateTime).isUtc, isTrue);
        expect((r[4] as DateTime).isBefore((r[3] as DateTime)), isFalse);
      }
    });

    test('Pre-release versions are supported', () async {
      final path = await fixture({
        '1.0.0-beta': {'up': 'CREATE TABLE public.table1 (id int);', 'down': 'DROP TABLE public.table1;'},
        '1.0.0': {'up': 'ALTER TABLE public.table1 ADD col1 int;', 'down': 'ALTER TABLE public.table1 DROP col1;'},
      });
      final migrator = conn.migrator(options: fopts(path));
      await migrator.migrate(version: '1.0.0-beta');
      expect((await migrator.queryVersion())!.version, '1.0.0-beta');
      await migrator.migrate(version: '1.0.0');
      expect((await migrator.queryVersion())!.version, '1.0.0');
    });

    test('A missing or empty migrations directory is rejected', () async {
      final empty = await fixture({});
      await expectLater(conn.migrator(options: fopts(empty)).migrate(version: '1.0.0'), throwsA(isA<Object>()));
      await expectLater(
        conn.migrator(options: fopts('$empty/missing')).migrate(version: '1.0.0'),
        throwsA(isA<Object>()),
      );
    });

    test('Invalid or non-existent target versions are rejected', () async {
      final migrator = conn.migrator(options: opts());
      await expectLater(migrator.migrate(version: 'abc'), throwsA(isA<MigrationInvalidVersionError>()));
      await expectLater(migrator.migrate(version: '9.9.9'), throwsA(isA<MigrationInvalidVersionError>()));
    });

    test('Multi-statement SQL files are executed', () async {
      final path = await fixture({
        '1.0.0': {
          'up':
              "CREATE TABLE public.table1 (id int); INSERT INTO public.table1 VALUES (1); INSERT INTO public.table1 VALUES (2);",
          'down': 'DROP TABLE public.table1;',
        },
      });
      await conn.migrator(options: fopts(path)).migrate(version: '1.0.0');
      final rows = await conn.execute('SELECT count(*) FROM public.table1');
      expect(rows.first.first, 2);
    });

    test('CREATE INDEX CONCURRENTLY fails inside the migration transaction (known limitation)', () async {
      final path = await fixture({
        '1.0.0': {
          'up': 'CREATE TABLE public.table1 (id int); CREATE INDEX CONCURRENTLY idx_t1 ON public.table1 (id);',
          'down': 'DROP TABLE public.table1;',
        },
      });
      await expectLater(conn.migrator(options: fopts(path)).migrate(version: '1.0.0'), throwsA(isA<MigrationError>()));
      await expectLater(conn.execute('SELECT 1 FROM public.table1'), throwsA(isA<ServerException>()));
    });

    test('Concurrent migrators on separate connections serialize through the advisory lock', () async {
      final other = await open();
      addTearDown(other.close);
      final results = await Future.wait([
        conn.migrator(options: opts()).migrate(version: '2.0.0'),
        other.migrator(options: opts()).migrate(version: '2.0.0'),
      ]);
      expect(results.where((r) => r.files.isNotEmpty), hasLength(1));
      final rows = await conn.execute('SELECT count(*) FROM public._version');
      expect(rows.first.first, 1);
    });

    test('Names needing quotes (hyphen, reserved word) work', () async {
      final res = await conn
          .migrator(
            options: opts(schema: 'My-Schema', versionTable: 'user'),
          )
          .migrate(version: '0.0.1');
      expect(res.direction, MigrationDirection.up);
      final rows = await conn.execute('SELECT count(*) FROM "My-Schema"."user"');
      expect(rows.first.first, 1);
    });

    test('search_path resolves unqualified names to the configured schema', () async {
      final path = await fixture({
        '1.0.0': {'up': 'CREATE TABLE unqualified_tbl (id int);', 'down': 'DROP TABLE unqualified_tbl;'},
      });
      await conn.migrator(options: fopts(path, schema: 'My-Schema')).migrate(version: '1.0.0');
      final rows = await conn.execute(
        "SELECT table_schema FROM information_schema.tables WHERE table_name = 'unqualified_tbl'",
      );
      expect(rows.map((r) => r[0]), ['My-Schema']);
    });

    test('queryVersion rethrows when the schema is not accessible', () async {
      await conn.execute('DROP ROLE IF EXISTS no_access_role', queryMode: QueryMode.simple);
      await conn.execute('CREATE ROLE no_access_role LOGIN PASSWORD \'x\'', queryMode: QueryMode.simple);
      addTearDown(() => conn.execute('DROP ROLE IF EXISTS no_access_role', queryMode: QueryMode.simple));
      await conn.migrator(options: opts()).queryVersion(); // creates the version table
      final restricted = await Connection.open(
        Endpoint(host: 'localhost', port: 5932, database: 'test_db', username: 'no_access_role', password: 'x'),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );
      addTearDown(restricted.close);
      await expectLater(
        restricted.migrator(options: opts()).queryVersion(),
        throwsA(isA<ServerException>().having((e) => e.code, 'code', '42501')),
      );
    });

    test('isRetryable accepts each transient SQLSTATE and client-side connection errors', () async {
      final migrator = conn.migrator(options: opts());
      final errors = <String, ServerException>{};
      Future<void> raise(String code) async {
        try {
          await conn.execute(
            "DO \$\$ BEGIN RAISE EXCEPTION 'x' USING ERRCODE = '$code'; END \$\$",
            queryMode: QueryMode.simple,
          );
        } on ServerException catch (e) {
          errors[code] = e;
        }
      }

      const retryable = [
        '08000',
        '08001',
        '08003',
        '08004',
        '08006',
        '08007',
        '08P01',
        '53300',
        '57P01',
        '57P02',
        '57P03',
        '57P04',
        '55P03',
      ];
      const permanent = ['23505', '42P01', '42501', '40001', '40P01', '57014', '25006'];
      for (final code in [...retryable, ...permanent]) {
        await raise(code);
      }
      ServerException err(String code) => errors[code]!;
      for (final code in [
        '08000',
        '08001',
        '08003',
        '08004',
        '08006',
        '08007',
        '08P01',
        '53300',
        '57P01',
        '57P02',
        '57P03',
        '57P04',
        '55P03',
      ]) {
        expect(migrator.isRetryable(err(code)), isTrue, reason: code);
      }
      for (final code in permanent) {
        expect(migrator.isRetryable(err(code)), isFalse, reason: code);
      }
      expect(migrator.isRetryable(const SocketException('closed')), isTrue);
    });

    test('execute and saveVersion throw ArgumentError for a non-TxSession ctx', () async {
      final migrator = conn.migrator(options: opts());
      await expectLater(migrator.execute('SELECT 1', ctx: 'not a session'), throwsArgumentError);
      await expectLater(migrator.execute(42), throwsArgumentError);
      final result = await migrator.migrate(version: '0.0.1');
      await expectLater(migrator.saveVersion(result: result, ctx: Object()), throwsArgumentError);
    });
  });
}

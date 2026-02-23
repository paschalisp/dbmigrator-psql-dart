import 'package:dbmigrator/dbmigrator.dart';
import 'package:dbmigrator_psql/dbmigrator_psql.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  group('File-based migrations execution', () {
    late final Connection conn;

    setUpAll(() async {
      conn = await Connection.open(
        Endpoint(host: 'localhost', port: 5932, database: 'test_db', username: 'test', password: 'test'),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );
    });

    setUp(() async {
      await conn.execute('''
        DROP TABLE IF EXISTS public._version;
        DROP TABLE IF EXISTS public.table1;
        DROP TABLE IF EXISTS public.table2;
        DROP TABLE IF EXISTS public.table3;
      ''', queryMode: QueryMode.simple);
    });

    tearDown(() async {
      await conn.execute('''
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
      final res = await conn
          .migrator(options: PsqlMigrationOptions(path: './test/migrations/dir-based', directoryBased: true))
          .migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(res.files.names(), containsAllInOrder(['0.0.1/up.sql', '1.0.0/up.sql', '1.1.0/up.sql', '2.0.0/up.sql']));
    });

    test('Executes the correct upgrade migration files', () async {
      final res = await conn
          .migrator(options: PsqlMigrationOptions(path: './test/migrations/dir-based', directoryBased: true))
          .migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(res.files.names(), containsAllInOrder(['0.0.1/up.sql', '1.0.0/up.sql', '1.1.0/up.sql', '2.0.0/up.sql']));
    });

    test('Upgrading to the last version creates all tables with the subsequent changes', () async {
      await conn
          .migrator(options: PsqlMigrationOptions(path: './test/migrations/dir-based', directoryBased: true))
          .migrate(version: '2.0.0');

      await expectLater(conn.execute('SELECT id, col1, col2, col3 FROM public.table1'), completes);
      await expectLater(conn.execute('SELECT id, col1, col2, col3 FROM public.table2'), completes);
      await expectLater(conn.execute('SELECT id, col1, col2, col3 FROM public.table3'), completes);
    });

    test('Downgrading from the last version alters all tables accordingly', () async {
      final options = PsqlMigrationOptions(path: './test/migrations/dir-based', directoryBased: true);
      // Upgrade to latest schema
      await conn.migrator(options: options).migrate(version: '2.0.0');
      // Downgrade back to 1.0.0
      final res = await conn.migrator(options: options).migrate(version: '1.0.0');

      expect(res.direction, MigrationDirection.down);
      expect(res.files.names(), containsAllInOrder(['2.0.0/down.sql', '1.1.0/down.sql']));

      await expectLater(conn.execute('SELECT id, col1 FROM public.table1'), completes);
      await expectLater(conn.execute('SELECT id, col1 FROM public.table2'), completes);

      await expectLater(conn.execute('SELECT id, col1, col2 FROM public.table1'), doesNotComplete);
      await expectLater(conn.execute('SELECT id, col1, col2 FROM public.table2'), doesNotComplete);
      await expectLater(conn.execute('SELECT * FROM public.table3'), doesNotComplete);
    });
  });
}

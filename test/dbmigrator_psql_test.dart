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
      await conn.execute('DROP TABLE IF EXISTS public._version');
    });

    tearDown(() async {
      await conn.execute('DROP TABLE IF EXISTS public._version');
    });

    tearDownAll(() async {
      await conn.close();
    });

    test('Executes the correct upgrade migration files', () async {
      final res = await conn
          .migrator(options: PsqlMigrationOptions(path: './test/migrations/file-based'))
          .migrate(version: '2.0.0');
      expect(res.direction, MigrationDirection.up);
      expect(
        res.files.names(),
        containsAllInOrder(['1.2.0_test.sql', '1.2.0_test2.sql', '2.0.0-rc1.sql', '2.0.0.sql']),
      );
    });
  });
}

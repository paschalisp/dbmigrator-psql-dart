import 'package:dbmigrator_psql/dbmigrator_psql.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final conn = await Connection.open(
    Endpoint(host: 'localhost', database: 'test_db'),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );

  final res = await conn.migrator(options: PsqlMigrationOptions(path: './migrations')).migrate(version: '2.0.0');

  print('Result: ${res.message}'); // Migrated
}

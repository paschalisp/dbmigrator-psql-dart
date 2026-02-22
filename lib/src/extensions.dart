import 'package:postgres/postgres.dart';

import 'dbmigrator_psql.dart';

extension PsqlConnectionMigrationExtensions on Connection {
  PostgresMigrator migrator({required PsqlMigrationOptions options}) =>
      PostgresMigrator(connection: this, options: options);
}

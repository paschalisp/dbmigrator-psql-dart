A comprehensive PostgreSQL migration tool in Dart.

[![pub package](https://img.shields.io/pub/v/dbmigrator_psql.svg)](https://pub.dev/packages/dbmigrator_psql)
[![package publisher](https://img.shields.io/pub/publisher/dbmigrator_psql.svg)](https://pub.dev/packages/dbmigrator_psql/publisher)

## Usage
```dart
import 'package:dbmigrator_psql/dbmigrator_psql.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final conn = await Connection.open(
    Endpoint(host: 'localhost', database: 'test_db'),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );

  final res = await conn.migrator(options: PsqlMigrationOptions(path: './migrations')).migrate(version: '2.0.0');

  print('Migrated from ${result.fromVersion} to ${result.toVersion} (${result.direction.name})');
  print('Executed files: ${result.files.map((f) => f.name).join(", ")}');
  print('Duration: ${result.completed.difference(result.started).inSeconds} seconds');
}
```

## Features

Briefly, the package provides the following features:

- **Semantic version resolution** — migration versions are parsed, compared, and ordered using [pub_semver](https://pub.dev/packages/pub_semver).
- **Upgrading & downgrading** — determines whether to upgrade or downgrade based on the current vs. target version.
- **Two migration file structure modes:**
    - **File-based** — `.[up|down].sql` files named with their version (e.g., `1.0.0.up.sql`, `1.0.0.down.sql`, `1.2.0_add_users.up.sql`).
    - **Directory-based** — version-named subdirectories containing `.[up|down].sql` files.
- Multiple files with the same version prefix are supported and executed in alphabetical order (e.g., `1.2.0_a_core_tables.up.sql`,
  `1.2.0_b_crm_tables.up.sql`), in both file-based and directory-based structures.
- **SHA-256 checksum verification** — optional integrity checks to detect migration files modified after applying the migration.
- **Migration locks** — acquire and release migration locks to ensure no other migration can be performed at the same time
  (essential in clustered environments).
- **Transaction-safe execution** — provides the foundation to execute all migration files under a single transaction context.
- **Retry logic** — configurable retry attempts and timeouts for failed migration operations.

> For a detailed list of **features** and **configuration options**, see the [dbmigrator](https://pub.dev/packages/dbmigrator),
which implements the migration logic this package derives from.


## Additional information

### Other RDBMS migration tools

> - [dbmigrator_mysql](https://pub.dev/packages/dbmigrator_mysql) - Migrations for MySQL databases.
> - [dbmigrator_mssql](https://pub.dev/packages/dbmigrator_mssql) - Migrations for Microsoft SQL Server databases.

### Contributing

Please file feature requests and bugs at the [issue tracker][tracker].

### License

Licensed under the BSD-3-Clause License.

[tracker]: https://github.com/paschalisp/dbmigrator-psql-dart/issues/new
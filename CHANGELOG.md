## 0.2.0

> ⚠️ **BREAKING:** This version requires `dbmigrator ^0.2.0`, which contains breaking changes. **Read the steps below before upgrading.**
>
> - **Checksums changed:** a version's checksum is now calculated from the names and contents of all of its files (ignoring
>   BOM and CRLF/LF differences). Checksums already stored in your version table won't match. If the database is already at
>   the target version, `migrate()` throws `MigrationChecksumMismatchError`. Before upgrading, either update the stored
>   checksum of your current version to the new value (from `queryMigrationVersions()`), or upgrade together with your next
>   new migration version (it runs and stores the new checksum). Databases with no stored checksum are not affected.
> - **Target versions must exist:** `migrate()` now throws `MigrationInvalidVersionError` if the target version has no `up` or
>   `down` file. Previously any version was accepted as an upper bound. Check the versions your code passes to `migrate()`.
> - `migrate()`'s `version` is now optional; use `latest: true` to migrate to the newest version.
> - The recorded `toVersion` is now always the target version.
>
> See the `dbmigrator` 0.2.0 changelog for the full list.

- Requires `dbmigrator ^0.2.0` (see the breaking changes above) and `postgres ^3.5.20`.
- The version table is created only on undefined table/schema errors (`42P01`/`3F000`); all other errors are rethrown. A missing schema is created, and concurrent-creation races are tolerated.
- Schema and table identifiers are quoted, so names with hyphens, mixed case or reserved words work.
- `PsqlMigrationOptions` throws `ArgumentError` (also in release builds) for empty/blank `schema` or `versionTable`, and for a `versionTable` longer than 51 characters (so the version index name fits in 63 bytes). The `lockKey` option is now exposed.
- `isRetryable` decides by SQLSTATE: FATAL severity alone is no longer retryable; added `08001`, `08004`, `08007`, `08P01` and `57P04`; `57014`, `40001` and `40P01` are not retried. Server errors are checked before timeout errors.
- The advisory lock uses `pg_try_advisory_lock(hashtext(...))` polling up to `timeout`; `releaseLock` throws if the lock was not held.
- Migrations run with `SET LOCAL search_path` set to the configured schema.
- `execute` and `saveVersion` accept a null `ctx` (no transaction), and throw `ArgumentError` for a non-`TxSession` `ctx` or a non-`String` SQL argument.
- `queryVersion` returns an empty version consistently for new and empty tables; `timeout` is applied to version queries; timestamps are saved as UTC.
- Tests: split into file-based and directory-based groups, with many new edge-case tests (rollback, checksum mismatch, concurrency, quoting, permissions, retry logic).
- Known limitation: statements that cannot run in a transaction (e.g. `CREATE INDEX CONCURRENTLY`) are not supported.

## 0.1.2

- Fixed processing of SQL files
- Added unit tests on real schemas
- Updated docs

## 0.1.1

- Align with base package updates.

## 0.1.0

- Initial version.

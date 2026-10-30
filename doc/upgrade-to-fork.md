# Upgrading an existing oracle_fdw installation to the fork

This document describes how to replace an oracle_fdw installation that was
built from the original repository <https://github.com/laurenz/oracle_fdw> with
the version from the fork <https://github.com/grbr2010/oracle_fdw>, branch
`feature/oracle-query`.

The upgrade consists of two independent parts:

- the C library `oracle_fdw.so`, which is replaced by a new build, and
- the SQL objects of the extension, which are updated from version 1.2 to 1.3.

Both parts are needed.  Installing only the library leaves the database
without the four new functions; updating only the extension leaves the server
running the old code.

## What changes

|                         | Original repository | Fork (`feature/oracle-query`) |
|-------------------------|---------------------|------------------------------|
| Extension version       | 1.2                 | 1.3                          |
| Version reported by `oracle_diag()` | `2.10.0`  | `2.10.0devel`                |
| `oracle_fdw.so`         | replaced            | new build                    |
| New functions           | none                | `oracle_query`, `oracle_scalar`, `oracle_call`, `oracle_exec` |

The script `oracle_fdw--1.2.sql` is unchanged in the fork, so the upgrade
script `oracle_fdw--1.2--1.3.sql` is sufficient: the foreign data wrapper,
the handler, the validator and the functions that already existed are not
recreated.

**The upgrade revokes `EXECUTE` on `oracle_execute` from `PUBLIC`.**  In
version 1.2 that function had the default privileges, so every role could
call it.  After the upgrade only the owner and the roles that were granted
the privilege explicitly can call it.  Save the current privileges *before*
the upgrade (step 2), otherwise the roles that relied on the default
privileges can no longer be identified.

The four new functions are created with `EXECUTE` revoked from `PUBLIC` as
well, so they need explicit grants, too.

## Step 1: Switch the source tree to the fork

Option A - build the fork in a separate directory.  This is the safest
option on a production server, because it leaves the original source tree
untouched:

```bash
git clone git@github.com:grbr2010/oracle_fdw.git
cd oracle_fdw
git switch feature/oracle-query
```

Option B - reuse the source tree that was cloned from the original
repository.  Add the fork as a second remote and create a branch for it, so
that no local work is lost:

```bash
cd /path/to/oracle_fdw
git remote -v                     # show the configured remotes
git remote add fork git@github.com:grbr2010/oracle_fdw.git
git fetch fork
git switch -c upgrade-to-fork fork/feature/oracle-query
```

If the remote `fork` already exists, use `git remote set-url fork ...`
instead of `git remote add`.  If the branch `upgrade-to-fork` already exists
locally, use `git switch upgrade-to-fork` instead of `git switch -c`.

The changes of the fork live only in its own repository; a `git pull` in the
original tree will not bring the new functions.

## Step 2: Back up the library and save the current privileges

### 2.1 Back up the installed library

`make install` overwrites the shared library in place, so keep a copy of the
original one for the rollback in the last section:

```bash
sudo cp "$(pg_config --pkglibdir)/oracle_fdw.so" /root/oracle_fdw.so.1.2.orig
```

### 2.2 Save the privileges

Do this **before** the upgrade, in every database where the extension is
installed.  After the upgrade the default privilege of `PUBLIC` is gone, and
the roles that relied on it can no longer be found.

```sql
-- run as superuser
CREATE TABLE IF NOT EXISTS oracle_fdw_acl_backup (
    fn     text PRIMARY KEY,
    proacl text
);

INSERT INTO oracle_fdw_acl_backup (fn, proacl)
SELECT p.oid::regprocedure::text,
       coalesce(p.proacl::text, 'NULL')
  FROM pg_proc p
 WHERE p.proname IN ('oracle_execute', 'oracle_diag', 'oracle_close_connections',
                     'oracle_fdw_handler', 'oracle_fdw_validator')
   AND p.prokind = 'f'
ON CONFLICT (fn) DO UPDATE SET proacl = EXCLUDED.proacl;
```

The value `NULL` in `proacl` means "default privileges", that is `EXECUTE`
for `PUBLIC`.  A value that contains `=X/` means that `EXECUTE` for `PUBLIC`
was granted explicitly.

Which roles can call the functions right now:

```sql
SELECT r.rolname,
       p.oid::regprocedure::text AS function
  FROM pg_proc p
   CROSS JOIN pg_roles r
 WHERE p.proname = 'oracle_execute'
   AND p.prokind = 'f'
   AND has_function_privilege(r.oid, p.oid, 'EXECUTE')
   AND r.rolname NOT LIKE 'pg\_%'
   AND r.rolname <> 'postgres'
 ORDER BY 1, 2;
```

Write the result down or store it in a file.  The same can be done for all
five functions of the extension by removing the filter on `p.proname`.

## Step 3: Build and install the fork

```bash
make clean
make -j"$(nproc)" \
     ORACLE_HOME=/opt/oracle/instantclient_19_30 \
     PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config

sudo make install \
     ORACLE_HOME=/opt/oracle/instantclient_19_30 \
     PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

`ORACLE_HOME` must point to the Oracle client that the server itself uses,
and `PG_CONFIG` to the `pg_config` of the PostgreSQL installation that shall
run the extension.  `make install` writes

- `oracle_fdw.so` to `$(pg_config --pkglibdir)`,
- `oracle_fdw.control` and the SQL scripts to `$(pg_config --sharedir)/extension`.

The new `oracle_fdw.control` has `default_version = '1.3'`.

Check that the library links against the expected Oracle client:

```bash
ldd "$(pg_config --pkglibdir)/oracle_fdw.so" | grep clntsh
```

The result must name the same client that the server loads at runtime; if it
does not, the server will fail to load the extension with a message about a
missing `libclntsh.so`.

On Windows, build with `msbuild` as described in the README and copy
`oracle_fdw.dll`, `oracle_fdw.control` and the SQL scripts
(`oracle_fdw--1.3.sql`, `oracle_fdw--1.2--1.3.sql`, `oracle_fdw--1.2.sql`,
`oracle_fdw--1.1--1.2.sql`, `oracle_fdw--1.0--1.1.sql`) into the
corresponding directories of the PostgreSQL installation.

## Step 4: Restart the PostgreSQL server

The shared library is loaded into every backend separately, so the server has
to be restarted; `pg_reload_conf()` is not enough:

```bash
sudo pg_ctlcluster 18 main restart
```

For a cluster that was started by hand, use `pg_ctl -D $PGDATA restart`.

## Step 5: Upgrade the extension in every database

The extension is installed per database, so the statement has to be run in
each database that uses it:

```sql
ALTER EXTENSION oracle_fdw UPDATE TO '1.3';
```

If the database still has version 1.0 or 1.1, use `ALTER EXTENSION oracle_fdw
UPDATE;` without `TO`:  PostgreSQL then follows the chain `1.1--1.2` and
`1.2--1.3` on its own.

The statement creates the four new functions and revokes `EXECUTE` from
`PUBLIC` on them and on `oracle_execute`.  The foreign data wrapper and the
functions that already existed stay untouched and keep working.

## Step 6: Restore the privileges

Restore the privilege of `PUBLIC` for the functions that had it before the
upgrade, using the table from step 2.2:

```sql
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT fn FROM oracle_fdw_acl_backup
         WHERE proacl = 'NULL' OR proacl LIKE '%=X/%'
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', r.fn);
    END LOOP;
END $$;
```

The explicit grants to single roles survive the upgrade, because the upgrade
only revokes the privilege of `PUBLIC`.  If roles should keep the access to
the new functions, grant it explicitly:

```sql
GRANT EXECUTE ON FUNCTION oracle_execute(name, text)      TO app_role;
GRANT EXECUTE ON FUNCTION oracle_query(name, text, text[])  TO app_role;
GRANT EXECUTE ON FUNCTION oracle_scalar(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_call(name, text, text[])   TO app_role;
GRANT EXECUTE ON FUNCTION oracle_exec(name, text, text[])   TO app_role;
```

Repeat the grants for every role that was listed by the query in step 2.2.

The privileges of a function that had the default privileges are now stored
explicitly in the catalog instead of being implicit, but the effect is the
same.  When the backup table is no longer needed, drop it:

```sql
DROP TABLE oracle_fdw_acl_backup;
```

## Step 7: Verify the result

```sql
-- in every database
SELECT extversion FROM pg_extension WHERE extname = 'oracle_fdw';   -- 1.3

SELECT oracle_diag();
-- oracle_fdw 2.10.0devel, PostgreSQL 18.x, Oracle client 19.30.0.0.0, ...

SELECT proname, proacl FROM pg_proc WHERE proname LIKE 'oracle_%' ORDER BY 1;

-- functional test
SELECT * FROM oracle_scalar('oradb', 'SELECT 1 FROM dual');
```

## Behavior changes to be aware of

The new library changes the behavior of the functions that already existed,
not only of the new ones:

- **Values are limited to 64 kB.**  A value longer than 65535 bytes is
  rejected.  A result column that is declared with more than 16383
  characters does not work any more.
- **An embedded NUL byte** in a returned value raises an error instead of
  silently truncating the value at the first NUL.
- **The "the transaction has modified Oracle data" flag** is now tracked per
  connection instead of globally, so it is cleared when the remote
  transaction of that connection ends.
- **The statement handle is kept in the session**, which removes the
  `ORA-01000 maximum open cursors exceeded` error after about 299 failed
  `oracle_execute` calls in one transaction.
- **Rollback to a savepoint** works correctly when the first Oracle call of
  a transaction happens inside a subtransaction; the remote DML is rolled
  back as well.
- The number of rows that are fetched from the remote server in one go is
  now adapted to the size of the rows.

## Rollback

PostgreSQL has no downgrade script, so the version cannot be lowered with
`ALTER EXTENSION`:

```
ERROR:  extension "oracle_fdw" has no update path from version "1.3" to version "1.2"
```

To go back to the original version, remove the new functions and restore the
original library.  Run this in every database that was upgraded:

```sql
-- remove the functions from the extension
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_query(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_scalar(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_call(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_exec(name, text, text[]);

-- drop the functions themselves
DROP FUNCTION oracle_query(name, text, text[]);
DROP FUNCTION oracle_scalar(name, text, text[]);
DROP FUNCTION oracle_call(name, text, text[]);
DROP FUNCTION oracle_exec(name, text, text[]);

-- restore the privilege of PUBLIC on oracle_execute
GRANT EXECUTE ON FUNCTION oracle_execute(name, text) TO PUBLIC;

-- set the version back (requires superuser)
UPDATE pg_extension SET extversion = '1.2' WHERE extname = 'oracle_fdw';
```

`DROP FUNCTION` without `ALTER EXTENSION ... DROP FUNCTION` fails with
`cannot drop function oracle_query(name,text,text[]) because extension
oracle_fdw requires it`.

Then restore the original library and restart the server:

```bash
sudo cp /root/oracle_fdw.so.1.2.orig "$(pg_config --pkglibdir)/oracle_fdw.so"
sudo pg_ctlcluster 18 main restart
```

The original `oracle_fdw.control` and the SQL scripts can be restored from
the original source tree with `make install` in that tree.

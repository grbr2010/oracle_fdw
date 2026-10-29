# oracle_fdw usage examples

[English](usage-examples.md) | [Русский](usage-examples.ru.md)

The examples in this document were verified with:

- PostgreSQL 18.6;
- oracle_fdw 2.10.0devel from the `feature/oracle-query` branch;
- Oracle Database 21c Express Edition 21.3 in the
  `gvenzl/oracle-xe:21.3.0-faststart` container;
- Oracle Instant Client 19.30;
- Oracle AI Database 23.26 Free with Instant Client 23.26 for the 23ai
  error messages and the `expected/oracle_fdw_5.out` output.

They assume a foreign server named `oracle` and an Oracle user `SCOTT` with
the password `tiger`.  Replace the server name, user and password with the
values of your installation.

The examples use `dbserver ''`, which means a local (BEQUEATH) connection.
For a remote database use a connect string such as
`//db.example.com:1521/ORCLPDB1`.

## 1. Minimal setup

```sql
CREATE EXTENSION oracle_fdw;

-- An empty dbserver means a local (BEQUEATH) connection.
CREATE SERVER oracle FOREIGN DATA WRAPPER oracle_fdw
   OPTIONS (dbserver '');

-- The Oracle user whose credentials are used for this PostgreSQL role.
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle
   OPTIONS (user 'SCOTT', password 'tiger');
```

The PostgreSQL server process must see the Oracle client libraries and the
connection environment (`TWO_TASK`, or `ORACLE_HOME` and `ORACLE_SID`).
See section 10 for a reproducible test setup.

Since oracle_fdw 1.3, `oracle_execute`, `oracle_query`, `oracle_scalar`,
`oracle_call` and `oracle_exec` are revoked from `PUBLIC`, because they can
execute arbitrary SQL with the credentials of the user mapping.  Grant
`EXECUTE` to the roles that need them:

```sql
GRANT EXECUTE ON FUNCTION oracle_execute(name, text) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_query(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_scalar(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_call(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_exec(name, text, text[]) TO app_role;
```

## 2. `oracle_execute`: DDL and DML without a result

`oracle_execute` returns `void`; use it for statements that do not return
rows.  The empty result column in psql is expected.

```sql
-- Drop the demo table if it exists.  ORA-00942 means "table or view does
-- not exist"; any other Oracle error is re-raised.
SELECT oracle_execute('oracle', $ora$BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE scott.fdw_demo PURGE';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -942 THEN RAISE; END IF;
END;$ora$);

-- DDL: Oracle performs an implicit COMMIT here.
SELECT oracle_execute('oracle',
  'CREATE TABLE scott.fdw_demo (id NUMBER(5), v VARCHAR2(30))');

-- DML without a result.
SELECT oracle_execute('oracle',
  'INSERT INTO scott.fdw_demo VALUES (1, ''alpha'')');
```

```text
 oracle_execute
----------------

(1 row)
```

`oracle_execute` is convenient for DDL, but DDL in Oracle issues an implicit
`COMMIT`.  Do not use it in the middle of a multi-statement transaction if
you expect to roll the transaction back.

## 3. `oracle_query`: a set of rows

`oracle_query` is a set-returning function, so every call must include a
column definition list.  Oracle returns values as strings; PostgreSQL
converts them to the declared types.

```sql
SELECT * FROM oracle_query('oracle',
          'SELECT level AS n, ''row-'' || level AS label
             FROM dual CONNECT BY level <= 3')
       AS q(n int, label text);
```

```text
 n | label
---+-------
 1 | row-1
 2 | row-2
 3 | row-3
(3 rows)
```

Bind parameters are positional `:1`, `:2`, ... and are passed as strings.
A `NULL` array element binds SQL `NULL`:

```sql
SELECT * FROM oracle_query('oracle',
          'SELECT :1 AS a, :2 AS b FROM dual',
          ARRAY['hello', 'world'])
       AS q(a text, b text);
```

```text
   a   |   b
-------+-------
 hello | world
(1 row)
```

Placeholders must be consecutive; a placeholder may be repeated.  Named
placeholders such as `:name` are rejected.  The number of placeholders is
cross-checked against the bind count reported by Oracle.

`oracle_query` materializes the complete result before PostgreSQL applies
`LIMIT` or `OFFSET`.  To reduce the work on the Oracle server, restrict the
remote statement itself with `ROWNUM`, `FETCH FIRST ... ROWS ONLY`, or a
`WHERE` condition.

Only data types with a sensible string representation are supported in the
select list.  Cast LOBs, `LONG` and user-defined types explicitly, for
example with `TO_CHAR` or `CAST`.

## 4. `oracle_scalar`: a single value

`oracle_scalar` returns the first column of the first result row as `text`.
It returns `NULL` if there is no row or the first value is `NULL`.  Cast the
result to the type you need.

```sql
SELECT oracle_scalar('oracle', 'SELECT 6 * 7 FROM dual') AS answer;
```

```text
 answer
--------
 42
(1 row)
```

Only the first column and the first row are read.  An error or an
unsupported data type in later rows or columns does not affect the call.

## 5. `oracle_call`: a remote function, including DML

`oracle_call` calls a remote function through an anonymous PL/SQL block.
It is the convenient, checked form for functions that modify data, which
Oracle rejects in a plain query with `ORA-14551`.

```sql
-- A remote function without side effects.
SELECT oracle_execute('oracle', $ora$CREATE OR REPLACE FUNCTION scott.fdw_add(
  a NUMBER, b NUMBER) RETURN NUMBER IS
BEGIN
  RETURN a + b;
END;$ora$);

SELECT oracle_call('oracle', 'scott.fdw_add', '20', '22') AS sum;
```

```text
 sum
-----
 42
(1 row)
```

```sql
-- A remote function that inserts a row.
SELECT oracle_execute('oracle', $ora$CREATE OR REPLACE FUNCTION scott.fdw_log4(
  msg VARCHAR2) RETURN NUMBER IS
BEGIN
  INSERT INTO scott.fdw_demo VALUES (4, msg);
  RETURN 1;
END;$ora$);

SELECT oracle_call('oracle', 'scott.fdw_log4', 'delta') AS inserted;
```

```text
 inserted
----------
 1
(1 row)
```

The function name must consist of one to three unquoted identifier segments
(`function`, `package.function` or `schema.package.function`).  Quoted names
and overloaded functions need `oracle_exec`.

Arguments are bound as strings to `:p1`, `:p2`, ...; a `NULL` argument binds
SQL `NULL`.  The result is returned as `text` and can be at most 32767 bytes.
For longer results, write them to a table or return a CLOB and read it with
`oracle_query`.

DML performed by the function participates in the local transaction,
including savepoints and subtransactions.  This does not apply to operations
with their own commit rules, such as autonomous transactions or DDL.

## 6. `oracle_exec`: a PL/SQL block with an OUT parameter

`oracle_exec` executes an anonymous PL/SQL block.  The block must assign its
result to `:p0`; the arguments are bound to `:p1`, `:p2`, ...

```sql
-- A procedure with an OUT parameter.
SELECT oracle_execute('oracle', $ora$CREATE OR REPLACE PROCEDURE scott.fdw_out(
  p_in IN VARCHAR2, p_out OUT VARCHAR2) IS
BEGIN
  p_out := 'out:' || p_in;
END;$ora$);

SELECT oracle_exec('oracle',
  'BEGIN scott.fdw_out(:p1, :p0); END;', '42') AS result;
```

```text
 result
--------
 out:42
(1 row)
```

Use `oracle_execute` for blocks that return no result; `oracle_exec` rejects
a block that does not assign `:p0`.  The result is limited to 32767 bytes,
and the same transaction caveats as for `oracle_call` apply.

## 7. Assigning Oracle results to PostgreSQL variables

`oracle_scalar`, `oracle_call` and `oracle_exec` return `text`, so cast the
result to the target type.  `oracle_query` returns a set, so use
`SELECT ... INTO` with the same column definition list.

### 7.1 Scalar assignment

```sql
DO $$
DECLARE
   v_answer text;
BEGIN
   v_answer := oracle_scalar('oracle', 'SELECT 6 * 7 FROM dual');
   RAISE NOTICE 'Oracle returned: %', v_answer;
END;
$$;
```

```text
NOTICE:  Oracle returned: 42
DO
```

### 7.2 Assignment in a PL/pgSQL function

```sql
CREATE OR REPLACE FUNCTION pg_fdw_add(a numeric, b numeric)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
   v_sum numeric;
BEGIN
   v_sum := oracle_scalar(
      'oracle',
      'SELECT scott.fdw_add(:1, :2) FROM dual',
      ARRAY[a::text, b::text]
   )::numeric;
   RETURN v_sum;
END;
$$;

SELECT pg_fdw_add(20, 22) AS sum_from_oracle;
```

```text
 sum_from_oracle
-----------------
              42
(1 row)
```

### 7.3 Assignment from `oracle_query` with `SELECT ... INTO`

```sql
DO $$
DECLARE
   v_id int;
   v_v  text;
BEGIN
   SELECT q.id, q.v
     INTO v_id, v_v
     FROM oracle_query('oracle',
            'SELECT id, v FROM scott.fdw_demo WHERE id = 3')
          AS q(id int, v text);
   RAISE NOTICE 'row from Oracle: id=%, v=%', v_id, v_v;
END;
$$;
```

```text
NOTICE:  row from Oracle: id=3, v=gamma
DO
```

### 7.4 Assignment from `oracle_call`

```sql
DO $$
DECLARE
   v_inserted int;
BEGIN
   v_inserted := oracle_call('oracle', 'scott.fdw_log4', 'delta')::int;
   RAISE NOTICE 'oracle_call returned: %', v_inserted;
END;
$$;
```

```text
NOTICE:  oracle_call returned: 1
DO
```

### 7.5 Assignment from `oracle_exec`

```sql
DO $$
DECLARE
   v_result text;
BEGIN
   v_result := oracle_exec('oracle',
      'BEGIN scott.fdw_out(:p1, :p0); END;', '42');
   RAISE NOTICE 'oracle_exec returned: %', v_result;
END;
$$;
```

```text
NOTICE:  oracle_exec returned: out:42
DO
```

## 8. Diagnostics and connection management

`oracle_diag` shows the oracle_fdw, PostgreSQL and Oracle client versions.
With a foreign server name it also shows the Oracle server version:

```sql
SELECT oracle_diag('oracle') AS diag;
```

```text
 oracle_fdw 2.10.0devel, PostgreSQL 18.6 (Ubuntu 18.6-1.pgdg24.04+2), Oracle client 19.30.0.0.0, Oracle server 21.0.0.0.0
(1 row)
```

`oracle_diag(NULL)` additionally shows Oracle environment variables, but only
to superusers.

`oracle_close_connections()` closes all cached Oracle connections.  A new
connection is opened on the next access:

```sql
SELECT oracle_close_connections();
```

It cannot be called in a transaction that has already modified Oracle data:

```text
ERROR:  connections with an active transaction cannot be closed
HINT:  The transaction that modified Oracle data must be closed first.
```

## 9. Transaction behavior

DML performed through foreign tables and through `oracle_call` participates
in the local transaction:

```sql
BEGIN;
SELECT oracle_call('oracle', 'scott.fdw_log4', 'rolled back');
ROLLBACK;
-- The row inserted by the function is rolled back as well.
```

A read-only local transaction makes Oracle reject DML:

```sql
BEGIN READ ONLY;
SELECT oracle_call('oracle', 'scott.fdw_log4', 'read-only');
-- ERROR: ... ORA-01456: may not perform insert/delete/update operation
--        inside a READ ONLY transaction
ROLLBACK;
```

`oracle_execute` follows Oracle's own commit rules.  In particular, DDL
commits immediately and cannot be rolled back with the local transaction.

## 10. Reproducing the test environment

This section records the environment used to verify the examples.  It is
optional; adapt the paths, versions and credentials to your system.

### Oracle in Docker

```bash
docker run -d --name oraclexe \
  -p 1521:1521 \
  -e ORACLE_PASSWORD=oracle \
  gvenzl/oracle-xe:21.3.0-faststart

# Wait until the database reports that it is ready.
until docker logs oraclexe 2>&1 | grep -q 'DATABASE IS READY TO USE'; do
  sleep 5
done
```

Create the `SCOTT` user in the pluggable database:

```bash
docker exec -i oraclexe sqlplus -s / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = XEPDB1;
CREATE USER scott IDENTIFIED BY tiger
   DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW,
      CREATE MATERIALIZED VIEW, CREATE PROCEDURE TO scott;
GRANT SELECT ON sys.v_$sql TO scott;
GRANT SELECT ON sys.v_$sql_plan TO scott;
EXIT
SQL
```

For Oracle Free 23.26 use the image
`gvenzl/oracle-free:23.26.3-faststart`, the service `FREEPDB1` and a
different host port, for example `-p 1522:1521`.

### Oracle Instant Client on Ubuntu

```bash
sudo mkdir -p /opt/oracle
sudo unzip instantclient-basic-linux.x64-19.30.0.0.0dbru.zip -d /opt/oracle
sudo unzip instantclient-sdk-linux.x64-19.30.0.0.0dbru.zip -d /opt/oracle

echo /opt/oracle/instantclient_19_30 | \
  sudo tee /etc/ld.so.conf.d/oracle-instantclient.conf
sudo ldconfig
```

The oracle_fdw `Makefile` also looks in the standard directories
`/usr/include/oracle/*/client64` and `/usr/lib/oracle/*/client64/lib`, so
these symlinks make the client discoverable without setting `ORACLE_HOME`:

```bash
sudo mkdir -p /usr/include/oracle/19.30 /usr/lib/oracle/19.30/client64
sudo ln -sfn /opt/oracle/instantclient_19_30/sdk/include \
  /usr/include/oracle/19.30/client64
sudo ln -sfn /opt/oracle/instantclient_19_30 \
  /usr/lib/oracle/19.30/client64/lib
```

### PostgreSQL cluster

```bash
sudo pg_createcluster 18 main --port 5433 --start
```

Put the Oracle environment into `/etc/postgresql/18/main/environment`:

```text
ORACLE_HOME = '/opt/oracle/instantclient_19_30'
LD_LIBRARY_PATH = '/opt/oracle/instantclient_19_30'
TWO_TASK = '//localhost:1521/XEPDB1'
```

Then restart the cluster and build the extension:

```bash
sudo pg_ctlcluster 18 main restart

make -j"$(nproc)" ORACLE_HOME=/opt/oracle/instantclient_19_30
sudo make install ORACLE_HOME=/opt/oracle/instantclient_19_30
PGPORT=5433 make installcheck
```

For Oracle Free 23.26, use Instant Client 23.26 and
`TWO_TASK = '//localhost:1522/FREEPDB1'`.  The extension links against
`libclntsh.so.23.1` in that case, so rebuild and reinstall it with the 23.26
client.

The CI workflow runs the same suite with PostgreSQL 18 against Oracle XE
21.3 with Instant Client 19.32 and against Oracle Free 23.26 with Instant
Client 23.26.

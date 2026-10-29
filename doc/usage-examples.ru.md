# Примеры использования oracle_fdw

[English](usage-examples.md) | [Русский](usage-examples.ru.md)

Примеры в этом документе проверены на:

- PostgreSQL 18.6;
- oracle_fdw 2.10.0devel из ветки `feature/oracle-query`;
- Oracle Database 21c Express Edition 21.3 в контейнере
  `gvenzl/oracle-xe:21.3.0-faststart`;
- Oracle Instant Client 19.30;
- Oracle AI Database 23.26 Free с Instant Client 23.26 — для сообщений
  об ошибках 23ai и вывода `expected/oracle_fdw_5.out`.

Предполагается, что внешний сервер называется `oracle`, а в Oracle есть
пользователь `SCOTT` с паролем `tiger`.  Замените имя сервера, пользователя
и пароль на значения из вашей установки.

В примерах используется `dbserver ''`, то есть локальное подключение
(BEQUEATH).  Для удалённой базы укажите строку подключения, например
`//db.example.com:1521/ORCLPDB1`.

## 1. Минимальная настройка

```sql
CREATE EXTENSION oracle_fdw;

-- Пустой dbserver означает локальное подключение (BEQUEATH).
CREATE SERVER oracle FOREIGN DATA WRAPPER oracle_fdw
   OPTIONS (dbserver '');

-- Пользователь Oracle, от имени которого работает эта роль PostgreSQL.
CREATE USER MAPPING FOR CURRENT_USER SERVER oracle
   OPTIONS (user 'SCOTT', password 'tiger');
```

Процесс сервера PostgreSQL должен видеть библиотеки клиента Oracle и
параметры подключения (`TWO_TASK` либо `ORACLE_HOME` и `ORACLE_SID`).
Готовый тестовый стенд описан в разделе 10.

Начиная с oracle_fdw 1.3, функции `oracle_execute`, `oracle_query`,
`oracle_scalar`, `oracle_call` и `oracle_exec` отозваны у `PUBLIC`, потому
что они могут выполнять произвольный SQL с учётными данными пользователя
из user mapping.  Выдайте `EXECUTE` тем ролям, которым это нужно:

```sql
GRANT EXECUTE ON FUNCTION oracle_execute(name, text) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_query(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_scalar(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_call(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_exec(name, text, text[]) TO app_role;
```

## 2. `oracle_execute`: DDL и DML без результата

`oracle_execute` возвращает `void`; используйте её для инструкций, которые
не возвращают строки.  Пустой столбец результата в psql — это нормально.

```sql
-- Удаляем демонстрационную таблицу, если она есть.  ORA-00942 означает
-- "table or view does not exist"; любая другая ошибка Oracle пробрасывается.
SELECT oracle_execute('oracle', $ora$BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE scott.fdw_demo PURGE';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -942 THEN RAISE; END IF;
END;$ora$);

-- DDL: Oracle выполняет неявный COMMIT.
SELECT oracle_execute('oracle',
  'CREATE TABLE scott.fdw_demo (id NUMBER(5), v VARCHAR2(30))');

-- DML без результата.
SELECT oracle_execute('oracle',
  'INSERT INTO scott.fdw_demo VALUES (1, ''alpha'')');
```

```text
 oracle_execute
----------------

(1 row)
```

`oracle_execute` удобна для DDL, но DDL в Oracle выполняет неявный
`COMMIT`.  Не используйте её в середине многооператорной транзакции, если
рассчитываете откатить её целиком.

## 3. `oracle_query`: множество строк

`oracle_query` — set-returning функция, поэтому при каждом вызове нужно
указывать список определения столбцов.  Oracle возвращает значения
строками; PostgreSQL преобразует их в объявленные типы.

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

Параметры привязки позиционные: `:1`, `:2`, ...; они передаются строками.
Элемент массива `NULL` привязывает SQL `NULL`:

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

Заполнители должны идти подряд; один и тот же заполнитель можно повторять.
Именованные заполнители вроде `:name` отклоняются.  Количество
заполнителей сверяется с количеством bind-переменных, которое сообщает
Oracle.

`oracle_query` материализует весь результат до того, как PostgreSQL
применит `LIMIT` или `OFFSET`.  Чтобы уменьшить работу на сервере Oracle,
ограничьте сам удалённый запрос с помощью `ROWNUM`,
`FETCH FIRST ... ROWS ONLY` или условия `WHERE`.

В списке выборки поддерживаются только типы с разумным строковым
представлением.  LOB, `LONG` и пользовательские типы приводите явно,
например через `TO_CHAR` или `CAST`.

## 4. `oracle_scalar`: одно значение

`oracle_scalar` возвращает первый столбец первой строки результата как
`text`.  Если строк нет или первое значение равно `NULL`, возвращается
`NULL`.  Приводите результат к нужному типу.

```sql
SELECT oracle_scalar('oracle', 'SELECT 6 * 7 FROM dual') AS answer;
```

```text
 answer
--------
 42
(1 row)
```

Читаются только первый столбец и первая строка.  Ошибка или
неподдерживаемый тип в последующих строках или столбцах на вызов не влияет.

## 5. `oracle_call`: удалённая функция, в том числе с DML

`oracle_call` вызывает удалённую функцию через анонимный блок PL/SQL.
Это удобная проверяемая форма для функций, изменяющих данные; в обычном
запросе Oracle отвергает такой DML с `ORA-14551`.

```sql
-- Удалённая функция без побочных эффектов.
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
-- Удалённая функция, которая вставляет строку.
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

Имя функции должно состоять из одного–трёх сегментов без кавычек
(`function`, `package.function` или `schema.package.function`).  Для имён
в кавычках и перегруженных функций нужна `oracle_exec`.

Аргументы привязываются строками к `:p1`, `:p2`, ...; аргумент `NULL`
привязывает SQL `NULL`.  Результат возвращается как `text` и может быть не
длиннее 32767 байт.  Для более длинных результатов записывайте их в таблицу
или возвращайте CLOB и читайте его через `oracle_query`.

DML, выполненный функцией, участвует в локальной транзакции, включая
savepoint'ы и подтранзакции.  Это не относится к операциям со своими
правилами фиксации, например к автономным транзакциям или DDL.

## 6. `oracle_exec`: блок PL/SQL с OUT-параметром

`oracle_exec` выполняет анонимный блок PL/SQL.  Блок должен присвоить
результат параметру `:p0`; аргументы привязываются к `:p1`, `:p2`, ...

```sql
-- Процедура с OUT-параметром.
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

Для блоков без результата используйте `oracle_execute`; `oracle_exec`
отклоняет блок, который не присваивает `:p0`.  Результат ограничен
32767 байтами; те же замечания о транзакциях, что и для `oracle_call`.

## 7. Присваивание результатов Oracle переменным PostgreSQL

`oracle_scalar`, `oracle_call` и `oracle_exec` возвращают `text`, поэтому
приводите результат к целевому типу.  `oracle_query` возвращает множество,
поэтому используйте `SELECT ... INTO` с тем же списком определения
столбцов.

### 7.1 Присваивание скалярного значения

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

### 7.2 Присваивание в функции PL/pgSQL

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

### 7.3 Присваивание из `oracle_query` через `SELECT ... INTO`

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

### 7.4 Присваивание результата `oracle_call`

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

### 7.5 Присваивание результата `oracle_exec`

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

## 8. Диагностика и управление соединениями

`oracle_diag` показывает версии oracle_fdw, PostgreSQL и клиента Oracle.
Если передать имя внешнего сервера, добавляется версия сервера Oracle:

```sql
SELECT oracle_diag('oracle') AS diag;
```

```text
 oracle_fdw 2.10.0devel, PostgreSQL 18.6 (Ubuntu 18.6-1.pgdg24.04+2), Oracle client 19.30.0.0.0, Oracle server 21.0.0.0.0
(1 row)
```

`oracle_diag(NULL)` дополнительно показывает переменные окружения Oracle,
но только суперпользователям.

`oracle_close_connections()` закрывает все кэшированные соединения с
Oracle.  Следующее обращение откроет новое соединение:

```sql
SELECT oracle_close_connections();
```

Функцию нельзя вызывать в транзакции, которая уже изменила данные Oracle:

```text
ERROR:  connections with an active transaction cannot be closed
HINT:  The transaction that modified Oracle data must be closed first.
```

## 9. Поведение транзакций

DML через внешние таблицы и через `oracle_call` участвует в локальной
транзакции:

```sql
BEGIN;
SELECT oracle_call('oracle', 'scott.fdw_log4', 'rolled back');
ROLLBACK;
-- Строка, вставленная функцией, тоже откатывается.
```

Локальная транзакция только для чтения заставляет Oracle отклонить DML:

```sql
BEGIN READ ONLY;
SELECT oracle_call('oracle', 'scott.fdw_log4', 'read-only');
-- ERROR: ... ORA-01456: may not perform insert/delete/update operation
--        inside a READ ONLY transaction
ROLLBACK;
```

`oracle_execute` подчиняется правилам фиксации Oracle.  В частности, DDL
фиксируется сразу и не может быть откатан локальной транзакцией.

## 10. Воспроизведение тестового окружения

В этом разделе записано окружение, на котором проверялись примеры.  Он
необязателен; адаптируйте пути, версии и учётные данные под свою систему.

### Oracle в Docker

```bash
docker run -d --name oraclexe \
  -p 1521:1521 \
  -e ORACLE_PASSWORD=oracle \
  gvenzl/oracle-xe:21.3.0-faststart

# Ждём, пока база сообщит о готовности.
until docker logs oraclexe 2>&1 | grep -q 'DATABASE IS READY TO USE'; do
  sleep 5
done
```

Создаём пользователя `SCOTT` в pluggable database:

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

Для Oracle Free 23.26 используйте образ
`gvenzl/oracle-free:23.26.3-faststart`, сервис `FREEPDB1` и другой порт
на хосте, например `-p 1522:1521`.

### Oracle Instant Client в Ubuntu

```bash
sudo mkdir -p /opt/oracle
sudo unzip instantclient-basic-linux.x64-19.30.0.0.0dbru.zip -d /opt/oracle
sudo unzip instantclient-sdk-linux.x64-19.30.0.0.0dbru.zip -d /opt/oracle

echo /opt/oracle/instantclient_19_30 | \
  sudo tee /etc/ld.so.conf.d/oracle-instantclient.conf
sudo ldconfig
```

`Makefile` oracle_fdw также ищет клиент в стандартных каталогах
`/usr/include/oracle/*/client64` и `/usr/lib/oracle/*/client64/lib`,
поэтому следующие символические ссылки делают клиент видимым без
переменной `ORACLE_HOME`:

```bash
sudo mkdir -p /usr/include/oracle/19.30 /usr/lib/oracle/19.30/client64
sudo ln -sfn /opt/oracle/instantclient_19_30/sdk/include \
  /usr/include/oracle/19.30/client64
sudo ln -sfn /opt/oracle/instantclient_19_30 \
  /usr/lib/oracle/19.30/client64/lib
```

### Кластер PostgreSQL

```bash
sudo pg_createcluster 18 main --port 5433 --start
```

Пропишите окружение Oracle в `/etc/postgresql/18/main/environment`:

```text
ORACLE_HOME = '/opt/oracle/instantclient_19_30'
LD_LIBRARY_PATH = '/opt/oracle/instantclient_19_30'
TWO_TASK = '//localhost:1521/XEPDB1'
```

Затем перезапустите кластер и соберите расширение:

```bash
sudo pg_ctlcluster 18 main restart

make -j"$(nproc)" ORACLE_HOME=/opt/oracle/instantclient_19_30
sudo make install ORACLE_HOME=/opt/oracle/instantclient_19_30
PGPORT=5433 make installcheck
```

Для Oracle Free 23.26 используйте Instant Client 23.26 и
`TWO_TASK = '//localhost:1522/FREEPDB1'`.  В этом случае расширение
линкуется с `libclntsh.so.23.1`, поэтому пересоберите и переустановите его
с клиентом 23.26.

CI workflow запускает тот же набор тестов с PostgreSQL 18 против Oracle XE
21.3 с Instant Client 19.32 и против Oracle Free 23.26 с Instant Client
23.26.

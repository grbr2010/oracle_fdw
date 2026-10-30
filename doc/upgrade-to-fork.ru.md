# Обновление установленного oracle_fdw до версии из форка

Документ описывает, как заменить установленный oracle_fdw, собранный из
оригинального репозитория <https://github.com/laurenz/oracle_fdw>, на версию
из форка <https://github.com/grbr2010/oracle_fdw>, ветка `feature/oracle-query`.

Обновление состоит из двух независимых частей:

- библиотека `oracle_fdw.so`, которая заменяется новой сборкой, и
- SQL-объекты расширения, которые обновляются с версии 1.2 до версии 1.3.

Нужны обе части.  Если установить только библиотеку, в базе не появятся
четыре новые функции; если обновить только расширение, сервер продолжит
работать со старым кодом.

## Что меняется

|                         | Оригинальный репозиторий | Форк (`feature/oracle-query`) |
|-------------------------|---------------------------|------------------------------|
| Версия расширения       | 1.2                       | 1.3                          |
| Версия в `oracle_diag()` | `2.10.0`                 | `2.10.0devel`                |
| `oracle_fdw.so`         | заменяется                | новая сборка                 |
| Новые функции           | нет                       | `oracle_query`, `oracle_scalar`, `oracle_call`, `oracle_exec` |

Скрипт `oracle_fdw--1.2.sql` в форке не изменён, поэтому достаточно
upgrade-скрипта `oracle_fdw--1.2--1.3.sql`:  внешний data wrapper, handler,
валидатор и уже существовавшие функции не пересоздаются.

**При обновлении `EXECUTE` на `oracle_execute` отзывается у `PUBLIC`.**  В
версии 1.2 у функции были права по умолчанию, то есть вызвать её могла любая
роль.  После обновления это доступно только владельцу и тем ролям, которым
право было выдано явно.  Сохраните текущие права *до* обновления (шаг 2),
иначе роли, которые полагались на права по умолчанию, уже нельзя будет найти.

Четыре новые функции создаются тоже без `EXECUTE` для `PUBLIC`, поэтому им
нужны явные гранты.

## Шаг 1: Переключить исходники на форк

Вариант A - собрать форк в отдельном каталоге.  Это самый безопасный вариант
на рабочем сервере, потому что исходники оригинала остаются нетронутыми:

```bash
git clone git@github.com:grbr2010/oracle_fdw.git
cd oracle_fdw
git switch feature/oracle-query
```

Вариант B - переиспользовать каталог, склонированный из оригинального
репозитория.  Добавьте форк вторым remote и создайте для него ветку, чтобы
не потерять локальные изменения:

```bash
cd /path/to/oracle_fdw
git remote -v                     # показать настроенные remote
git remote add fork git@github.com:grbr2010/oracle_fdw.git
git fetch fork
git switch -c upgrade-to-fork fork/feature/oracle-query
```

Если remote `fork` уже есть, вместо `git remote add` используйте
`git remote set-url fork ...`.  Если ветка `upgrade-to-fork` уже создана
локально, вместо `git switch -c` используйте `git switch upgrade-to-fork`.

Изменения форка есть только в его собственном репозитории; `git pull` в
оригинальном каталоге новые функции не принесёт.

## Шаг 2: Сохранить библиотеку и текущие права

### 2.1 Сохранить установленную библиотеку

`make install` перезаписывает разделяемую библиотеку на месте, поэтому
сохраните копию оригинала - она понадобится для отката в последнем разделе:

```bash
sudo cp "$(pg_config --pkglibdir)/oracle_fdw.so" /root/oracle_fdw.so.1.2.orig
```

### 2.2 Сохранить права

Сделайте это **до** обновления, в каждой базе, где установлено расширение.
После обновления права по умолчанию для `PUBLIC` исчезают, и найти роли,
которые на них полагались, уже невозможно.

```sql
-- выполнить от суперпользователя
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

Значение `NULL` в `proacl` означает "права по умолчанию", то есть `EXECUTE`
для `PUBLIC`.  Значение, содержащее `=X/`, означает, что `EXECUTE` для
`PUBLIC` был выдан явно.

Кто именно может вызывать функции прямо сейчас:

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

Запишите результат или сохраните его в файл.  То же самое можно сделать по
всем пяти функциям расширения, убрав фильтр по `p.proname`.

## Шаг 3: Собрать и установить форк

```bash
make clean
make -j"$(nproc)" \
     ORACLE_HOME=/opt/oracle/instantclient_19_30 \
     PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config

sudo make install \
     ORACLE_HOME=/opt/oracle/instantclient_19_30 \
     PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
```

`ORACLE_HOME` должен указывать на тот Oracle-клиент, который использует сам
сервер, а `PG_CONFIG` - на `pg_config` той установки PostgreSQL, в которой
должно работать расширение.  `make install` записывает

- `oracle_fdw.so` в `$(pg_config --pkglibdir)`,
- `oracle_fdw.control` и SQL-скрипты в `$(pg_config --sharedir)/extension`.

В новом `oracle_fdw.control` указано `default_version = '1.3'`.

Проверьте, что библиотека слинкована с нужным Oracle-клиентом:

```bash
ldd "$(pg_config --pkglibdir)/oracle_fdw.so" | grep clntsh
```

В результате должен быть тот же клиент, который сервер грузит во время
работы; иначе сервер не сможет загрузить расширение и сообщит об отсутствии
`libclntsh.so`.

В Windows сборка выполняется через `msbuild`, как описано в README, после
чего нужно скопировать `oracle_fdw.dll`, `oracle_fdw.control` и SQL-скрипты
(`oracle_fdw--1.3.sql`, `oracle_fdw--1.2--1.3.sql`, `oracle_fdw--1.2.sql`,
`oracle_fdw--1.1--1.2.sql`, `oracle_fdw--1.0--1.1.sql`) в соответствующие
каталоги установки PostgreSQL.

## Шаг 4: Перезапустить сервер PostgreSQL

Разделяемая библиотека загружается в каждый бэкенд отдельно, поэтому сервер
нужно перезапустить; `pg_reload_conf()` недостаточно:

```bash
sudo pg_ctlcluster 18 main restart
```

Для кластера, запущенного вручную, используйте `pg_ctl -D $PGDATA restart`.

## Шаг 5: Обновить расширение в каждой базе

Расширение устанавливается в каждой базе отдельно, поэтому оператор нужно
выполнить в каждой базе, где оно используется:

```sql
ALTER EXTENSION oracle_fdw UPDATE TO '1.3';
```

Если в базе ещё версия 1.0 или 1.1, выполните `ALTER EXTENSION oracle_fdw
UPDATE;` без `TO`:  тогда PostgreSQL сам пройдёт цепочку `1.1--1.2` и
`1.2--1.3`.

Оператор создаёт четыре новые функции и отзывает `EXECUTE` у `PUBLIC` на них
и на `oracle_execute`.  Внешний data wrapper и ранее существовавшие функции
не меняются и продолжают работать.

## Шаг 6: Восстановить права

Верните право `PUBLIC` для тех функций, у которых оно было до обновления,
используя таблицу из шага 2.2:

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

Явные гранты отдельным ролям переживают обновление, потому что обновление
отзывает только право `PUBLIC`.  Если роли должны получить доступ и к новым
функциям, выдайте его явно:

```sql
GRANT EXECUTE ON FUNCTION oracle_execute(name, text)      TO app_role;
GRANT EXECUTE ON FUNCTION oracle_query(name, text, text[])  TO app_role;
GRANT EXECUTE ON FUNCTION oracle_scalar(name, text, text[]) TO app_role;
GRANT EXECUTE ON FUNCTION oracle_call(name, text, text[])   TO app_role;
GRANT EXECUTE ON FUNCTION oracle_exec(name, text, text[])   TO app_role;
```

Повторите гранты для каждой роли из списка, полученного запросом в шаге 2.2.

Права функции, имевшей права по умолчанию, теперь хранятся в каталоге явно,
а не подразумеваются, но действуют точно так же.  Когда таблица с резервной
копией больше не нужна, удалите её:

```sql
DROP TABLE oracle_fdw_acl_backup;
```

## Шаг 7: Проверить результат

```sql
-- в каждой базе
SELECT extversion FROM pg_extension WHERE extname = 'oracle_fdw';   -- 1.3

SELECT oracle_diag();
-- oracle_fdw 2.10.0devel, PostgreSQL 18.x, Oracle client 19.30.0.0.0, ...

SELECT proname, proacl FROM pg_proc WHERE proname LIKE 'oracle_%' ORDER BY 1;

-- функциональная проверка
SELECT * FROM oracle_scalar('oradb', 'SELECT 1 FROM dual');
```

## Изменения в поведении

Новая библиотека меняет поведение и ранее существовавших функций, а не
только новых:

- **Значения ограничены 64 КБ.**  Значение длиннее 65535 байт отвергается.
  Колонка результата, объявленная длиннее 16383 символов, больше не работает.
- **Встроенный байт NUL** в возвращаемом значении теперь вызывает ошибку
  вместо молчаливого обрезания значения по первому NUL.
- **Флаг "транзакция изменила данные в Oracle"** теперь отслеживается по
  каждому соединению, а не глобально, поэтому он снимается при завершении
  удалённой транзакции этого соединения.
- **Хендл statement** хранится в сессии, что устраняет ошибку `ORA-01000
  maximum open cursors exceeded` примерно после 299 неудачных вызовов
  `oracle_execute` в одной транзакции.
- **Откат к savepoint** работает корректно, когда первый вызов Oracle
  происходит внутри subtransaction:  удалённый DML тоже откатывается.
- Количество строк, забираемых с удалённого сервера за один раз, теперь
  подбирается под размер строк.

## Откат

В PostgreSQL нет скрипта для понижения версии, поэтому версию нельзя
изменить оператором `ALTER EXTENSION`:

```
ERROR:  extension "oracle_fdw" has no update path from version "1.3" to version "1.2"
```

Чтобы вернуться к оригинальной версии, удалите новые функции и восстановите
исходную библиотеку.  Выполните это в каждой обновлённой базе:

```sql
-- убрать функции из расширения
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_query(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_scalar(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_call(name, text, text[]);
ALTER EXTENSION oracle_fdw DROP FUNCTION oracle_exec(name, text, text[]);

-- удалить сами функции
DROP FUNCTION oracle_query(name, text, text[]);
DROP FUNCTION oracle_scalar(name, text, text[]);
DROP FUNCTION oracle_call(name, text, text[]);
DROP FUNCTION oracle_exec(name, text, text[]);

-- вернуть право PUBLIC на oracle_execute
GRANT EXECUTE ON FUNCTION oracle_execute(name, text) TO PUBLIC;

-- вернуть версию (нужен суперпользователь)
UPDATE pg_extension SET extversion = '1.2' WHERE extname = 'oracle_fdw';
```

`DROP FUNCTION` без `ALTER EXTENSION ... DROP FUNCTION` завершается ошибкой
`cannot drop function oracle_query(name,text,text[]) because extension
oracle_fdw requires it`.

Затем восстановите исходную библиотеку и перезапустите сервер:

```bash
sudo cp /root/oracle_fdw.so.1.2.orig "$(pg_config --pkglibdir)/oracle_fdw.so"
sudo pg_ctlcluster 18 main restart
```

Исходные `oracle_fdw.control` и SQL-скрипты можно восстановить из
оригинального дерева исходников командой `make install` в этом дереве.

CREATE FUNCTION oracle_query(server name, statement text, params text[] DEFAULT NULL)
RETURNS SETOF record
AS 'MODULE_PATHNAME'
LANGUAGE C COST 100 ROWS 1000;

COMMENT ON FUNCTION oracle_query(name, text, text[])
IS 'executes a query with a result on the Oracle server and returns all result rows; the result types are taken from a column definition list, the statement can use the bind parameters :1, :2, ... which are set from the "params" array';

CREATE FUNCTION oracle_scalar(server name, statement text, params text[] DEFAULT NULL)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION oracle_scalar(name, text, text[])
IS 'executes a query on the Oracle server and returns the first column of the first row as text; the statement can use the bind parameters :1, :2, ... which are set from the "params" array';

CREATE FUNCTION oracle_call(server name, func text, VARIADIC args text[] DEFAULT NULL)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION oracle_call(name, text, text[])
IS 'calls a remote function that may modify data and returns its result as text; the function name consists of 1 to 3 unquoted identifier segments, the arguments are bound to the placeholders :p1, :p2, ... and the function result is returned through the OUT bind :p0';

CREATE FUNCTION oracle_exec(server name, block text, VARIADIC args text[] DEFAULT NULL)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION oracle_exec(name, text, text[])
IS 'executes an anonymous PL/SQL block that assigns its result to the bind parameter :p0 and returns it as text; the arguments are bound to the placeholders :p1, :p2, ...; use oracle_execute for blocks without a result';

-- these functions execute arbitrary SQL on the Oracle server, so they are
-- not available to PUBLIC; grant EXECUTE to the roles that need them
REVOKE ALL ON FUNCTION oracle_query(name, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION oracle_scalar(name, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION oracle_call(name, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION oracle_exec(name, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION oracle_execute(name, text) FROM PUBLIC;

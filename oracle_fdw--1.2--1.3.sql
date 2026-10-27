CREATE FUNCTION oracle_query(server name, statement text, params text[] DEFAULT NULL)
RETURNS SETOF record
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION oracle_query(name, text, text[])
IS 'executes a query with a result on the Oracle server and returns all result rows; the result types are taken from a column definition list, the statement can use the bind parameters :1, :2, ... which are set from the "params" array';

CREATE FUNCTION oracle_scalar(server name, statement text, params text[] DEFAULT NULL)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION oracle_scalar(name, text, text[])
IS 'executes a query on the Oracle server and returns the first column of the first row as text; the statement can use the bind parameters :1, :2, ... which are set from the "params" array';

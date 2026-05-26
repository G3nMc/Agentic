"""Database connection and query execution tool.

Supports:
- MariaDB  via connection string  (mysql+pymysql://user:pass@host:port/db)
- SQL Server via connection string (mssql://user:pass@host:port/db)
- SQLite   via file path
"""
from __future__ import annotations

import json
import urllib.parse
from typing import Any, Dict, Optional

# Maximum rows returned to the model in a single call.
_MAX_ROWS = 500

# SQL statement prefixes whose result set must be fetched (not committed).
_SELECT_PREFIXES = (
    "SELECT",
    "SHOW",
    "DESCRIBE",
    "DESC",
    "EXPLAIN",
    "PRAGMA",
    "WITH",   # CTEs
    "CALL",   # stored procedures that return result sets
)


def _is_read_query(query: str) -> bool:
    first = query.strip().lstrip("(").upper().split()[0] if query.strip() else ""
    return first in _SELECT_PREFIXES


def _parse_url(connection_string: str, scheme_aliases: tuple) -> Dict[str, Any]:
    """Generic URL parser for database connection strings.
    Normalises any known scheme alias to 'db://' so urlparse handles it uniformly.
    Credentials are percent-decoded so special chars (@, /, :) are safe.
    """
    cs = connection_string
    for alias in scheme_aliases:
        if cs.lower().startswith(alias + "://"):
            cs = "db://" + cs[len(alias) + 3:]
            break
    if not cs.startswith("db://"):
        cs = "db://" + cs

    parsed = urllib.parse.urlparse(cs)
    return {
        "host": parsed.hostname or "127.0.0.1",
        "port": parsed.port,
        "user": urllib.parse.unquote(parsed.username or ""),
        "password": urllib.parse.unquote(parsed.password or ""),
        "database": parsed.path.lstrip("/") or None,
    }


def _rows_to_result(cursor_desc, rows, truncated: bool) -> Dict[str, Any]:
    """Build the standard result dict from cursor description + fetched rows."""
    columns = [col[0] for col in cursor_desc] if cursor_desc else []
    result: Dict[str, Any] = {
        "status": "success",
        "columns": columns,
        "rows": [dict(zip(columns, r)) for r in rows],
        "row_count": len(rows),
        "truncated": truncated,
    }
    if truncated:
        result["message"] = (
            f"Result capped at {_MAX_ROWS} rows. "
            "Add a LIMIT/TOP clause to retrieve a specific range."
        )
    return result


def register(registry) -> None:

    def db_query(
            connection_key: str,
            query: str,
            parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Execute a SQL query using a named database connection."""
        try:
            connections = _load_connections(registry)
            if connection_key not in connections:
                return json.dumps({
                    "status": "error",
                    "message": (
                        f"Unknown connection key: {connection_key}. "
                        f"Available: {list(connections.keys())}"
                    ),
                })

            conn_info = connections[connection_key]
            conn_type = conn_info.get("type", "").lower()
            conn_value = conn_info.get("value", "")

            if not conn_value:
                return json.dumps({
                    "status": "error",
                    "message": f"Connection '{connection_key}' has no value configured",
                })

            if conn_type == "mariadb":
                return _execute_mariadb(conn_value, query, parameters)
            elif conn_type == "sqlserver":
                return _execute_sqlserver(conn_value, query, parameters)
            elif conn_type == "sqlite":
                return _execute_sqlite(conn_value, query, parameters)
            else:
                return json.dumps({
                    "status": "error",
                    "message": (
                        f"Unknown connection type: {conn_type}. "
                        "Supported: mariadb, sqlserver, sqlite"
                    ),
                })

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def _load_connections(registry) -> Dict[str, Dict[str, str]]:
        return getattr(registry, "db_connections", None) or {}

    # ------------------------------------------------------------------
    # MariaDB / MySQL
    # ------------------------------------------------------------------
    def _execute_mariadb(
            connection_string: str,
            query: str,
            parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        try:
            import pymysql
        except ImportError:
            return json.dumps({
                "status": "error",
                "message": "pymysql not installed. Install with: pip install pymysql",
            })

        try:
            cfg = _parse_url(connection_string, ("mysql+pymysql", "mysql", "mariadb", "mariadb+pymysql"))
            conn = pymysql.connect(
                host=cfg["host"],
                port=cfg["port"] or 3306,
                user=cfg["user"] or "root",
                password=cfg["password"],
                database=cfg["database"],
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
            )
            try:
                cursor = conn.cursor()
                cursor.execute(query, parameters or ())

                if _is_read_query(query):
                    rows = cursor.fetchmany(_MAX_ROWS)
                    truncated = cursor.fetchone() is not None
                    columns = list(rows[0].keys()) if rows else []
                    result: Dict[str, Any] = {
                        "status": "success",
                        "columns": columns,
                        "rows": [dict(r) for r in rows],
                        "row_count": len(rows),
                        "truncated": truncated,
                    }
                    if truncated:
                        result["message"] = (
                            f"Result capped at {_MAX_ROWS} rows. "
                            "Add a LIMIT clause to retrieve a specific range."
                        )
                else:
                    conn.commit()
                    result = {"status": "success", "rows_affected": cursor.rowcount}

                return json.dumps(result, default=str)
            finally:
                conn.close()

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    # ------------------------------------------------------------------
    # SQL Server
    # ------------------------------------------------------------------
    def _execute_sqlserver(
            connection_string: str,
            query: str,
            parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        try:
            import pymssql
        except ImportError:
            return json.dumps({
                "status": "error",
                "message": "pymssql not installed. Install with: pip install pymssql",
            })

        try:
            cfg = _parse_url(connection_string, ("mssql+pymssql", "mssql", "sqlserver"))
            conn = pymssql.connect(
                server=cfg["host"],
                port=str(cfg["port"] or 1433),
                user=cfg["user"],
                password=cfg["password"],
                database=cfg["database"],
                charset="UTF-8",
            )
            try:
                cursor = conn.cursor()
                cursor.execute(query, parameters or ())

                if _is_read_query(query):
                    rows = cursor.fetchmany(_MAX_ROWS)
                    truncated = cursor.fetchone() is not None
                    result = _rows_to_result(cursor.description, rows, truncated)
                else:
                    conn.commit()
                    result = {"status": "success", "rows_affected": cursor.rowcount}

                return json.dumps(result, default=str)
            finally:
                conn.close()

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    # ------------------------------------------------------------------
    # SQLite
    # ------------------------------------------------------------------
    def _execute_sqlite(
            db_path: str,
            query: str,
            parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        try:
            import sqlite3
            from pathlib import Path

            db_file = Path(db_path)
            if not db_file.is_absolute():
                db_file = registry.base_path / db_path

            conn = sqlite3.connect(str(db_file))
            try:
                cursor = conn.cursor()
                cursor.execute(query, parameters or ())

                if _is_read_query(query):
                    rows = cursor.fetchmany(_MAX_ROWS)
                    truncated = cursor.fetchone() is not None
                    result = _rows_to_result(cursor.description, rows, truncated)
                else:
                    conn.commit()
                    result = {"status": "success", "rows_affected": cursor.rowcount}

                return json.dumps(result, default=str)
            finally:
                conn.close()

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    # ------------------------------------------------------------------
    # Registration
    # ------------------------------------------------------------------
    registry.tools["db_query"] = db_query
    registry.definitions.append({
        "type": "function",
        "function": {
            "name": "db_query",
            "description": (
                "Execute a SQL query using a named database connection. "
                "Supports MariaDB (mysql+pymysql://user:pass@host:port/db), "
                "SQL Server (mssql://user:pass@host:port/db), "
                "and SQLite (file path). "
                "Connections must be configured in Settings -> Developer -> Database Connections. "
                f"SELECT results are capped at {_MAX_ROWS} rows; use LIMIT/TOP for pagination."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "connection_key": {
                        "type": "string",
                        "description": "The key/name of the database connection from settings",
                    },
                    "query": {
                        "type": "string",
                        "description": "SQL query to execute",
                    },
                    "parameters": {
                        "type": "object",
                        "description": "Optional parameters for prepared statements",
                        "additionalProperties": True,
                    },
                },
                "required": ["connection_key", "query"],
            },
        },
    })
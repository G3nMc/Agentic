"""Database connection and query execution tool.

Supports:
- MariaDB via connection string (mysql+pymysql://user:pass@host:port/db)
- SQLite via file path
"""
from __future__ import annotations

import json
from typing import Any, Dict, Optional


def register(registry) -> None:
    def db_query(
        connection_key: str,
        query: str,
        parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Execute a SQL query using a named database connection.

        Args:
            connection_key: The key identifying the connection (from settings)
            query: SQL query to execute
            parameters: Optional dict of query parameters for prepared statements

        Returns:
            JSON string with query results or error message
        """
        try:
            # Fetch connection info from settings
            connections = _load_connections(registry)
            if connection_key not in connections:
                return json.dumps({
                    "status": "error",
                    "message": f"Unknown connection key: {connection_key}. "
                               f"Available: {list(connections.keys())}"
                })

            conn_info = connections[connection_key]
            conn_type = conn_info.get("type", "").lower()
            conn_value = conn_info.get("value", "")

            if not conn_value:
                return json.dumps({
                    "status": "error",
                    "message": f"Connection '{connection_key}' has no value configured"
                })

            if conn_type == "mariadb":
                return _execute_mariadb(conn_value, query, parameters)
            elif conn_type == "sqlite":
                return _execute_sqlite(conn_value, query, parameters)
            else:
                return json.dumps({
                    "status": "error",
                    "message": f"Unknown connection type: {conn_type}. "
                               f"Supported: mariadb, sqlite"
                })

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def _load_connections(registry) -> Dict[str, Dict[str, str]]:
        """Load database connections from settings file."""
        # Read from the orchestrator's settings JSON
        settings_path = registry.base_path / ".agent" / "settings.json"
        if not settings_path.exists():
            return {}

        try:
            with open(settings_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            connections_data = data.get("database_connections", [])
            if not isinstance(connections_data, list):
                return {}

            # Convert list of {key, value, type} to dict keyed by name
            connections = {}
            for item in connections_data:
                if isinstance(item, dict) and "key" in item and "value" in item:
                    connections[item["key"]] = {
                        "value": item.get("value", ""),
                        "type": item.get("type", "sqlite"),
                    }
            return connections
        except (json.JSONDecodeError, IOError):
            return {}

    def _execute_mariadb(
        connection_string: str,
        query: str,
        parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Execute query against MariaDB/MySQL database."""
        try:
            import pymysql

            # Parse connection string: mysql+pymysql://user:pass@host:port/db
            conn_str = connection_string
            if conn_str.startswith("mysql+pymysql://"):
                conn_str = conn_str[len("mysql+pymysql://"):]

            # Parse components
            # Format: user:pass@host:port/db or user:pass@host/db
            at_idx = conn_str.rfind("@")
            if at_idx == -1:
                # No auth, just host/db
                user = "root"
                password = ""
                remainder = conn_str
            else:
                user_pass = conn_str[:at_idx]
                remainder = conn_str[at_idx + 1:]
                if ":" in user_pass:
                    user, password = user_pass.split(":", 1)
                else:
                    user = user_pass
                    password = ""

            # Parse host:port/db
            slash_idx = remainder.find("/")
            if slash_idx == -1:
                host_port = remainder
                database = ""
            else:
                host_port = remainder[:slash_idx]
                database = remainder[slash_idx + 1:]

            # Parse host:port
            colon_idx = host_port.rfind(":")
            if colon_idx == -1:
                host = host_port
                port = 3306
            else:
                host = host_port[:colon_idx]
                port = int(host_port[colon_idx + 1:])

            # Connect and execute
            conn = pymysql.connect(
                host=host,
                port=port,
                user=user,
                password=password,
                database=database if database else None,
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
            )

            try:
                cursor = conn.cursor()
                if parameters:
                    cursor.execute(query, parameters)
                else:
                    cursor.execute(query)

                # Check if it's a SELECT query
                query_upper = query.strip().upper()
                if query_upper.startswith("SELECT") or query_upper.startswith("SHOW") or query_upper.startswith("DESCRIBE"):
                    rows = cursor.fetchall()
                    result = {
                        "status": "success",
                        "columns": list(rows[0].keys()) if rows else [],
                        "rows": [dict(row) for row in rows],
                        "row_count": len(rows),
                    }
                else:
                    conn.commit()
                    result = {
                        "status": "success",
                        "rows_affected": cursor.rowcount,
                    }

                return json.dumps(result, default=str)
            finally:
                conn.close()

        except ImportError:
            return json.dumps({
                "status": "error",
                "message": "pymysql not installed. Install with: pip install pymysql"
            })
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def _execute_sqlite(
        db_path: str,
        query: str,
        parameters: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Execute query against SQLite database."""
        try:
            import sqlite3

            # Resolve path relative to base_path if not absolute
            from pathlib import Path
            db_file = Path(db_path)
            if not db_file.is_absolute():
                db_file = registry.base_path / db_path

            conn = sqlite3.connect(str(db_file))
            conn.row_factory = sqlite3.Row

            try:
                cursor = conn.cursor()
                if parameters:
                    cursor.execute(query, parameters)
                else:
                    cursor.execute(query)

                # Check if it's a SELECT query
                query_upper = query.strip().upper()
                if query_upper.startswith("SELECT") or query_upper.startswith("PRAGMA"):
                    rows = cursor.fetchall()
                    if rows:
                        columns = list(rows[0].keys())
                        result = {
                            "status": "success",
                            "columns": columns,
                            "rows": [dict(row) for row in rows],
                            "row_count": len(rows),
                        }
                    else:
                        result = {
                            "status": "success",
                            "columns": [],
                            "rows": [],
                            "row_count": 0,
                        }
                else:
                    conn.commit()
                    result = {
                        "status": "success",
                        "rows_affected": cursor.rowcount,
                    }

                return json.dumps(result, default=str)
            finally:
                conn.close()

        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    # Register the tool
    registry.tools["db_query"] = db_query
    registry.definitions.append({
        "type": "function",
        "function": {
            "name": "db_query",
            "description": (
                "Execute a SQL query using a named database connection. "
                "Supports MariaDB (via connection string) and SQLite (via file path). "
                "Connections must be configured in Settings → Developer → Database Connections."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "connection_key": {
                        "type": "string",
                        "description": "The key/name of the database connection from settings"
                    },
                    "query": {
                        "type": "string",
                        "description": "SQL query to execute"
                    },
                    "parameters": {
                        "type": "object",
                        "description": "Optional parameters for prepared statements",
                        "additionalProperties": True
                    }
                },
                "required": ["connection_key", "query"],
            },
        },
    })

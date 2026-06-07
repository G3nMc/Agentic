"""Tests for ToolSchema and ParameterSchema."""

import pytest
from multi_mode.core.tool_schema import ToolSchema, ParameterSchema


class TestParameterSchema:
    def test_simple_parameter(self):
        ps = ParameterSchema(type="string", description="A test parameter")
        assert ps.type == "string"
        assert ps.description == "A test parameter"

    def test_to_json_schema_simple(self):
        ps = ParameterSchema(type="string", description="A test parameter")
        schema = ps.to_json_schema()
        assert schema["type"] == "string"
        assert schema["description"] == "A test parameter"

    def test_to_json_schema_with_enum(self):
        ps = ParameterSchema(type="string", description="Choice", enum=["a", "b", "c"])
        schema = ps.to_json_schema()
        assert schema["enum"] == ["a", "b", "c"]

    def test_to_json_schema_with_default(self):
        ps = ParameterSchema(type="integer", description="Count", default=5)
        schema = ps.to_json_schema()
        assert schema["default"] == 5

    def test_to_json_schema_with_required(self):
        ps = ParameterSchema(type="object", properties={
            "name": ParameterSchema(type="string"),
            "age": ParameterSchema(type="integer"),
        }, required=["name"])
        schema = ps.to_json_schema()
        assert schema["required"] == ["name"]
        assert "name" in schema["properties"]
        assert "age" in schema["properties"]

    def test_to_json_schema_with_items(self):
        ps = ParameterSchema(type="array", items=ParameterSchema(type="string"))
        schema = ps.to_json_schema()
        assert schema["items"]["type"] == "string"


class TestToolSchema:
    def test_create_tool_schema(self):
        params = ParameterSchema(type="object", properties={
            "path": ParameterSchema(type="string", description="File path"),
        }, required=["path"])
        ts = ToolSchema(name="read_file", description="Read a file", parameters=params)
        assert ts.name == "read_file"
        assert ts.description == "Read a file"

    def test_to_json_schema(self):
        params = ParameterSchema(type="object", properties={
            "path": ParameterSchema(type="string"),
        }, required=["path"])
        ts = ToolSchema(name="read_file", description="Read a file", parameters=params)
        schema = ts.to_json_schema()
        assert schema["type"] == "function"
        assert schema["function"]["name"] == "read_file"
        assert schema["function"]["description"] == "Read a file"
        assert "parameters" in schema["function"]

    def test_to_anthropic_format(self):
        params = ParameterSchema(type="object", properties={
            "path": ParameterSchema(type="string"),
        }, required=["path"])
        ts = ToolSchema(name="read_file", description="Read a file", parameters=params)
        schema = ts.to_anthropic_format()
        assert schema["name"] == "read_file"
        assert schema["description"] == "Read a file"
        assert "input_schema" in schema

    def test_to_gemini_format(self):
        params = ParameterSchema(type="object", properties={
            "path": ParameterSchema(type="string"),
        }, required=["path"])
        ts = ToolSchema(name="read_file", description="Read a file", parameters=params)
        schema = ts.to_gemini_format()
        assert schema["name"] == "read_file"
        assert schema["description"] == "Read a file"
        assert "parameters" in schema

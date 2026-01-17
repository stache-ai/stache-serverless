"""MCP Tool Definitions for Stache

This module defines all MCP-compatible tool schemas for the Stache knowledge base.
Tools are discovered via entry points, allowing external packages to register
additional tools.

Core tools (10):
- search: Semantic search with optional reranking
- ingest_text: Add text content to knowledge base
- list_namespaces: List all namespaces
- create_namespace: Create a new namespace
- get_namespace: Get namespace details
- update_namespace: Update namespace properties
- delete_namespace: Delete a namespace
- list_documents: List documents with optional filtering
- get_document: Get document by ID
- delete_document: Delete document by ID

External tools can be registered via the 'stache.mcp_tools' entry point group.
"""

import logging
from dataclasses import dataclass, field
from typing import Any
from importlib.metadata import entry_points

logger = logging.getLogger(__name__)

# Entry point group for external tool plugins
TOOLS_ENTRY_POINT_GROUP = "stache.mcp_tools"


@dataclass
class ToolParameter:
    """Definition of a tool parameter."""

    name: str
    type: str  # "string", "integer", "boolean", "object", "array"
    description: str
    required: bool = False
    default: Any = None
    enum: list[str] | None = None
    max_length: int | None = None
    min_value: int | None = None
    max_value: int | None = None
    items_type: str | None = None  # For array types


@dataclass
class ToolDefinition:
    """Definition of an MCP tool."""

    name: str
    description: str
    parameters: list[ToolParameter] = field(default_factory=list)

    def to_json_schema(self) -> dict:
        """Convert to JSON Schema format for MCP."""
        properties = {}
        required = []

        for param in self.parameters:
            prop = {"type": param.type, "description": param.description}

            if param.enum:
                prop["enum"] = param.enum
            if param.max_length:
                prop["maxLength"] = param.max_length
            if param.min_value is not None:
                prop["minimum"] = param.min_value
            if param.max_value is not None:
                prop["maximum"] = param.max_value
            if param.default is not None:
                prop["default"] = param.default
            if param.items_type:
                prop["items"] = {"type": param.items_type}

            properties[param.name] = prop

            if param.required:
                required.append(param.name)

        schema = {
            "type": "object",
            "properties": properties,
        }

        if required:
            schema["required"] = required

        return schema

    def to_mcp_tool(self) -> dict:
        """Convert to MCP tool format."""
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.to_json_schema(),
        }


# Core tool definitions
CORE_TOOLS: list[ToolDefinition] = [
    ToolDefinition(
        name="search",
        description="Semantic search in Stache knowledge base. Returns relevant text chunks ranked by relevance.",
        parameters=[
            ToolParameter(
                name="query",
                type="string",
                description="Search query",
                required=True,
                max_length=10000,
            ),
            ToolParameter(
                name="namespace",
                type="string",
                description="Optional namespace filter",
                required=False,
                max_length=100,
            ),
            ToolParameter(
                name="top_k",
                type="integer",
                description="Number of results (default 20, max 50)",
                required=False,
                default=20,
                min_value=1,
                max_value=50,
            ),
            ToolParameter(
                name="rerank",
                type="boolean",
                description="Whether to rerank results for relevance (default true)",
                required=False,
                default=True,
            ),
            ToolParameter(
                name="filter",
                type="object",
                description="Metadata filter (e.g. {\"source\": \"docs\"})",
                required=False,
            ),
        ],
    ),
    ToolDefinition(
        name="ingest_text",
        description="Add text content to Stache knowledge base. Use to save notes, documentation, or synthesized information.",
        parameters=[
            ToolParameter(
                name="text",
                type="string",
                description="Text content to ingest (max 100KB)",
                required=True,
                max_length=100000,
            ),
            ToolParameter(
                name="namespace",
                type="string",
                description="Target namespace",
                required=False,
                max_length=100,
            ),
            ToolParameter(
                name="metadata",
                type="object",
                description="Optional metadata to attach",
                required=False,
            ),
            ToolParameter(
                name="chunking_strategy",
                type="string",
                description="Chunking strategy",
                required=False,
                default="recursive",
                enum=["recursive", "markdown", "semantic", "character"],
            ),
            ToolParameter(
                name="prepend_metadata",
                type="array",
                description="Metadata keys to prepend to chunks for better search (e.g. ['author', 'topic'])",
                required=False,
                items_type="string",
            ),
        ],
    ),
    ToolDefinition(
        name="list_namespaces",
        description="List all namespaces in the knowledge base.",
        parameters=[],
    ),
    ToolDefinition(
        name="create_namespace",
        description="Create a new namespace.",
        parameters=[
            ToolParameter(
                name="id",
                type="string",
                description="Namespace ID (e.g., 'mba/finance')",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="name",
                type="string",
                description="Display name",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="description",
                type="string",
                description="What belongs in this namespace",
                required=False,
                max_length=1000,
            ),
            ToolParameter(
                name="parent_id",
                type="string",
                description="Optional parent namespace ID for hierarchy",
                required=False,
                max_length=200,
            ),
            ToolParameter(
                name="metadata",
                type="object",
                description="Optional metadata to attach",
                required=False,
            ),
            ToolParameter(
                name="filter_keys",
                type="array",
                description="Metadata keys that can be used for filtering",
                required=False,
                items_type="string",
            ),
        ],
    ),
    ToolDefinition(
        name="get_namespace",
        description="Get namespace details.",
        parameters=[
            ToolParameter(
                name="id",
                type="string",
                description="Namespace ID",
                required=True,
                max_length=200,
            ),
        ],
    ),
    ToolDefinition(
        name="update_namespace",
        description="Update namespace properties.",
        parameters=[
            ToolParameter(
                name="id",
                type="string",
                description="Namespace ID",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="name",
                type="string",
                description="New name",
                required=False,
                max_length=200,
            ),
            ToolParameter(
                name="description",
                type="string",
                description="New description",
                required=False,
                max_length=1000,
            ),
            ToolParameter(
                name="metadata",
                type="object",
                description="New metadata (replaces existing)",
                required=False,
            ),
        ],
    ),
    ToolDefinition(
        name="delete_namespace",
        description="Delete a namespace.",
        parameters=[
            ToolParameter(
                name="id",
                type="string",
                description="Namespace ID",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="cascade",
                type="boolean",
                description="Delete children too",
                required=False,
                default=False,
            ),
        ],
    ),
    ToolDefinition(
        name="list_documents",
        description="List documents, optionally filtered by namespace.",
        parameters=[
            ToolParameter(
                name="namespace",
                type="string",
                description="Optional namespace filter",
                required=False,
                max_length=100,
            ),
            ToolParameter(
                name="limit",
                type="integer",
                description="Max documents (default 50, max 100)",
                required=False,
                default=50,
                min_value=1,
                max_value=100,
            ),
            ToolParameter(
                name="next_key",
                type="string",
                description="Pagination token from previous response",
                required=False,
            ),
        ],
    ),
    ToolDefinition(
        name="get_document",
        description="Get document content by ID.",
        parameters=[
            ToolParameter(
                name="doc_id",
                type="string",
                description="Document ID (UUID)",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="namespace",
                type="string",
                description="Namespace (default 'default')",
                required=False,
                max_length=100,
            ),
        ],
    ),
    ToolDefinition(
        name="delete_document",
        description="Delete a document by ID.",
        parameters=[
            ToolParameter(
                name="doc_id",
                type="string",
                description="Document ID to delete",
                required=True,
                max_length=200,
            ),
            ToolParameter(
                name="namespace",
                type="string",
                description="Namespace (default 'default')",
                required=False,
                max_length=100,
            ),
        ],
    ),
]


def _convert_dict_to_tool(tool_dict: dict) -> ToolDefinition | None:
    """Convert a dict-format tool definition to ToolDefinition.

    Accepts tools in the format:
    {
        "name": "tool_name",
        "description": "Tool description",
        "input_schema": {
            "type": "object",
            "properties": {...},
            "required": [...]
        }
    }
    """
    try:
        name = tool_dict.get("name")
        description = tool_dict.get("description", "")
        input_schema = tool_dict.get("input_schema", {})

        if not name:
            logger.warning("Dict tool missing 'name' field")
            return None

        parameters = []
        properties = input_schema.get("properties", {})
        required = input_schema.get("required", [])

        for param_name, param_def in properties.items():
            param = ToolParameter(
                name=param_name,
                type=param_def.get("type", "string"),
                description=param_def.get("description", ""),
                required=param_name in required,
                default=param_def.get("default"),
                enum=param_def.get("enum"),
                max_length=param_def.get("maxLength"),
                min_value=param_def.get("minimum"),
                max_value=param_def.get("maximum"),
                items_type=param_def.get("items", {}).get("type") if "items" in param_def else None,
            )
            parameters.append(param)

        return ToolDefinition(name=name, description=description, parameters=parameters)

    except Exception as e:
        logger.warning(f"Failed to convert dict to ToolDefinition: {e}")
        return None


def _discover_plugin_tools() -> list[ToolDefinition]:
    """Discover additional tools from entry points.

    External packages can register tools via the 'stache.mcp_tools' entry point:

    [project.entry-points."stache.mcp_tools"]
    my_tool = "my_package:MyToolDefinition"

    The entry point should resolve to either:
    - A ToolDefinition instance
    - A callable that returns a ToolDefinition
    - A list of ToolDefinition instances

    Returns:
        List of discovered ToolDefinition objects
    """
    discovered = []

    try:
        eps = entry_points(group=TOOLS_ENTRY_POINT_GROUP)
    except TypeError:
        # Python < 3.10 compatibility
        all_eps = entry_points()
        eps = all_eps.get(TOOLS_ENTRY_POINT_GROUP, [])

    for ep in eps:
        try:
            tool_or_factory = ep.load()

            # Handle callable factory
            if callable(tool_or_factory) and not isinstance(tool_or_factory, ToolDefinition):
                tool_or_factory = tool_or_factory()

            # Handle single tool or list of tools
            if isinstance(tool_or_factory, ToolDefinition):
                discovered.append(tool_or_factory)
                logger.info(f"Discovered plugin tool: {tool_or_factory.name}")
            elif isinstance(tool_or_factory, dict):
                # Dict format tool definition
                converted = _convert_dict_to_tool(tool_or_factory)
                if converted:
                    discovered.append(converted)
                    logger.info(f"Discovered plugin tool: {converted.name}")
            elif isinstance(tool_or_factory, list):
                for tool in tool_or_factory:
                    if isinstance(tool, ToolDefinition):
                        discovered.append(tool)
                        logger.info(f"Discovered plugin tool: {tool.name}")
                    elif isinstance(tool, dict):
                        # Dict format tool definition
                        converted = _convert_dict_to_tool(tool)
                        if converted:
                            discovered.append(converted)
                            logger.info(f"Discovered plugin tool: {converted.name}")
                    else:
                        logger.warning(f"Entry point {ep.name} returned invalid tool type: {type(tool)}")
            else:
                logger.warning(f"Entry point {ep.name} returned invalid type: {type(tool_or_factory)}")

        except Exception as e:
            logger.warning(f"Failed to load tool from entry point {ep.name}: {e}")

    return discovered


# Cache for discovered tools
_all_tools: list[ToolDefinition] | None = None


def get_available_tools(include_plugins: bool = True) -> list[ToolDefinition]:
    """Get all available MCP tools.

    Args:
        include_plugins: Whether to include tools from entry points (default True)

    Returns:
        List of all available ToolDefinition objects
    """
    global _all_tools

    if _all_tools is None or not include_plugins:
        tools = list(CORE_TOOLS)

        if include_plugins:
            plugin_tools = _discover_plugin_tools()

            # Deduplicate by name, plugins can override core tools
            core_names = {t.name for t in tools}
            for plugin_tool in plugin_tools:
                if plugin_tool.name in core_names:
                    # Plugin overrides core tool
                    tools = [t for t in tools if t.name != plugin_tool.name]
                    logger.info(f"Plugin tool '{plugin_tool.name}' overrides core tool")
                tools.append(plugin_tool)

            _all_tools = tools
        else:
            return tools

    return _all_tools


def get_tool_by_name(name: str) -> ToolDefinition | None:
    """Get a specific tool by name.

    Args:
        name: Tool name to find

    Returns:
        ToolDefinition if found, None otherwise
    """
    for tool in get_available_tools():
        if tool.name == name:
            return tool
    return None


def get_tools_as_mcp_format() -> list[dict]:
    """Get all tools in MCP-compatible format.

    Returns:
        List of tool dictionaries with name, description, and inputSchema
    """
    return [tool.to_mcp_tool() for tool in get_available_tools()]


def clear_tool_cache() -> None:
    """Clear the cached tools list.

    Call this if you need to re-discover plugins after loading new packages.
    """
    global _all_tools
    _all_tools = None

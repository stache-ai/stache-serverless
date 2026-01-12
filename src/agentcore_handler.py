"""AWS Lambda handler for AgentCore Gateway tool invocations

This handler provides direct tool access for AWS AgentCore Gateway,
used by Claude Desktop MCP integration. AgentCore bypasses HTTP and
invokes Lambda directly with tool parameters.
"""

import json
from .shared import (
    logger,
    do_search,
    do_ingest_text,
    do_list_namespaces,
    do_list_documents,
    do_get_document,
    do_delete_document,
    do_create_namespace,
    do_get_namespace,
    do_update_namespace,
    do_delete_namespace,
)


def _validate_string(value, name, required=True, max_length=None):
    """Validate a string parameter.

    Args:
        value: The value to validate
        name: Parameter name for error messages
        required: Whether the parameter is required
        max_length: Maximum allowed length

    Returns:
        Validated and stripped string, or None if not required and not provided

    Raises:
        ValueError: If validation fails
    """
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ValueError(f"{name} is required")
        return None

    if not isinstance(value, str):
        raise ValueError(f"{name} must be a string")

    value = value.strip()

    if max_length and len(value) > max_length:
        raise ValueError(f"{name} exceeds maximum length of {max_length}")

    return value


def _validate_integer(value, name, required=True, min_val=None, max_val=None):
    """Validate an integer parameter.

    Args:
        value: The value to validate
        name: Parameter name for error messages
        required: Whether the parameter is required
        min_val: Minimum allowed value
        max_val: Maximum allowed value

    Returns:
        Validated integer, or None if not required and not provided

    Raises:
        ValueError: If validation fails
    """
    if value is None:
        if required:
            raise ValueError(f"{name} is required")
        return None

    if not isinstance(value, int):
        raise ValueError(f"{name} must be an integer")

    if min_val is not None and value < min_val:
        raise ValueError(f"{name} must be at least {min_val}")

    if max_val is not None and value > max_val:
        raise ValueError(f"{name} must be at most {max_val}")

    return value


def _validate_dict(value, name, required=False, request_id=None):
    """Validate a dict parameter.

    Args:
        value: The value to validate
        name: Parameter name for error messages
        required: Whether the parameter is required
        request_id: Request ID for logging context

    Returns:
        Validated dict, or None if not required and not provided
    """
    if value is None:
        if required:
            raise ValueError(f"{name} is required")
        return None

    if not isinstance(value, dict):
        logger.warning(f"[{request_id}] Invalid {name}: expected dict, got {type(value).__name__}, ignoring")
        return None

    return value


def _validate_string_list(value, name, max_items=20, max_item_length=100, request_id=None):
    """Validate a list of strings parameter.

    Args:
        value: The value to validate
        name: Parameter name for error messages
        max_items: Maximum number of items allowed
        max_item_length: Maximum length per item
        request_id: Request ID for logging context

    Returns:
        Validated list of strings, or None if not provided/invalid
    """
    if value is None:
        return None

    if not isinstance(value, list):
        logger.warning(f"[{request_id}] Invalid {name}: expected list, got {type(value).__name__}, ignoring")
        return None

    # Filter to valid strings and enforce limits
    result = []
    for item in value[:max_items]:
        if isinstance(item, str) and item.strip():
            result.append(item.strip()[:max_item_length])

    return result if result else None


def _get_agentcore_context(context):
    """Extract AgentCore metadata from Lambda context.

    AgentCore invocations include bedrockAgentCore* fields in client_context.custom.
    Returns the custom dict if AgentCore, None otherwise.

    Args:
        context: Lambda context object

    Returns:
        dict: AgentCore metadata if present, None otherwise
    """
    try:
        client_context = getattr(context, 'client_context', None)
        if not client_context:
            return None

        custom = getattr(client_context, 'custom', None)
        if not custom:
            return None

        # Handle string or dict (may be JSON string in some cases)
        if isinstance(custom, str):
            custom = json.loads(custom)

        # Validate it's actually AgentCore
        if 'bedrockAgentCoreToolName' in custom:
            return custom

        return None
    except Exception as e:
        logger.warning(f"Failed to parse AgentCore context: {e}")
        return None


def _handle_agentcore_tool(custom: dict, params: dict) -> dict:
    """Route AgentCore tool calls to shared operations.

    Args:
        custom: The client_context.custom dict with AgentCore metadata
        params: The Lambda event (flat dict of tool parameters)

    Returns:
        dict: Result to be returned from Lambda
    """
    # Extract tool name (format: ${target_name}___${tool_name})
    full_tool_name = custom.get('bedrockAgentCoreToolName', '')
    tool_name = full_tool_name.split('___')[-1]

    # Correlation ID for debugging
    request_id = custom.get('bedrockAgentCoreAwsRequestId')

    logger.info(f"[{request_id}] AgentCore tool call: {tool_name}")

    try:
        if tool_name == 'search':
            query = _validate_string(params.get('query'), 'query', required=True, max_length=10000)
            namespace = _validate_string(params.get('namespace'), 'namespace', required=False, max_length=100)
            top_k = _validate_integer(params.get('top_k', 20), 'top_k', required=False, min_val=1, max_val=50)
            filter_param = _validate_dict(params.get('filter'), 'filter', request_id=request_id)
            return do_search(
                query=query,
                namespace=namespace,
                top_k=top_k,
                rerank=params.get('rerank', True),
                filter=filter_param,
                request_id=request_id
            )

        elif tool_name == 'ingest_text':
            text = _validate_string(params.get('text'), 'text', required=True, max_length=100000)
            namespace = _validate_string(params.get('namespace'), 'namespace', required=False, max_length=100)
            metadata = _validate_dict(params.get('metadata'), 'metadata', request_id=request_id)
            prepend_metadata = _validate_string_list(params.get('prepend_metadata'), 'prepend_metadata', request_id=request_id)
            chunking_strategy = params.get('chunking_strategy', 'recursive')
            # Validate chunking_strategy
            valid_strategies = ['recursive', 'markdown', 'semantic', 'character']
            if chunking_strategy not in valid_strategies:
                logger.warning(f"[{request_id}] Invalid chunking_strategy '{chunking_strategy}', using 'recursive'")
                chunking_strategy = 'recursive'
            return do_ingest_text(
                text=text,
                metadata=metadata,
                namespace=namespace,
                chunking_strategy=chunking_strategy,
                prepend_metadata=prepend_metadata,
                request_id=request_id
            )

        elif tool_name == 'list_namespaces':
            return do_list_namespaces(request_id=request_id)

        elif tool_name == 'list_documents':
            namespace = _validate_string(params.get('namespace'), 'namespace', required=False, max_length=100)
            limit = _validate_integer(params.get('limit', 50), 'limit', required=False, min_val=1, max_val=100)
            return do_list_documents(
                namespace=namespace,
                limit=limit,
                next_key=params.get('next_key'),
                request_id=request_id
            )

        elif tool_name == 'get_document':
            doc_id = _validate_string(params.get('doc_id'), 'doc_id', required=True, max_length=200)
            namespace = _validate_string(params.get('namespace', 'default'), 'namespace', required=False, max_length=100)
            return do_get_document(
                doc_id=doc_id,
                namespace=namespace or 'default',
                request_id=request_id
            )

        elif tool_name == 'delete_document':
            doc_id = _validate_string(params.get('doc_id'), 'doc_id', required=True, max_length=200)
            namespace = _validate_string(params.get('namespace', 'default'), 'namespace', required=False, max_length=100)
            return do_delete_document(
                doc_id=doc_id,
                namespace=namespace or 'default',
                request_id=request_id
            )

        elif tool_name == 'create_namespace':
            ns_id = _validate_string(params.get('id'), 'id', required=True, max_length=200)
            name = _validate_string(params.get('name'), 'name', required=True, max_length=200)
            description = _validate_string(params.get('description', ''), 'description', required=False, max_length=1000)
            parent_id = _validate_string(params.get('parent_id'), 'parent_id', required=False, max_length=200)
            metadata = _validate_dict(params.get('metadata'), 'metadata', request_id=request_id)
            filter_keys = _validate_string_list(params.get('filter_keys'), 'filter_keys', request_id=request_id)
            return do_create_namespace(
                id=ns_id,
                name=name,
                description=description or '',
                parent_id=parent_id,
                metadata=metadata,
                filter_keys=filter_keys,
                request_id=request_id
            )

        elif tool_name == 'get_namespace':
            ns_id = _validate_string(params.get('id'), 'id', required=True, max_length=200)
            return do_get_namespace(
                id=ns_id,
                request_id=request_id
            )

        elif tool_name == 'update_namespace':
            ns_id = _validate_string(params.get('id'), 'id', required=True, max_length=200)
            name = _validate_string(params.get('name'), 'name', required=False, max_length=200)
            description = _validate_string(params.get('description'), 'description', required=False, max_length=1000)
            metadata = _validate_dict(params.get('metadata'), 'metadata', request_id=request_id)
            return do_update_namespace(
                id=ns_id,
                name=name,
                description=description,
                metadata=metadata,
                request_id=request_id
            )

        elif tool_name == 'delete_namespace':
            ns_id = _validate_string(params.get('id'), 'id', required=True, max_length=200)
            cascade = params.get('cascade', False)
            if not isinstance(cascade, bool):
                cascade = False
            return do_delete_namespace(
                id=ns_id,
                cascade=cascade,
                request_id=request_id
            )

        else:
            logger.warning(f"[{request_id}] Unknown tool: {tool_name}")
            return {"error": f"Unknown tool: {tool_name}", "request_id": request_id}

    except ValueError as e:
        # Validation errors - safe to return to user
        logger.warning(f"[{request_id}] Validation error in {tool_name}: {e}")
        msg = str(e)
        # Extra safety: check message doesn't contain sensitive patterns
        if len(msg) < 200 and not any(x in msg.lower() for x in ['path', 'file', 'config', 'key', 'secret', 'token', 'arn:', 'aws:', 'password', 'credential', 'endpoint']):
            error_message = msg
        else:
            error_message = "Invalid input parameters"
        return {"error": error_message, "request_id": request_id}

    except KeyError as e:
        # Missing required key - don't expose internal structure
        logger.error(f"[{request_id}] KeyError in {tool_name}: {e}", exc_info=True)
        return {"error": "Missing required parameter", "request_id": request_id}

    except Exception as e:
        # Unexpected error - sanitize completely
        logger.error(f"[{request_id}] Tool {tool_name} failed: {e}", exc_info=True)
        return {"error": "An error occurred processing your request", "request_id": request_id}


def handler(event, context):
    """Lambda entry point for AgentCore Gateway tool invocations.

    AgentCore Gateway invokes Lambda directly with tool parameters,
    bypassing HTTP entirely. This is used by Claude Desktop MCP integration.

    Args:
        event: Flat dict of tool parameters from AgentCore
        context: Lambda context object with AgentCore metadata

    Returns:
        dict: Tool execution result
    """
    # Validate this is an AgentCore invocation
    custom = _get_agentcore_context(context)
    if not custom:
        logger.error("AgentCore handler invoked without AgentCore context")
        return {"error": "This handler only accepts AgentCore invocations"}

    # Route to appropriate tool
    return _handle_agentcore_tool(custom, event)

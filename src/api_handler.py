"""AWS Lambda handler for Stache AI HTTP API

This handler provides HTTP access to the Stache AI FastAPI application
via API Gateway with Cognito JWT authentication.
"""

from mangum import Mangum
from stache_ai.api.main import app
from .shared import logger

# Lambda handler with Mangum ASGI adapter
# Use lifespan="off" for Lambda - execution environment persists between invocations
# so startup events only need to run once per container lifecycle, not per request
# api_gateway_base_path strips the stage prefix from rawPath (HTTP API includes /Prod/ in path)
_mangum_handler = Mangum(app, lifespan="off", api_gateway_base_path="/Prod")


def handler(event, context):
    """Lambda entry point for HTTP API requests via API Gateway.

    This handler wraps the Stache AI FastAPI application with Mangum
    to handle HTTP requests from API Gateway. All requests are authenticated
    via Cognito JWT tokens.

    Args:
        event: API Gateway event with HTTP request details
        context: Lambda context object

    Returns:
        API Gateway response with HTTP status, headers, and body
    """
    request_context = event.get('requestContext', {})
    http_info = request_context.get('http', {})
    method = http_info.get('method', 'UNKNOWN')
    path = http_info.get('path', '/')
    logger.info(f"HTTP API request: {method} {path}")
    return _mangum_handler(event, context)

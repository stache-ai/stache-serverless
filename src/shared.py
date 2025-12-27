"""Shared utilities and imports for Stache AI Lambda handlers"""

import logging

# Configure logging
logger = logging.getLogger(__name__)

# Import operations from stache-ai
from stache_ai.core.operations import (
    do_search,
    do_ingest_text,
    do_list_namespaces,
    do_list_documents,
    do_get_document,
)

__all__ = [
    'logger',
    'do_search',
    'do_ingest_text',
    'do_list_namespaces',
    'do_list_documents',
    'do_get_document',
]

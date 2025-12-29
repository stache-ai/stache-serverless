"""Shared utilities and imports for Stache AI Lambda handlers"""

import logging

from stache_ai.core.operations import (
    do_create_namespace,
    do_delete_document,
    do_delete_namespace,
    do_get_document,
    do_get_namespace,
    do_ingest_text,
    do_list_documents,
    do_list_namespaces,
    do_search,
    do_update_namespace,
)

# Configure logging
logger = logging.getLogger(__name__)

__all__ = [
    'logger',
    'do_search',
    'do_ingest_text',
    'do_list_namespaces',
    'do_list_documents',
    'do_get_document',
    'do_delete_document',
    'do_create_namespace',
    'do_get_namespace',
    'do_update_namespace',
    'do_delete_namespace',
]

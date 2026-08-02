/// True when [error] is AO rejecting an unknown `mcpProviderIds` catalog entry.
bool isUnknownMcpCatalogError(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('unknown catalog id') &&
      (s.contains('mcp_provider') || s.contains('client.'));
}

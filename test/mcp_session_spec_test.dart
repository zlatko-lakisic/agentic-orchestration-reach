import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  test('sessionTunnelMcpEntry builds tunnel URL', () {
    final e = sessionTunnelMcpEntry(
      clientId: 'client.filesystem_local',
      description: 'docs',
      alias: 'filesystem',
    );
    expect(e['id'], 'client.filesystem_local');
    expect(
      (e['streamable_http'] as Map)['url'],
      'tunnel://session-mcp/filesystem',
    );
  });

  test('sessionHttpMcpEntry builds hosted URL + Accept', () {
    final e = sessionHttpMcpEntry(
      clientId: 'client.search_tavily',
      description: 'Tavily',
      url: 'https://mcp.tavily.com/mcp/?tavilyApiKey=x',
    );
    final http = e['streamable_http'] as Map;
    expect(http['url'], contains('tavily'));
    expect((http['headers'] as Map)['Accept'], contains('text/event-stream'));
  });

  test('McpSessionSpec.clientId', () {
    const s = McpSessionSpec(
      bareId: 'search_exa',
      alias: 'search_exa',
      transport: McpSessionTransport.stdioTunnel,
      description: 'Exa',
      npxPackage: 'exa-mcp-server',
    );
    expect(s.clientId, 'client.search_exa');
  });
}

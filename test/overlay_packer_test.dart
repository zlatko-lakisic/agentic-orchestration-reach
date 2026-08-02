import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String get _fixtureRoot =>
    p.join(Directory.current.path, 'test', 'fixtures');

void main() {
  test('strips ollama_host and forces selfcontained false', () async {
    final pack = await OverlayPacker().pack(
      overlayRoot: _fixtureRoot,
      includeFilesystemMcp: true,
    );
    expect(pack.agents, hasLength(2));
    expect(pack.agents.every((a) => (a['id'] as String).startsWith('client.')), isTrue);
    expect(pack.agentIds, containsAll(['client.demo_agent', 'client.demo_agent_b']));
    final a = pack.agents.firstWhere((e) => e['id'] == 'client.demo_agent');
    expect(a.containsKey('ollama_host'), isFalse);
    expect(a['selfcontained'], isFalse);
    expect(a['model'], 'qwen2.5:3b');
    expect(pack.mcpIds, contains(clientFilesystemMcpId));
  });

  test('agents-only when no MCPs', () async {
    final pack = await OverlayPacker().pack(overlayRoot: _fixtureRoot);
    expect(pack.mcps, isEmpty);
  });

  test('email + calendar convenience tunnels', () async {
    final pack = await OverlayPacker().pack(
      overlayRoot: _fixtureRoot,
      includeEmailGmailMcp: true,
      includeCalendarGoogleMcp: true,
    );
    expect(pack.mcpIds, containsAll([clientEmailGmailMcpId, clientCalendarGoogleMcpId]));
    final gmail = pack.mcps.firstWhere((m) => m['id'] == clientEmailGmailMcpId);
    expect(
      (gmail['streamable_http'] as Map)['url'],
      'tunnel://session-mcp/$emailGmailTunnelAlias',
    );
  });

  test('tunnelSpecs + httpMcps + extraMcps merge without dupes', () async {
    const crawl = McpSessionSpec(
      bareId: 'crawl_firecrawl',
      alias: 'crawl_firecrawl',
      transport: McpSessionTransport.stdioTunnel,
      description: 'Firecrawl',
      npxPackage: 'firecrawl-mcp',
    );
    final pack = await OverlayPacker().pack(
      overlayRoot: _fixtureRoot,
      includeFilesystemMcp: true,
      tunnelSpecs: const [crawl],
      httpMcps: [
        sessionHttpMcpEntry(
          clientId: 'client.search_tavily',
          description: 'Tavily',
          url: 'https://mcp.tavily.com/mcp/?k=x',
        ),
      ],
      extraMcps: [
        sessionTunnelMcpEntry(
          clientId: clientFilesystemMcpId,
          description: 'dupe',
          alias: filesystemTunnelAlias,
        ),
      ],
    );
    expect(pack.mcpIds, containsAll([
      clientFilesystemMcpId,
      'client.crawl_firecrawl',
      'client.search_tavily',
    ]));
    expect(
      pack.mcpIds.where((id) => id == clientFilesystemMcpId),
      hasLength(1),
    );
  });

  test('missing agent_providers throws', () async {
    await expectLater(
      OverlayPacker().pack(overlayRoot: Directory.systemTemp.path),
      throwsA(isA<StateError>()),
    );
  });
}

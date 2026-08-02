import 'package:ao_reach/ao_reach.dart';
import 'package:test/test.dart';

void main() {
  group('client id mapping', () {
    test('toClientAgentId prefixes once', () {
      expect(toClientAgentId('kb_researcher'), 'client.kb_researcher');
      expect(toClientAgentId('client.kb_bizdev'), 'client.kb_bizdev');
      expect(toClientAgentId('  se_tech  '), 'client.se_tech');
      expect(toClientAgentId(''), '');
    });

    test('bareAgentId strips prefix', () {
      expect(bareAgentId('client.kb_se_technical'), 'kb_se_technical');
      expect(bareAgentId('kb_bizdev'), 'kb_bizdev');
    });

    test('resolveProductAgentId toggles on overlay', () {
      expect(
        resolveProductAgentId('kb_bizdev', sessionOverlayActive: true),
        'client.kb_bizdev',
      );
      expect(
        resolveProductAgentId('kb_bizdev', sessionOverlayActive: false),
        'kb_bizdev',
      );
    });

    test('resolveSessionMcpId prefers registered client id', () {
      expect(
        resolveSessionMcpId(
          'crawl_firecrawl',
          sessionOverlayActive: true,
          registeredMcpIds: const ['client.crawl_firecrawl'],
        ),
        'client.crawl_firecrawl',
      );
      expect(
        resolveSessionMcpId(
          'crawl_firecrawl',
          sessionOverlayActive: true,
          registeredMcpIds: const [],
        ),
        'crawl_firecrawl',
      );
      expect(
        resolveSessionMcpId(
          'client.search_exa',
          sessionOverlayActive: false,
          registeredMcpIds: const ['client.search_exa'],
        ),
        'search_exa',
      );
    });
  });

  group('catalog errors', () {
    test('detects unknown mcp catalog id', () {
      expect(
        isUnknownMcpCatalogError(
          StateError("unknown catalog id 'client.crawl_firecrawl' for mcp_provider"),
        ),
        isTrue,
      );
      expect(isUnknownMcpCatalogError(StateError('timeout')), isFalse);
      expect(
        isUnknownMcpCatalogError(StateError('unknown catalog id agent_provider')),
        isFalse,
      );
    });
  });

  group('connection helpers', () {
    test('reachWsUri maps http(s) to ws(s)/ws', () {
      expect(
        reachWsUri('http://127.0.0.1:8765/'),
        Uri.parse('ws://127.0.0.1:8765/ws'),
      );
      expect(
        reachWsUri('https://host.example/@warpgate/ao'),
        Uri.parse('wss://host.example/ws'),
      );
    });

    test('ensureReachIdentity fills blanks', () {
      final filled = ensureReachIdentity(userName: '', sessionId: '');
      expect(filled.userName, isNotEmpty);
      expect(filled.sessionId, startsWith('reach-'));
      final keep = ensureReachIdentity(userName: 'alice', sessionId: 's1');
      expect(keep.userName, 'alice');
      expect(keep.sessionId, 's1');
    });
  });
}

import 'dart:convert';

import 'package:ao_reach/ao_reach.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('ReachCatalog.fromJson parses requiredSecrets', () {
    final cat = ReachCatalog.fromJson({
      'ok': true,
      'sessionEnvAllowedKeys': ['OPENAI_API_KEY', 'TAVILY_API_KEY'],
      'enableFields': {
        'agents': 'allowedAgentProviderIds',
        'mcps': 'allowedMcpProviderIds',
        'skills': 'allowedSkillIds',
        'harnesses': null,
      },
      'agents': [
        {
          'id': 'gpt_research',
          'kind': 'agent',
          'type': 'openai',
          'enableField': 'allowedAgentProviderIds',
          'requiredSecrets': [
            {
              'name': 'OPENAI_API_KEY',
              'label': 'OpenAI API key',
              'secret': true,
              'required': false,
              'anyOfGroup': 'openai_auth',
              'sessionEnvAllowed': true,
            },
          ],
        },
      ],
      'mcps': [
        {
          'id': 'search_tavily',
          'kind': 'mcp',
          'enableField': 'allowedMcpProviderIds',
          'requiredSecrets': [
            {
              'name': 'TAVILY_API_KEY',
              'label': 'Tavily API key',
              'secret': true,
              'required': false,
              'anyOfGroup': 'required_env_any:search_tavily',
            },
          ],
        },
      ],
      'skills': [],
      'harnesses': [
        {
          'id': 'general',
          'kind': 'harness',
          'enableField': null,
          'requiredSecrets': [],
        },
      ],
    });

    expect(cat.agents.single.id, 'gpt_research');
    expect(cat.agents.single.requiredSecrets.single.name, 'OPENAI_API_KEY');
    expect(cat.mcps.single.requiredSecrets.single.name, 'TAVILY_API_KEY');
    expect(cat.sessionEnvAllowedKeys, contains('TAVILY_API_KEY'));
    expect(cat.harnesses.single.enableField, isNull);
  });

  test('ReachCatalogClient.fetch hits /api/v1/catalog', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, '/api/v1/catalog');
      expect(request.url.queryParameters['kinds'], 'agents,mcps');
      return http.Response(
        jsonEncode({
          'ok': true,
          'agents': [
            {'id': 'a1', 'kind': 'agent', 'requiredSecrets': []},
          ],
          'mcps': [],
          'skills': [],
          'harnesses': [],
          'sessionEnvAllowedKeys': ['OPENAI_API_KEY'],
          'enableFields': {},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final client = ReachCatalogClient(httpClient: mock);
    final cat = await client.fetch(
      ReachConnectionConfig(
        baseUrl: 'http://127.0.0.1:8765',
        headers: const {},
        appId: 'demo-app',
      ),
      kinds: const ['agents', 'mcps'],
    );
    expect(cat.agents.single.id, 'a1');
  });

  test('ReachConnectionConfig carries mcp/skill allowlists', () {
    final cfg = ReachConnectionConfig(
      baseUrl: 'http://127.0.0.1:8765',
      headers: const {},
      appId: 'demo-app',
      allowedMcpProviderIds: const ['search_tavily'],
      allowedSkillIds: const ['web_research'],
      sessionEnv: const {'TAVILY_API_KEY': 'x'},
    );
    expect(cfg.allowedMcpProviderIds, ['search_tavily']);
    expect(cfg.allowedSkillIds, ['web_research']);
    expect(cfg.sessionEnv!['TAVILY_API_KEY'], 'x');
  });
}

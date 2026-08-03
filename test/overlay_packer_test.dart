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

  test('loads agent_skills and injects into agent backstory', () async {
    final root = Directory.systemTemp.createTempSync('ao_reach_skills_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory(p.join(root.path, 'agent_providers')).createSync();
    Directory(p.join(root.path, 'agent_skills')).createSync();
    File(p.join(root.path, 'agent_providers', 'demo.yaml')).writeAsStringSync('''
id: demo
type: ollama
model: qwen2.5:3b
backstory: Base backstory.
skills:
  - spoken_output
''');
    File(p.join(root.path, 'agent_skills', 'spoken_output.yaml')).writeAsStringSync('''
id: spoken_output
description: Voice style
content:
  body: |
    Plain speech only.
inject:
  target: backstory
  heading: "## Spoken"
''');
    final pack = await OverlayPacker().pack(overlayRoot: root.path);
    expect(pack.skillIds, contains('client.spoken_output'));
    final agent = pack.agents.single;
    expect(agent['skills'], equals(['client.spoken_output']));
    expect(agent['backstory'], contains('Base backstory'));
    expect(agent['backstory'], contains('## Spoken'));
    expect(agent['backstory'], contains('Plain speech only'));
  });

  test('resolves skill content.file relative to yaml', () async {
    final root = Directory.systemTemp.createTempSync('ao_reach_skill_file_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory(p.join(root.path, 'agent_providers')).createSync();
    final skillDir = Directory(p.join(root.path, 'agent_skills', 'bundle'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'agent_providers', 'demo.yaml')).writeAsStringSync('''
id: demo
type: ollama
model: qwen2.5:3b
skills: [bundle_skill]
''');
    File(p.join(root.path, 'agent_skills', 'bundle_skill.yaml')).writeAsStringSync('''
id: bundle_skill
description: file-backed
content:
  file: bundle/instructions.md
inject:
  heading: "## Bundle"
''');
    File(p.join(skillDir.path, 'instructions.md'))
        .writeAsStringSync('Do the bundle thing.\n');
    final pack = await OverlayPacker().pack(overlayRoot: root.path);
    expect(pack.skills.single['content']['body'], contains('Do the bundle thing'));
    expect(pack.agents.single['backstory'], contains('Do the bundle thing'));
  });

  test('packs live overlays/comstar with skills', () async {
    final root = p.normalize(
      p.join(Directory.current.path, '..', '..', 'overlays', 'comstar'),
    );
    if (!Directory(p.join(root, 'agent_providers')).existsSync()) {
      return;
    }
    final pack = await OverlayPacker().pack(overlayRoot: root);
    expect(pack.agentIds, containsAll(['client.greeter', 'client.voice_responder']));
    expect(
      pack.skillIds,
      containsAll([
        'client.spoken_output',
        'client.google_workspace_voice',
        'client.terminal_control_voice',
      ]),
    );
    final voice =
        pack.agents.firstWhere((a) => a['id'] == 'client.voice_responder');
    expect(voice['skills'], contains('client.spoken_output'));
    expect((voice['backstory'] as String), contains('calendar_list'));
  });
}

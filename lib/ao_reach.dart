/// AO Reach — client SDK for agentic-orchestration session overlays + MCP tunnels.
///
/// Pair with a shared AO daemon (v1.27+) that has
/// `AGENTIC_SERVE_SESSION_OVERLAY=1` and (for client tools)
/// `AGENTIC_SERVE_MCP_TUNNEL=1`.
library;

export 'src/catalog_client.dart';
export 'src/catalog_errors.dart';
export 'src/connection_config.dart';
export 'src/custom_tool_contract.dart';
export 'src/hybrid_mcp_bootstrap.dart';
export 'src/ids.dart';
export 'src/local_mcp_host.dart';
export 'src/mcp_bootstrap.dart';
export 'src/mcp_session_spec.dart';
export 'src/mtls.dart';
export 'src/mtls_enroller.dart';
export 'src/overlay_packer.dart';
export 'src/run_status.dart';
export 'src/sandbox_deploy_client.dart';
export 'src/session_bridge.dart';
export 'src/speech_client.dart';
export 'src/tool_packager.dart';

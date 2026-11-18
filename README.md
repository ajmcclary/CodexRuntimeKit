# CodexRuntimeKit

UI-free, deterministic semantics for the OpenAI Codex CLI's `app-server` protocol.

CodexRuntimeKit turns decoded Codex wire payloads into typed values and decisions: which thread
or turn a notification belongs to, whether to drop it, what a server request is asking for, how
a tool event should be normalized, whether the installed CLI version matches the protocol this
code was written against, and when to retry. Everything is pure values and static functions,
plus one caller-isolated state holder for tool-event correlation. It never spawns a process,
reads a pipe, or touches the file system.

## What's inside

- `CodexSessionRef`, `CodexThreadSnapshot`, `CodexTurnStatus`, `CodexThreadGoal` /
  `CodexThreadGoalStatus` — session, thread, turn and goal models.
- `CodexRuntimeEvent` — the normalized runtime-event enum (assistant and reasoning deltas, token
  usage, turn lifecycle, approval / permissions / user-input / MCP-elicitation requests, tool
  calls and results, liveness, errors), with payloads such as `CodexReasoningDeltaPayload`,
  `CodexLivenessActivity` and `CodexErrorNotification`.
- `CodexJSONValue` — a `Codable`, `Sendable` JSON value; `CodexJSONAccess` — tolerant lookups
  over `[String: Any]` payloads (alternate key spellings, string/number/bool coercion).
- `CodexNotificationInterpreter` — envelope IDs, routing decisions
  (`CodexNotificationRoutingDecision`), liveness/error/token-usage parsing, turn status, and
  thread snapshot/goal projection.
- `CodexServerRequestParser` — method classification (`CodexServerRequestRouting`) and payload
  parsing for approval, permissions, request-user-input, MCP-elicitation and auth-refresh
  requests.
- `CodexToolEventNormalizer` — tool-event parsing, deduplication and file-change/command
  correlation. Host-specific MCP tool naming is injected through the `CodexToolNamePolicy`
  protocol.
- `CodexCliVersion`, `CodexCompatibilityPolicy`, `CodexCapabilityProbeClassifier`,
  `CodexProtocolKnownDivergences`, `CodexExperimentalAdmission` — version parsing, compatibility
  assessment, capability probes and experimental-API admission. `CodexProtocolLockSnapshot` is
  a generated record of the CLI release the protocol surface was pinned to; don't edit it by hand.
- Policies: `CodexBackoffPolicy` (retry of overloaded `-32001` responses),
  `CodexCommandExecutionPolicy`, `CodexNativeSlashCommand` / `CodexGoalPolicy`,
  `CodexModelUpgradeAdvisor`, `CodexRequestTimeoutPolicy`.
- Client vocabulary shared with transports: `CodexClientError`, `CodexServerNotification`,
  `CodexServerRequest`, `CodexRemoteModel`, `CodexTransportTerminationReason`.

## When to use it / when not

Use it when:

- you already have decoded JSON from a Codex app-server and need to interpret it;
- you want Codex protocol decisions you can unit-test without a process or a UI;
- you need to decide whether an installed `codex` version is the pinned, tested, or an untested
  one, or which experimental capabilities to admit.

Pick something else when:

- you need to talk to the process — framing, stdout decoding, request bookkeeping, spawning.
  That is [CodexAppServerKit](https://github.com/ajmcclary/CodexAppServerKit), which has no
  dependency on this package (its transport carries no Codex vocabulary).
- you want a ready Codex client that combines both: the `AgentCodexClient` product of
  [AgentExecutionKit](https://github.com/ajmcclary/AgentExecutionKit) owns startup, admission,
  retries, timeouts, subscriptions and teardown on top of CodexRuntimeKit and CodexAppServerKit.
  (Its `AgentCodexExec` product drives the separate `codex exec` CLI path and uses neither.)
- you need provider-neutral agent types (approval requests, usage, run state) — those live in
  [AgentRuntimeKit](https://github.com/ajmcclary/AgentRuntimeKit), which this package builds on.

Out of scope: process launch and transport, executable resolution, environment composition,
authentication and token refresh execution, provider selection, settings, recovery policy,
transcript projection, persistence, and UI.

## Installation

```swift
dependencies: [
    // 0.1.0-beta.5 is a prerelease identifier — SwiftPM only resolves
    // prerelease tags when the lower bound itself names one.
    .package(url: "https://github.com/ajmcclary/CodexRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.5"))
]
```

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "CodexRuntimeKit", package: "CodexRuntimeKit")
])
```

Several public signatures use AgentRuntimeKit types (for example `CodexAppServerRequestID`,
`AgentApprovalRequest`, `AgentContextUsage`); if your code names them, also depend on
AgentRuntimeKit and `import AgentRuntimeKit`.

## Usage

```swift
import CodexRuntimeKit

// Where does the installed CLI sit relative to the pinned protocol?
switch CodexCompatibilityPolicy.assess(rawVersion: "codex-cli 0.144.6") {
case .schemaTarget, .testedCompatible: break
case .olderUntested, .newerUntested:
    print("untested; pinned to \(CodexProtocolLockSnapshot.schemaTargetCliVersion)")
case .knownIncompatible(let reason): print("incompatible: \(reason)")
case .malformed(let raw): print("unparseable --version output: \(raw)")
}

// Notifications: a decoded `params` object in, typed values out.
let params: [String: Any] = [
    "threadId": "thr_1", "turnId": "turn_7",
    "error": ["message": "Rate limited", "willRetry": true]
]
let decision = CodexNotificationInterpreter.routingDecision(
    method: "error", params: params,
    activeThreadID: "thr_1", currentTurnID: "turn_7", activeTurnIDs: ["turn_7"]
)
if !decision.shouldDrop,
   let error = CodexNotificationInterpreter.parseErrorNotification(from: params) {
    print(CodexRuntimeEvent.errorNotification(error))  // message "Rate limited", willRetry true
}

// Server requests: classify the method before parsing its payload.
let routing = CodexServerRequestParser.classifyMethod("item/commandExecution/requestApproval")
// routing == .approval

// Retry only overloaded (-32001) responses, with exponential backoff.
let overloaded = CodexClientError.rpcError(
    code: CodexBackoffPolicy.overloadErrorCode, message: "busy")
let delay = CodexBackoffPolicy.default.retryDelay(for: overloaded, attempt: 1)  // 1.0 seconds
```

## Requirements

- Swift tools 6.0, Swift 6 language mode with strict concurrency; built with Xcode 27.
- macOS 27.0 / iOS 27.0.
- Dependencies: [AgentRuntimeKit](https://github.com/ajmcclary/AgentRuntimeKit). No third-party
  dependencies.

## Stability

Pre-1.0 (`0.1.0-beta.x`): the public API may change between minor versions, so pin with
`.upToNextMinor`.

## Development

`swift build` and `swift test` (fast; pure value types and policies).

## Origin

Extracted from the RepoPrompt app (Apache-2.0).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

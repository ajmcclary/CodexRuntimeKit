// swift-tools-version: 6.0
import PackageDescription

// CodexRuntimeKit — Codex-specific, UI-free runtime vocabulary and
// deterministic protocol semantics.
//
// Promoted verbatim out of RepoPrompt's internal RepoPromptCore package
// (its CodexRuntimeCore target) as the fifth extraction of the migrate.md
// package map and the first provider-runtime promotion (staged-plan
// step 5). RepoPromptCore's CodexRuntimeCore target is now an @_exported
// re-export shim over this package (the AgentRuntimeKit /
// PromptAssemblyKit / ApplyEditsKit promotion precedent).
//
// Scope: session/thread/turn references and snapshots (CodexSessionRef,
// CodexThreadSnapshot, CodexTurnStatus); thread goals and the goal/slash
// -command policies; the neutral runtime-event enum with its reasoning/
// liveness/error payloads; Codex JSON values and safe access/parsing
// helpers (CodexJSONValue, CodexJSONAccess); server-request and
// notification interpretation (CodexServerRequestParser,
// CodexNotificationInterpreter); tool-event normalization behind the
// CodexToolNamePolicy port (CodexToolEventNormalizer and its parsing/
// payload helpers); compatibility, admission, and version semantics
// (CodexCliVersion, CodexCompatibilityPolicy, capability probes, known
// divergences, CodexExperimentalAdmission) including the generated
// CodexProtocolLockSnapshot (regenerated only via RepoPrompt's
// Scripts/update-codex-protocol); and the pure backoff, command-execution,
// and model-upgrade policies.
//
// Deliberately OUT of scope (the later CodexAppServerKit and the app):
// the Codex app-server process transport, JSON-RPC codec, stdout stream
// framing, pending-request store, process launch and PID ownership, and
// termination policy (RepoPromptCore's CodexAppServerRuntime target owns
// that machinery for now); CLI launch profiles, executable resolution and
// environment composition, authentication/refresh execution, provider
// selection, app settings and recovery policy, AgentChatItem projection,
// persistence, and all UI. This package is intentionally Codex-specific —
// provider-neutral agent vocabulary lives in AgentRuntimeKit below it.
//
// One package dependency: AgentRuntimeKit (CodexAppServerRequestID, the
// approval/permissions/user-input/elicitation request models,
// AgentContextUsage, and AgentSessionRunState cross the boundary in
// public signatures). Swift 5 language mode keeps the moved code
// byte-behaviorally identical (AgentRuntimeKit / PromptAssemblyKit /
// ApplyEditsKit / RepoPromptCore promoted-target precedent).
let package = Package(
    name: "CodexRuntimeKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "CodexRuntimeKit", targets: ["CodexRuntimeKit"])
    ],
    dependencies: [
        // Provider-neutral agent vocabulary consumed in public signatures.
        // Prerelease lower bound named explicitly (SwiftPM only resolves
        // prerelease tags when the requirement names one — ProcessKit rule).
        .package(url: "https://github.com/ajmcclary/AgentRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.1"))
    ],
    targets: [
        .target(
            name: "CodexRuntimeKit",
            dependencies: [.product(name: "AgentRuntimeKit", package: "AgentRuntimeKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodexRuntimeKitTests",
            dependencies: ["CodexRuntimeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

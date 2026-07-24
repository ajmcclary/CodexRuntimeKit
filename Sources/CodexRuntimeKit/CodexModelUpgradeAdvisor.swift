import Foundation

// Catalog-driven upgrade advisories for unavailable Codex models (item 6 of
// the hardening program). `model/list` `upgrade`/`upgradeInfo` are advisory
// metadata for client migration prompts — NEVER an automatic retry. This
// advisor validates a server recommendation against the same catalog it came
// from; the app surfaces the result and requires an explicit user decision.

/// A validated, server-recommended successor for an unavailable model.
public struct CodexModelUpgradeRecommendation: Equatable, Sendable {
	public let unavailableModelID: String
	public let target: CodexRemoteModel
	/// Server-provided migration copy, when present.
	public let upgradeCopy: String?
	/// The requested reasoning effort, carried forward ONLY when the target
	/// advertises support for it; nil means the target's default applies.
	public let carriedReasoningEffort: String?
	/// The requested service tier, carried forward ONLY when the target
	/// advertises it; nil means the default tier applies.
	public let carriedServiceTier: String?
}

public enum CodexModelUpgradeAdvisor {
	/// Resolves the server's recommended successor for `unavailableModelID`
	/// from `catalog` (the SAME server catalog the metadata came from, so a
	/// recommendation can never cross a provider or authentication
	/// boundary). Returns nil — ordinary unavailable-model UX — when:
	///
	/// - the unavailable model is no longer listed (no metadata to read);
	/// - it carries no upgrade metadata (valid: not every model has one);
	/// - the upgrade chain dangles (a pointer to a model the catalog does
	///   not list);
	/// - the chain is self-referential or cyclic.
	///
	/// Upgrade pointers are followed through superseded intermediates to the
	/// chain's head (a listed entry with no further pointer), with a visited
	/// set so cycles terminate as invalid rather than looping.
	public static func recommendation(
		forUnavailableModelID unavailableModelID: String,
		requestedReasoningEffort: String? = nil,
		requestedServiceTier: String? = nil,
		catalog: [CodexRemoteModel]
	) -> CodexModelUpgradeRecommendation? {
		guard let source = entry(for: unavailableModelID, in: catalog) else {
			return nil
		}
		guard let firstPointer = upgradePointer(of: source) else {
			return nil
		}

		var visited: Set<String> = [key(source.id), key(source.model)]
		var pointer = firstPointer
		var resolved: CodexRemoteModel?
		while true {
			guard let target = entry(for: pointer, in: catalog) else {
				return nil // dangling pointer
			}
			let targetKeys: Set<String> = [key(target.id), key(target.model)]
			guard visited.isDisjoint(with: targetKeys) else {
				return nil // self-reference or cycle
			}
			visited.formUnion(targetKeys)
			if let next = upgradePointer(of: target) {
				pointer = next
				continue
			}
			resolved = target
			break
		}
		guard let target = resolved else { return nil }

		let carriedEffort = requestedReasoningEffort.flatMap { requested in
			target.supportedReasoningEfforts.contains { key($0.reasoningEffort) == key(requested) }
				? requested
				: nil
		}
		let carriedTier = requestedServiceTier.flatMap { requested in
			target.serviceTierIDs.contains { key($0) == key(requested) } ? requested : nil
		}
		return CodexModelUpgradeRecommendation(
			unavailableModelID: unavailableModelID,
			target: target,
			upgradeCopy: source.upgradeInfo?.upgradeCopy,
			carriedReasoningEffort: carriedEffort,
			carriedServiceTier: carriedTier
		)
	}

	private static func entry(for identifier: String, in catalog: [CodexRemoteModel]) -> CodexRemoteModel? {
		let wanted = key(identifier)
		guard !wanted.isEmpty else { return nil }
		return catalog.first { key($0.id) == wanted || key($0.model) == wanted }
	}

	private static func upgradePointer(of model: CodexRemoteModel) -> String? {
		let pointer = model.upgradeInfo?.model ?? model.upgradeModelID
		guard let pointer, !key(pointer).isEmpty else { return nil }
		return pointer
	}

	private static func key(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}

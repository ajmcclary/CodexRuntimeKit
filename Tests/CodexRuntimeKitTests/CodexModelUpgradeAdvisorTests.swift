import XCTest
@testable import CodexRuntimeKit

/// Catalog-driven upgrade-advisory validation (item 6). All model IDs are
/// synthetic, proving the advisor carries no hard-coded model-family
/// assumptions: the catalog is the only source of truth.
final class CodexModelUpgradeAdvisorTests: XCTestCase {

	private func model(
		_ id: String,
		isDefault: Bool = false,
		efforts: [String] = [],
		tiers: [String] = [],
		upgrade: String? = nil,
		upgradeCopy: String? = nil
	) -> CodexRemoteModel {
		CodexRemoteModel(
			id: id,
			model: id,
			displayName: id.uppercased(),
			description: "",
			isDefault: isDefault,
			supportedReasoningEfforts: efforts.map {
				CodexRemoteReasoningEffort(reasoningEffort: $0, description: "")
			},
			defaultReasoningEffort: efforts.first,
			serviceTierIDs: tiers,
			upgradeModelID: upgrade,
			upgradeInfo: upgrade.map {
				CodexRemoteModelUpgradeInfo(model: $0, upgradeCopy: upgradeCopy, migrationMarkdown: nil, modelLink: nil)
			}
		)
	}

	// MARK: - Valid recommendations

	func testValidRecommendationResolvesArbitrarySyntheticTarget() {
		let catalog = [
			model("relic-epsilon", upgrade: "lodestone-nine", upgradeCopy: "Superseded by Lodestone."),
			model("lodestone-nine"),
			model("bystander-two", isDefault: true)
		]
		let recommendation = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "relic-epsilon",
			catalog: catalog
		)
		XCTAssertEqual(recommendation?.target.id, "lodestone-nine")
		XCTAssertEqual(recommendation?.upgradeCopy, "Superseded by Lodestone.")
		XCTAssertEqual(recommendation?.unavailableModelID, "relic-epsilon")
	}

	func testChainOfSupersededIntermediatesResolvesToHead() {
		let catalog = [
			model("gen-one", upgrade: "gen-two"),
			model("gen-two", upgrade: "gen-three"),
			model("gen-three")
		]
		let recommendation = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "gen-one",
			catalog: catalog
		)
		XCTAssertEqual(recommendation?.target.id, "gen-three")
	}

	// MARK: - Invalid recommendations degrade to nil (ordinary unavailable UX)

	func testMissingUpgradeMetadataIsValidAndYieldsNoRecommendation() {
		let catalog = [model("plain-model"), model("catalog-default", isDefault: true)]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "plain-model", catalog: catalog)
		)
	}

	func testModelAbsentFromCatalogYieldsNoRecommendation() {
		let catalog = [model("only-model", isDefault: true)]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "vanished-model", catalog: catalog)
		)
	}

	func testEmptyCatalogYieldsNoRecommendation() {
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "anything", catalog: [])
		)
	}

	func testDanglingUpgradePointerIsRejected() {
		let catalog = [model("orphaned", upgrade: "not-in-this-catalog")]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "orphaned", catalog: catalog)
		)
	}

	func testSelfReferenceIsRejected() {
		let catalog = [model("narcissus", upgrade: "narcissus")]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "narcissus", catalog: catalog)
		)
	}

	func testCycleIsRejected() {
		let catalog = [
			model("loop-a", upgrade: "loop-b"),
			model("loop-b", upgrade: "loop-a")
		]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(forUnavailableModelID: "loop-a", catalog: catalog)
		)
	}

	func testIsDefaultIsNeverUsedAsAFallbackForFailedExplicitSelection() {
		// A catalog default exists, but the unavailable model carries no
		// upgrade metadata: no substitution may be invented from isDefault.
		let catalog = [
			model("flagship-default", isDefault: true),
			model("unlisted-upgradeless")
		]
		XCTAssertNil(
			CodexModelUpgradeAdvisor.recommendation(
				forUnavailableModelID: "unlisted-upgradeless",
				catalog: catalog
			)
		)
	}

	// MARK: - Effort / service-tier carry-forward

	func testReasoningEffortCarriesOnlyWhenTargetAdvertisesSupport() {
		let catalog = [
			model("old-tiered", efforts: ["low", "xhigh"], upgrade: "new-tiered"),
			model("new-tiered", efforts: ["low", "medium"])
		]
		let carried = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "old-tiered",
			requestedReasoningEffort: "low",
			catalog: catalog
		)
		XCTAssertEqual(carried?.carriedReasoningEffort, "low")

		let dropped = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "old-tiered",
			requestedReasoningEffort: "xhigh",
			catalog: catalog
		)
		XCTAssertNotNil(dropped, "The recommendation itself remains valid")
		XCTAssertNil(dropped?.carriedReasoningEffort, "Unsupported effort must not carry forward")
	}

	func testServiceTierCarriesOnlyWhenTargetAdvertisesSupport() {
		let catalog = [
			model("old-fast", tiers: ["express"], upgrade: "new-fast"),
			model("new-fast", tiers: ["standard"])
		]
		let dropped = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "old-fast",
			requestedServiceTier: "express",
			catalog: catalog
		)
		XCTAssertNotNil(dropped)
		XCTAssertNil(dropped?.carriedServiceTier)

		let carried = CodexModelUpgradeAdvisor.recommendation(
			forUnavailableModelID: "old-fast",
			requestedServiceTier: "standard",
			catalog: [
				model("old-fast", tiers: ["express"], upgrade: "new-fast"),
				model("new-fast", tiers: ["standard", "express"])
			]
		)
		XCTAssertEqual(carried?.carriedServiceTier, "standard")
	}
}

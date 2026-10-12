import Foundation

/// A constructed 40-module iOS app mid-way through an `ObservableObject` → `@Observable`
/// migration. File counts and type counts are invented for the demo, not measured.
public enum SampleCodebase {
    public static let goal = "Migrate every ObservableObject to @Observable without changing the module graph."

    private static let features: [(String, Int, Int, [String])] = [
        ("FeatureHome", 26, 4, ["CatalogService", "LoyaltyService"]),
        ("FeatureSearch", 20, 3, ["SearchService", "CatalogService"]),
        ("FeatureProduct", 24, 3, ["CatalogService", "InventoryService"]),
        ("FeatureCart", 22, 3, ["CartService", "CatalogService"]),
        ("FeatureCheckout", 26, 4, ["CartService", "PaymentService", "OrderService"]),
        ("FeatureOrders", 20, 3, ["OrderService"]),
        ("FeatureProfile", 18, 2, ["ProfileService"]),
        ("FeatureSettings", 16, 2, ["ProfileService", "NotificationService"]),
        ("FeatureLogin", 18, 3, ["AccountService"]),
        ("FeatureOnboarding", 16, 2, ["AccountService"]),
        ("FeatureWishlist", 14, 2, ["CatalogService"]),
        ("FeatureReviews", 16, 2, ["CatalogService", "AccountService"]),
        ("FeatureLoyalty", 18, 3, ["LoyaltyService"]),
        ("FeatureNotifications", 14, 2, ["NotificationService"]),
        ("FeatureStores", 16, 2, ["InventoryService"]),
        ("FeatureHelp", 12, 1, ["AccountService"]),
        ("FeatureReturns", 18, 2, ["OrderService", "PaymentService"]),
        ("FeatureGiftCards", 14, 2, ["PaymentService"]),
        ("FeaturePromotions", 16, 2, ["CatalogService", "LoyaltyService"]),
        ("FeatureAddressBook", 12, 1, ["ProfileService"]),
        ("FeaturePaymentMethods", 16, 2, ["PaymentService"]),
        ("FeatureReferrals", 12, 1, ["LoyaltyService", "AccountService"])
    ]

    public static func modules() -> [Module] {
        var list: [Module] = [
            Module(name: "CoreModels", layer: .core, imports: [], fileCount: 18, legacyObservables: 3),
            Module(name: "CoreNetworking", layer: .core, imports: ["CoreModels"], fileCount: 14, legacyObservables: 1),
            Module(name: "CoreStorage", layer: .core, imports: ["CoreModels"], fileCount: 12, legacyObservables: 2),
            Module(name: "CoreAnalytics", layer: .core, imports: [], fileCount: 8, legacyObservables: 1),
            Module(name: "CoreDesign", layer: .core, imports: [], fileCount: 22, legacyObservables: 0),
            Module(name: "CoreAuth", layer: .core, imports: ["CoreNetworking", "CoreStorage"], fileCount: 10, legacyObservables: 2),
            Module(name: "AccountService", layer: .service, imports: ["CoreAuth", "CoreModels"], fileCount: 14, legacyObservables: 3),
            Module(name: "CartService", layer: .service, imports: ["CoreNetworking", "CoreStorage"], fileCount: 12, legacyObservables: 2),
            Module(name: "CatalogService", layer: .service, imports: ["CoreNetworking"], fileCount: 16, legacyObservables: 3),
            Module(name: "OrderService", layer: .service, imports: ["CoreNetworking", "CoreModels"], fileCount: 14, legacyObservables: 2),
            Module(name: "PaymentService", layer: .service, imports: ["CoreNetworking", "CoreAuth"], fileCount: 16, legacyObservables: 3),
            Module(name: "SearchService", layer: .service, imports: ["CoreNetworking"], fileCount: 10, legacyObservables: 2),
            Module(name: "ProfileService", layer: .service, imports: ["AccountService"], fileCount: 10, legacyObservables: 2),
            Module(name: "NotificationService", layer: .service, imports: ["CoreNetworking"], fileCount: 8, legacyObservables: 1),
            Module(name: "LoyaltyService", layer: .service, imports: ["AccountService", "OrderService"], fileCount: 10, legacyObservables: 2),
            Module(name: "InventoryService", layer: .service, imports: ["CatalogService"], fileCount: 10, legacyObservables: 1)
        ]
        for (name, files, legacy, services) in features {
            list.append(Module(name: name, layer: .feature, imports: services + ["CoreDesign", "CoreAnalytics"],
                               fileCount: files, legacyObservables: legacy))
        }
        list.append(Module(name: "AppShell", layer: .app, imports: features.map(\.0) + ["CoreAuth"],
                           fileCount: 22, legacyObservables: 4))
        list.append(Module(name: "AppWidgets", layer: .app, imports: ["FeatureHome", "FeatureOrders", "FeatureLoyalty"],
                           fileCount: 12, legacyObservables: 2))
        return list
    }

    public static func graph() -> ModuleGraph {
        // The sample is a compile-time constant; a failure here is a programming error in this file.
        guard let graph = try? ModuleGraph(modules()) else { preconditionFailure("SampleCodebase is malformed") }
        return graph
    }
}

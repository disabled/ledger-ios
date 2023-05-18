//
//  Copyright © 2021 Rosberry. All rights reserved.
//

import Foundation
import StoreKit
import SwiftyStoreKit
import KeychainAccess
import Kronos
import Ion

public final class Ledger {
    public enum Error: Swift.Error {
        case noProduct
    }

    private enum Constants {
        static let keychainService: String = "ledger"
        static let keychainReceiptKey: String = "receipt"
    }

    public private(set) static var receipt: Receipt = fetchCachedReceipt() {
        didSet {
            receiptUpdateEventEmitter.replace(receipt)
            if let data = try? JSONEncoder().encode(receipt) {
                try? keychain.set(data, key: Constants.keychainReceiptKey)
            }
        }
    }

    private static var receiptUpdateEventEmitter: Emitter<Receipt> = .init()
    public static var receiptUpdateEventSource: AnyEventSource<Receipt> = .init(receiptUpdateEventEmitter)

    private static var purchaseEventEmitter: Emitter<PurchaseInfo> = .init(valueStackDepth: 0)
    public static var purchaseEventSource: AnyEventSource<PurchaseInfo> = .init(purchaseEventEmitter)

    private static var productInfoEmitter: Emitter<Product> = .init()
    public static var productInfoSource: AnyEventSource<Product> = .init(productInfoEmitter)

    public static var skipReceiptValidation: Bool = false

    public static var referenceDate: Date {
        return Clock.now ?? Date()
    }

    private static var sharedSecret: String = .init()
    private static var productCache: NSCache<NSString, Product> = .init()
    private static var keychain: Keychain = .init(service: Constants.keychainService)
    private static var didInitiatePurchaseFlow: Bool = false

    public static var receiptRefreshHandler: ((Receipt) -> Void)?

    public static func start(sharedSecret: String) {
        self.sharedSecret = sharedSecret
        #if targetEnvironment(simulator)
        skipReceiptValidation = true
        #endif

        Clock.sync()
        SwiftyStoreKit.completeTransactions(atomically: false) { (purchases: [Purchase]) in
            if skipReceiptValidation {
                let identifiers = purchases.map { (purchase: Purchase) -> String in
                    return purchase.productId
                }
                fetchProducts(withIdentifiers: identifiers) { (products: [String: Product]) in
                    objc_sync_enter(self)
                    for product in products.values {
                        receipt.purchases[product.identifier] = .init(product: product)
                    }
                    objc_sync_exit(self)
                }
            }

            refreshReceipt { (receipt: Receipt) in
                for purchase in purchases where purchase.needsFinishTransaction {
                    SwiftyStoreKit.finishTransaction(purchase.transaction)
                    objc_sync_enter(self)
                    if let purchaseInfo = receipt.purchaseInfo(withIdentifier: purchase.productId) {
                        purchaseEventEmitter.emit(purchaseInfo)
                    }
                    objc_sync_exit(self)
                }
                DispatchQueue.main.async {
                    receiptRefreshHandler?(receipt)
                }
            }
        }

        refreshReceipt()
    }

    public static func refreshReceipt(force: Bool = false,
                                      success: @escaping (Receipt) -> Void = { _ in },
                                      failure: @escaping (Swift.Error) -> Void = { _ in }) {
        let isEmptyReceipt = (didInitiatePurchaseFlow == false) && (SwiftyStoreKit.localReceiptData == nil)
        if (skipReceiptValidation || isEmptyReceipt), force == false {
            receiptUpdateEventEmitter.replace(receipt)
            return success(receipt)
        }

        guard sharedSecret.isEmpty == false else {
            fatalError("No shared secret is provided")
        }

        let validator = AppleReceiptValidator(service: .production, sharedSecret: sharedSecret)
        SwiftyStoreKit.verifyReceipt(using: validator, forceRefresh: false) { (result: VerifyReceiptResult) in
            switch result {
            case .success(let receipt):
                objc_sync_enter(self)
                self.receipt = Receipt(dictionary: receipt) ?? .init()
                objc_sync_exit(self)
                success(self.receipt)
            case .error(let error):
                print("[EE] Error validating receipt: \(error)")
                failure(error)
            }
        }
    }

    public static func removeCachedReceipt() {
        try? keychain.removeAll()
    }

    public static func fetchProducts(withIdentifiers identifiers: [String], completion: @escaping ([String: Product]) -> Void = { _ in }) {
        var result: [String: Product] = [:]
        var pendingIdentifiers: [String] = []
        for identifier in identifiers {
            let nsIdentifier = identifier as NSString
            objc_sync_enter(self)
            if let product = productCache.object(forKey: nsIdentifier) {
                result[identifier] = product
            }
            else {
                pendingIdentifiers.append(identifier)
            }
            objc_sync_exit(self)
        }

        guard pendingIdentifiers.isEmpty == false else {
            return completion(result)
        }

        SwiftyStoreKit.retrieveProductsInfo(.init(pendingIdentifiers)) { (retrieveResults: RetrieveResults) in
            for storeProduct in retrieveResults.retrievedProducts {
                let product = Product(storeProduct: storeProduct)
                let nsIdentifier = product.identifier as NSString
                objc_sync_enter(self)
                productCache.setObject(product, forKey: nsIdentifier)
                objc_sync_exit(self)
                result[product.identifier] = product
                productInfoEmitter.emit(product)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    public static func purchaseProduct(withIdentifier identifier: String, completion: @escaping (Swift.Error?) -> Void) {
        fetchProducts(withIdentifiers: [identifier]) { (result: [String: Product]) in
            guard let product = result[identifier] else {
                return completion(Error.noProduct)
            }

            didInitiatePurchaseFlow = true
            SwiftyStoreKit.purchaseProduct(product.storeProduct, atomically: false) { (result: PurchaseResult) in
                switch result {
                case let .success(details):
                    if skipReceiptValidation {
                        objc_sync_enter(self)
                        receipt.purchases[identifier] = .init(product: product)
                        objc_sync_exit(self)
                    }

                    refreshReceipt { (_: Receipt) in
                        if details.needsFinishTransaction {
                            SwiftyStoreKit.finishTransaction(details.transaction)
                        }
                        objc_sync_enter(self)
                        if let purchaseInfo = receipt.purchaseInfo(withIdentifier: details.productId) {
                            purchaseEventEmitter.emit(purchaseInfo)
                        }
                        objc_sync_exit(self)
                        DispatchQueue.main.async {
                            completion(nil)
                        }
                    } failure: { (error: Swift.Error) in
                        DispatchQueue.main.async {
                            completion(error)
                        }
                    }
                case let .error(error):
                    DispatchQueue.main.async {
                        switch error.code {
                        case .unknown:
                            refreshReceipt()
                            completion(nil)
                        case .paymentCancelled:
                            completion(nil)
                        default:
                            completion(error)
                        }
                    }
                }
            }
        }
    }

    public static func isProductPurchased(identifier: String) -> Bool {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }

        return receipt.purchases[identifier] != nil
    }

    public static func isAnyProductPurchased() -> Bool {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }

        return receipt.purchases.isEmpty == false
    }

    public static func isSubscriptionActive(identifier: String) -> Bool {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }

        guard let purchaseInfo = receipt.purchases[identifier] else {
            return false
        }

        return purchaseInfo.expirationDate > referenceDate
    }

    public static func isAnySubscriptionActive() -> Bool {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }

        return receipt.purchases.values.contains { (purchaseInfo: PurchaseInfo) -> Bool in
            return (purchaseInfo.type == .subscription) && (purchaseInfo.expirationDate > referenceDate)
        }
    }

    private static func fetchCachedReceipt() -> Receipt {
        guard let data = try? keychain.getData(Constants.keychainReceiptKey),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
            return .init()
        }

        return receipt
    }
}

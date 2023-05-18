//
//  Copyright © 2021 Rosberry. All rights reserved.
//

import Foundation

public struct Receipt: Codable {
    enum CodingKeys: CodingKey {
        case creationDate
        case purchases
    }

    public let creationDate: Date
    public var purchases: [String: PurchaseInfo]
    public var raw: [String: Any] = [:]

    public init(purchases: [PurchaseInfo] = []) {
        creationDate = Date()
        self.purchases = [:]
        for purchase in purchases {
            self.purchases[purchase.identifier] = purchase
        }
    }

    init?(dictionary: [String: Any]) {
        raw = dictionary
        guard let receiptDict = dictionary["receipt"] as? [String: Any],
              let purchasesDict = receiptDict["in_app"] as? [[String: Any]] else {
            return nil
        }

        var purchases: [String: PurchaseInfo] = [:]
        for purchaseDict in purchasesDict {
            guard let info = PurchaseInfo(dictionary: purchaseDict) else {
                continue
            }

            if let existingPurchase = purchases[info.identifier] {
                purchases[info.identifier] = info.expirationDate > existingPurchase.expirationDate ? info : existingPurchase
            }
            else {
                purchases[info.identifier] = info
            }
        }
        self.purchases = purchases

        if let creationTimestampString = receiptDict["receipt_creation_date_ms"] as? String,
           let creationTimestamp = TimeInterval(creationTimestampString) {
            creationDate = Date(timeIntervalSince1970: creationTimestamp / 1000.0)
        }
        else {
            creationDate = Date()
        }
    }

    public func purchaseInfo(withIdentifier identifier: String) -> PurchaseInfo? {
        return purchases[identifier]
    }
}

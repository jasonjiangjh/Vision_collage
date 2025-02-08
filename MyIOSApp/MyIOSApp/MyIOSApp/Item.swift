//
//  Item.swift
//  MyIOSApp
//
//  Created by JasonJiang on 2025/2/8.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

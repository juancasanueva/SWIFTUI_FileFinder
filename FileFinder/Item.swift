//
//  Item.swift
//  FileFinder
//
//  Created by Juan Casanueva on 03/11/2026.
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

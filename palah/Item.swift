//
//  Item.swift
//  palah
//
//  Created by Gopakumar N on 03/06/26.
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

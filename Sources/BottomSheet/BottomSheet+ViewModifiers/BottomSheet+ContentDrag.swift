//
//  BottomSheet+ContentDrag.swift
//
//  Created by Lucas Zischka.
//  Copyright © 2022 Lucas Zischka. All rights reserved.
//

import Foundation

public extension BottomSheet {
    
    /// Makes it possible to resize the BottomSheet by dragging the mainContent.
    ///
    /// On iPhone (and iPad not floating) a ScrollView or List in the mainContent only scrolls when the BottomSheet
    /// is at its highest position and the content is taller than the ScrollView. Every other vertical swipe moves the
    /// BottomSheet, as does pulling the content down when it is scrolled to the top.
    /// These drags don't call `onDragChanged` or `onDragEnded`.
    ///
    /// On iPad floating and Mac this option has no effect or even makes the BottomSheet glitch
    /// if the mainContent is packed into a ScrollView or a List.
    ///
    /// - Parameters:
    ///   - bool: A boolean whether the option is enabled.
    ///
    /// - Returns: A BottomSheet where the mainContent can be used for resizing.
    func enableContentDrag(_ bool: Bool = true) -> BottomSheet {
        self.configuration.isContentDragEnabled = bool
        return self
    }
}

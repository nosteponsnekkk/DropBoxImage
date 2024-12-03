//
//  UIImage + Ext.swift
//
//
//  Created by Oleg on 03.12.2024.
//

import UIKit
public extension UIImage {
    static func dropBoxImage(_ path: String) async -> UIImage? {
        await DropBoxImageService.shared.image(at: path)
    }
}

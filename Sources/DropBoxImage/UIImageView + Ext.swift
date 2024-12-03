//
//  UIImageView + Ext.swift
//
//
//  Created by Oleg on 03.12.2024.
//

import UIKit

public extension UIImageView {
    func setDropBoxImage(with imagePath: String) {
        Task {
            let service = DropBoxImageService.shared
            Task {
                let image = await service.image(at: imagePath)
                DispatchQueue.main.async {
                    self.image = image
                }
            }
        }
    }
}

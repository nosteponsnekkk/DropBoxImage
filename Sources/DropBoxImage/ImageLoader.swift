//
//  File.swift
//  
//
//  Created by Oleg on 19.11.2024.
//

import SwiftUI
import Combine
import Dependencies

// MARK: - ImageLoader

final class ImageLoader: ObservableObject {
    @Published public var image: UIImage?
    @Published public var isLoading: Bool = false
    @Published public var hasFailed: Bool = false

    private var imagePath: String?
    private let cacheClient: ImageCacheClient
    private var currentTask: Task<Void, Never>? = nil
    private let checkRevision: Bool
    private let onImageDataLoaded: ((Data) -> Void)?

    init(imagePath: String?, checkRevision: Bool = true, cacheClient: ImageCacheClient = DropBoxImageService.shared, onImageDataLoaded: ((Data) -> Void)? = nil) {
        self.imagePath = imagePath
        self.cacheClient = cacheClient
        self.checkRevision = checkRevision
        self.onImageDataLoaded = onImageDataLoaded
        if let imagePath = imagePath {
            loadImage(from: imagePath)
        }
    }
    
    public func updateImagePath(_ newPath: String?) {
        if imagePath != newPath {
            imagePath = newPath
            image = nil
            hasFailed = false
            loadImage(from: newPath)
        }
    }
    
    public func cancelLoading() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    private func loadImage(from filePath: String?) {
        guard let filePath = filePath else { return }
        isLoading = true
        currentTask?.cancel()
        currentTask = Task {
            let fetchedImage = await cacheClient.image(at: filePath, checkRev: checkRevision)
            if let data = fetchedImage?.jpegData(compressionQuality: 0.8) {
                onImageDataLoaded?(data)
            }
            await MainActor.run {
                self.image = fetchedImage
                self.isLoading = false
                self.hasFailed = (fetchedImage == nil)
            }
        }
    }
}

//
//  ImageCacheClient.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import Foundation
import SwiftyDropbox
import UIKit
import Dependencies

// MARK: - ImageCacheClient Protocol

/// A protocol defining the necessary asynchronous methods for an image caching client.
public protocol ImageCacheClient {
    /// Asynchronously retrieves an image for the given Dropbox file path.
    ///
    /// - Parameter filePath: The Dropbox file path of the image.
    /// - Returns: The retrieved `UIImage` or `nil` if not found.
    func image(at filePath: String?) async -> UIImage?
    
    /// Asynchronously prefetches images for the given Dropbox file paths.
    ///
    /// - Parameter filePaths: An array of Dropbox file paths to prefetch.
    func prefetch(filePaths: [String]) async
    
    /// Asynchronously clears both memory and disk caches.
    func clearCache() async
}

// MARK: - Dependency Key

public extension DependencyValues {
    var imageCacheClient: ImageCacheClient {
        get { self[ImageCacheClientKey.self] }
        set { self[ImageCacheClientKey.self] = newValue }
    }
    
    struct ImageCacheClientKey: DependencyKey {
        public static let liveValue: ImageCacheClient = DropBoxImageService.shared
        public init() {}
    }
}

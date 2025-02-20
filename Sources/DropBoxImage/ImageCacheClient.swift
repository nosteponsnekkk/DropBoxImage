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
    /// - Parameters:
    ///   - filePath: The Dropbox file path of the image.
    ///   - checkRev: A flag indicating whether to verify the image revision with Dropbox.
    /// - Returns: The retrieved `UIImage` or `nil` if not found.
    func image(at filePath: String?, checkRev: Bool) async -> UIImage?
    
    /// Asynchronously prefetches images for the given Dropbox file paths.
    ///
    /// - Parameters:
    ///   - filePaths: An array of Dropbox file paths to prefetch.
    ///   - checkRev: A flag indicating whether to verify the image revision with Dropbox.
    func prefetch(filePaths: [String], checkRev: Bool) async
    
    /// Asynchronously clears both memory and disk caches.
    func clearCache() async
    
    /// - Parameters:
    ///   - filePaths: An array of Dropbox file paths to prefetch.
    ///   - checkRev: A flag indicating whether to verify the image revision with Dropbox.
    ///   - withConcurrencyOf concurrency: A number of concurrent operations.
    func prefetch(
        filePaths: [String],
        checkRev: Bool,
        withConcurrencyOf concurrency: Int
    ) async
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

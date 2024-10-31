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

/// A protocol defining the necessary methods for an image caching client.
public protocol ImageCacheClient {
    /// Sets the Dropbox client to be used for downloading images.
    /// - Parameter client: The `DropboxClient` instance.
    func setClient(_ client: DropboxClient)
    
    /// Retrieves an image for the given Dropbox file path asynchronously.
    /// - Parameter filePath: The Dropbox file path of the image.
    /// - Returns: The retrieved `UIImage` or `nil` if not found.
    func image(at filePath: String) async -> UIImage?
    
    /// Prefetches images for the given Dropbox file paths.
    /// - Parameter filePaths: Array of Dropbox file paths to prefetch.
    func prefetch(filePaths: [String])
    
    /// Clears both memory and disk caches asynchronously.
    /// - Returns: Void.
    func clearCache() async
}

// MARK: - Dependency Key

public extension DependencyValues {
    var imageCacheClient: ImageCacheClient {
        get { self[ImageCacheClientKey.self] }
        set { self[ImageCacheClientKey.self] = newValue }
    }
    
    struct ImageCacheClientKey: DependencyKey {
        public static let liveValue: ImageCacheClient = {
            let service = DropBoxImageService()
            
            if let client = DropboxClientsManager.authorizedClient {
                service.setClient(client)
            }
            return service
        }()
        
        public init() {}
    }
}

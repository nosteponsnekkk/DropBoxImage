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
public protocol ImageCacheClient {
    func image(at filePath: String?, checkRev: Bool, format: ImageStorageFormat) async -> UIImage?
    func prefetch(filePaths: [String], checkRev: Bool, format: ImageStorageFormat) async
    func prefetch(filePaths: [String], checkRev: Bool, withConcurrencyOf concurrency: Int, format: ImageStorageFormat) async
    func clearCache()
    func clearCacheAsync() async
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

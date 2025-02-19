//
//  DropBoxImageService.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import Foundation
import SwiftyDropbox
import UIKit
import CommonCrypto

// MARK: - CachedImageEntry

/// A simple container that holds an image and its Dropbox revision identifier.
fileprivate final class CachedImageEntry {
    let image: UIImage
    let rev: String

    init(image: UIImage, rev: String) {
        self.image = image
        self.rev = rev
    }
}

// MARK: - DropBoxImageService

/// A service that manages caching of images from Dropbox. It caches images both in memory and on disk,
/// verifies the freshness using Dropbox’s `rev` property on first access per session,
/// and supports concurrent prefetching of images.
final class DropBoxImageService: ImageCacheClient {

    // MARK: - Private Properties

    /// Dropbox client instance (if authorized).
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }

    /// In-memory cache for images.
    private let memoryCache = NSCache<NSString, CachedImageEntry>()

    /// A concurrent dispatch queue for performing disk I/O operations.
    private let ioQueue: DispatchQueue

    /// FileManager instance for disk operations.
    private let fileManager: FileManager

    /// URL for the disk cache directory.
    private let diskCacheURL: URL

    /// Maximum allowed disk cache size (800 MB).
    private let maxDiskCacheSize: UInt64 = 800 * 1024 * 1024
    /// Maximum allowed cost for the memory cache (400 MB).
    private let maxMemoryCacheCost: Int = 400 * 1024 * 1024

    /// Array to track LRU (least recently used) access order for cached keys.
    private var accessOrder: [String] = []
    private let accessOrderQueue = DispatchQueue(label: "com.dropboximageservice.accessOrderQueue", attributes: .concurrent)

    /// Set to track which cache keys have had their revision checked in this session.
    private var checkedRevKeys: Set<String> = []
    private let checkedRevKeysQueue = DispatchQueue(label: "com.dropboximageservice.checkedRevKeysQueue", attributes: .concurrent)

    // MARK: - Initialization

    /// Shared singleton instance.
    static let shared = DropBoxImageService()

    private init() {
        memoryCache.totalCostLimit = maxMemoryCacheCost
        memoryCache.countLimit = 5000

        fileManager = FileManager.default

        // Create (or validate) the disk cache directory.
        if let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            diskCacheURL = cacheDir.appendingPathComponent("DropBoxImageCache")
            if !fileManager.fileExists(atPath: diskCacheURL.path) {
                do {
                    try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    fatalError("Unable to create disk cache directory: \(error)")
                }
            }
        } else {
            fatalError("Unable to access caches directory")
        }

        ioQueue = DispatchQueue(label: "com.dropboximageservice.ioQueue", attributes: .concurrent)

        // Subscribe to memory warning notifications to clear in-memory cache.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Memory Warning Handling

    /// Called when the app receives a memory warning.
    /// This method clears the in-memory cache immediately.
    /// Note: It cannot be async because it is called via an Objective-C selector.
    @objc private func handleMemoryWarning() {
        clearMemoryCache()
        // Optionally, you can also clear the disk cache here.
        // For example, using a background Task:
        /*
        Task {
            await clearCacheAsync()
        }
        */
    }

    // MARK: - Public APIs

    /// Retrieves an image for the given Dropbox file path.
    /// - Parameters:
    ///   - filePath: The Dropbox file path.
    ///   - checkRev: If `true`, the method verifies that the cached image’s revision matches Dropbox.
    ///               If `false`, it returns any cached image without verifying its revision.
    public func image(at filePath: String?, checkRev: Bool = true) async -> UIImage? {
        guard let filePath = filePath else { return nil }
        let key = cacheKey(for: filePath)
        let nsKey = key as NSString

        // 1. Check in-memory cache.
        if let cachedEntry = memoryCache.object(forKey: nsKey) {
            if checkRev {
                let hasChecked = await hasCheckedRev(for: key)
                if !hasChecked {
                    if let currentRev = await getCurrentRev(for: filePath) {
                        if currentRev != cachedEntry.rev {
                            if let (image, rev) = await downloadImage(from: filePath) {
                                await store(image: image, rev: rev, forKey: key)
                                await markRevAsChecked(for: key)
                                return image
                            } else {
                                await markRevAsChecked(for: key)
                                return cachedEntry.image
                            }
                        } else {
                            await markRevAsChecked(for: key)
                            await updateAccessOrder(for: key)
                            return cachedEntry.image
                        }
                    } else {
                        await markRevAsChecked(for: key)
                        await updateAccessOrder(for: key)
                        return cachedEntry.image
                    }
                } else {
                    await updateAccessOrder(for: key)
                    return cachedEntry.image
                }
            } else { // Rev check is disabled.
                await updateAccessOrder(for: key)
                return cachedEntry.image
            }
        }
        
        // 2. Check disk cache.
        if let cachedEntry = await loadImageAndRevFromDisk(forKey: key) {
            if checkRev {
                let hasChecked = await hasCheckedRev(for: key)
                if !hasChecked {
                    if let currentRev = await getCurrentRev(for: filePath) {
                        if currentRev != cachedEntry.rev {
                            if let (image, rev) = await downloadImage(from: filePath) {
                                await store(image: image, rev: rev, forKey: key)
                                await markRevAsChecked(for: key)
                                return image
                            } else {
                                await markRevAsChecked(for: key)
                                return cachedEntry.image
                            }
                        } else {
                            await markRevAsChecked(for: key)
                            memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                            await updateAccessOrder(for: key)
                            return cachedEntry.image
                        }
                    } else {
                        await markRevAsChecked(for: key)
                        memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                        await updateAccessOrder(for: key)
                        return cachedEntry.image
                    }
                } else {
                    memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                    await updateAccessOrder(for: key)
                    return cachedEntry.image
                }
            } else {
                memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                await updateAccessOrder(for: key)
                return cachedEntry.image
            }
        }
        
        // 3. Download from Dropbox.
        if let (image, rev) = await downloadImage(from: filePath) {
            await store(image: image, rev: rev, forKey: key)
            if checkRev {
                await markRevAsChecked(for: key)
            }
            return image
        }
        
        return nil
    }
    
    /// Prefetches images for the given Dropbox file paths.
       public func prefetch(filePaths: [String], checkRev: Bool = true) async {
           await withTaskGroup(of: Void.self) { group in
               for filePath in filePaths {
                   group.addTask {
                       _ = await self.image(at: filePath, checkRev: checkRev)
                   }
               }
           }
       }
    /// Synchronously clears both the memory and disk caches.
    ///
    /// Call this method when you need to free up cached data.
    public func clearCache() {
        clearMemoryCache()
        clearDiskCacheSync()
    }

    /// Asynchronously clears both the memory and disk caches.
    ///
    /// Use this version when calling from a Swift Concurrency context.
    public func clearCacheAsync() async {
        clearMemoryCache()
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.fileManager.removeItem(at: self.diskCacheURL)
                    try self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true, attributes: nil)
                    self.accessOrderQueue.async(flags: .barrier) {
                        self.accessOrder.removeAll()
                        self.resetCheckedRevKeys()
                        continuation.resume()
                    }
                } catch {
                    print("Error clearing disk cache: \(error)")
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Private Disk Cache Helpers

    /// Synchronously clears the disk cache and resets related tracking data.
    private func clearDiskCacheSync() {
        ioQueue.sync(flags: .barrier) {
            do {
                try fileManager.removeItem(at: diskCacheURL)
                try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true, attributes: nil)
                accessOrderQueue.sync(flags: .barrier) {
                    accessOrder.removeAll()
                }
                resetCheckedRevKeys()
            } catch {
                print("Error clearing disk cache: \(error)")
            }
        }
    }

    // MARK: - Private Utility Methods

    /// Clears the in-memory cache and resets revision tracking.
    private func clearMemoryCache() {
        memoryCache.removeAllObjects()
        accessOrderQueue.async(flags: .barrier) {
            self.accessOrder.removeAll()
        }
        resetCheckedRevKeys()
    }

    /// Generates a unique cache key for a given Dropbox file path using SHA256 hashing.
    ///
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: A hexadecimal string representing the hashed cache key.
    private func cacheKey(for filePath: String) -> String {
        let data = Data(filePath.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads an image and its revision from disk asynchronously.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: A `CachedImageEntry` if the file exists on disk; otherwise, `nil`.
    private func loadImageAndRevFromDisk(forKey key: String) async -> CachedImageEntry? {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let imageURL = self.diskCacheURL.appendingPathComponent(key)
                let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")

                guard
                    let imageData = try? Data(contentsOf: imageURL),
                    let image = self.decodeImage(data: imageData),
                    let revData = try? Data(contentsOf: revURL),
                    let rev = String(data: revData, encoding: .utf8)
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let cachedEntry = CachedImageEntry(image: image, rev: rev)
                // Update file access date to reflect recent use.
                self.updateFileAccessDate(for: imageURL)
                continuation.resume(returning: cachedEntry)
            }
        }
    }

    /// Downloads an image from Dropbox asynchronously.
    ///
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: A tuple containing the downloaded `UIImage` and its revision, or `nil` if download fails.
    private func downloadImage(from filePath: String) async -> (UIImage, String)? {
        guard let client = client else {
            print("Dropbox client not set.")
            return nil
        }
        do {
            let (metadata, fileData) = try await client.files.download(path: filePath).response()
            guard let image = decodeImage(data: fileData) else {
                return nil
            }
            let rev = metadata.rev
            return (image, rev)
        } catch {
            print("Error downloading image from Dropbox: \(error)")
            return nil
        }
    }

    /// Stores an image (and its revision) into both the memory and disk caches asynchronously.
    ///
    /// - Parameters:
    ///   - image: The `UIImage` to store.
    ///   - rev: The Dropbox revision identifier.
    ///   - key: The cache key.
    private func store(image: UIImage, rev: String, forKey key: String) async {
        // Store in memory.
        let cachedEntry = CachedImageEntry(image: image, rev: rev)
        memoryCache.setObject(cachedEntry, forKey: key as NSString, cost: imageCost(for: image))
        await updateAccessOrder(for: key)

        // Store on disk.
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                let imageURL = self.diskCacheURL.appendingPathComponent(key)
                let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")

                if let data = image.pngData(), let revData = rev.data(using: .utf8) {
                    do {
                        try data.write(to: imageURL, options: .atomic)
                        try revData.write(to: revURL, options: .atomic)
                        self.updateFileAccessDate(for: imageURL)
                        self.controlDiskCacheSize()
                    } catch {
                        print("Error writing image or rev to disk: \(error)")
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Fetches the current revision (`rev`) for a Dropbox file asynchronously.
    ///
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: The current revision string or `nil` if an error occurs.
    private func getCurrentRev(for filePath: String) async -> String? {
        guard let client = client else {
            print("Dropbox client not set.")
            return nil
        }
        do {
            let revisions = try await client.files.listRevisions(path: filePath).response().entries
            return revisions.first?.rev
        } catch {
            print("Error fetching metadata from Dropbox: \(error)")
            return nil
        }
    }

    /// Updates the file's last modification date to the current date.
    ///
    /// - Parameter fileURL: The URL of the file to update.
    private func updateFileAccessDate(for fileURL: URL) {
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        } catch {
            print("Error updating file access date: \(error)")
        }
    }

    /// Decodes raw image data into a `UIImage` and forces decompression off the main thread.
    ///
    /// - Parameter data: The raw image data.
    /// - Returns: A decoded `UIImage`, or `nil` if decoding fails.
    private func decodeImage(data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        // Force image decompression.
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        let decodedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return decodedImage
    }

    /// Calculates an approximate memory cost for a given image.
    ///
    /// - Parameter image: The `UIImage` for which to calculate cost.
    /// - Returns: An integer representing the estimated memory usage.
    private func imageCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Updates the LRU (least recently used) access order for the given cache key.
    ///
    /// - Parameter key: The cache key to update.
    private func updateAccessOrder(for key: String) async {
        await withCheckedContinuation { continuation in
            accessOrderQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                if let index = self.accessOrder.firstIndex(of: key) {
                    self.accessOrder.remove(at: index)
                }
                self.accessOrder.append(key)
                continuation.resume()
            }
        }
    }

    /// Checks and controls the disk cache size, evicting the least recently used files if necessary.
    private func controlDiskCacheSize() {
        ioQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentAccessDateKey, .totalFileAllocatedSizeKey]

            guard let fileURLs = try? self.fileManager.contentsOfDirectory(
                at: self.diskCacheURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: .skipsHiddenFiles
            ) else { return }

            var cachedFiles: [URL: [URLResourceKey: Any]] = [:]
            var currentCacheSize: UInt64 = 0

            for fileURL in fileURLs {
                // Exclude revision files from size calculations.
                if fileURL.pathExtension == "rev" { continue }

                guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                      resourceValues.isDirectory == false,
                      let fileSize = resourceValues.totalFileAllocatedSize,
                      let _ = resourceValues.contentAccessDate else { continue }

                cachedFiles[fileURL] = resourceValues.allValues
                currentCacheSize += UInt64(fileSize)
            }

            if currentCacheSize <= self.maxDiskCacheSize { return }

            // Sort files by last access date (oldest first).
            let sortedFiles = cachedFiles.keys.sorted {
                let date1 = cachedFiles[$0]?[.contentAccessDateKey] as? Date ?? .distantPast
                let date2 = cachedFiles[$1]?[.contentAccessDateKey] as? Date ?? .distantPast
                return date1 < date2
            }

            for fileURL in sortedFiles {
                do {
                    let attributes = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    if let fileSize = attributes.totalFileAllocatedSize {
                        try self.fileManager.removeItem(at: fileURL)
                        let revURL = self.diskCacheURL.appendingPathComponent("\(fileURL.lastPathComponent).rev")
                        try? self.fileManager.removeItem(at: revURL)
                        currentCacheSize -= UInt64(fileSize)
                    }
                } catch {
                    print("Error removing file during cache size control: \(error)")
                }
                if currentCacheSize <= self.maxDiskCacheSize { break }
            }
        }
    }

    // MARK: - Revision Check Tracking

    /// Asynchronously checks if the given cache key’s revision has already been verified this session.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: `true` if the revision has been checked; otherwise, `false`.
    private func hasCheckedRev(for key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            checkedRevKeysQueue.async {
                let result = self.checkedRevKeys.contains(key)
                continuation.resume(returning: result)
            }
        }
    }

    /// Marks a cache key’s revision as having been checked.
    ///
    /// - Parameter key: The cache key.
    private func markRevAsChecked(for key: String) async {
        await withCheckedContinuation { continuation in
            checkedRevKeysQueue.async(flags: .barrier) {
                self.checkedRevKeys.insert(key)
                continuation.resume()
            }
        }
    }

    /// Resets all revision check tracking.
    private func resetCheckedRevKeys() {
        checkedRevKeysQueue.async(flags: .barrier) {
            self.checkedRevKeys.removeAll()
        }
    }
}

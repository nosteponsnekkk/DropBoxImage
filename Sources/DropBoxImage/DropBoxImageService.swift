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

// MARK: - Revision Tracker Actor

/// An actor to safely track which cache keys have had their revision checked.
actor CheckedRevTracker {
    private var checkedRevKeys: Set<String> = []
    
    func hasCheckedRev(for key: String) -> Bool {
        checkedRevKeys.contains(key)
    }
    
    func markRevAsChecked(for key: String) {
        checkedRevKeys.insert(key)
    }
    
    func reset() {
        checkedRevKeys.removeAll()
    }
}

// MARK: - DropBoxImageService

/// A service that manages caching of images from Dropbox. It caches images both in memory and on disk,
/// verifies freshness via Dropbox’s `rev` property, and supports concurrent prefetching.
final class DropBoxImageService: ImageCacheClient {
    
    // MARK: - Private Properties
    
    /// Dropbox client instance (if authorized).
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    /// In-memory cache for images.
    private let memoryCache = NSCache<NSString, CachedImageEntry>()
    
    /// A concurrent dispatch queue for disk I/O operations.
    private let ioQueue: DispatchQueue
    
    /// FileManager instance for disk operations.
    private let fileManager: FileManager
    
    /// URL for the disk cache directory.
    private let diskCacheURL: URL
    
    /// Maximum allowed disk cache size (800 MB).
    private let maxDiskCacheSize: UInt64 = 800 * 1024 * 1024
    /// Maximum allowed cost for the memory cache (100 MB).
    private let maxMemoryCacheCost: Int = 100 * 1024 * 1024
    
    /// Actor for revision check tracking.
    private let revisionTracker = CheckedRevTracker()
    
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
    @objc private func handleMemoryWarning() {
        clearMemoryCache()
    }
    
    // MARK: - Public APIs
    
    /// Retrieves an image for the given Dropbox file path.
    public func image(at filePath: String?, checkRev: Bool = true) async -> UIImage? {
        guard let filePath = filePath else { return nil }
        let key = cacheKey(for: filePath)
        let nsKey = key as NSString
        
        // 1. Check in-memory cache.
        if let cachedEntry = memoryCache.object(forKey: nsKey) {
            if checkRev {
                let hasChecked = await revisionTracker.hasCheckedRev(for: key)
                if !hasChecked {
                    if let currentRev = await getCurrentRev(for: filePath) {
                        if currentRev != cachedEntry.rev {
                            if let (image, rev) = await downloadImage(from: filePath) {
                                await store(image: image, rev: rev, forKey: key)
                                await revisionTracker.markRevAsChecked(for: key)
                                return image
                            } else {
                                await revisionTracker.markRevAsChecked(for: key)
                                return cachedEntry.image
                            }
                        } else {
                            await revisionTracker.markRevAsChecked(for: key)
                            updateFileAccessDate(forKey: key)
                            return cachedEntry.image
                        }
                    } else {
                        await revisionTracker.markRevAsChecked(for: key)
                        updateFileAccessDate(forKey: key)
                        return cachedEntry.image
                    }
                } else {
                    updateFileAccessDate(forKey: key)
                    return cachedEntry.image
                }
            } else {
                updateFileAccessDate(forKey: key)
                return cachedEntry.image
            }
        }
        
        // 2. Check disk cache.
        if let cachedEntry = await loadImageAndRevFromDisk(forKey: key) {
            if checkRev {
                let hasChecked = await revisionTracker.hasCheckedRev(for: key)
                if !hasChecked {
                    if let currentRev = await getCurrentRev(for: filePath) {
                        if currentRev != cachedEntry.rev {
                            if let (image, rev) = await downloadImage(from: filePath) {
                                await store(image: image, rev: rev, forKey: key)
                                await revisionTracker.markRevAsChecked(for: key)
                                return image
                            } else {
                                await revisionTracker.markRevAsChecked(for: key)
                                return cachedEntry.image
                            }
                        } else {
                            await revisionTracker.markRevAsChecked(for: key)
                            memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                            updateFileAccessDate(forKey: key)
                            return cachedEntry.image
                        }
                    } else {
                        await revisionTracker.markRevAsChecked(for: key)
                        memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                        updateFileAccessDate(forKey: key)
                        return cachedEntry.image
                    }
                } else {
                    memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                    updateFileAccessDate(forKey: key)
                    return cachedEntry.image
                }
            } else {
                memoryCache.setObject(cachedEntry, forKey: nsKey, cost: imageCost(for: cachedEntry.image))
                updateFileAccessDate(forKey: key)
                return cachedEntry.image
            }
        }
        
        // 3. Download from Dropbox.
        if let (image, rev) = await downloadImage(from: filePath) {
            await store(image: image, rev: rev, forKey: key)
            if checkRev {
                await revisionTracker.markRevAsChecked(for: key)
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
    
    /// Prefetches images concurrently.
    public func prefetch(filePaths: [String], checkRev: Bool = true, withConcurrencyOf concurrency: Int) async {
        let semaphore = AsyncSemaphore(value: concurrency)
        await withTaskGroup(of: Void.self) { group in
            for filePath in filePaths {
                group.addTask {
                    await semaphore.wait()
                    _ = await self.image(at: filePath, checkRev: checkRev)
                    await semaphore.signal()
                }
            }
        }
    }
    
    /// Synchronously clears both the memory and disk caches.
    public func clearCache() {
        clearMemoryCache()
        clearDiskCacheSync()
    }
    
    /// Asynchronously clears both the memory and disk caches.
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
                    Task { await self.revisionTracker.reset() }
                    continuation.resume()
                } catch {
                    print("Error clearing disk cache: \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Private Disk Cache Helpers
    
    /// Synchronously clears the disk cache.
    private func clearDiskCacheSync() {
        ioQueue.sync(flags: .barrier) {
            do {
                try fileManager.removeItem(at: diskCacheURL)
                try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true, attributes: nil)
                Task { await revisionTracker.reset() }
            } catch {
                print("Error clearing disk cache: \(error)")
            }
        }
    }
    
    // MARK: - Private Utility Methods
    
    /// Clears the in-memory cache.
    private func clearMemoryCache() {
        memoryCache.removeAllObjects()
        Task { await revisionTracker.reset() }
    }
    
    /// Generates a unique cache key for a given Dropbox file path using SHA256 hashing.
    private func cacheKey(for filePath: String) -> String {
        let data = Data(filePath.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Loads an image and its revision from disk asynchronously.
    private func loadImageAndRevFromDisk(forKey key: String) async -> CachedImageEntry? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                autoreleasepool {
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
                    self.updateFileAccessDate(for: imageURL)
                    continuation.resume(returning: cachedEntry)
                }
            }
        }
    }
    
    /// Downloads an image from Dropbox asynchronously.
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
            // Downscale the image to reduce memory footprint.
            let downscaledImage = downscaleImage(image)
            let rev = metadata.rev
            return (downscaledImage, rev)
        } catch {
            print("Error downloading image from Dropbox: \(error)")
            return nil
        }
    }
    
    /// Stores an image (and its revision) into both the memory and disk caches asynchronously.
    private func store(image: UIImage, rev: String, forKey key: String) async {
        let cachedEntry = CachedImageEntry(image: image, rev: rev)
        memoryCache.setObject(cachedEntry, forKey: key as NSString, cost: imageCost(for: image))
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) {
                autoreleasepool {
                    let imageURL = self.diskCacheURL.appendingPathComponent(key)
                    let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")
                    
                    // Store as JPEG to reduce disk usage.
                    if let data = image.jpegData(compressionQuality: 0.8),
                       let revData = rev.data(using: .utf8) {
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
    }
    
    /// Fetches the current Dropbox revision for a file.
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
    
    /// Updates the file's last modification date.
    private func updateFileAccessDate(for fileURL: URL) {
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        } catch {
            print("Error updating file access date: \(error)")
        }
    }
    
    /// Convenience to update file access date using the cache key.
    private func updateFileAccessDate(forKey key: String) {
        let fileURL = diskCacheURL.appendingPathComponent(key)
        updateFileAccessDate(for: fileURL)
    }
    
    /// Decodes raw image data into a UIImage, forcing decompression off the main thread.
    private func decodeImage(data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        let decodedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return decodedImage
    }
    
    /// Downscales an image if its largest dimension exceeds maxDimension.
    private func downscaleImage(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let largerDimension = max(width, height)
        if largerDimension <= maxDimension {
            return image
        }
        let scale = maxDimension / largerDimension
        let newSize = CGSize(width: width * scale, height: height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let downscaledImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return downscaledImage
    }
    
    /// Calculates an approximate memory cost for a given image.
    private func imageCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
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
}

// MARK: - AsyncSemaphore

internal actor AsyncSemaphore {
    private var value: Int
    private var waitQueue: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.value = value
    }
    
    func wait() async {
        if value > 0 {
            value -= 1
        } else {
            await withCheckedContinuation { continuation in
                waitQueue.append(continuation)
            }
        }
    }
    
    func signal() {
        if !waitQueue.isEmpty {
            let continuation = waitQueue.removeFirst()
            continuation.resume()
        } else {
            value += 1
        }
    }
}

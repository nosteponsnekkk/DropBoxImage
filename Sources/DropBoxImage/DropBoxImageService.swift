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
// MARK: - ImageStorageFormat

/// Specifies how to store an image on disk.
public enum ImageStorageFormat {
    case jpeg(quality: CGFloat)
    case png
}

extension UIImage {
    /// Returns image data in the specified format.
    func data(using format: ImageStorageFormat) -> Data? {
        switch format {
        case .jpeg(let quality):
            return self.jpegData(compressionQuality: quality)
        case .png:
            return self.pngData()
        }
    }
}

// Global helper to compute an approximate memory cost for an image.
private func imageCost(for image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 1 }
    return cgImage.bytesPerRow * cgImage.height
}


// MARK: - CachedImageEntry

/// A simple container that holds an image and its Dropbox revision.
internal final class CachedImageEntry {
    let image: UIImage
    let rev: String

    init(image: UIImage, rev: String) {
        self.image = image
        self.rev = rev
    }
}

// MARK: - CheckedRevTracker Actor

/// Tracks which cache keys have been checked for revision.
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

// MARK: - LRU Memory Cache Actor

/// A strict LRU (least recently used) memory cache that guarantees its total cost never exceeds costLimit.
actor MemoryCacheLRU {
    private var cache: [String: CachedImageEntry] = [:]
    private var order: [String] = []
    private var totalCost: Int = 0
    let costLimit: Int

    init(costLimit: Int) {
        self.costLimit = costLimit
    }

    func get(for key: String) -> CachedImageEntry? {
        if let entry = cache[key] {
            // Move key to the most recently used position.
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            order.append(key)
            return entry
        }
        return nil
    }
    
    func set(entry: CachedImageEntry, for key: String, cost: Int) {
        // Remove any existing entry.
        if let _ = cache[key] {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            totalCost -= imageCost(for: entry.image)
        }
        cache[key] = entry
        order.append(key)
        totalCost += cost
        
        // Evict least recently used items until totalCost <= costLimit.
        while totalCost > costLimit, let oldestKey = order.first {
            if let evicted = cache.removeValue(forKey: oldestKey) {
                totalCost -= imageCost(for: evicted.image)
            }
            order.removeFirst()
        }
    }
    
    func removeAll() {
        cache.removeAll()
        order.removeAll()
        totalCost = 0
    }
}

// MARK: - DropBoxImageService

/// Manages caching of Dropbox images. It downloads images, caches them in a custom LRU memory cache (max 100 MB),
/// stores them on disk (using JPEG or PNG as specified), and verifies freshness using Dropbox revisions.
final class DropBoxImageService: ImageCacheClient {
    
    // MARK: - Private Properties
    
    /// Dropbox client instance (if authorized).
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    /// Custom in-memory cache (max 100 MB).
    private let memoryCache: MemoryCacheLRU = MemoryCacheLRU(costLimit: 100 * 1024 * 1024)
    
    /// A concurrent queue for disk I/O.
    private let ioQueue: DispatchQueue
    
    /// FileManager instance.
    private let fileManager: FileManager
    
    /// URL for the disk cache directory.
    private let diskCacheURL: URL
    
    /// Maximum allowed disk cache size (800 MB).
    private let maxDiskCacheSize: UInt64 = 800 * 1024 * 1024
    
    /// Actor for tracking Dropbox revision checks.
    private let revisionTracker = CheckedRevTracker()
    
    // MARK: - Initialization
    
    static let shared = DropBoxImageService()
    
    private init() {
        fileManager = FileManager.default
        
        // Create (or verify) the disk cache directory.
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
        
        // Listen for memory warnings.
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
    
    @objc private func handleMemoryWarning() {
        Task { await clearMemoryCache() }
    }
    
    // MARK: - Public APIs
    
    /// Retrieves an image for the given Dropbox file path.
    func image(at filePath: String?, checkRev: Bool = true, format: ImageStorageFormat = .jpeg(quality: 0.8)) async -> UIImage? {
        guard let filePath = filePath else { return nil }
        let key = cacheKey(for: filePath)
        
        // 1. Check memory cache.
        if let cachedEntry = await memoryCache.get(for: key) {
            if checkRev {
                if !(await revisionTracker.hasCheckedRev(for: key)) {
                    if let currentRev = await getCurrentRev(for: filePath),
                       currentRev != cachedEntry.rev {
                        if let (image, rev) = await downloadImage(from: filePath) {
                            await store(image: image, rev: rev, forKey: key, format: format)
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
                if !(await revisionTracker.hasCheckedRev(for: key)) {
                    if let currentRev = await getCurrentRev(for: filePath),
                       currentRev != cachedEntry.rev {
                        if let (image, rev) = await downloadImage(from: filePath) {
                            await store(image: image, rev: rev, forKey: key, format: format)
                            await revisionTracker.markRevAsChecked(for: key)
                            return image
                        } else {
                            await revisionTracker.markRevAsChecked(for: key)
                            return cachedEntry.image
                        }
                    } else {
                        await revisionTracker.markRevAsChecked(for: key)
                        await memoryCache.set(entry: cachedEntry, for: key, cost: imageCost(for: cachedEntry.image))
                        updateFileAccessDate(forKey: key)
                        return cachedEntry.image
                    }
                } else {
                    await memoryCache.set(entry: cachedEntry, for: key, cost: imageCost(for: cachedEntry.image))
                    updateFileAccessDate(forKey: key)
                    return cachedEntry.image
                }
            } else {
                await memoryCache.set(entry: cachedEntry, for: key, cost: imageCost(for: cachedEntry.image))
                updateFileAccessDate(forKey: key)
                return cachedEntry.image
            }
        }
        
        // 3. Download from Dropbox.
        if let (image, rev) = await downloadImage(from: filePath) {
            await store(image: image, rev: rev, forKey: key, format: format)
            if checkRev {
                await revisionTracker.markRevAsChecked(for: key)
            }
            return image
        }
        
        return nil
    }
    
    /// Prefetches images with the given Dropbox file paths, using the specified storage format.
    func prefetch(filePaths: [String], checkRev: Bool = true, format: ImageStorageFormat = .jpeg(quality: 0.8)) async {
        await withTaskGroup(of: Void.self) { group in
            for filePath in filePaths {
                group.addTask {
                    _ = await self.image(at: filePath, checkRev: checkRev, format: format)
                }
            }
        }
    }
    
    /// Prefetches images concurrently with a given concurrency level.
    func prefetch(filePaths: [String], checkRev: Bool = true, withConcurrencyOf concurrency: Int, format: ImageStorageFormat = .jpeg(quality: 0.8)) async {
        let semaphore = AsyncSemaphore(value: concurrency)
        await withTaskGroup(of: Void.self) { group in
            for filePath in filePaths {
                group.addTask {
                    await semaphore.wait()
                    _ = await self.image(at: filePath, checkRev: checkRev, format: format)
                    await semaphore.signal()
                }
            }
        }
    }
    
    /// Synchronously clears both the memory and disk caches.
    func clearCache() {
        Task { await clearMemoryCache() }
        clearDiskCache()
    }
    
    /// Asynchronously clears both the memory and disk caches.
    func clearCacheAsync() async {
        await clearMemoryCache()
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) {
                self.clearDiskCache()
                continuation.resume()
            }
        }
    }
    
    // MARK: - Private Disk Cache Helpers
    
    /// Clears the disk cache by enumerating and removing all files.
    private func clearDiskCache() {
        ioQueue.sync(flags: .barrier) {
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for fileURL in fileURLs {
                    try fileManager.removeItem(at: fileURL)
                }
                Task { await self.revisionTracker.reset() }
            } catch {
                print("Error clearing disk cache: \(error)")
            }
        }
    }
    
    // MARK: - Private Utility Methods
    
    /// Clears the in-memory cache.
    private func clearMemoryCache() async {
        await memoryCache.removeAll()
        await revisionTracker.reset()
    }
    
    /// Generates a unique cache key for a Dropbox file path.
    private func cacheKey(for filePath: String) -> String {
        let data = Data(filePath.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Loads an image and its revision from disk.
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
                    self.updateFileAccessDate(forKey: key)
                    continuation.resume(returning: cachedEntry)
                }
            }
        }
    }
    
    /// Downloads an image from Dropbox.
    private func downloadImage(from filePath: String) async -> (UIImage, String)? {
        guard let client = client else {
            print("Dropbox client not set.")
            return nil
        }
        do {
            let (metadata, fileData) = try await client.files.download(path: filePath).response()
            guard let image = decodeImage(data: fileData) else { return nil }
            // Downscale to reduce memory if needed.
            let downscaledImage = downscaleImage(image)
            let rev = metadata.rev
            return (downscaledImage, rev)
        } catch {
            print("Error downloading image from Dropbox: \(error)")
            return nil
        }
    }
    
    /// Stores an image and its revision into both memory and disk caches.
    private func store(image: UIImage, rev: String, forKey key: String, format: ImageStorageFormat) async {
        let cachedEntry = CachedImageEntry(image: image, rev: rev)
        await memoryCache.set(entry: cachedEntry, for: key, cost: imageCost(for: image))
        
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) {
                autoreleasepool {
                    let imageURL = self.diskCacheURL.appendingPathComponent(key)
                    let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")
                    
                    if let data = image.data(using: format),
                       let revData = rev.data(using: .utf8) {
                        do {
                            try data.write(to: imageURL, options: .atomic)
                            try revData.write(to: revURL, options: .atomic)
                            self.updateFileAccessDate(forKey: key)
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
    
    /// Retrieves the current Dropbox revision for a file.
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
    
    /// Updates the access date for a cached file.
    private func updateFileAccessDate(for fileURL: URL) {
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        } catch {
            print("Error updating file access date: \(error)")
        }
    }
    
    /// Convenience to update file access date using a cache key.
    private func updateFileAccessDate(forKey key: String) {
        let fileURL = diskCacheURL.appendingPathComponent(key)
        updateFileAccessDate(for: fileURL)
    }
    
    /// Decodes image data off the main thread.
    private func decodeImage(data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        let decoded = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return decoded
    }
    
    /// Downscales an image if its largest dimension exceeds maxDimension.
    private func downscaleImage(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let largerDimension = max(width, height)
        if largerDimension <= maxDimension { return image }
        let scale = maxDimension / largerDimension
        let newSize = CGSize(width: width * scale, height: height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let downscaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return downscaled
    }
    
    /// Controls the disk cache size, evicting the least recently used files if necessary.
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
                if fileURL.pathExtension == "rev" { continue }
                guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                      resourceValues.isDirectory == false,
                      let fileSize = resourceValues.totalFileAllocatedSize,
                      resourceValues.contentAccessDate != nil
                else { continue }
                cachedFiles[fileURL] = resourceValues.allValues
                currentCacheSize += UInt64(fileSize)
            }
            
            if currentCacheSize <= self.maxDiskCacheSize { return }
            
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

/// A simple semaphore for limiting concurrent tasks.
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

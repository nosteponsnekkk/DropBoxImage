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

/// A struct to hold cached image along with its revision.
fileprivate class CachedImageEntry {
    let image: UIImage
    let rev: String
    init(image: UIImage, rev: String) {
        self.image = image
        self.rev = rev
    }
}

// MARK: - DropBoxImageService

final class DropBoxImageService: ImageCacheClient {
    
    // MARK: - Private Properties
    
    private var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }
    
    private let memoryCache = NSCache<NSString, CachedImageEntry>()
    private let ioQueue: DispatchQueue
    private let fileManager: FileManager
    private let diskCacheURL: URL
    private let maxDiskCacheSize: UInt64 = 500 * 1024 * 1024 // 500 MB
    private let maxMemoryCacheCost: Int = 100 * 1024 * 1024 // 100 MB
    
    // To track access order for LRU
    private var accessOrder: [String] = []
    private let accessOrderQueue = DispatchQueue(label: "com.dropboximageservice.accessOrderQueue", attributes: .concurrent)
    
    /// Tracks which keys have had their `rev` checked in the current session.
    private var checkedRevKeys: Set<String> = []
    private let checkedRevKeysQueue = DispatchQueue(label: "com.dropboximageservice.checkedRevKeysQueue", attributes: .concurrent)
    
    // MARK: - Initialization
    
    public init() {
        memoryCache.totalCostLimit = maxMemoryCacheCost
        memoryCache.countLimit = 1000 // Adjust as needed
        
        fileManager = FileManager.default
        // Create disk cache directory
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
        
        // Subscribe to memory warnings to clear cache
        NotificationCenter.default.addObserver(self, selector: #selector(clearCache), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - ImageCacheClient Methods
    
    /// Fetches an image from cache or Dropbox asynchronously, ensuring it is up-to-date based on `rev` only on first access per session.
    /// - Parameter filePath: The Dropbox file path of the image.
    /// - Returns: The `UIImage` if available and up-to-date, else `nil`.
    public func image(at filePath: String) async -> UIImage? {
        let key = cacheKey(for: filePath)
        let nsKey = key as NSString
        
        // Step 1: Check in-memory cache
        if let cachedEntry = memoryCache.object(forKey: nsKey) {
            // Check if `rev` has already been validated in this session
            let hasCheckedRev = await hasCheckedRev(for: key)
            if !hasCheckedRev {
                // Perform rev check
                if let currentRev = await getCurrentRev(for: filePath) {
                    if currentRev != cachedEntry.rev {
                        // Rev has changed; download new image
                        if let (image, rev) = await downloadImage(from: filePath) {
                            await store(image: image, rev: rev, forKey: key)
                            await markRevAsChecked(for: key)
                            return image
                        } else {
                            // Download failed; return stale image
                            await markRevAsChecked(for: key)
                            return cachedEntry.image
                        }
                    } else {
                        // Rev is up-to-date
                        await markRevAsChecked(for: key)
                        await updateAccessOrder(for: key)
                        return cachedEntry.image
                    }
                } else {
                    // Unable to fetch current rev; assume cache is valid
                    await markRevAsChecked(for: key)
                    await updateAccessOrder(for: key)
                    return cachedEntry.image
                }
            } else {
                // `rev` already checked in this session; return cached image
                await updateAccessOrder(for: key)
                return cachedEntry.image
            }
        }
        
        // Step 2: Check disk cache
        if let cachedEntry = await loadImageAndRevFromDisk(forKey: key) {
            // Check if `rev` has already been validated in this session
            let hasCheckedRev = await hasCheckedRev(for: key)
            if !hasCheckedRev {
                // Perform rev check
                if let currentRev = await getCurrentRev(for: filePath) {
                    if currentRev != cachedEntry.rev {
                        // Rev has changed; download new image
                        if let (image, rev) = await downloadImage(from: filePath) {
                            await store(image: image, rev: rev, forKey: key)
                            await markRevAsChecked(for: key)
                            return image
                        } else {
                            // Download failed; return stale image
                            await markRevAsChecked(for: key)
                            return cachedEntry.image
                        }
                    } else {
                        // Rev is up-to-date
                        await markRevAsChecked(for: key)
                        // Store in memory cache
                        let cost = imageCost(for: cachedEntry.image)
                        memoryCache.setObject(cachedEntry, forKey: nsKey, cost: cost)
                        await updateAccessOrder(for: key)
                        return cachedEntry.image
                    }
                } else {
                    // Unable to fetch current rev; assume cache is valid
                    await markRevAsChecked(for: key)
                    // Store in memory cache
                    let cost = imageCost(for: cachedEntry.image)
                    memoryCache.setObject(cachedEntry, forKey: nsKey, cost: cost)
                    await updateAccessOrder(for: key)
                    return cachedEntry.image
                }
            } else {
                // `rev` already checked in this session; return cached image
                // Store in memory cache
                let cost = imageCost(for: cachedEntry.image)
                memoryCache.setObject(cachedEntry, forKey: nsKey, cost: cost)
                await updateAccessOrder(for: key)
                return cachedEntry.image
            }
        }
        
        // Step 3: Download image from Dropbox
        if let (image, rev) = await downloadImage(from: filePath) {
            await store(image: image, rev: rev, forKey: key)
            await markRevAsChecked(for: key)
            return image
        }
        
        return nil
    }
    
    /// Prefetches images by their Dropbox file paths.
    /// - Parameter filePaths: Array of Dropbox file paths.
    public func prefetch(filePaths: [String]) {
        Task {
            for filePath in filePaths {
                _ = await image(at: filePath)
            }
        }
    }
    
    /// Clears both memory and disk caches.
    /// - Returns: Void.
    @objc public func clearCache() async {
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
                        // Reset the checkedRevKeys as the cache has been cleared
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
    
    // MARK: - Private Methods
    
    /// Generates a unique cache key for a Dropbox file path using SHA256 hashing.
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: A unique string key.
    private func cacheKey(for filePath: String) -> String {
        let data = Data(filePath.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Loads an image and its rev from disk for the given key asynchronously.
    /// - Parameter key: The cache key.
    /// - Returns: `CachedImageEntry` if found, else `nil`.
    private func loadImageAndRevFromDisk(forKey key: String) async -> CachedImageEntry? {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let imageURL = self.diskCacheURL.appendingPathComponent(key)
                let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")
                
                guard let imageData = try? Data(contentsOf: imageURL),
                      let image = self.decodeImage(data: imageData),
                      let revData = try? Data(contentsOf: revURL),
                      let rev = String(data: revData, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let cachedEntry = CachedImageEntry(image: image, rev: rev)
                
                // Update access date
                self.updateFileAccessDate(for: imageURL)
                
                continuation.resume(returning: cachedEntry)
            }
        }
    }
    
    /// Downloads an image from Dropbox for the given file path asynchronously.
    /// - Parameters:
    ///   - filePath: The Dropbox file path of the image.
    /// - Returns: A tuple containing the downloaded `UIImage` and its `rev`, or `nil` if failed.
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
    
    /// Stores an image and its rev in both memory and disk caches asynchronously.
    /// - Parameters:
    ///   - image: The `UIImage` to store.
    ///   - rev: The revision string of the image.
    ///   - key: The cache key.
    private func store(image: UIImage, rev: String, forKey key: String) async {
        // Store in memory
        let cachedEntry = CachedImageEntry(image: image, rev: rev)
        let cost = imageCost(for: image)
        memoryCache.setObject(cachedEntry, forKey: key as NSString, cost: cost)
        await updateAccessOrder(for: key)
        
        // Store on disk asynchronously
        await withCheckedContinuation { continuation in
            ioQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                let imageURL = self.diskCacheURL.appendingPathComponent(key)
                let revURL = self.diskCacheURL.appendingPathComponent("\(key).rev")
                
                if let data = image.pngData(),
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
    
    /// Fetches the current rev of a file from Dropbox.
    /// - Parameter filePath: The Dropbox file path.
    /// - Returns: The current rev string or `nil` if failed.
    private func getCurrentRev(for filePath: String) async -> String? {
        guard let client = client else {
            print("Dropbox client not set.")
            return nil
        }
        
        do {
            let rev = try await client.files.listRevisions(path: filePath).response().entries.first?.rev
            return rev
        } catch {
            print("Error fetching metadata from Dropbox: \(error)")
            return nil
        }
    }
    
    /// Updates the file's access date to the current date.
    /// - Parameter fileURL: The URL of the file.
    private func updateFileAccessDate(for fileURL: URL) {
        do {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        } catch {
            print("Error updating file access date: \(error)")
        }
    }
    
    /// Decodes image data into a `UIImage`, optimized off the main thread.
    /// - Parameter data: The image data.
    /// - Returns: Decoded `UIImage` or `nil`.
    private func decodeImage(data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        // Force decoding
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(at: .zero)
        let decodedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return decodedImage
    }
    
    /// Calculates the cost of an image for caching purposes.
    /// - Parameter image: The `UIImage`.
    /// - Returns: Cost as `Int`.
    private func imageCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
    
    /// Updates the access order for LRU eviction asynchronously.
    /// - Parameter key: The cache key.
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
                // Optional: Trigger eviction if needed
                continuation.resume()
            }
        }
    }
    
    /// Controls the disk cache size by evicting least recently used items asynchronously.
    private func controlDiskCacheSize() {
        ioQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentAccessDateKey, .totalFileAllocatedSizeKey]
            guard let fileURLs = try? self.fileManager.contentsOfDirectory(at: self.diskCacheURL, includingPropertiesForKeys: Array(resourceKeys), options: .skipsHiddenFiles) else { return }
            
            var cachedFiles: [URL: [URLResourceKey: Any]] = [:]
            var currentCacheSize: UInt64 = 0
            
            for fileURL in fileURLs {
                // Skip rev files
                if fileURL.pathExtension == "rev" {
                    continue
                }
                guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                      resourceValues.isDirectory == false,
                      let fileSize = resourceValues.totalFileAllocatedSize,
                      let _ = resourceValues.contentAccessDate else { continue }
                cachedFiles[fileURL] = resourceValues.allValues
                currentCacheSize += UInt64(fileSize)
            }
            
            if currentCacheSize <= self.maxDiskCacheSize { return }
            
            // Sort files by last access date (oldest first)
            let sortedFiles = cachedFiles.keys.sorted {
                let date1 = cachedFiles[$0]?[.contentAccessDateKey] as? Date ?? Date.distantPast
                let date2 = cachedFiles[$1]?[.contentAccessDateKey] as? Date ?? Date.distantPast
                return date1 < date2
            }
            
            // Remove files until cache size is under limit
            for fileURL in sortedFiles {
                do {
                    let attributes = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    if let fileSize = attributes.totalFileAllocatedSize {
                        // Remove image file
                        try self.fileManager.removeItem(at: fileURL)
                        // Remove corresponding rev file
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
    
    /// Clears the in-memory cache.
    @objc private func clearMemoryCache() {
        memoryCache.removeAllObjects()
        accessOrderQueue.async(flags: .barrier) {
            self.accessOrder.removeAll()
        }
        // Reset the checkedRevKeys as the memory cache has been cleared
        resetCheckedRevKeys()
    }
    
    /// Checks if the `rev` for a given key has already been validated in the current session.
    /// - Parameter key: The cache key.
    /// - Returns: `true` if checked, else `false`.
    private func hasCheckedRev(for key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            checkedRevKeysQueue.async {
                let result = self.checkedRevKeys.contains(key)
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Marks the `rev` for a given key as checked in the current session.
    /// - Parameter key: The cache key.
    private func markRevAsChecked(for key: String) async {
        await withCheckedContinuation { continuation in
            checkedRevKeysQueue.async(flags: .barrier) {
                self.checkedRevKeys.insert(key)
                continuation.resume()
            }
        }
    }
    
    /// Resets the `checkedRevKeys` set, typically called when the cache is cleared.
    private func resetCheckedRevKeys() {
        checkedRevKeysQueue.async(flags: .barrier) {
            self.checkedRevKeys.removeAll()
        }
    }
}

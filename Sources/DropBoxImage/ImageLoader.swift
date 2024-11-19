//
//  File.swift
//  
//
//  Created by Oleg on 19.11.2024.
//

import SwiftUI
import Combine
import Dependencies

// ObservableObject to manage image loading
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading: Bool = false
    @Published var hasFailed: Bool = false
    
    private var imagePath: String?
    private var loadTask: Task<Void, Never>? = nil
    @Dependency(\.imageCacheClient) var imageCacher
    
    init(imagePath: String?) {
        self.imagePath = imagePath
        loadImage()
    }
    
    // Method to update the imagePath and reload the image
    func updateImagePath(_ newPath: String?) {
        guard newPath != imagePath else { return }
        imagePath = newPath
        loadImage()
    }
    
    // Method to load the image asynchronously
    private func loadImage() {
        // Cancel any existing loading task
        loadTask?.cancel()
        
        // Reset states
        self.image = nil
        self.hasFailed = false
        
        guard let path = imagePath else {
            self.isLoading = false
            self.hasFailed = true
            return
        }
        
        self.isLoading = true
        
        // Start a new task to load the image
        loadTask = Task {
            defer { 
                DispatchQueue.main.async { [weak self] in
                    self?.isLoading = false
                }
            }
            
            if Task.isCancelled { return }
            
            // Attempt to fetch the image from the cache
            if let fetchedImage = await imageCacher.image(at: path) {
                if Task.isCancelled { return }
                // Update the image on the main thread
                await MainActor.run {
                    self.image = fetchedImage
                }
            } else {
                // Handle failure to fetch the image
                await MainActor.run {
                    self.hasFailed = true
                }
            }
        }
    }
    
    // Cancel the loading task if needed
    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }
}

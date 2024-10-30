//
//  DropBoxImage.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import SwiftUI
import Dependencies

struct DropBoxImage<Placeholder: View>: View {
    
    // Inject the ImageCacheClient using Dependencies
    @Dependency(\.imageCacheClient) private var imageCacher
    
    let imagePath: String
    let placeholder: Placeholder
    
    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = false
    
    // Task to manage image loading
    @State private var loadTask: Task<Void, Never>? = nil
    
    init(imagePath: String,
         @ViewBuilder placeholder: () -> Placeholder){
        self.placeholder = placeholder()
        self.imagePath = imagePath
    }
    
    var body: some View {
        content
            .onAppear {
                loadImage()
            }
            .onDisappear {
                cancelLoading()
            }
    }
    
    @ViewBuilder
    private var content: some View {
        if let uiImage = image {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if isLoading {
            //TODO: Loading placeholder
            placeholder
        } else {
            //TODO: Failed placeholder
            placeholder
        }
    }
    
    private func loadImage() {
        guard !isLoading && image == nil else { return }
        isLoading = true
        
        // Start a Task to handle async image loading
        loadTask = Task {
            // Handle potential cancellation
            defer { isLoading = false }
            
            if Task.isCancelled {
                return
            }
            
            // Await the asynchronous image retrieval
            if let fetchedImage = await imageCacher.image(at: imagePath) {
                if Task.isCancelled {
                    return
                }
                // Update the UI on the main thread
                await MainActor.run {
                    self.image = fetchedImage
                }
            } else {
                // Handle the case where the image could not be fetched
                await MainActor.run {
                    self.image = nil
                }
            }
        }
    }
    
    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }
}

#Preview {
    DropBoxImage(imagePath: "/images/sampleImage.png") {
        Color.gray
    }
}

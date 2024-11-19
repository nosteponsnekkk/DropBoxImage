//
//  DropBoxImage.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import SwiftUI
import Dependencies

public struct DropBoxImage<Placeholder: View>: View {
    
    @Dependency(\.imageCacheClient) private var imageCacher
    
    let imagePath: String?
    let placeholder: Placeholder
    
    @State private var image: UIImage? = nil
    @State private var isLoading: Bool = false
    
    // Task to manage image loading
    @State private var loadTask: Task<Void, Never>? = nil
    
    public init(imagePath: String?,
                @ViewBuilder placeholder: () -> Placeholder){
        self.placeholder = placeholder()
        self.imagePath = imagePath
    }
    
    public var body: some View {
        content
            .onAppear {
                loadImage()
            }
            .onDisappear {
                cancelLoading()
            }
            .onChange(of: imagePath) { newPath in
                cancelLoading()
                
                image = nil
                isLoading = false
                
                loadImage()
            }
    }
    
    @ViewBuilder
    private var content: some View {
        if let uiImage = image {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if isLoading {
            placeholder
        } else {
            placeholder
        }
    }
    
    private func loadImage() {
        guard !isLoading && image == nil else { return }
        isLoading = true
        
        loadTask = Task {
            defer { isLoading = false }
            
            if Task.isCancelled {
                return
            }
            
            if let fetchedImage = await imageCacher.image(at: imagePath) {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    self.image = fetchedImage
                }
            } else {
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

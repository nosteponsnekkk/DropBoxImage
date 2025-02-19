//
//  DropBoxImage.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import SwiftUI
import Dependencies

public struct DropBoxImage<Placeholder: View>: View {
    
    let imagePath: String?
    let renderingMode: Image.TemplateRenderingMode
    let placeholder: Placeholder
    let onImageSet: ((Bool) -> Void)? // Optional closure property
    
    // Use StateObject to manage the ImageLoader's lifecycle
    @StateObject private var loader: ImageLoader
    
    public init(imagePath: String?,
                renderingMode: Image.TemplateRenderingMode = .original,
                onImageSet: ((Bool) -> Void)? = nil,  // New optional parameter
                @ViewBuilder placeholder: () -> Placeholder) {
        self.imagePath = imagePath
        self.placeholder = placeholder()
        self.renderingMode = renderingMode
        self.onImageSet = onImageSet
        // Initialize the loader with the initial imagePath
        _loader = StateObject(
            wrappedValue: ImageLoader(
                imagePath: imagePath
            )
        )
    }
    
    public var body: some View {
        content
            .onAppear {
                // No additional action needed on appear
            }
            .onDisappear {
                loader.cancelLoading()
            }
            .onChange(of: imagePath) { newPath in
                loader.updateImagePath(newPath)
            }
            .onChange(of: loader.image) { newImage in
                // Fires the closure with true if an image is set, false otherwise
                onImageSet?(newImage != nil)
            }
    }
    
    @ViewBuilder
    private var content: some View {
        if let uiImage = loader.image {
            Image(uiImage: uiImage)
                .renderingMode(renderingMode)
                .resizable()
                .scaledToFill()
        } else if loader.isLoading {
            placeholder
        } else if loader.hasFailed {
            placeholder
        } else {
            placeholder
        }
    }
}

#Preview {
    DropBoxImage(imagePath: "/images/sampleImage.png", onImageSet: { isSet in
        print("Image is set: \(isSet)")
    }) {
        Color.gray
    }
}

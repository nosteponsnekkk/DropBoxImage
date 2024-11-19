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
    let placeholder: Placeholder
    
    // Use StateObject to manage the ImageLoader's lifecycle
    @StateObject private var loader: ImageLoader
    
    public init(imagePath: String?,
                @ViewBuilder placeholder: () -> Placeholder){
        self.imagePath = imagePath
        self.placeholder = placeholder()
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
    }
    
    @ViewBuilder
    private var content: some View {
        if let uiImage = loader.image {
            Image(uiImage: uiImage)
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
    DropBoxImage(imagePath: "/images/sampleImage.png") {
        Color.gray
    }
}

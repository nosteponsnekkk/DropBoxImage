//
//  DropBoxImage.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import SwiftUI
import Dependencies

// MARK: - DropBoxImage SwiftUI View

/// A SwiftUI view that displays an image fetched from Dropbox via the cache service.
public struct DropBoxImage<Placeholder: View>: View {
    
    let imagePath: String?
    let renderingMode: Image.TemplateRenderingMode
    let placeholder: Placeholder
    let onImageSet: ((Bool) -> Void)?
    let checkRevision: Bool
    let format: ImageStorageFormat
    @StateObject private var loader: ImageLoader
    
    public init(imagePath: String?,
                renderingMode: Image.TemplateRenderingMode = .original,
                checkRevision: Bool = true,
                format: ImageStorageFormat = .jpeg(quality: 0.8),
                onImageSet: ((Bool) -> Void)? = nil,
                onImageDataLoaded: ((Data) -> Void)? = nil,
                @ViewBuilder placeholder: () -> Placeholder) {
        self.imagePath = imagePath
        self.renderingMode = renderingMode
        self.checkRevision = checkRevision
        self.placeholder = placeholder()
        self.onImageSet = onImageSet
        self.format = format
        _loader = StateObject(
            wrappedValue: ImageLoader(
                imagePath: imagePath,
                checkRevision: checkRevision,
                format: format, 
                onImageDataLoaded: onImageDataLoaded
            )
        )
    }
    
    public var body: some View {
        content
            .onDisappear {
                loader.cancelLoading()
            }
            .onChange(of: imagePath) { newPath in
                loader.updateImagePath(newPath, format: format)
            }
            .onChange(of: loader.image) { newImage in
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
        } else {
            placeholder
        }
    }
}

// MARK: - SwiftUI Preview

struct DropBoxImage_Previews: PreviewProvider {
    static var previews: some View {
        DropBoxImage(imagePath: "/images/sampleImage.png",
                     checkRevision: false,
                     onImageSet: { isSet in
            print("Image is set: \(isSet)")
        }) {
            Color.gray
        }
    }
}

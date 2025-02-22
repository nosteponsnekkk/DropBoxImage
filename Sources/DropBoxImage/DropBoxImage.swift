//
//  DropBoxImage.swift
//  DropBoxImage
//
//  Created by Oleg on 30.10.2024.
//

import SwiftUI
import Dependencies

/// A SwiftUI view that displays an image fetched from Dropbox via a cache service.
/// It shows a placeholder while loading and notifies when the image is set.
/// Revision checking can be disabled on a per‑view basis.
public struct DropBoxImage<Placeholder: View>: View {
    
    /// The Dropbox file path for the image.
    let imagePath: String?
    
    /// The image rendering mode.
    let renderingMode: Image.TemplateRenderingMode
    
    /// A view to display while the image is loading or if loading fails.
    let placeholder: Placeholder
    
    /// An optional closure that is fired when the image is updated.
    let onImageSet: ((Bool) -> Void)?
    
    /// If `true` (the default), the view will verify the Dropbox image revision.
    /// Set to `false` to disable revision checking.
    let checkRevision: Bool
    
    /// The image loader responsible for fetching the image.
    @StateObject private var loader: ImageLoader
    
    /// Initializes a new DropBoxImage view.
    /// - Parameters:
    ///   - imagePath: The Dropbox file path for the image.
    ///   - renderingMode: The rendering mode for the image (default is `.original`).
    ///   - checkRevision: When `true`, the loader will verify the image revision with Dropbox.
    ///                    Set to `false` to bypass the revision check.
    ///   - onImageSet: An optional closure called when the image is updated.
    ///   - placeholder: A view builder that provides a placeholder view.
    public init(imagePath: String?,
                renderingMode: Image.TemplateRenderingMode = .original,
                checkRevision: Bool = true,
                onImageSet: ((Bool) -> Void)? = nil,
                onImageDataLoaded: ((Data) -> Void)? = nil,
                @ViewBuilder placeholder: () -> Placeholder) {
        self.imagePath = imagePath
        self.renderingMode = renderingMode
        self.checkRevision = checkRevision
        self.placeholder = placeholder()
        self.onImageSet = onImageSet
        _loader = StateObject(
            wrappedValue: ImageLoader(
                imagePath: imagePath,
                checkRevision: checkRevision,
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
                loader.updateImagePath(newPath)
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

#Preview {
    DropBoxImage(imagePath: "/images/sampleImage.png",
                 checkRevision: false, // Disable revision checking for this view
                 onImageSet: { isSet in
        print("Image is set: \(isSet)")
    }) {
        Color.gray
    }
}

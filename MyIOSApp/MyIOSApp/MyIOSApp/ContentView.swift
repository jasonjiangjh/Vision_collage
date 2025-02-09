//
//  ContentView.swift
//  MyIOSApp
//
//  Created by Developer on 2023/10/10.
//
//  Description: Demonstrates a smoother version of multi-image selection
//  with caching and background tasks to avoid blocking the main thread.
//  After generating a collage, the user can choose whether to save it to
//  the photo library.
//
//  Changes in this version:
//   - The generated collage is now sized to a 9:16 ratio for iPhone wallpapers (default 1080x1920).
//   - The collage logic is no longer a rigid 3x3 (nine-grid). Instead, it arranges images
//     vertically in equal segments, each filling the full width but sharing the total height.
//
//  As a result, the resulting image is more suitable as a vertical (portrait) wallpaper.

import SwiftUI

#if canImport(UIKit)
import UIKit
import PhotosUI
#endif

// MARK: - Model

/// Information about an image fetched from the server.
struct ImageInfo: Codable, Identifiable, Equatable {
    let id: String
    let download_url: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case download_url
    }
}

// MARK: - ImageLoader

/// Handles data loading, caching, and multi-batch selection status to improve UX.
/// Accumulates images across multiple fetches, preserving old selections.
final class ImageLoader: ObservableObject {
    
    // MARK: Public Properties
    
    /// A list of fetched image metadata from all loads (accumulating).
    @Published private(set) var imagesInfo: [ImageInfo] = []
    
    #if canImport(UIKit)
    /// A set of selected image IDs; only IDs are tracked.
    @Published private(set) var selectedIDs: Set<String> = []
    
    /// The collaged image generated after user selects images.
    @Published var collageUIImage: UIImage?
    #endif
    
    // MARK: Private Properties
    
    private let pageSize = 9      // number of images per batch
    private var currentPage = 1
    private let maxSelectable = 10
    
    /// Cache of downloaded images: [ImageInfo.id : UIImage]
    private var imageCache: [String: UIImage] = [:]
    private let cacheLock = NSLock()
    
    /// Ongoing download tasks to avoid duplication: [ImageInfo.id : Task<UIImage?, Never>]
    private var downloadTasks: [String: Task<UIImage?, Never>] = [:]
    private let taskLock = NSLock()
    
    // MARK: - Public Methods
    
    /// Loads a new random batch of images and appends them to the existing list.
    /// Previously fetched images remain so the user can still see and select them.
    func loadNewBatch() async {
        // Clear only the old collage preview, keep images and selections
        await MainActor.run {
            #if canImport(UIKit)
            self.collageUIImage = nil
            #endif
        }
        
        // Randomize the page index
        currentPage = Int(Date().timeIntervalSince1970) % 100
        
        // Fetch new batch
        let fetched = await fetchImagesInfo(page: currentPage, limit: pageSize)
        
        // Append results to the existing array
        await MainActor.run {
            self.imagesInfo.append(contentsOf: fetched)
        }
    }
    
    /// Loads more pages sequentially, preserving old images and selections.
    func loadMore() async {
        currentPage += 1
        let fetched = await fetchImagesInfo(page: currentPage, limit: pageSize)
        await MainActor.run {
            self.imagesInfo.append(contentsOf: fetched)
        }
    }
    
    #if canImport(UIKit)
    /// Toggle selection of an image by ID.
    func toggleSelection(for imageID: String) {
        if selectedIDs.contains(imageID) {
            selectedIDs.remove(imageID)
        } else {
            guard selectedIDs.count < maxSelectable else {
                print("You can select up to \(maxSelectable) images.")
                return
            }
            selectedIDs.insert(imageID)
        }
    }
    
    /// Returns the corresponding UIImage for a given ImageInfo (checks cache or downloads if needed).
    func uiImage(for info: ImageInfo) async -> UIImage? {
        // Check the cache first
        cacheLock.lock()
        if let cached = imageCache[info.id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        // If there's an existing download task, wait for it
        taskLock.lock()
        if let existingTask = downloadTasks[info.id] {
            taskLock.unlock()
            return await existingTask.value
        } else {
            // Otherwise, create a new background task for downloading
            let t = Task.detached(priority: .medium) { [weak self] () -> UIImage? in
                guard let self = self else { return nil }
                return await self.downloadImage(info: info)
            }
            downloadTasks[info.id] = t
            taskLock.unlock()
            
            let result = await t.value
            
            // Remove from the dictionary after completion
            taskLock.lock()
            self.downloadTasks.removeValue(forKey: info.id)
            taskLock.unlock()
            
            return result
        }
    }
    
    /// Perform an actual download in a background task.
    private func downloadImage(info: ImageInfo) async -> UIImage? {
        guard let url = URL(string: info.download_url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                cacheLock.lock()
                self.imageCache[info.id] = img
                cacheLock.unlock()
                return img
            }
        } catch {
            print("Image download error: \(error.localizedDescription)")
        }
        return nil
    }
    
    /// Generates a collage image in 9:16 ratio (e.g. 1080x1920),
    /// stacking selected images vertically in equal-height segments.
    func generateCollage() async {
        // Clear old result
        await MainActor.run {
            self.collageUIImage = nil
        }
        
        let currentIDs = selectedIDs
        if currentIDs.isEmpty {
            print("No images selected.")
            return
        }
        
        // Retrieve all selected images from the cache
        let selectedImages: [UIImage] = currentIDs.compactMap { id in
            cacheLock.lock()
            let cached = self.imageCache[id]
            cacheLock.unlock()
            return cached
        }
        
        if selectedImages.isEmpty {
            print("No cached images for your selection.")
            return
        }
        
        // Perform background creation of the wallpaper collage
        let collage = await Task.detached(priority: .medium) { () -> UIImage? in
            return Self.createWallpaperCollage(images: selectedImages)
        }.value
        
        // Update UI on main thread
        await MainActor.run {
            self.collageUIImage = collage
        }
    }
    
    /// Saves the collaged image to the user's photo album (iOS only).
    func saveCollageToAlbum() async {
        guard let collage = self.collageUIImage else {
            print("No collage to save.")
            return
        }
        
        // Check or request photo library authorization
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            // Already authorized, proceed
            break
        case .notDetermined:
            // Request new permission
            if #available(iOS 14, *) {
                _ = try? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            } else {
                await withCheckedContinuation { continuation in
                    PHPhotoLibrary.requestAuthorization { _ in
                        continuation.resume(returning: ())
                    }
                }
            }
        case .denied, .restricted:
            print("Photo library permission denied or restricted.")
            return
        @unknown default:
            return
        }
        
        // Save
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: collage)
            }
            print("Collage saved to photo album.")
        } catch {
            print("Saving collage failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: Helpers

    private static let wallpaperSize = CGSize(width: 1080, height: 1920)
    
    /// Creates a 9:16 ratio canvas (1080x1920) and arranges all images
    /// as vertical strips with equal heights.
    ///
    /// Each image is scaled with aspect fill to occupy its segment fully (width=1080, segment height=1920/N).
    private static func createWallpaperCollage(images: [UIImage]) -> UIImage? {
        // Set up a canvas at 1080 x 1920
        let targetSize = wallpaperSize
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }
        
        let count = CGFloat(images.count)
        let segmentHeight = targetSize.height / count
        
        for (index, img) in images.enumerated() {
            let yPos = segmentHeight * CGFloat(index)
            let subRect = CGRect(x: 0, y: yPos, width: targetSize.width, height: segmentHeight)
            
            // Determine how to aspect-fill each sub-rect
            let scaledRect = scaleToFill(sourceSize: img.size, destRect: subRect)
            
            // Draw the image
            if let cgImg = img.cgImage {
                context.saveGState()
                context.addRect(subRect)
                context.clip()
                context.draw(cgImg, in: scaledRect)
                context.restoreGState()
            }
        }
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        return newImage
    }
    
    /// Returns a CGRect in which the source image will fill the destination rect while preserving aspect.
    /// The image may overflow outside horizontally or vertically but will fill the entire destRect.
    private static func scaleToFill(sourceSize: CGSize, destRect: CGRect) -> CGRect {
        let scaleW = destRect.width / sourceSize.width
        let scaleH = destRect.height / sourceSize.height
        let scale = max(scaleW, scaleH) // Fill means we use the bigger scale
        
        let newWidth = sourceSize.width * scale
        let newHeight = sourceSize.height * scale
        
        // Center align
        let x = destRect.midX - (newWidth / 2.0)
        let y = destRect.midY - (newHeight / 2.0)
        
        return CGRect(x: x, y: y, width: newWidth, height: newHeight)
    }
    #endif
    
    // MARK: - Networking
    
    /// Fetch a list of images info from Picsum (or any API).
    /// This is a simple example using an asynchronous URLSession.
    private func fetchImagesInfo(page: Int, limit: Int) async -> [ImageInfo] {
        let urlString = "https://picsum.photos/v2/list?page=\(page)&limit=\(limit)&order_by=random"
        guard let url = URL(string: urlString) else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let fetched = try JSONDecoder().decode([ImageInfo].self, from: data)
            return fetched
        } catch {
            print("Failed to fetch images info:", error.localizedDescription)
            return []
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var loader = ImageLoader()
    @State private var showCollagePreview = false
    
    #if os(iOS)
    // Grid layout: e.g., 3 columns
    let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 8)
    ]
    #else
    // For macOS or other platforms, adjust appropriately
    let columns = [
        GridItem(.flexible(minimum: 100), spacing: 8),
        GridItem(.flexible(minimum: 100), spacing: 8),
        GridItem(.flexible(minimum: 100), spacing: 8)
    ]
    #endif
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(colors: [.pink.opacity(0.2), .cyan.opacity(0.3)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                .ignoresSafeArea()
                
                VStack {
                    // Grid of images
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(loader.imagesInfo) { info in
                                ZStack {
                                    // Custom async thumbnail
                                    AsyncThumbnail(info: info, loader: loader)
                                        .frame(width: 100, height: 100)
                                        .cornerRadius(12)
                                        .shadow(color: .black.opacity(0.1), radius: 2, x: 2, y: 2)
                                    
                                    #if canImport(UIKit)
                                    if loader.selectedIDs.contains(info.id) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.green, lineWidth: 3)
                                    }
                                    #endif
                                }
                                .onTapGesture {
                                    #if canImport(UIKit)
                                    loader.toggleSelection(for: info.id)
                                    #endif
                                }
                            }
                        }
                        .padding()
                    }
                    
                    #if canImport(UIKit)
                    // Control buttons for iOS
                    HStack {
                        Button(action: {
                            Task {
                                await loader.loadNewBatch()
                            }
                        }) {
                            Text("Load New Batch")
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            Task {
                                await loader.generateCollage()
                                if loader.collageUIImage != nil {
                                    showCollagePreview = true
                                }
                            }
                        }) {
                            Text("Generate Collage")
                                .foregroundColor(.white)
                                .padding()
                                // Ensure both branches are the same type, e.g. Color
                                .background(loader.selectedIDs.isEmpty ? Color.gray : Color.green)
                                .cornerRadius(8)
                        }
                        .disabled(loader.selectedIDs.isEmpty)
                    }
                    .padding(.horizontal)
                    #else
                    // For non-UIKit platforms
                    Button("Load New Batch") {
                        Task {
                            await loader.loadNewBatch()
                        }
                    }
                    .padding()
                    #endif
                }
            }
            .navigationTitle("Wallpapers Demo")
            .sheet(isPresented: $showCollagePreview) {
                #if canImport(UIKit)
                CollagePreviewView(loader: loader, isPresented: $showCollagePreview)
                #else
                Text("Preview not supported here.")
                #endif
            }
        }
        .onAppear {
            Task {
                await loader.loadNewBatch()
            }
        }
    }
}

#if canImport(UIKit)
// MARK: - Collage Preview (iOS only)

@MainActor
struct CollagePreviewView: View {
    @ObservedObject var loader: ImageLoader
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [.orange, .purple]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 16) {
                Spacer()
                if let collage = loader.collageUIImage {
                    Image(uiImage: collage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 400)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 2, y: 2)
                    
                    Text("Generated Collage (9:16)")
                        .font(.headline)
                        .foregroundColor(.white)
                } else {
                    Text("No collage generated.")
                        .foregroundColor(.white)
                }
                Spacer()
                
                // Save to album
                Button(action: {
                    Task {
                        await loader.saveCollageToAlbum()
                    }
                }) {
                    Text("Save to Photo Album")
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                
                // Close
                Button(action: {
                    loader.collageUIImage = nil
                    isPresented = false
                }) {
                    Text("Close")
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }
}
#endif

// MARK: - AsyncThumbnail

/// An async thumbnail component that retrieves or caches images
/// without blocking the main thread, providing a smooth UI experience.
struct AsyncThumbnail: View {
    let info: ImageInfo
    @ObservedObject var loader: ImageLoader
    
    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let uiImg = thumbnail {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .transition(.opacity.animation(.easeInOut))
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                    .transition(.opacity.animation(.easeInOut))
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .onAppear {
            Task {
                guard thumbnail == nil else { return }
                isLoading = true
                #if canImport(UIKit)
                if let fetched = await loader.uiImage(for: info) {
                    await MainActor.run {
                        thumbnail = fetched
                    }
                }
                #endif
                isLoading = false
            }
        }
    }
}
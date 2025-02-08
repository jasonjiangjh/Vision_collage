//
//  ContentView.swift
//  MyIOSApp
//
//
//  Description: Demonstrates a smoother version of multi-image selection with caching
//  and background tasks to avoid blocking the main thread. 
//  After generating a collage, the user can choose to save it to the photo library.

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

/// Handles data loading, caching, and selection status to improve performance and user experience.
final class ImageLoader: ObservableObject {
    
    // MARK: Public Properties
    
    /// A list of fetched image metadata from the server
    @Published private(set) var imagesInfo: [ImageInfo] = []
    
    #if canImport(UIKit)
    /// A set of selected image IDs; only the IDs are tracked to reduce overhead
    @Published private(set) var selectedIDs: Set<String> = []
    
    /// The collaged image generated after user selects images
    @Published var collageUIImage: UIImage?
    #endif
    
    // MARK: Private Properties
    
    private let pageSize = 9
    private var currentPage = 1
    private let maxSelectable = 10
    
    /// Cache of downloaded images: [ImageInfo.id : UIImage]
    private var imageCache: [String: UIImage] = [:]
    private let cacheLock = NSLock()
    
    /// Ongoing download tasks to avoid duplicate requests: [ImageInfo.id : Task<UIImage?,Never>]
    private var downloadTasks: [String: Task<UIImage?, Never>] = [:]
    private let taskLock = NSLock()
    
    // MARK: - Public Methods
    
    /// Loads a new batch of images (clearing existing data) and fetches from random page
    func loadNewBatch() async {
        // Clear local states on the main thread
        await MainActor.run {
            self.imagesInfo.removeAll()
            #if canImport(UIKit)
            self.selectedIDs.removeAll()
            self.collageUIImage = nil
            #endif
        }
        
        // Randomize the page index
        currentPage = Int(Date().timeIntervalSince1970) % 100
        
        // Fetch images info
        let fetched = await fetchImagesInfo(page: currentPage, limit: pageSize)
        
        // Update UI
        await MainActor.run {
            self.imagesInfo = fetched
        }
    }
    
    /// Loads next page of images (pagination)
    func loadMore() async {
        currentPage += 1
        let fetched = await fetchImagesInfo(page: currentPage, limit: pageSize)
        await MainActor.run {
            self.imagesInfo.append(contentsOf: fetched)
        }
    }
    
    #if canImport(UIKit)
    /// Toggle selection of an image by ID.
    /// Minimally updates a Set<String> to avoid heavy tasks on the main thread.
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
    
    /// Returns the corresponding UIImage for a given ImageInfo
    /// If already cached, returns immediately; otherwise downloads in a background task.
    func uiImage(for info: ImageInfo) async -> UIImage? {
        // 1. Check memory cache first
        cacheLock.lock()
        if let cached = imageCache[info.id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        // 2. If there's an existing download task, wait for it
        taskLock.lock()
        if let existingTask = downloadTasks[info.id] {
            taskLock.unlock()
            return await existingTask.value
        } else {
            // 3. Otherwise, create a new download task
            let t = Task.detached(priority: .medium) { [weak self] () -> UIImage? in
                guard let self = self else { return nil }
                return await self.downloadImage(info: info)
            }
            downloadTasks[info.id] = t
            taskLock.unlock()
            
            let result = await t.value
            
            // Remove the task from dictionary after completion
            taskLock.lock()
            self.downloadTasks.removeValue(forKey: info.id)
            taskLock.unlock()
            
            return result
        }
    }
    
    /// Actual download logic, performed in a background Task
    private func downloadImage(info: ImageInfo) async -> UIImage? {
        guard let url = URL(string: info.download_url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                cacheLock.lock()
                imageCache[info.id] = img
                cacheLock.unlock()
                return img
            }
        } catch {
            print("Image download error: \(error.localizedDescription)")
        }
        return nil
    }
    
    /// Generates a collage image (does not save automatically). Runs the heavy task in background.
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
        let images = currentIDs.compactMap { id -> UIImage? in
            cacheLock.lock()
            let img = imageCache[id]
            cacheLock.unlock()
            return img
        }
        
        if images.isEmpty {
            print("No valid cached images for your selection.")
            return
        }
        
        // Generate in background
        let composedCollage = await Task.detached(priority: .medium) { () -> UIImage? in
            if images.count == 1, let single = images.first {
                return single
            } else {
                return Self.createNineGridCollage(images: images)
            }
        }.value
        
        // Update UI on main thread
        await MainActor.run {
            self.collageUIImage = composedCollage
        }
    }
    
    /// Saves the generated collage to the photo album. Requires iOS photo library permission.
    func saveCollageToAlbum() async {
        guard let collage = collageUIImage else {
            print("No collage has been generated.")
            return
        }
        
        do {
            // Check photo library permission
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined {
                if #available(iOS 14, *) {
                    try await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                } else {
                    // Fallback for iOS <14
                    await withCheckedContinuation { continuation in
                        PHPhotoLibrary.requestAuthorization { _ in
                            continuation.resume(returning: ())
                        }
                    }
                }
            }
            let newStatus = PHPhotoLibrary.authorizationStatus()
            switch newStatus {
            case .authorized, .limited:
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: collage)
                }
                print("Collage saved to the photo album.")
            default:
                print("Photo album permission is restricted. Cannot save image.")
            }
        } catch {
            print("Failed to save collage: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Helpers
    
    /// Creates a simple 9-grid collage
    private static func createNineGridCollage(images: [UIImage]) -> UIImage? {
        let targetSize = CGSize(width: 1920, height: 1080)
        let rowCount = 3
        let columnCount = 3
        let itemWidth = targetSize.width / CGFloat(columnCount)
        let itemHeight = targetSize.height / CGFloat(rowCount)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        let context = UIGraphicsGetCurrentContext()
        
        if let ctx = context {
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            
            for (index, img) in images.prefix(9).enumerated() {
                let r = index / columnCount
                let c = index % columnCount
                let x = CGFloat(c) * itemWidth
                let y = CGFloat(r) * itemHeight
                let rect = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
                
                let scaled = scaleImage(img, toFit: rect.size)
                scaled.draw(in: rect)
            }
        }
        
        let finalImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return finalImage
    }
    
    /// Utility to scale an image to the specified size
    private static func scaleImage(_ image: UIImage, toFit size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif
    
    // MARK: - Networking
    
    /// Fetches the list of images from an API
    private func fetchImagesInfo(page: Int, limit: Int) async -> [ImageInfo] {
        let urlString = "https://picsum.photos/v2/list?page=\(page)&limit=\(limit)&order_by=random"
        guard let url = URL(string: urlString) else {
            return []
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let fetched = try JSONDecoder().decode([ImageInfo].self, from: data)
            return fetched
        } catch {
            print("Failed to fetch image info: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - SwiftUI ContentView

struct ContentView: View {
    @StateObject private var loader = ImageLoader()
    @State private var showCollagePreview = false
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            VStack {
                // Grid of images
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(loader.imagesInfo) { info in
                            ZStack {
                                // Custom async thumbnail
                                AsyncThumbnail(info: info, loader: loader)
                                    .frame(width: 100, height: 100)
                                    .cornerRadius(8)
                                
                                #if canImport(UIKit)
                                // Outline if selected
                                if loader.selectedIDs.contains(info.id) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.green, lineWidth: 3)
                                }
                                #endif
                            }
                            .onTapGesture {
                                #if canImport(UIKit)
                                // Toggle selection on tap
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
                    Button("Load New Batch") {
                        Task {
                            await loader.loadNewBatch()
                        }
                    }
                    Spacer()
                    Button("Generate Collage") {
                        Task {
                            await loader.generateCollage()
                            // If collage was generated, present preview
                            if loader.collageUIImage != nil {
                                showCollagePreview = true
                            }
                        }
                    }
                    .disabled(loader.selectedIDs.isEmpty)
                }
                .padding()
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
            .navigationTitle("Photo Selection Demo - Smooth Version")
            .sheet(isPresented: $showCollagePreview) {
                #if canImport(UIKit)
                CollagePreviewView(loader: loader, isPresented: $showCollagePreview)
                #else
                Text("This platform does not support the preview.")
                #endif
            }
            .onAppear {
                // Automatically load when view appears
                Task {
                    await loader.loadNewBatch()
                }
            }
        }
    }
}

// MARK: - Collage Preview Sheet (iOS only)

#if canImport(UIKit)
@MainActor
struct CollagePreviewView: View {
    @ObservedObject var loader: ImageLoader
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let collage = loader.collageUIImage {
                Image(uiImage: collage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 200)
                Text("Generated Collage")
                    .font(.headline)
            } else {
                Text("No collage yet.")
            }
            Spacer()
            // Save to album
            Button("Save to Photo Album") {
                Task {
                    await loader.saveCollageToAlbum()
                }
            }
            .padding(.bottom, 8)
            
            // Close
            Button("Close") {
                loader.collageUIImage = nil
                isPresented = false
            }
        }
        .padding()
    }
}
#endif

// MARK: - AsyncThumbnail

/// An async thumbnail component that retrieves/caches images without blocking the main thread
struct AsyncThumbnail: View {
    let info: ImageInfo
    @ObservedObject var loader: ImageLoader
    
    @State private var thumbnail: UIImage?
    
    var body: some View {
        ZStack {
            if let uiImg = thumbnail {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .background(Color.gray.opacity(0.2))
            } else {
                // Placeholder
                ProgressView("Loading...")
                    .frame(width: 100, height: 100)
            }
        }
        .task {
            #if canImport(UIKit)
            // Fetch image from cache or download asynchronously
            if let fetched = await loader.uiImage(for: info) {
                await MainActor.run {
                    thumbnail = fetched
                }
            }
            #endif
        }
    }
}
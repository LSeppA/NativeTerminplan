import Foundation
import Photos
import UIKit
import os

final class PhotoStore {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "PhotoStore")

    private var photosDirectoryURL: URL? {
        SharedConstants.containerURL?.appendingPathComponent("Photos", isDirectory: true)
    }

    func save(_ image: UIImage) -> URL? {
        guard let photosDirectoryURL else { return nil }
        do {
            try FileManager.default.createDirectory(at: photosDirectoryURL, withIntermediateDirectories: true)
            let fileURL = photosDirectoryURL.appendingPathComponent(UUID().uuidString + ".jpg")
            guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.error("Failed to save image to app container: \(String(describing: error))")
            return nil
        }
    }

    func pruneUnreferencedImages(referencedPaths: Set<String>) {
        guard let photosDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(at: photosDirectoryURL, includingPropertiesForKeys: nil) else { return }

        for file in files where !referencedPaths.contains(file.path) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.error("Failed to remove unreferenced image: \(String(describing: error))")
            }
        }
    }

    func deleteAllImages() {
        guard let photosDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(at: photosDirectoryURL, includingPropertiesForKeys: nil) else { return }

        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.error("Failed to remove image: \(String(describing: error))")
            }
        }
    }

    func loadImage(identifier: String, completion: @escaping (Result<UIImage, PhotoStoreError>) -> Void) {
        if FileManager.default.fileExists(atPath: identifier) {
            DispatchQueue.global(qos: .userInitiated).async {
                if let image = UIImage(contentsOfFile: identifier) {
                    DispatchQueue.main.async { completion(.success(image)) }
                } else {
                    DispatchQueue.main.async { completion(.failure(.imageUnavailable)) }
                }
            }
            return
        }

        requestPhotoLibraryAccess { [weak self] granted in
            guard granted else {
                completion(.failure(.photosAccessDenied))
                return
            }
            self?.loadPhotosAsset(identifier: identifier, completion: completion)
        }
    }

    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        if #available(iOS 14.0, *) {
            let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if currentStatus == .authorized || currentStatus == .limited {
                completion(true)
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { completion(status == .authorized || status == .limited) }
            }
        } else {
            let currentStatus = PHPhotoLibrary.authorizationStatus()
            if currentStatus == .authorized {
                completion(true)
                return
            }
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        }
    }

    private func loadPhotosAsset(identifier: String, completion: @escaping (Result<UIImage, PhotoStoreError>) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else {
            completion(.failure(.imageUnavailable))
            return
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.version = .current
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            DispatchQueue.main.async {
                if let image {
                    completion(.success(image))
                } else {
                    completion(.failure(.imageUnavailable))
                }
            }
        }
    }
}

enum PhotoStoreError: LocalizedError {
    case photosAccessDenied
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            return "Kein Zugriff auf Fotos. Bitte in den Einstellungen erlauben."
        case .imageUnavailable:
            return "Das Foto konnte nicht geladen werden."
        }
    }
}

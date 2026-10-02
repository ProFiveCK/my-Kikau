import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Finds pictures that look alike without being byte-identical: the same
/// photo resized, re-saved or exported twice, burst shots, near-identical
/// edits. (Exact copies are `DuplicateFinder`'s job.)
///
/// Each image is reduced to a feature print by Vision, on this Mac; two
/// images are "similar" when their prints are closer than `threshold`.
/// Results are suggestions for the user to look at — nothing is selected for
/// removal automatically, because "similar" is a judgement.
public enum SimilarImageFinder {
    public struct Group: Identifiable, Sendable {
        public let id: String
        /// Largest file first — usually the best-quality copy.
        public let files: [DuplicateFinder.FileEntry]

        public init(id: String, files: [DuplicateFinder.FileEntry]) {
            self.id = id
            self.files = files
        }

        /// Bytes used by every file except the largest.
        public var reclaimableBytes: Int64 {
            files.dropFirst().reduce(0) { $0 + $1.sizeBytes }
        }
    }

    public struct Report: Sendable {
        public var groups: [Group] = []
        public var imagesExamined = 0
        /// Images left out because the folder set holds more than `maximumImages`.
        public var skippedOverLimit = 0
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    /// Icons and thumbnails aren't photos worth comparing.
    static let minimumBytes: Int64 = 50000

    /// Comparing every pair grows with the square of the count; beyond this
    /// the largest images are examined and the rest reported as skipped.
    public static let maximumImages = 4000

    /// Feature-print distance below which two images count as similar.
    /// Measured on real pictures: a resized, recompressed copy of a photo
    /// lands around 0.15–0.35; unrelated photos are mostly above 0.45.
    public static let defaultThreshold: Float = 0.35

    /// - Parameter files: files from `DuplicateFinder.walkReport` (already
    ///   free of hard-link repeats and cloud-only placeholders).
    public static func find(
        in files: [DuplicateFinder.FileEntry],
        threshold: Float = defaultThreshold,
        onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) -> Report {
        var report = Report()
        var images = files.filter {
            imageExtensions.contains($0.url.pathExtension.lowercased()) && $0.sizeBytes >= minimumBytes
        }
        images.sort { $0.sizeBytes > $1.sizeBytes }
        if images.count > maximumImages {
            report.skippedOverLimit = images.count - maximumImages
            images = Array(images.prefix(maximumImages))
        }
        report.imagesExamined = images.count
        guard images.count > 1 else { return report }

        // 1. A feature print per image, a batch at a time so cancellation
        //    and progress stay responsive.
        var prints: [(file: DuplicateFinder.FileEntry, print: FeaturePrint)] = []
        prints.reserveCapacity(images.count)
        let batchSize = 48
        var index = 0
        while index < images.count {
            if Task.isCancelled {
                return Report()
            }
            let batch = Array(images[index ..< min(index + batchSize, images.count)])
            let computed = concurrentMapOptional(batch) { featurePrint(of: $0.url) }
            for (file, print) in zip(batch, computed) {
                if let print {
                    prints.append((file, print))
                }
            }
            index += batch.count
            onProgress?(index, images.count)
        }

        // 2. Join every pair that is close enough (union–find).
        var parent = Array(0 ..< prints.count)
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        for first in 0 ..< prints.count {
            if first % 64 == 0, Task.isCancelled {
                return Report()
            }
            for second in (first + 1) ..< prints.count {
                var distance: Float = .greatestFiniteMagnitude
                guard (try? prints[first].print.observation.computeDistance(&distance, to: prints[second].print.observation)) != nil,
                      distance < threshold else { continue }
                let (a, b) = (root(first), root(second))
                if a != b {
                    parent[a] = b
                }
            }
        }

        // 3. Collect the groups with more than one member.
        var members: [Int: [DuplicateFinder.FileEntry]] = [:]
        for position in 0 ..< prints.count {
            members[root(position), default: []].append(prints[position].file)
        }
        report.groups = members.values
            .filter { $0.count > 1 }
            .map { files in
                let sorted = files.sorted { $0.sizeBytes > $1.sizeBytes }
                return Group(id: sorted[0].id, files: sorted)
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        return report
    }

    /// A small, orientation-corrected version of the image — all Vision
    /// needs, and far quicker than decoding a full-size photo.
    public static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func featurePrint(of url: URL) -> FeaturePrint? {
        guard let image = thumbnail(of: url, maxPixelSize: 299) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        return FeaturePrint(observation: observation)
    }

    /// Vision's observation is immutable once produced; the wrapper lets it
    /// cross threads.
    struct FeaturePrint: @unchecked Sendable {
        let observation: VNFeaturePrintObservation
    }

    private static func concurrentMapOptional<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        _ transform: @Sendable (Input) -> Output?
    ) -> [Output?] {
        let results = OptionalSlots<Output>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            results.set(index, transform(items[index]))
        }
        return results.values()
    }
}

private final class OptionalSlots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value?]

    init(count: Int) {
        storage = [Value?](repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: Value?) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    func values() -> [Value?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

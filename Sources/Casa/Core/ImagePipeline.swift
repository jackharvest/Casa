import Foundation

/// Owns every decoded bitmap in the process, and decides what is worth keeping.
///
/// Memory is the whole personality of this app. Picasa's viewer was remembered
/// as weightless, and the way to earn that is not micro-optimization — it is
/// refusing to hold bitmaps you cannot justify.
///
/// The policy is enforced by *shape* rather than by accounting, which is the
/// important design decision here. An earlier version kept one dictionary and a
/// byte ceiling, and it drifted to 310 MB over a dozen navigations: every image
/// the user passed through kept its full screen-resolution bitmap, and the
/// GPU-side copies Core Animation makes were invisible to the byte count
/// entirely. A budget you have to remember to enforce is a budget that leaks.
///
/// So there are two stores with different shapes:
///
///   * **one** sharp image — the one being looked at, at screen resolution,
///     around 60 MB. There is a single slot, so a second one cannot exist.
///   * **a few** previews — the navigation neighborhood at `previewCap`, about
///     4 MB each, bounded by count.
///
/// Total resident bitmap memory is therefore bounded by construction at roughly
/// 60 MB + 8 × 4 MB, and no future change can quietly exceed it without
/// changing the shape of the type.
actor ImagePipeline {

    /// How many images either side of the current one to decode ahead.
    /// Two is enough to make held-arrow scrubbing feel continuous without
    /// turning a folder walk into a decode storm.
    static let preloadRadius = 2

    /// Preview slots: the neighborhood plus slack, so reversing direction does
    /// not immediately evict the image behind you.
    private static let previewLimit = (preloadRadius * 2 + 1) + 3

    /// Cheap proxies, keyed by URL. Bounded by count.
    private var previews: [URL: DecodedImage] = [:]
    /// Least-recently-used ordering for `previews`; last is most recent.
    private var previewOrder: [URL] = []

    /// The single screen-resolution (or full) bitmap. Assigning replaces the
    /// previous one, which is what makes the bound structural.
    private var sharp: (url: URL, image: DecodedImage)?

    /// Filmstrip thumbnails. A third store rather than a third use of the
    /// preview one, because the rail wants *many* small images while the
    /// preview window wants *few* medium ones — sharing a bound would make
    /// each starve the other.
    private var strips: [URL: DecodedImage] = [:]
    private var stripOrder: [URL] = []
    /// ~320 px each, so about 400 KB; sixty of them is well under 30 MB.
    private static let stripLimit = 60

    private var inFlight: [CacheKey: Task<DecodedImage?, Never>] = [:]
    /// The one screen-resolution decode allowed to be running at a time.
    private var sharpDecode: Task<DecodedImage?, Never>?
    /// The one filmstrip decode allowed to be running at a time.
    private var stripDecode: Task<DecodedImage?, Never>?

    private struct CacheKey: Hashable {
        let url: URL
        let tier: DecodeTier
    }

    // MARK: - Reads

    /// Best bitmap currently resident for `url`, whatever its tier.
    /// Non-blocking and never decodes — this is what the first paint uses.
    func anyCached(_ url: URL) -> DecodedImage? {
        if let sharp, sharp.url == url { return sharp.image }
        if let preview = previews[url] {
            touch(url)
            return preview
        }
        // Last resort, and a good one: a filmstrip thumbnail is blurry but it
        // is *there*, which beats a blank window while the real decode runs.
        return strips[url]
    }

    /// Cached filmstrip thumbnail, if one is resident. Never decodes — the
    /// rail asks for every visible item on every layout pass.
    func cachedStrip(_ url: URL) -> DecodedImage? {
        strips[url]
    }

    /// Decodes a filmstrip thumbnail.
    ///
    /// Strictly one at a time, and never while a screen-resolution decode is
    /// running. The rail asks for every visible cell at once — a dozen or more
    /// — and letting those run concurrently saturated every core: each strip
    /// decode took 3.2 s instead of ~150 ms, and it dragged the foreground
    /// image the user was waiting for from 150 ms to 3259 ms with it.
    ///
    /// Low priority alone does not prevent this. `.background` changes who
    /// wins a scheduling contest, not how many contestants there are. The only
    /// thing that bounds the damage is bounding the concurrency.
    func stripThumbnail(_ url: URL) async -> DecodedImage? {
        if let resident = strips[url] { return resident }

        let key = CacheKey(url: url, tier: .strip)
        if let existing = inFlight[key] { return await existing.value }

        // The photograph always outranks its thumbnail.
        await drainSharpDecode()
        await drainStripDecode()

        // Another caller may have finished this exact thumbnail while we
        // waited, and re-decoding it would waste the very cores we just
        // queued for.
        if let resident = strips[url] { return resident }

        let task = Task.detached(priority: .background) {
            if VideoSource.isVideo(url) {
                return await Self.poster(url, tier: .strip, maxPixelSize: 0)
            }
            return ImageSource.decode(url, tier: .strip, maxPixelSize: 0)
        }
        inFlight[key] = task
        stripDecode = task

        let decoded = await task.value
        inFlight[key] = nil
        if stripDecode == task { stripDecode = nil }

        if let decoded { store(decoded, for: url) }
        return decoded
    }

    /// Waits for any outstanding filmstrip decode to finish.
    private func drainStripDecode() async {
        while let outstanding = stripDecode {
            _ = await outstanding.value
            if stripDecode == outstanding { stripDecode = nil }
        }
    }

    /// Decodes `url` at `tier`, reusing an in-flight decode if one exists.
    ///
    /// Duplicate requests are common — the user arrows forward onto an image
    /// the preloader is already fetching — and coalescing them is the
    /// difference between one decode and two.
    /// - Parameter force: decode even if something suitable is resident. Used
    ///   when the *target size* has changed — moving between a 1x and a 2x
    ///   display needs a different bitmap for the same tier, and the cache has
    ///   no way to know that on its own.
    func image(_ url: URL, tier: DecodeTier, maxPixelSize: Int, force: Bool = false) async -> DecodedImage? {
        if !force, let resident = anyCached(url), resident.tier >= tier {
            return resident
        }

        let key = CacheKey(url: url, tier: tier)
        if !force, let existing = inFlight[key] {
            return await existing.value
        }

        // Screen-resolution decodes are serialized, one at a time.
        //
        // The single `sharp` slot bounds what we *keep*; this bounds what is
        // being *made*. Scrubbing with a held arrow key starts a new 60 MB
        // decode every ~170 ms, and because `ImageSource.decode` is a blocking
        // ImageIO call with no cancellation points, cancelling an outstanding
        // one does not stop it allocating — it runs to completion regardless.
        // Draining the previous decode before starting the next is therefore
        // the only thing that actually caps the transient, and it costs the
        // user nothing visible: the cheap preview is already on screen, so
        // what is being waited on is sharpening, not appearing.
        if tier >= .display {
            await drainSharpDecode()
        }

        let task = Task.detached(priority: .userInitiated) {
            // A movie enters the ladder as its poster frame, so that every
            // stage upstream — preload, filmstrip, fit geometry — can treat it
            // as an ordinary picture.
            if VideoSource.isVideo(url) {
                return await Self.poster(url, tier: tier, maxPixelSize: maxPixelSize)
            }
            // Blocking CPU work, deliberately off the actor so the pipeline
            // stays responsive to cancellation and to further requests.
            return ImageSource.decode(url, tier: tier, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task

        if tier >= .display { sharpDecode = task }

        let decoded = await task.value
        inFlight[key] = nil
        if tier >= .display, sharpDecode == task { sharpDecode = nil }

        if let decoded { store(decoded, for: url) }
        return decoded
    }

    /// Waits for any outstanding screen-resolution decode to finish.
    private func drainSharpDecode() async {
        while let outstanding = sharpDecode {
            _ = await outstanding.value
            if sharpDecode == outstanding { sharpDecode = nil }
        }
    }

    // MARK: - Preloading

    /// Warms the neighborhood around `index` and drops everything outside it.
    ///
    /// Called once the current image is sharp — never before, because four
    /// background HEIC decodes competing with the foreground one stretched the
    /// image the user was actually waiting for from ~140 ms to ~390 ms.
    func preload(around index: Int, in urls: [URL]) {
        guard urls.indices.contains(index) else { return }

        let lower = max(0, index - Self.preloadRadius)
        let upper = min(urls.count - 1, index + Self.preloadRadius)
        let neighborhood = Array(urls[lower...upper])
        let keep = Set(neighborhood)

        // Drop work for anything we have navigated away from. On a fast scrub
        // the user has already moved on and these results would only cost
        // memory to throw away.
        for (key, task) in inFlight where !keep.contains(key.url) {
            task.cancel()
            inFlight[key] = nil
        }

        for url in previews.keys where !keep.contains(url) {
            removePreview(url)
        }

        // Nearest-first, so a user who keeps moving gets the adjacent image
        // before the far edge of the window is even considered.
        let positions = Dictionary(uniqueKeysWithValues: neighborhood.enumerated().map { ($1, $0 + lower) })
        let ordered = neighborhood.sorted {
            abs((positions[$0] ?? 0) - index) < abs((positions[$1] ?? 0) - index)
        }

        // Skipping the current image matters more than it looks. Promoting it
        // to `sharp` drops its preview as redundant, which left the preloader
        // seeing a gap and immediately decoding the very image already on
        // screen at full resolution — a whole wasted decode per navigation.
        for url in ordered where previews[url] == nil && sharp?.url != url {
            let key = CacheKey(url: url, tier: .preview)
            guard inFlight[key] == nil else { continue }

            let task = Task.detached(priority: .utility) {
                if VideoSource.isVideo(url) {
                    return await Self.poster(url, tier: .preview, maxPixelSize: 0)
                }
                return ImageSource.decode(url, tier: .preview, maxPixelSize: 0)
            }
            inFlight[key] = task
            Task { await self.collect(key: key, url: url, task: task) }
        }
    }

    private func collect(key: CacheKey, url: URL, task: Task<DecodedImage?, Never>) async {
        let decoded = await task.value
        guard inFlight[key] != nil else { return }   // cancelled and cleared
        inFlight[key] = nil
        guard let decoded else { return }
        store(decoded, for: url)
    }

    // MARK: - Storage

    private func store(_ image: DecodedImage, for url: URL) {
        if image.tier == .strip {
            strips[url] = image
            stripOrder.removeAll { $0 == url }
            stripOrder.append(url)
            while stripOrder.count > Self.stripLimit, let oldest = stripOrder.first {
                strips.removeValue(forKey: oldest)
                stripOrder.removeFirst()
            }
            return
        }

        if image.tier >= .display {
            // Single slot. The previous sharp bitmap is released here, which is
            // the only place a large allocation can be held, and the only place
            // one needs to be freed.
            sharp = (url, image)
            // Its cheap proxy is now redundant.
            removePreview(url)
        } else {
            if let existing = previews[url], existing.tier >= image.tier { return }
            previews[url] = image
            touch(url)
            trimPreviews()
        }
    }

    private func touch(_ url: URL) {
        previewOrder.removeAll { $0 == url }
        previewOrder.append(url)
    }

    private func removePreview(_ url: URL) {
        previews.removeValue(forKey: url)
        previewOrder.removeAll { $0 == url }
    }

    private func trimPreviews() {
        while previewOrder.count > Self.previewLimit, let oldest = previewOrder.first {
            removePreview(oldest)
        }
    }

    /// Produces a movie's poster frame at the size this rung calls for.
    private static func poster(_ url: URL, tier: DecodeTier, maxPixelSize: Int) async -> DecodedImage? {
        let budget = tier == .display ? max(maxPixelSize, 1) : ImageSource.capacity(for: tier)
        guard let frame = await VideoSource.posterFrame(url, maxPixelSize: budget) else { return nil }
        let native = await VideoSource.naturalSize(url)
            ?? CGSize(width: frame.width, height: frame.height)
        return DecodedImage(cgImage: frame, tier: tier, nativePixelSize: native)
    }

    /// Approximate resident bitmap bytes, for the debug readout.
    var memoryFootprint: Int {
        (sharp?.image.byteCost ?? 0)
            + previews.values.reduce(0) { $0 + $1.byteCost }
            + strips.values.reduce(0) { $0 + $1.byteCost }
    }
}

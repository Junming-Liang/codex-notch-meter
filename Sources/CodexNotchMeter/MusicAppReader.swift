import AppKit
import CoreServices
import Darwin
import ImageIO
import NotchCore

/// Read-only public Apple Events adapter. Construction is inert. The controller
/// must keep this off by default and call it only while explicitly enabled.
///
/// No AppleScript, application-name/bundle-ID event address, launch, activation,
/// playback command, library query, token/cache access or network operation.
/// A PID-addressed event fails if its process exits; it has no app path from
/// which to launch Music. We revalidate the process identity before every event
/// and after the read; no retry redirects an event to a newly launched process.
final class MusicAppReader: MusicSnapshotProvider, @unchecked Sendable {
    // Separate shared slots bound required playback and optional artwork. A
    // stalled artwork decoder cannot occupy the required reader worker.
    private static let diagnostics = MusicReadDiagnosticStore()
    private static let artworkCache = MusicArtworkCache()

    private static let reader = BoundedMusicSnapshotProvider { request in
        autoreleasepool {
            diagnostics.begin()
            do { return try MusicAppleEvents.read(request, artworkCache: artworkCache, diagnostic: diagnostics) }
            catch let failure as MusicReadFailure { return .unavailable(failure) }
            catch { return .unavailable(.invalidResponse) }
        }
    }

    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        await withTaskCancellationHandler {
            let result = await Self.reader.read(allowPermissionPrompt: allowPermissionPrompt)
            if result != .unavailable(.busy) { Self.diagnostics.finish(result) }
            if case .unavailable = result { Self.artworkCache.invalidate() }
            return result
        } onCancel: { Self.artworkCache.invalidate() }
    }
    func invalidate() { Self.artworkCache.invalidate() }
    var readDiagnostic: MusicReadDiagnostic { Self.diagnostics.snapshot }
    var artworkDiagnostic: MusicArtworkDiagnostic { Self.artworkCache.diagnostic }
}

private enum MusicAppleEvents {
    private static let bundleID = "com.apple.Music"
    private static let bundlePath = "/System/Applications/Music.app"
    private static let executablePath = bundlePath + "/Contents/MacOS/Music"
    private static let maximumReplyBytes = 65_536
    private static let maximumDescriptorBytes = 16_384
    private static let maximumArtworkReplyBytes = MusicArtworkDecodingPolicy.maximumEncodedBytes + 65_536
    // Optional IPC has its own short budget on a separate bounded worker.
    private static let artworkWaitLimit: TimeInterval = 0.15

    // Public Music scripting dictionary properties; none is a write/control
    // command. Mac CI compiles this adapter and inspects the public dictionary.
    // Actual Music/TCC compatibility remains unverified; unit tests use mocks.
    private enum Property {
        static let currentTrack = code("pTrk")
        static let playerState = code("pPlS")
        static let playerPosition = code("pPos")
        static let title = code("pnam")
        static let artist = code("pArt")
        static let album = code("pAlb")
        static let duration = code("pDur")
        static let persistentID = code("pPIS")
        static let artworkRawData = code("pRaw")
    }

    private static let artworkClass = code("cArt")

    private struct Target {
        let application: NSRunningApplication
        let pid: pid_t
        let launchDate: Date
        let address: NSAppleEventDescriptor

        init() throws {
            // Enumeration is read-only and does not launch the application.
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            guard !applications.isEmpty else { throw MusicReadFailure.notRunning }
            guard applications.count == 1, let application = applications.first,
                  application.processIdentifier > 0, let launchDate = application.launchDate,
                  MusicAppleEvents.isExpectedApplication(application) else {
                throw MusicReadFailure.targetMismatch
            }
            self.application = application
            self.pid = application.processIdentifier
            self.launchDate = launchDate
            self.address = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
        }

        func validate() throws {
            guard !application.isTerminated,
                  let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated else {
                throw MusicReadFailure.notRunning
            }
            guard current.launchDate == launchDate, MusicAppleEvents.isExpectedApplication(current) else {
                throw MusicReadFailure.targetMismatch
            }
        }
    }

    private static func isExpectedApplication(_ application: NSRunningApplication) -> Bool {
        // Fail closed for renamed/copied/spoofed bundle identifiers. These are
        // the system-protected Music paths on the minimum supported macOS 13.
        application.bundleIdentifier == bundleID
            && application.bundleURL?.standardizedFileURL.path == bundlePath
            && application.executableURL?.standardizedFileURL.path == executablePath
    }

    static func read(_ request: MusicReadRequest, artworkCache: MusicArtworkCache,
                     diagnostic: MusicReadDiagnosticStore) throws -> MusicReadResult {
        let session = artworkCache.sessionToken
        try request.checkCancellation()
        let target = try Target()
        try target.validate()
        guard let address = target.address.aeDesc else { throw MusicReadFailure.invalidResponse }
        try request.checkCancellation()

        // Public preflight is scoped to the only event sent here: core/getd.
        // false must never be upgraded to true by a polling/recovery path.
        // This OS call has no cancellation primitive; the outer bounded gate
        // releases the caller while retaining its sole occupied worker slot.
        diagnostic.mark(.permission)
        let permission = AEDeterminePermissionToAutomateTarget(address, AEEventClass(kAECoreSuite),
                                                              AEEventID(kAEGetData), request.allowPermissionPrompt)
        guard permission == noErr else { throw MusicReadFailure.appleEventStatus(permission) }
        try request.checkCancellation()

        let result = try transaction(target: target, request: request).playback(request: request, diagnostic: diagnostic)
        guard case .snapshot(let snapshot) = result, snapshot.state == .playing else {
            artworkCache.invalidate()
            return result
        }
        let key = MusicArtworkKey(pid: target.pid, launchDate: target.launchDate, track: snapshot.track)
        let artwork = artworkCache.cachedArtwork(for: key, session: session) { optionalRequest in
            try autoreleasepool { try readArtwork(for: key, request: optionalRequest) }
        }
        guard let enriched = MusicPlaybackSnapshot(track: snapshot.track, state: snapshot.state,
                                                   position: snapshot.position, observedAt: snapshot.observedAt,
                                                   artwork: artwork) else { return result }
        return .snapshot(enriched)
    }

    private static func readArtwork(for key: MusicArtworkKey, request: MusicReadRequest) throws -> MusicArtwork? {
        try request.checkCancellation()
        let target = try Target()
        guard target.pid == key.pid, target.launchDate == key.launchDate else {
            throw MusicReadFailure.targetMismatch
        }
        try target.validate()
        guard let address = target.address.aeDesc else { throw MusicReadFailure.invalidResponse }
        let permission = AEDeterminePermissionToAutomateTarget(address, AEEventClass(kAECoreSuite),
                                                              AEEventID(kAEGetData), false)
        guard permission == noErr else { throw MusicReadFailure.appleEventStatus(permission) }
        try request.checkCancellation()
        return try transaction(target: target, request: request).artwork(
            for: key.track, request: request,
            read: { try optionalArtworkData(target: target, request: request) },
            decode: MusicArtworkDecoder.decode)
    }

    private static func transaction(target: Target, request: MusicReadRequest) -> MusicReadTransaction {
        MusicReadTransaction(
            state: { try state(target: target, request: request) },
            track: { try track(target: target, request: request) },
            position: { try number(get(Property.playerPosition, target: target, request: request)) },
            validate: { try target.validate() })
    }

    private static func optionalArtworkData(target: Target, request: MusicReadRequest) throws -> Data? {
        try request.checkCancellation()
        // Read only raw data of artwork 1 of current track. No enumeration,
        // library lookup, file URL, image download, or alternate source.
        let container = try firstArtwork(of: property(Property.currentTrack))
        let value = try get(Property.artworkRawData, container: container,
                            target: target, request: request,
                            replyLimit: maximumArtworkReplyBytes, waitLimit: artworkWaitLimit)
        guard !isMissing(value),
              MusicArtworkDecodingPolicy.acceptsEncodedByteCount(descriptorSize(value)) else { return nil }
        let allowedTypes: [DescType] = [DescType(typeData), code("JPEG"), code("PNGf")]
        guard allowedTypes.contains(value.descriptorType) else { return nil }
        return value.data
    }

    private static func track(target: Target, request: MusicReadRequest) throws -> MusicTrackFields {
        let container = try property(Property.currentTrack)
        let title = try string(get(Property.title, container: container, target: target, request: request))
        let artist = try string(get(Property.artist, container: container, target: target, request: request))
        let album = try string(get(Property.album, container: container, target: target, request: request))
        let duration = try number(get(Property.duration, container: container, target: target, request: request))
        let persistentID: String?
        do {
            persistentID = try string(get(Property.persistentID, container: container, target: target, request: request))
        } catch MusicReadFailure.unknownTrack {
            // Some streaming tracks expose metadata without a library ID. This
            // cannot be mistaken for a catalog ID; equality includes all fields.
            persistentID = nil
        }
        return MusicTrackFields(title: title, artist: artist, album: album,
                                duration: duration, persistentID: persistentID)
    }

    private static func state(target: Target, request: MusicReadRequest) throws -> MusicPlaybackState {
        let value = try get(Property.playerState, target: target, request: request)
        guard !isMissing(value) else { return .unknown }
        guard value.descriptorType == typeEnumerated, descriptorSize(value) == 4 else {
            throw MusicReadFailure.invalidResponse
        }
        switch value.enumCodeValue {
        case code("kPSP"): return .playing
        case code("kPSp"): return .paused
        case code("kPSS"): return .stopped
        default: return .unknown // Seeking/unknown states must not interpolate.
        }
    }

    private static func property(_ propertyCode: OSType,
                                 container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: propertyCode), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MusicReadFailure.invalidResponse
        }
        return specifier
    }

    private static func firstArtwork(of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: artworkClass), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MusicReadFailure.invalidResponse
        }
        return specifier
    }

    private static func get(_ propertyCode: OSType, container: NSAppleEventDescriptor = .null(),
                            target: Target, request: MusicReadRequest,
                            replyLimit: Int = maximumReplyBytes,
                            waitLimit: TimeInterval = 5) throws -> NSAppleEventDescriptor {
        try request.checkCancellation()
        try target.validate()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                           targetDescriptor: target.address,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(try property(propertyCode, container: container), forKeyword: keyDirectObject)

        // AESendMessage is documented thread-safe. Apple's TN2053 requires a
        // private reply Mach port for background kAEWaitReply sends. The port is
        // owned only by this send and destroyed after return (macOS >= 13).
        var port: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &port) == KERN_SUCCESS else {
            throw MusicReadFailure.invalidResponse
        }
        defer { _ = mach_port_destroy(mach_task_self_, port) }
        guard let replyPort = NSAppleEventDescriptor(descriptorType: typeMachPort,
                                                     bytes: &port, length: MemoryLayout<mach_port_t>.size) else {
            throw MusicReadFailure.invalidResponse
        }
        event.setAttribute(replyPort, forKeyword: keyReplyPortAttr)
        guard let descriptor = event.aeDesc else { throw MusicReadFailure.invalidResponse }
        let remaining = request.remainingTime
        guard remaining > 0 else { throw MusicReadFailure.timedOut }
        let ticks = max(1, Int(min(remaining, waitLimit) * 60))
        var reply = AppleEvent()
        defer { AEDisposeDesc(&reply) }
        // The no-consent-prompt flag closes the race between preflight and send,
        // including when the user revokes permission. No activation/switch flag.
        let mode = AESendMode(kAEWaitReply) | AESendMode(kAENeverInteract)
            | AESendMode(kAEDontRecord) | AESendMode(kAEDoNotPromptForUserConsent)
        try request.checkCancellation()
        let status = AESendMessage(descriptor, &reply, mode, ticks)
        guard status == noErr else { throw MusicReadFailure.appleEventStatus(status) }
        try request.checkCancellation()
        try target.validate()
        let size = AESizeOfFlattenedDesc(&reply)
        guard size > 0, size <= replyLimit else { throw MusicReadFailure.invalidResponse }

        // Check the error number, never the potentially private error message.
        var errorNumber: Int32 = 0
        var actualType: DescType = 0
        var actualSize: Int = 0 // The SDK imports the legacy C Size parameter as Int.
        let errorStatus = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &actualType,
                                        &errorNumber, MemoryLayout<Int32>.size, &actualSize)
        if errorStatus == noErr {
            guard actualSize == MemoryLayout<Int32>.size else { throw MusicReadFailure.invalidResponse }
            if errorNumber != 0 { throw MusicReadFailure.appleEventStatus(errorNumber) }
        } else if errorStatus != errAEDescNotFound { throw MusicReadFailure.invalidResponse }

        var value = AEDesc()
        let valueStatus = AEGetParamDesc(&reply, keyDirectObject, typeWildCard, &value)
        guard valueStatus == noErr else {
            AEDisposeDesc(&value)
            throw MusicReadFailure.unknownTrack
        }
        // Ownership of value transfers to the Foundation wrapper.
        return NSAppleEventDescriptor(aeDescNoCopy: &value)
    }

    private static func isMissing(_ value: NSAppleEventDescriptor) -> Bool {
        value.descriptorType == typeNull
            || (value.descriptorType == typeType && value.typeCodeValue == code("msng"))
    }

    private static func descriptorSize(_ value: NSAppleEventDescriptor) -> Int {
        guard let descriptor = value.aeDesc else { return -1 }
        return AEGetDescDataSize(descriptor)
    }

    private static func string(_ value: NSAppleEventDescriptor) throws -> String? {
        guard !isMissing(value) else { return nil }
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(value.descriptorType),
              (0...maximumDescriptorBytes).contains(descriptorSize(value)),
              let text = value.stringValue,
              text.utf8.prefix(MusicTrackIdentity.maximumFieldBytes + 1).count <= MusicTrackIdentity.maximumFieldBytes else {
            throw MusicReadFailure.invalidResponse
        }
        return text
    }

    private static func number(_ value: NSAppleEventDescriptor) throws -> Double? {
        guard !isMissing(value) else { return nil }
        guard [typeSInt16, typeSInt32, typeSInt64, typeUInt32, typeIEEE32BitFloatingPoint,
               typeIEEE64BitFloatingPoint].contains(value.descriptorType),
              (1...8).contains(descriptorSize(value)),
              let converted = value.coerce(toDescriptorType: typeIEEE64BitFloatingPoint),
              descriptorSize(converted) == MemoryLayout<Double>.size else {
            throw MusicReadFailure.invalidResponse
        }
        let result = converted.doubleValue
        guard result.isFinite else { throw MusicReadFailure.invalidResponse }
        return result
    }

    private static func code(_ value: StaticString) -> OSType {
        value.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | OSType($1) } }
    }
}

/// Data-only, bounded ImageIO boundary. It is internal so native synthetic
/// fixtures can exercise it without Music, Apple Events, file or network access.
enum MusicArtworkDecoder {
    static func decode(_ data: Data) -> MusicArtwork? {
        guard MusicArtworkDecodingPolicy.acceptsEncodedByteCount(data.count) else { return nil }
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let jpegSignature: [UInt8] = [255, 216, 255]
        guard data.starts(with: pngSignature) || data.starts(with: jpegSignature) else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false,
                                             kCGImageSourceShouldAllowFloat: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let sourceType = CGImageSourceGetType(source),
              ["public.jpeg", "public.png"].contains(sourceType as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let depth = properties[kCGImagePropertyDepth] as? NSNumber,
              (1...8).contains(depth.intValue), depth.doubleValue == Double(depth.intValue),
              MusicArtworkDecodingPolicy.acceptsSource(pixelWidth: width.doubleValue,
                                                       pixelHeight: height.doubleValue,
                                                       imageCount: CGImageSourceGetCount(source)) else { return nil }

        // No full-sized CGImage/NSImage is created. Bound both the requested and
        // returned thumbnail, then normalize into an exact small RGBA buffer.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: MusicArtwork.maximumDimension,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              (1...MusicArtwork.maximumDimension).contains(thumbnail.width),
              (1...MusicArtwork.maximumDimension).contains(thumbnail.height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let pixelWidth: Int = thumbnail.width
        let pixelHeight: Int = thumbnail.height
        let bytesPerRow: Int = pixelWidth * MusicArtwork.bytesPerPixel
        var rgba = Data(count: bytesPerRow * pixelHeight)
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = rgba.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
            return true
        }
        guard rendered else { return nil }
        return MusicArtwork(rgbaBytes: rgba, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

// Primary API references checked for this implementation:
// https://developer.apple.com/documentation/coreservices/1442994-aesendmessage
// https://developer.apple.com/library/archive/technotes/tn2002/tn2053.html
// https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet
// https://developer.apple.com/documentation/appkit/nsrunningapplication
// https://developer.apple.com/documentation/foundation/nsappleeventdescriptor
// https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html
// Public Music current-track limitations (not a universal streaming guarantee):
// https://developer.apple.com/forums/thread/798267

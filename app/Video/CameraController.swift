//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2025 Apple Inc. All Rights Reserved.
//

import AVFoundation
import CoreImage
import ARKit
import RealityKit
#if os(iOS)
    import UIKit
#endif

#if os(visionOS)
@available(visionOS 2.1, *)
#endif
@Observable
public class CameraController: NSObject {
    
    #if os(visionOS)
    private var arkitSession: ARKitSession?
    private var cameraFrameProvider: CameraFrameProvider?
    private var visionStreamingTask: Task<Void, Never>?
    #endif


    private var framesContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    public var backCamera = true {
        didSet {
            stop()
            start()
        }
    }

    public var devices = [AVCaptureDevice]()

    public var device: AVCaptureDevice = AVCaptureDevice.default(for: .video)! {
        didSet {
            stop()
            start()
        }
    }

    private var permissionGranted = true
    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "sessionQueue")
    #if !os(visionOS)
    @objc dynamic private var rotationCoordinator : AVCaptureDevice.RotationCoordinator?
    #endif
    private var rotationObservation: NSKeyValueObservation?

    public func attach(continuation: AsyncStream<CMSampleBuffer>.Continuation) {
        sessionQueue.async {
            self.framesContinuation = continuation
        }
    }

    public func detatch() {
        sessionQueue.async {
            self.framesContinuation = nil
        }
    }

    public func stop() {
        #if os(visionOS)
            stopVisionOS()
        #endif
        sessionQueue.sync { [self] in
            captureSession?.stopRunning()
            captureSession = nil
        }
    }

    public func start() {
        #if os(visionOS)
            startVisionOS()
        #else
        sessionQueue.async { [self] in
            let captureSession = AVCaptureSession()
            self.captureSession = captureSession

            self.checkPermission()
            self.setupCaptureSession(position: backCamera ? .back : .front)
            captureSession.startRunning()
        }
        #endif
    }

    #if os(iOS)
        private func setOrientation(_ orientation: UIDeviceOrientation) {
            guard let captureSession else { return }

            let angle: Double?
            switch orientation {
            case .unknown, .faceDown:
                angle = nil
            case .portrait, .faceUp:
                angle = 90
            case .portraitUpsideDown:
                angle = 270
            case .landscapeLeft:
                angle = 0
            case .landscapeRight:
                angle = 180
            @unknown default:
                angle = nil
            }

            if let angle {
                for output in captureSession.outputs {
                    output.connection(with: .video)?.videoRotationAngle = angle
                }
            }
        }
    
    private func updateRotation(rotation : CGFloat) {
        guard let captureSession else { return }
        for output in captureSession.outputs {
            output.connection(with: .video)?.videoRotationAngle = rotation
        }
    }
    #endif

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            self.permissionGranted = true

        case .notDetermined:
            // The user has not yet been asked for camera access.
            self.requestPermission()

        // Combine the two other cases into the default case
        default:
            self.permissionGranted = false
        }
    }

    func requestPermission() {
        // Strong reference not a problem here but might become one in the future.
        AVCaptureDevice.requestAccess(for: .video) { [unowned self] granted in
            self.permissionGranted = granted
        }
    }

    func setupCaptureSession(position: AVCaptureDevice.Position) {
        guard let captureSession else { return }

        let videoOutput = AVCaptureVideoDataOutput()

        guard permissionGranted else {
            print("No permission for camera")
            return
        }

        let deviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS)
            deviceTypes = [.builtInDualCamera, .builtInWideAngleCamera]
        #elseif os(visionOS)
            deviceTypes = [.builtInWideAngleCamera, .external]
        #elseif os(macOS)
            deviceTypes = [.continuityCamera, .external, .builtInWideAngleCamera]
        #endif

        let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position)

        let videoDevice: AVCaptureDevice?
        if videoDeviceDiscoverySession.devices.contains(self.device) {
            videoDevice = self.device
        } else {
            videoDevice = videoDeviceDiscoverySession.devices.first
        }

        if devices.isEmpty {
            self.devices = videoDeviceDiscoverySession.devices
        }

        guard
            let videoDevice
        else {
            print("Unable to find video device")
            return
        }
        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            print("Unable to create AVCaptureDeviceInput")
            return
        }
        guard captureSession.canAddInput(videoDeviceInput) else {
            print("Unable to add input")
            return
        }
        captureSession.addInput(videoDeviceInput)

        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sampleBufferQueue"))
        captureSession.addOutput(videoOutput)
        #if !os(visionOS)
        captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080
        #endif
        #if os(iOS)
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: nil)
        rotationObservation = observe(\.rotationCoordinator!.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
            if let nv = change.newValue {
                self?.updateRotation(rotation: nv)
            }
        }
        #endif
    }
    #if os(visionOS)
    private func startVisionOS() {
        stopVisionOS()

        guard CameraFrameProvider.isSupported else {
            print("CameraFrameProvider is not supported on this device/config.")
            return
        }

        let session = ARKitSession()
        let provider = CameraFrameProvider()
        self.arkitSession = session
        self.cameraFrameProvider = provider

        visionStreamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await session.run([provider])
                let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left])
                guard let highRes = formats.max(by: { $0.frameSize.height < $1.frameSize.height }),
                      let updates = provider.cameraFrameUpdates(for: highRes)
                else {
                    print("No supported camera format/updates.")
                    return
                }

                for await frame in updates {
                    if let sample = frame.sample(for: .left) {
                        let pixelBuffer = sample.pixelBuffer

                        let ts = CMTime(seconds: sample.parameters.captureTimestamp, preferredTimescale: 1_000_000)
                        if let cms = Self.cmsampleBuffer(from: pixelBuffer, timestamp: ts) {
                            self.sessionQueue.async { [weak self] in
                                self?.framesContinuation?.yield(cms)
                            }
                        }
                    }
                }

            } catch {
                print("ARKitSession run error: \(error)")
            }
        }
    }

    private func stopVisionOS() {
        visionStreamingTask?.cancel()
        visionStreamingTask = nil
        arkitSession = nil
        cameraFrameProvider = nil
    }
    
    private static func cmsampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        var videoInfo: CMVideoFormatDescription?
        let status1 = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                   imageBuffer: pixelBuffer,
                                                                   formatDescriptionOut: &videoInfo)
        guard status1 == noErr, let videoInfo else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: CMTime.invalid)

        var sampleBuffer: CMSampleBuffer?
        let status2 = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         dataReady: true,
                                                         makeDataReadyCallback: nil,
                                                         refcon: nil,
                                                         formatDescription: videoInfo,
                                                         sampleTiming: &timing,
                                                         sampleBufferOut: &sampleBuffer)

        guard status2 == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
    #endif
}

@available(visionOS 2.1, *)
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if sampleBuffer.isValid && sampleBuffer.imageBuffer != nil {
            framesContinuation?.yield(sampleBuffer)
        }
    }
}

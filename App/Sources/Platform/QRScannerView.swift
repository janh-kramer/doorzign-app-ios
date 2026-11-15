import AVFoundation
import SwiftUI
import UIKit

/// Vollbild-Sheet mit QR-Scanner, Kamerazugriff und Hinweisen.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch authorization {
                case .authorized:
                    QRScannerView(onScan: onScan)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Richte die Kamera auf den QR-Code.")
                                .padding(12)
                                .floatingGlass(in: Capsule())
                                .padding(.bottom, 40)
                        }
                case .notDetermined:
                    ProgressView()
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            authorization = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    ContentUnavailableView {
                        Label("Kein Kamerazugriff", systemImage: "camera.fill")
                    } description: {
                        Text("Erlaube DoorZign in den Einstellungen den Zugriff auf die Kamera, um QR-Codes zu scannen.")
                    } actions: {
                        Button("Einstellungen öffnen") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            .navigationTitle("QR-Code scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
    }
}

/// QR-Scanner auf Basis von AVFoundation (`AVCaptureMetadataOutput`).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onScan = onScan
    }

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let captureSession = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "de.doorzign.app.scanner")
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didScan = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  captureSession.canAddInput(input)
            else { return }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else { return }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: captureSession)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            didScan = false
            // AVCaptureSession ist nicht Sendable, start/stop auf der seriellen sessionQueue ist aber Apples Vorgabe.
            nonisolated(unsafe) let session = captureSession
            sessionQueue.async { if !session.isRunning { session.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // AVCaptureSession ist nicht Sendable, start/stop auf der seriellen sessionQueue ist aber Apples Vorgabe.
            nonisolated(unsafe) let session = captureSession
            sessionQueue.async { if session.isRunning { session.stopRunning() } }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let value = metadataObjects
                .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
                .first
            MainActor.assumeIsolated {
                guard !didScan, let value else { return }
                didScan = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onScan?(value)
            }
        }
    }
}

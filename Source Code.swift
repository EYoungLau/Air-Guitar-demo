import SwiftUI
import AVFoundation
import Vision


// 此乃主界面😬
struct ContentView: View {
    @StateObject private var gestureManager = HandGestureManager()
    
    var body: some View {
        ZStack {
            
            CameraPreview(session: gestureManager.captureSession)
                .ignoresSafeArea()
            
            
            VStack {
                Text("Air Guitar")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.top, 40)
                
                Spacer()
                
                VStack(spacing: 15) {
                    Image(systemName: gestureManager.isHandDetected ? "hand.raised.fill" : "hand.raised.slash")
                        .font(.system(size: 40))
                        .foregroundColor(gestureManager.isHandDetected ? .green : .red)
                    
                    Text(gestureManager.currentChord)
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(gestureManager.isHandDetected ? "已识别到手势" : "请将手放在镜头前")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.vertical, 30)
                .padding(.horizontal, 50)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            gestureManager.checkPermissionsAndStart()
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
         
            if let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported {
                if let windowScene = self.window?.windowScene {
                    connection.videoOrientation = videoOrientation(for: windowScene.interfaceOrientation)
                }
            }
        }
        
        private func videoOrientation(for interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch interfaceOrientation {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .landscapeRight
            }
        }
    }
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
    }
}
class HandGestureManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentChord: String = "Ready"
    @Published var isHandDetected: Bool = false
    
    let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private var audioPlayers: [String: AVAudioPlayer] = [:]
    
    private var lastPlayedChord: String = ""
    
    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 1
        setupAudio()
    }
    
    private func setupAudio() {
        let chords = ["C", "G", "Am"]
        for chord in chords {
            if let url = Bundle.main.url(forResource: chord, withExtension: "mp3") {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.prepareToPlay()
                    audioPlayers[chord] = player
                } catch {
                    print("无法加载音频文件: \(chord).mp3")
                }
            }
        }
    }
    
    func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.main.async { self.setupCamera() }
                }
            }
        default:
            break
        }
    }
    
    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480
        
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: frontCamera) else { return }
        
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        
        videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue", qos: .userInteractive))
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoDataOutput) { captureSession.addOutput(videoDataOutput) }
        
        captureSession.commitConfiguration()
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            guard let observation = handPoseRequest.results?.first else {
                DispatchQueue.main.async {
                    self.isHandDetected = false
                    self.lastPlayedChord = "" 
                }
                return
            }
            
            DispatchQueue.main.async { self.isHandDetected = true }
            processHandObservation(observation)
            
        } catch {
            print("Vision error: \(error)")
        }
    }
    
    private func processHandObservation(_ observation: VNHumanHandPoseObservation) {
        guard let thumbTip = try? observation.recognizedPoint(.thumbTip),
              let indexTip = try? observation.recognizedPoint(.indexTip),
              let middleTip = try? observation.recognizedPoint(.middleTip),
              let ringTip = try? observation.recognizedPoint(.ringTip) else { return }
        
        guard thumbTip.confidence > 0.5 else { return }
        
        let thumbPoint = CGPoint(x: thumbTip.location.x, y: thumbTip.location.y)
        let indexPoint = CGPoint(x: indexTip.location.x, y: indexTip.location.y)
        let middlePoint = CGPoint(x: middleTip.location.x, y: middleTip.location.y)
        let ringPoint = CGPoint(x: ringTip.location.x, y: ringTip.location.y)
        
        let pinchThreshold: CGFloat = 0.08
        let distanceToIndex = distance(from: thumbPoint, to: indexPoint)
        let distanceToMiddle = distance(from: thumbPoint, to: middlePoint)
        let distanceToRing = distance(from: thumbPoint, to: ringPoint)
      
        let minDistance = min(distanceToIndex, min(distanceToMiddle, distanceToRing))
        
        if minDistance < pinchThreshold {
            if minDistance == distanceToIndex {
                triggerChord("C")
            } else if minDistance == distanceToMiddle {
                triggerChord("G")
            } else if minDistance == distanceToRing {
                triggerChord("Am")
            }
        } else {
            DispatchQueue.main.async { self.lastPlayedChord = "" }
        }
    }
    
    private func triggerChord(_ chord: String) {
        if lastPlayedChord != chord {
            lastPlayedChord = chord
            DispatchQueue.main.async {
                self.currentChord = chord + " Chord"
                self.audioPlayers[chord]?.currentTime = 0
                self.audioPlayers[chord]?.play()
            }
        }
    }
    
    private func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        return hypot(p1.x - p2.x, p1.y - p2.y)
    }
}

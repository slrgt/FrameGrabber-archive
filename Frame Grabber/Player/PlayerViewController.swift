import UIKit
import AVKit

class PlayerViewController: UIViewController {

    var videoManager: VideoManager!
    var settings = UserDefaults.standard

    private var playbackController: PlaybackController?

    private lazy var timeFormatter = VideoTimeFormatter()

    @IBOutlet private var backgroundView: BlurredImageView!
    @IBOutlet private var playerView: ZoomingPlayerView!
    @IBOutlet private var loadingView: PlayerLoadingView!
    @IBOutlet private var titleView: PlayerTitleView!
    @IBOutlet private var controlsView: PlayerControlsView!

    private var isScrubbing: Bool {
        return controlsView.timeSlider.isInteracting
    }

    private var isSeeking: Bool {
        return playbackController?.isSeeking ?? false
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override var prefersStatusBarHidden: Bool {
        let verticallyCompact = traitCollection.verticalSizeClass == .compact
        return verticallyCompact || shouldHideStatusBar
    }

    // For seamless transition from status bar to non status bar view controller, need to
    // a) keep `prefersStatusBarHidden` false until `viewWillAppear` and b) animate change.
    private var shouldHideStatusBar = false {
        didSet {
            UIView.animate(withDuration: 0.15) {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        loadPreviewImage()
        loadVideo()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        shouldHideStatusBar = true
    }
}

// MARK: - Actions

private extension PlayerViewController {

    @IBAction func done() {
        videoManager.cancelAllRequests()
        playbackController?.pause()
        dismiss(animated: true)
    }

    @IBAction func playOrPause() {
        guard !isScrubbing else { return }
        playbackController?.playOrPause()
    }

    func stepBackward() {
        guard !isScrubbing else { return }
        playbackController?.step(byCount: -1)
    }

    func stepForward() {
        guard !isScrubbing else { return }
        playbackController?.step(byCount: 1)
    }

    @IBAction func shareCurrentFrame() {
        guard !isScrubbing,
            let item = playbackController?.currentItem else { return }

        playbackController?.pause()
        generateFrameAndShare(from: item.asset, at: item.currentTime())
    }

    @IBAction func scrub(_ sender: TimeSlider) {
        playbackController?.seeker.smoothlySeek(to: sender.time)
        // When scrubbing, display slider time instead of player time.
        updateSlider(withTime: sender.time)
        updateTimeLabel(withTime: sender.time)
    }
}

// MARK: - PlaybackControllerDelegate

extension PlayerViewController: PlaybackControllerDelegate {

    func player(_ player: AVPlayer, didUpdateStatus status: AVPlayerStatus) {
        if status == .failed {
            presentAlert(.playbackFailed { _ in self.done() })
        }

        updatePlayerControlsEnabled()
        updatePreviewImage()
    }

    func currentPlayerItem(_ playerItem: AVPlayerItem, didUpdateStatus status: AVPlayerItemStatus) {
        if status == .failed {
            presentAlert(.playbackFailed { _ in self.done() })
        }

        updatePlayerControlsEnabled()
        updatePreviewImage()
    }

    func player(_ player: AVPlayer, didPeriodicUpdateAtTime time: CMTime) {
        updateSlider(withTime: time)
        updateTimeLabel(withTime: time)
    }

    func player(_ player: AVPlayer, didUpdateTimeControlStatus status: AVPlayerTimeControlStatus) {
        updatePlayButton(withStatus: status)
    }

    func currentPlayerItem(_ playerItem: AVPlayerItem, didUpdateDuration duration: CMTime) {
        updateSlider(withDuration: duration)
    }

    func currentPlayerItem(_ playerItem: AVPlayerItem, didUpdateTracks tracks: [AVPlayerItemTrack]) {
        updateDetailLabels()
    }
}

// MARK: - ZoomingPlayerViewDelegate

extension PlayerViewController: ZoomingPlayerViewDelegate {

    func playerView(_ playerView: ZoomingPlayerView, didUpdateReadyForDisplay ready: Bool) {
        updatePreviewImage()
    }
}

// MARK: - Private

private extension PlayerViewController {

    func configureViews() {
        playerView.delegate = self

        controlsView.previousButton.repeatAction = { [weak self] in
            self?.stepBackward()
        }

        controlsView.nextButton.repeatAction = { [weak self] in
            self?.stepForward()
        }

        configureGestures()

        updatePlayButton(withStatus: .paused)
        updateSlider(withDuration: .zero)
        updateSlider(withTime: .zero)
        updateTimeLabel(withTime: .zero)
        updateDetailLabels()
        updatePlayerControlsEnabled()
        updateLoadingProgress(with: nil)
        updatePreviewImage()
    }

    func configureGestures() {
        let swipeRecognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeRecognizer.direction = .down
        playerView.addGestureRecognizer(swipeRecognizer)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapRecognizer.require(toFail: playerView.doubleTapToZoomRecognizer)
        tapRecognizer.require(toFail: swipeRecognizer)
        playerView.addGestureRecognizer(tapRecognizer)
    }

    @objc func handleTap(sender: UIGestureRecognizer) {
        guard sender.state == .ended else { return }
        titleView.toggleHidden(animated: true)
        controlsView.toggleHidden(animated: true)
    }

    @objc func handleSwipeDown(sender: UIGestureRecognizer) {
        guard sender.state == .ended else { return }
        done()
    }

    // MARK: Sync Player UI

    func updatePlayerControlsEnabled() {
        let enabled = (playbackController?.isReadyToPlay ?? false)
            && !videoManager.isGeneratingFrame

        controlsView.setControlsEnabled(enabled)
    }

    func updatePreviewImage() {
        let isReady = (playbackController?.isReadyToPlay ?? false) && playerView.isReadyForDisplay
        loadingView.imageView.isHidden = isReady
    }

    func updateLoadingProgress(with progress: Float?) {
        loadingView.setProgress(progress, animated: true)
    }

    func updatePlayButton(withStatus status: AVPlayerTimeControlStatus) {
        controlsView.playButton.setTimeControlStatus(status)
    }

    func updateDetailLabels() {
        let asset = videoManager.asset
        let fps = playbackController?.frameRate

        let dimensions = NumberFormatter().string(fromPixelWidth: asset.pixelWidth, height: asset.pixelHeight)
        let frameRate = fps.flatMap { NumberFormatter.frameRateFormatter().string(from: $0) }
        // Frame rate usually arrives later. Fade it in.
        titleView.setDetailLabels(for: dimensions, frameRate: frameRate, animated: true)
    }

    func updateTimeLabel(withTime time: CMTime) {
        let showMilliseconds = playbackController?.isPlaying == false
        let formattedTime = timeFormatter.string(fromCurrentTime: time, includeMilliseconds: showMilliseconds)
        controlsView.timeLabel.text = formattedTime
    }

    func updateSlider(withTime time: CMTime) {
        guard !isScrubbing && !isSeeking else { return }
        controlsView.timeSlider.time = time
    }

    func updateSlider(withDuration duration: CMTime) {
        controlsView.timeSlider.duration = duration
    }

    // MARK: Video Loading

    func loadPreviewImage() {
        let size = loadingView.imageView.bounds.size.scaledToScreen
        let config = ImageConfig(size: size, mode: .aspectFit, options: .default())

        videoManager.posterImage(with: config) { [weak self] image, _ in
            guard let image = image else { return }
            self?.loadingView.imageView.image = image
            // use same image for background (ignoring different size/content mode as it's blurred)
            self?.backgroundView.imageView.image = image
            self?.updatePreviewImage()
        }
    }

    func loadVideo() {
        videoManager.downloadingPlayerItem(progressHandler: { [weak self] progress in
            self?.updateLoadingProgress(with: Float(progress))

        }, resultHandler: { [weak self] playerItem, info in
            self?.updateLoadingProgress(with: nil)

            guard !info.isCancelled else { return }

            if let playerItem = playerItem {
                self?.configurePlayer(with: playerItem)
            } else {
                self?.presentAlert(.videoLoadingFailed { _ in self?.done() })
            }
        })
    }

    func configurePlayer(with playerItem: AVPlayerItem) {
        playbackController = PlaybackController(playerItem: playerItem)
        playbackController?.delegate = self
        playerView.player = playbackController?.player

        playbackController?.play()
    }

    // MARK: Image Generation

    func generateFrameAndShare(from asset: AVAsset, at time: CMTime) {
        videoManager.frame(for: asset, at: time) { [weak self] result in
            self?.updatePlayerControlsEnabled()

            switch (result) {
            case .cancelled:
                break
            case .failed:
                self?.presentAlert(.imageGenerationFailed())
            case .succeeded(let image, _, _):
                self?.shareImage(image)
            }
        }

        updatePlayerControlsEnabled()
    }

    func shareImage(_ image: UIImage) {
        // If creation fails, share plain image without metadata.
        if settings.includeMetadata,
            let metadataImage = videoManager.jpgImageDataByAddingAssetMetadata(to: image, quality: 1) {

            shareItem(metadataImage)
        } else {
            shareItem(image)
        }
    }

    func shareItem(_ item: Any) {
        let shareController = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        present(shareController, animated: true)
    }
}

//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.


import UIKit
import CoreImage
import Verge
import PixelEngine

final class _ImageView: UIImageView, HardwareImageViewType {
  
  func display(image: CIImage) {
    
    func setImage(image: UIImage) {

      assert(image.scale == 1)
      self.image = image
    }
    
    let uiImage: UIImage
    
    let _image = image
    
    if let cgImage = _image.cgImage {
      uiImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    } else {
      //      assertionFailure()
      // Displaying will be slow in iOS13
      uiImage = UIImage(
        ciImage: _image.transformed(
          by: .init(
            translationX: -_image.extent.origin.x,
            y: -_image.extent.origin.y
          )),
        scale: 1,
        orientation: .up
      )
    }
    
    setImage(image: uiImage)
  }
}

/**
 A view that previews how crops the image.
 */
public final class CropView: UIView, UIScrollViewDelegate {
  
  public struct State: Equatable {
    enum ModifiedSource: Equatable {
      case fromState
      case fromScrollView
      case fromGuide
    }
    
    public fileprivate(set) var proposedCropAndRotate: CropAndRotate?
    fileprivate var modifiedSource: ModifiedSource?
    
    public fileprivate(set) var frame: CGRect = .zero
    fileprivate var hasLoaded = false
  }
  
  /**
   A view that covers the area out of cropping extent.
   */
  public private(set) weak var cropOutsideOverlay: UIView?
    
  /**
   An image view that displayed in the scroll view.
   */
  #if true
  private let imageView = _ImageView()
  #else
  private let imageView: UIView & HardwareImageViewType = {
    #if canImport(MetalKit) && !targetEnvironment(simulator)
    return MetalImageView()
    #else
    return GLImageView()
    #endif
  }()
  #endif
  private let scrollView = _CropScrollView()
  
  /**
   a guide view that displayed on guide container view.
   */
  private lazy var guideView = _InteractiveCropGuideView(containerView: self, imageView: self.imageView)
  
  public let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)
  
  private var subscriptions = Set<VergeAnyCancellable>()
  
  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let throttle = Debounce(interval: 1)
  
  public convenience init(editingStack: EditingStack) {
    self.init()
    
    editingStack.sinkState { [weak self] state in
      
      guard let self = self else { return }
      
      state.ifChanged(\.cropRect) { cropRect in
        
        self.setCropAndRotate(cropRect)
      }
      
      state.ifChanged(\.targetOriginalSizeImage) { image in
        guard let image = image else { return }
        self.setImage(image)
      }
    }
    .store(in: &subscriptions)
    
    store.sinkState { state in
            
      state.ifChanged(\.proposedCropAndRotate) { cropAndRotate in
        guard let cropAndRotate = cropAndRotate else { return }
        editingStack.crop(cropAndRotate)
      }
    }
    .store(in: &subscriptions)
    
  }
  
  private init() {
    super.init(frame: .zero)
    
    clipsToBounds = false
    
    addSubview(scrollView)
    addSubview(guideView)
    
    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    scrollView.delegate = self
        
    guideView.didChange = { [weak self] in
      guard let self = self else { return }
      self.didChangeGuideViewWithDelay()
    }
    
    guideView.willChange = { [weak self] in
      guard let self = self else { return }
      self.willChangeGuideView()
    }
    
    #if DEBUG
    store.sinkState { state in
      EditorLog.debug(state.primitive)
    }
    .store(in: &subscriptions)
         
    #endif
    
    store.sinkState(queue: .mainIsolated()) { [weak self] state in
      
      guard let self = self else { return }
      
      state.ifChanged(\.proposedCropAndRotate, \.frame) { cropAndRotate, frame in
        
        guard frame != .zero else { return }
                
        if let cropAndRotate = cropAndRotate, state.modifiedSource != .fromScrollView {
          self.updateScrollContainerView(
            by: cropAndRotate,
            animated: state.hasLoaded,
            animatesRotation: state.hasChanges(\.proposedCropAndRotate?.rotation)
          )
        } else {
          // TODO:
        }
      }
    }
    .store(in: &subscriptions)
  }
  
  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override public func layoutSubviews() {
    super.layoutSubviews()
    
    store.commit {
      if $0.frame != frame {
        $0.frame = frame
      }
    }
          
    if let outOfBoundsOverlay = cropOutsideOverlay {
      outOfBoundsOverlay.frame.size = .init(width: 1000, height: 1000)
      outOfBoundsOverlay.center = center
    }
  }
  
  override public func didMoveToSuperview() {
    super.didMoveToSuperview()
    
    DispatchQueue.main.async { [self] in
      store.commit {
        $0.hasLoaded = superview != nil
      }
    }
    
  }
  
  public func setImage(_ ciImage: CIImage) {        
    imageView.display(image: ciImage)
  }
  
  public func resetCropAndRotate() {
    store.commit {
      $0.proposedCropAndRotate = $0.proposedCropAndRotate?.makeInitial()
      $0.modifiedSource = .fromState
    }
    
    guideView.setLockedAspectRatio(nil)
  }
  
  public func setRotation(_ rotation: CropAndRotate.Rotation) {
    store.commit {
      $0.proposedCropAndRotate?.rotation = rotation
      $0.modifiedSource = .fromState
    }
  }
  
  public func setCropAndRotate(_ cropAndRotate: CropAndRotate) {
    store.commit {
      $0.proposedCropAndRotate = cropAndRotate
      $0.modifiedSource = .fromState
    }
  }
  
  public func setCroppingAspectRatio(_ ratio: PixelAspectRatio) {
    
    store.commit {
      $0.proposedCropAndRotate?.updateCropExtent(by: ratio)
      $0.proposedCropAndRotate?.preferredAspectRatio = ratio
      $0.modifiedSource = .fromState
    }
  }
  
  /**
   Displays a view as an overlay.
   e.g. grid view
   */
  public func setCropInsideOverlay(_ view: CropInsideOverlayBase) {
    guideView.setCropInsideOverlay(view)
  }
  
  /**
   Displays an overlay that covers the area out of cropping extent.
   Given view's frame would be adjusted automatically.
   
   - Attention: view's userIntereactionEnabled turns off
   */
  public func setCropOutsideOverlay(_ view: CropOutsideOverlayBase) {
    
    cropOutsideOverlay?.removeFromSuperview()
    
    cropOutsideOverlay = view
    view.isUserInteractionEnabled = false
    
    // TODO: Unsafe operation.
    insertSubview(view, aboveSubview: scrollView)
    
    guideView.setCropOutsideOverlay(view)
    
    setNeedsLayout()
    layoutIfNeeded()
  }
  
  private func updateScrollContainerView(
    by cropAndRotate: CropAndRotate,
    animated: Bool,
    animatesRotation: Bool
  ) {
    
    func perform() {
      frame: do {
        let insets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let bounds = self.bounds.inset(by: insets)
        
        let size: CGSize
        switch cropAndRotate.rotation {
        case .angle_0:
          size = cropAndRotate.cropExtent.size.aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(cropAndRotate.preferredAspectRatio)
        case .angle_90:
          size = cropAndRotate.cropExtent.size.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(cropAndRotate.preferredAspectRatio?.swapped())
        case .angle_180:
          size = cropAndRotate.cropExtent.size.aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(cropAndRotate.preferredAspectRatio)
        case .angle_270:
          size = cropAndRotate.cropExtent.size.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(cropAndRotate.preferredAspectRatio?.swapped())
        }
        
        scrollView.transform = cropAndRotate.rotation.transform
        
        scrollView.frame = .init(
          origin: .init(
            x: insets.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: insets.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )
      }
      
      applyLayoutDescendants: do {
        guideView.frame = scrollView.frame
      }
      
      zoom: do {
        UIView.performWithoutAnimation {
          let currentZoomScale = scrollView.zoomScale
          scrollView.zoomScale = 1
          scrollView.contentSize = cropAndRotate.scrollViewContentSize()
          scrollView.zoomScale = currentZoomScale
        }
        imageView.bounds = .init(origin: .zero, size: cropAndRotate.scrollViewContentSize())
        
        let (min, max) = cropAndRotate.calculateZoomScale(scrollViewBounds: scrollView.bounds)
        
        scrollView.minimumZoomScale = min
        scrollView.maximumZoomScale = max
        
        scrollView.zoom(to: cropAndRotate.cropExtent.cgRect, animated: false)
      }
      
    }
    
    if animated {
      layoutIfNeeded()
            
      if animatesRotation {
        
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.startAnimation()
        }
        
        UIViewPropertyAnimator(duration: 0.12, dampingRatio: 1) {
          self.guideView.alpha = 0
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.addCompletion { _ in
            UIViewPropertyAnimator(duration: 0.5, dampingRatio: 1) {
              self.guideView.alpha = 1
            }
            .startAnimation(afterDelay: 0.8)
          }
          $0.startAnimation()
        }
        
      } else {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
          self.layoutIfNeeded()
        }&>.do {
          $0.startAnimation()
        }
      }
      
    } else {
      UIView.performWithoutAnimation {
        layoutIfNeeded()
        perform()
      }
    }
  }
  
  @inline(__always)
  private func willChangeGuideView() {
    throttle.on { /* for debounce */ }
  }
  
  @inline(__always)
  private func didChangeGuideViewWithDelay() {
    throttle.on { [weak self] in
      
      guard let self = self else { return }
      
      self.store.commit {
        let rect = self.guideView.convert(self.guideView.bounds, to: self.imageView)
        if var crop = $0.proposedCropAndRotate {
          // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
          crop.cropExtent = .init(cgRect: rect)
          $0.proposedCropAndRotate = crop
          $0.modifiedSource = .fromGuide
        } else {
          assertionFailure()
        }
      }
    }
  }
  
  @inline(__always)
  private func didChangeScrollView() {
    store.commit {
      let rect = scrollView.convert(scrollView.bounds, to: imageView)
      
      if var crop = $0.proposedCropAndRotate {
        // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
        crop.cropExtent = .init(cgRect: rect)
        $0.proposedCropAndRotate = crop
        $0.modifiedSource = .fromScrollView
      } else {
        assertionFailure()
      }
    }
  }
  
  // MARK: UIScrollViewDelegate
  
  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return imageView
  }
  
  public func scrollViewDidZoom(_ scrollView: UIScrollView) {
    func adjustFrameToCenterOnZooming() {
      var frameToCenter = imageView.frame
      
      // center horizontally
      if frameToCenter.size.width < scrollView.bounds.width {
        frameToCenter.origin.x = (scrollView.bounds.width - frameToCenter.size.width) / 2
      } else {
        frameToCenter.origin.x = 0
      }
      
      // center vertically
      if frameToCenter.size.height < scrollView.bounds.height {
        frameToCenter.origin.y = (scrollView.bounds.height - frameToCenter.size.height) / 2
      } else {
        frameToCenter.origin.y = 0
      }
      
      imageView.frame = frameToCenter
    }
    
    adjustFrameToCenterOnZooming()
  }
  
  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guideView.willBeginScrollViewAdjustment()
  }
  
  public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    guideView.willBeginScrollViewAdjustment()
  }
  
  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      didChangeScrollView()
      guideView.didEndScrollViewAdjustment()
    }
  }
  
  public func scrollViewDidEndZooming(
    _ scrollView: UIScrollView,
    with view: UIView?,
    atScale scale: CGFloat
  ) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }
  
  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }
}

extension CropAndRotate {
  fileprivate func scrollViewContentSize() -> CGSize {
    imageSize.cgSize
  }
  
  fileprivate func calculateZoomScale(scrollViewBounds: CGRect) -> (min: CGFloat, max: CGFloat) {
    let minXScale = scrollViewBounds.width / imageSize.cgSize.width
    let minYScale = scrollViewBounds.height / imageSize.cgSize.height
        
    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
    
    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
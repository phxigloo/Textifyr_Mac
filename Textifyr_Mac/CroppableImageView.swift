import SwiftUI
import AppKit

/// A reusable image view with a draggable, resizable crop rectangle overlay.
/// The user adjusts the crop region and confirms to receive the cropped CGImage.
struct CroppableImageView: View {
    let image: CGImage
    let onCrop: (CGImage) -> Void
    let onCancel: () -> Void

    /// Crop rectangle in normalized coordinates (0…1 relative to image dimensions).
    @State private var cropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let imageSize = CGSize(width: image.width, height: image.height)
                let displaySize = aspectFitSize(imageSize: imageSize, containerSize: geo.size)
                let origin = CGPoint(
                    x: (geo.size.width  - displaySize.width)  / 2,
                    y: (geo.size.height - displaySize.height) / 2
                )

                ZStack {
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)

                    CropOverlayView(cropRect: $cropRect, displaySize: displaySize, origin: origin)
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Reset") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        cropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    if let cropped = cropImage() { onCrop(cropped) }
                } label: {
                    Label("Crop & Recognise", systemImage: "crop")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func cropImage() -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let rect = CGRect(
            x: cropRect.origin.x * imgW,
            y: cropRect.origin.y * imgH,
            width: max(cropRect.width  * imgW, 1),
            height: max(cropRect.height * imgH, 1)
        )
        return image.cropping(to: rect)
    }

    private func aspectFitSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let ratio = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }
}

// MARK: - Crop Overlay

/// Draws a dimmed overlay with a clear crop cutout and draggable corner/edge handles.
/// All gestures compute absolute offsets from `dragStartRect` to avoid accumulation drift.
private struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let displaySize: CGSize
    let origin: CGPoint

    @State private var dragStartRect: CGRect?

    private let minSize: CGFloat    = 0.05
    private let handleRadius: CGFloat = 8

    private var screenRect: CGRect {
        CGRect(
            x: origin.x + cropRect.origin.x * displaySize.width,
            y: origin.y + cropRect.origin.y * displaySize.height,
            width:  cropRect.width  * displaySize.width,
            height: cropRect.height * displaySize.height
        )
    }

    var body: some View {
        ZStack {
            CropMask(rect: screenRect)
                .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            Rectangle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
                .allowsHitTesting(false)

            ruleOfThirdsGrid.allowsHitTesting(false)

            Color.clear
                .frame(width: max(screenRect.width - 32, 10), height: max(screenRect.height - 32, 10))
                .contentShape(Rectangle())
                .position(x: screenRect.midX, y: screenRect.midY)
                .gesture(moveDragGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }

            cornerHandle(at: .topLeading)
            cornerHandle(at: .topTrailing)
            cornerHandle(at: .bottomLeading)
            cornerHandle(at: .bottomTrailing)

            edgeHandle(at: .top)
            edgeHandle(at: .bottom)
            edgeHandle(at: .leading)
            edgeHandle(at: .trailing)
        }
    }

    // MARK: Rule of thirds

    @ViewBuilder private var ruleOfThirdsGrid: some View {
        let r = screenRect
        Path { p in
            p.move(to: CGPoint(x: r.minX + r.width / 3, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + r.width / 3, y: r.maxY))
            p.move(to: CGPoint(x: r.minX + 2 * r.width / 3, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + 2 * r.width / 3, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: r.minY + r.height / 3))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height / 3))
            p.move(to: CGPoint(x: r.minX, y: r.minY + 2 * r.height / 3))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * r.height / 3))
        }
        .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
    }

    // MARK: Corner handles

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    @ViewBuilder
    private func cornerHandle(at corner: Corner) -> some View {
        Circle()
            .fill(.white)
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .shadow(radius: 2)
            .position(cornerPosition(corner))
            .gesture(cornerDragGesture(corner))
    }

    private func cornerPosition(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeading:    CGPoint(x: screenRect.minX, y: screenRect.minY)
        case .topTrailing:   CGPoint(x: screenRect.maxX, y: screenRect.minY)
        case .bottomLeading: CGPoint(x: screenRect.minX, y: screenRect.maxY)
        case .bottomTrailing:CGPoint(x: screenRect.maxX, y: screenRect.maxY)
        }
    }

    private func cornerDragGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? cropRect
                if dragStartRect == nil { dragStartRect = cropRect }
                let dx = value.translation.width  / displaySize.width
                let dy = value.translation.height / displaySize.height
                var r = start
                switch corner {
                case .topLeading:    r.origin.x += dx; r.origin.y += dy; r.size.width -= dx; r.size.height -= dy
                case .topTrailing:  r.size.width += dx; r.origin.y += dy; r.size.height -= dy
                case .bottomLeading: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
                case .bottomTrailing:r.size.width += dx; r.size.height += dy
                }
                cropRect = clampRect(r)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    // MARK: Edge handles

    private enum Edge { case top, bottom, leading, trailing }

    @ViewBuilder
    private func edgeHandle(at edge: Edge) -> some View {
        let (pos, size) = edgePositionAndSize(edge)
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: size.width, height: size.height)
            .shadow(radius: 2)
            .position(pos)
            .gesture(edgeDragGesture(edge))
    }

    private func edgePositionAndSize(_ edge: Edge) -> (CGPoint, CGSize) {
        switch edge {
        case .top:     return (CGPoint(x: screenRect.midX, y: screenRect.minY), CGSize(width: 32, height: handleRadius))
        case .bottom:  return (CGPoint(x: screenRect.midX, y: screenRect.maxY), CGSize(width: 32, height: handleRadius))
        case .leading: return (CGPoint(x: screenRect.minX, y: screenRect.midY), CGSize(width: handleRadius, height: 32))
        case .trailing:return (CGPoint(x: screenRect.maxX, y: screenRect.midY), CGSize(width: handleRadius, height: 32))
        }
    }

    private func edgeDragGesture(_ edge: Edge) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? cropRect
                if dragStartRect == nil { dragStartRect = cropRect }
                let dx = value.translation.width  / displaySize.width
                let dy = value.translation.height / displaySize.height
                var r = start
                switch edge {
                case .top:     r.origin.y += dy; r.size.height -= dy
                case .bottom:  r.size.height += dy
                case .leading: r.origin.x += dx; r.size.width -= dx
                case .trailing:r.size.width += dx
                }
                cropRect = clampRect(r)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    // MARK: Move gesture

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? cropRect
                if dragStartRect == nil { dragStartRect = cropRect }
                let dx = value.translation.width  / displaySize.width
                let dy = value.translation.height / displaySize.height
                var r = start
                r.origin.x = max(0, min(r.origin.x + dx, 1 - r.width))
                r.origin.y = max(0, min(r.origin.y + dy, 1 - r.height))
                cropRect = r
            }
            .onEnded { _ in dragStartRect = nil }
    }

    // MARK: Clamping

    private func clampRect(_ r: CGRect) -> CGRect {
        var result = r
        if result.width  < minSize { result.size.width  = minSize; result.origin.x = min(result.origin.x, 1 - minSize) }
        if result.height < minSize { result.size.height = minSize; result.origin.y = min(result.origin.y, 1 - minSize) }
        result.origin.x = max(0, result.origin.x)
        result.origin.y = max(0, result.origin.y)
        if result.maxX > 1 { result.size.width  = 1 - result.origin.x }
        if result.maxY > 1 { result.size.height = 1 - result.origin.y }
        return result
    }
}

// MARK: - Crop Mask Shape

private struct CropMask: Shape {
    let rect: CGRect
    func path(in frame: CGRect) -> Path {
        var path = Path()
        path.addRect(frame)
        path.addRect(rect)
        return path
    }
}

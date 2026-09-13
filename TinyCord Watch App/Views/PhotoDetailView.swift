//
//  PhotoDetailView.swift
//  TinyCord Watch App
//

import SwiftUI

struct PhotoDetailView: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var zoomScale: Double = 1.0
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero
    @State private var showControls: Bool = true
    @FocusState private var isCrownFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CachedGIFImageView(url: imageURL, contentMode: .fit, cornerRadius: 0)
                .scaleEffect(zoomScale)
                .offset(dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if zoomScale > 1.0 {
                                dragOffset = CGSize(
                                    width: lastDragOffset.width + value.translation.width,
                                    height: lastDragOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { _ in
                            lastDragOffset = dragOffset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if zoomScale > 1.0 {
                            zoomScale = 1.0
                            dragOffset = .zero
                            lastDragOffset = .zero
                        } else {
                            zoomScale = 2.5
                        }
                    }
                }
                .onTapGesture(count: 1) {
                    withAnimation {
                        showControls.toggle()
                    }
                }

            // Zoom indicator overlay when zoomed in
            if showControls && zoomScale > 1.05 {
                VStack {
                    HStack {
                        Spacer()
                        Text(String(format: "%.1fx", zoomScale))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                    }
                    Spacer()
                }
            }
        }
        // Explicitly opened media is not part of the chat viewport queue.
        .environment(\.chatMediaLoader, nil)
        .focusable()
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $zoomScale,
            from: 1.0,
            through: 5.0,
            by: 0.15,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: zoomScale) { newScale in
            if newScale <= 1.0 {
                withAnimation {
                    dragOffset = .zero
                    lastDragOffset = .zero
                }
            }
        }
        .onAppear {
            isCrownFocused = true
        }
    }
}

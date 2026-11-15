#!/usr/bin/env swift
// Draws the tvOS static Top Shelf images (shown when the Top Shelf extension has nothing to show)
// from the App Store icon's layers: the back layer stretched to fill, the middle and front layers
// centred over it at about three quarters of the height.
//
//   swift scripts/make_top_shelf.swift
//
// Run from the repo root. Writes the four PNGs the brand assets' two Top Shelf image sets expect.
import AppKit

let brand = "AppleTV/RabbitEars/RabbitEars/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
let stack = "\(brand)/App Icon - App Store.imagestack"
let layers = ["Back", "Middle", "Front"].map { name -> CGImage in
    let dir = "\(stack)/\(name).imagestacklayer/Content.imageset"
    guard let file = try? FileManager.default.contentsOfDirectory(atPath: dir).first(where: { $0.hasSuffix(".png") }),
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(file)") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("no \(name) layer image in \(dir)")
    }
    return image
}

let outputs: [(file: String, width: Int, height: Int)] = [
    ("Top Shelf Image.imageset/shelf_1920x720.png", 1920, 720),
    ("Top Shelf Image.imageset/shelf_3840x1440.png", 3840, 1440),
    ("Top Shelf Image Wide.imageset/shelfwide_2320x720.png", 2320, 720),
    ("Top Shelf Image Wide.imageset/shelfwide_4640x1440.png", 4640, 1440),
]

for output in outputs {
    let width = CGFloat(output.width), height = CGFloat(output.height)
    guard let context = CGContext(data: nil, width: output.width, height: output.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
    context.interpolationQuality = .high
    context.draw(layers[0], in: CGRect(x: 0, y: 0, width: width, height: height))

    // The layers are 1280 x 768 with the artwork spanning about 70% of their height, centred.
    let layerHeight = height * 1.05
    let layerWidth = layerHeight * CGFloat(layers[1].width) / CGFloat(layers[1].height)
    let rect = CGRect(x: (width - layerWidth) / 2, y: (height - layerHeight) / 2, width: layerWidth, height: layerHeight)
    for layer in layers.dropFirst() { context.draw(layer, in: rect) }

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(brand)/\(output.file)") as CFURL,
                                                            "public.png" as CFString, 1, nil) else { fatalError("write") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(output.file)")
}

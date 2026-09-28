// 生成 1024x1024 应用图标 PNG：Firebase 黄→橙渐变圆角方块 + 白色上传箭头。
// 用法: swift scripts/make-icon.swift <输出路径.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon1024.png"

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("无法创建图形上下文")
}

// macOS 图标需要自带圆角与透明外沿（icns 不会自动加圆角）
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius = size * 0.2320
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
ctx.clip()

// 背景：Firebase 黄 → 橙，垂直渐变
let colors = [
    CGColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1),
    CGColor(red: 0.98, green: 0.42, blue: 0.05, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 白色上传箭头：箭头（向上）+ 箭杆 + 顶部横杠
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

let cx = size / 2
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: cx, y: size * 0.72))
arrow.addLine(to: CGPoint(x: cx - size * 0.17, y: size * 0.46))
arrow.addLine(to: CGPoint(x: cx + size * 0.17, y: size * 0.46))
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.fillPath()

ctx.fill(CGRect(x: cx - size * 0.055, y: size * 0.30, width: size * 0.11, height: size * 0.20))

ctx.addPath(CGPath(
    roundedRect: CGRect(x: size * 0.28, y: size * 0.20, width: size * 0.44, height: size * 0.05),
    cornerWidth: size * 0.025,
    cornerHeight: size * 0.025,
    transform: nil
))
ctx.fillPath()

guard let image = ctx.makeImage() else {
    fatalError("渲染失败")
}
let url = URL(fileURLWithPath: output) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("无法创建输出文件: \(output)")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("图标已生成: \(output)")

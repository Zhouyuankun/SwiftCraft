import Foundation
import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState

    // 天空渐变管线
    let skyPipelineState: MTLRenderPipelineState
    let skyDepthStencilState: MTLDepthStencilState
    
    // 从 4×4 图集拆分得到的 16 层纹理数组，每层拥有独立 mipmap。
    let atlasTexture: MTLTexture
    
    // 摄像机引用
    var camera: Camera?

    // 当前被屏幕中心准心选中的方块类型；未命中时为 air
    private(set) var targetedBlockType: BlockType = .air
    private var targetedBlock: BlockCoord?
    
    // --- 新增：逻辑更新回调 ---
    var onUpdate: (() -> Void)?

    // 多区块世界：负责区块的动态加载/卸载
    let world: World

    private var frameWindowSampleCount = 0
    private var frameWindowTotalMilliseconds: Double = 0
    private var frameWindowMaximumMilliseconds: Double = 0
    private var frameWindowOverBudgetCount = 0
    private var frameWindowSevereSpikeCount = 0

    init?(metalKitView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.world = World(device: device)

        metalKitView.device = device
        metalKitView.depthStencilPixelFormat = .depth32Float
        // 天空蓝背景
        metalKitView.clearColor = MTLClearColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)

        // 1. 加载图集原图，再拆为独立切片，防止 mipmap 混合相邻材质。
        let textureLoader = MTKTextureLoader(device: device)
        let sourceAtlas: MTLTexture
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]
            sourceAtlas = try textureLoader.newTexture(
                name: "terrain_atlas",
                scaleFactor: 1.0,
                bundle: nil,
                options: options
            )
        } catch {
            print("图集加载失败: \(error)")
            return nil
        }

        let atlasGridSize = 4
        guard sourceAtlas.width % atlasGridSize == 0,
              sourceAtlas.height % atlasGridSize == 0 else {
            print("图集尺寸必须能被 4×4 网格整除")
            return nil
        }
        let tileWidth = sourceAtlas.width / atlasGridSize
        let tileHeight = sourceAtlas.height / atlasGridSize
        let arrayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceAtlas.pixelFormat,
            width: tileWidth,
            height: tileHeight,
            mipmapped: true
        )
        arrayDescriptor.textureType = .type2DArray
        arrayDescriptor.arrayLength = atlasGridSize * atlasGridSize
        arrayDescriptor.storageMode = .private
        arrayDescriptor.usage = .shaderRead

        guard let textureArray = device.makeTexture(descriptor: arrayDescriptor),
              let textureCommandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = textureCommandBuffer.makeBlitCommandEncoder() else {
            print("纹理数组创建失败")
            return nil
        }
        textureArray.label = "Terrain Texture Array"

        for row in 0..<atlasGridSize {
            for col in 0..<atlasGridSize {
                let slice = row * atlasGridSize + col
                blitEncoder.copy(
                    from: sourceAtlas,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: col * tileWidth, y: row * tileHeight, z: 0),
                    sourceSize: MTLSize(width: tileWidth, height: tileHeight, depth: 1),
                    to: textureArray,
                    destinationSlice: slice,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
        }
        blitEncoder.generateMipmaps(for: textureArray)
        blitEncoder.endEncoding()
        textureCommandBuffer.commit()
        textureCommandBuffer.waitUntilCompleted()
        guard textureCommandBuffer.status == .completed else {
            print("纹理数组 mipmap 生成失败: \(textureCommandBuffer.error?.localizedDescription ?? "未知错误")")
            return nil
        }
        atlasTexture = textureArray

        // 2. 配置管线
        let library = device.makeDefaultLibrary()
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        // 修正绕序：由于之前手动调整了顶点，这里使用 CounterClockwise + Back 剔除
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // 4. 深度测试配置
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)!

        // 5. 天空渐变管线（顶点着色器内部生成全屏三角形，无需顶点缓冲区）
        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = library?.makeFunction(name: "sky_vertex")
        skyDescriptor.fragmentFunction = library?.makeFunction(name: "sky_fragment")
        skyDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        skyDescriptor.depthAttachmentPixelFormat = .depth32Float
        skyPipelineState = try! device.makeRenderPipelineState(descriptor: skyDescriptor)

        // 天空的深度状态：不写深度（保证不遮挡地形），lessEqual 让贴在远裁剪面上的天空通过测试
        let skyDepthDesc = MTLDepthStencilDescriptor()
        skyDepthDesc.depthCompareFunction = .lessEqual
        skyDepthDesc.isDepthWriteEnabled = false
        skyDepthStencilState = device.makeDepthStencilState(descriptor: skyDepthDesc)!

        super.init()
    }

    func draw(in view: MTKView) {
        let frameStart = ProcessInfo.processInfo.systemUptime
        defer {
            recordFrameCPUTime(
                seconds: ProcessInfo.processInfo.systemUptime - frameStart
            )
        }

        // --- 核心：每一帧开始渲染前，先执行逻辑更新（处理 WASD/Shift 移动） ---
        onUpdate?()
        
        // 确保资源就绪
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let currentCamera = camera else { return }

        // 1. 获取投影矩阵
        let aspectRatio = Float(view.drawableSize.width / view.drawableSize.height)
        let projectionMatrix = matrix_float4x4.perspective(
            degrees: 45,
            aspectRatio: aspectRatio,
            near: 0.1,
            far: 100
        )

        // 2. 从 Camera 获取当前的视图矩阵
        let viewMatrix = currentCamera.getViewMatrix()

        // --- 第一步：绘制天空渐变（先画天空，让它垫在地形后面） ---
        var skyUniforms = SkyUniforms(
            invViewProj: (projectionMatrix * viewMatrix).inverse,
            cameraPos: currentCamera.position
        )
        renderEncoder.setRenderPipelineState(skyPipelineState)
        renderEncoder.setDepthStencilState(skyDepthStencilState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&skyUniforms, length: MemoryLayout<SkyUniforms>.stride, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // --- 第二步：绘制地形（多区块流式加载） ---
        // 计算相机当前所在的区块，动态加载渲染距离内的区块、卸载超出的区块
        let centerChunk = World.worldToChunkCoord(currentCamera.position)
        world.update(center: centerChunk)

        // 从屏幕中心（相机前向）选取 6 格内的第一个实心方块。
        targetedBlock = world.raycast(
            origin: currentCamera.position,
            direction: currentCamera.lookAt,
            maxDistance: 6
        )
        if let target = targetedBlock {
            targetedBlockType = world.blockAtWorld(x: target.x, y: target.y, z: target.z) ?? .air
        } else {
            targetedBlockType = .air
        }

        // 合并 VP 矩阵（区块顶点已是世界坐标，模型矩阵为单位阵）
        var uniforms = Uniforms(modelViewProjectionMatrix: projectionMatrix * viewMatrix)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)

        // 使用背面剔除
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)

        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)

        var highlightUniforms: HighlightUniforms
        if let target = targetedBlock {
            highlightUniforms = HighlightUniforms(
                blockMin: simd_float4(Float(target.x), Float(target.y), Float(target.z), 1),
                blockMax: simd_float4(Float(target.x + 1), Float(target.y + 1), Float(target.z + 1), 1)
            )
        } else {
            highlightUniforms = HighlightUniforms(blockMin: .zero, blockMax: .zero)
        }
        renderEncoder.setFragmentBytes(
            &highlightUniforms,
            length: MemoryLayout<HighlightUniforms>.stride,
            index: 1
        )

        // 逐个绘制所有已加载的区块
        for (_, mesh) in world.loadedChunks {
            renderEncoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        }

        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }

    /// 删除准心当前选中的方块。实际数据由 World 持久保存并负责重建相关网格。
    func removeTargetedBlock() {
        guard let target = targetedBlock else { return }
        if world.removeBlock(at: target) {
            targetedBlock = nil
            targetedBlockType = .air
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func recordFrameCPUTime(seconds: TimeInterval) {
        let milliseconds = seconds * 1_000
        frameWindowSampleCount += 1
        frameWindowTotalMilliseconds += milliseconds
        frameWindowMaximumMilliseconds = max(frameWindowMaximumMilliseconds, milliseconds)
        if milliseconds > 16.7 { frameWindowOverBudgetCount += 1 }
        if milliseconds > 33 { frameWindowSevereSpikeCount += 1 }

        guard frameWindowSampleCount >= 120 else { return }
        let average = frameWindowTotalMilliseconds / Double(frameWindowSampleCount)
        print(String(
            format: "Frame CPU (120): avg %.2f ms, max %.2f ms, >16.7 %d, >33 %d",
            average,
            frameWindowMaximumMilliseconds,
            frameWindowOverBudgetCount,
            frameWindowSevereSpikeCount
        ))
        frameWindowSampleCount = 0
        frameWindowTotalMilliseconds = 0
        frameWindowMaximumMilliseconds = 0
        frameWindowOverBudgetCount = 0
        frameWindowSevereSpikeCount = 0
    }
}

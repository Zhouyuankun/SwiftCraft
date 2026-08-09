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
    
    // 纹理图集
    let atlasTexture: MTLTexture
    
    // 摄像机引用
    var camera: Camera?
    
    // --- 新增：逻辑更新回调 ---
    var onUpdate: (() -> Void)?

    // 多区块世界：负责区块的动态加载/卸载
    let world: World

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

        // 1. 加载图集
        let textureLoader = MTKTextureLoader(device: device)
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: true // 生成多级渐远纹理，远处不闪烁
            ]
            // 请确保 Assets 中有名为 "terrain_atlas" 的图片
            atlasTexture = try textureLoader.newTexture(name: "terrain_atlas", scaleFactor: 1.0, bundle: nil, options: options)
        } catch {
            print("图集加载失败: \(error)")
            return nil
        }

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

        // 合并 VP 矩阵（区块顶点已是世界坐标，模型矩阵为单位阵）
        var uniforms = Uniforms(modelViewProjectionMatrix: projectionMatrix * viewMatrix)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)

        // 使用背面剔除
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)

        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)

        // 逐个绘制所有已加载的区块
        for (_, mesh) in world.loadedChunks {
            renderEncoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        }

        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

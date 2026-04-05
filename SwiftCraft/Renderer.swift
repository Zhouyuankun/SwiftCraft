import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    // 纹理图集
    let atlasTexture: MTLTexture
    
    // 摄像机引用
    var camera: Camera?
    
    // --- 新增：逻辑更新回调 ---
    var onUpdate: (() -> Void)?
    
    // 动态生成的顶点 Buffer
    var vertexBuffer: MTLBuffer?
    var vertexCount: Int = 0
    
    let chunk = Chunk() // 5x5x5 的地形数据

    init?(metalKitView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        
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

        // 2. 生成区块网格
        let vertices = GeometryFactory.generateChunkMesh(chunk: chunk)
        self.vertexCount = vertices.count
        
        if vertexCount > 0 {
            vertexBuffer = device.makeBuffer(bytes: vertices,
                                            length: vertices.count * MemoryLayout<Vertex>.stride,
                                            options: [])
        }

        // 3. 配置管线
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

        super.init()
    }

    func draw(in view: MTKView) {
        // --- 核心：每一帧开始渲染前，先执行逻辑更新（处理 WASD/Shift 移动） ---
        onUpdate?()
        
        // 确保资源就绪
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let vBuffer = vertexBuffer,
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
        
        // 3. 模型矩阵：将 5x5x5 的区块中心移到世界原点附近，方便观察
        let modelMatrix = matrix_float4x4.translation(-2.5, -2.5, -2.5)
        
        // 4. 合并 MVP 矩阵传递给 Shader
        var uniforms = Uniforms(modelViewProjectionMatrix: projectionMatrix * viewMatrix * modelMatrix)
        
        // --- 执行渲染指令 ---
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)
        
        // 使用背面剔除
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        renderEncoder.setFragmentTexture(atlasTexture, index: 0)
        
        // 绘制
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        
        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

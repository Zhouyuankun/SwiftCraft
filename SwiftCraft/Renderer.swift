import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate {
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    // 1. 定义两个 Buffer：一个存顶点，一个存索引
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    
    var rotation: Float = 0
    
    // --- 顶点数据：立方体的 8 个角 ---
    let cubeVertices: [Vertex] = [
        Vertex(position: [-0.5, -0.5,  0.5], color: [1, 0, 0, 1]), // 0: 左下前
        Vertex(position: [ 0.5, -0.5,  0.5], color: [0, 1, 0, 1]), // 1: 右下前
        Vertex(position: [ 0.5,  0.5,  0.5], color: [0, 0, 1, 1]), // 2: 右上前
        Vertex(position: [-0.5,  0.5,  0.5], color: [1, 1, 0, 1]), // 3: 左上前
        Vertex(position: [-0.5, -0.5, -0.5], color: [1, 0, 1, 1]), // 4: 左下后
        Vertex(position: [ 0.5, -0.5, -0.5], color: [0, 1, 1, 1]), // 5: 右下后
        Vertex(position: [ 0.5,  0.5, -0.5], color: [1, 1, 1, 1]), // 6: 右上后
        Vertex(position: [-0.5,  0.5, -0.5], color: [0, 0, 0, 1])  // 7: 左上后
    ]
    
    // --- 索引数据：定义 12 个三角形的连接顺序 ---
    let cubeIndices: [UInt16] = [
        0, 1, 2,  0, 2, 3, // 前面
        4, 6, 5,  4, 7, 6, // 后面
        4, 0, 3,  4, 3, 7, // 左面
        1, 5, 6,  1, 6, 2, // 右面
        3, 2, 6,  3, 6, 7, // 上面
        4, 5, 1,  4, 1, 0  // 下面
    ]

    init?(metalKitView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        
        metalKitView.device = device
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

        // 2. 加载 Shader
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "vertex_main")
        let fragmentFunction = library?.makeFunction(name: "fragment_main")

        // 3. 配置管线
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Pipeline Error: \(error)")
            return nil
        }

        // 4. 配置深度测试
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        // 5. 创建 Buffer
        // 顶点 Buffer
        vertexBuffer = device.makeBuffer(bytes: cubeVertices,
                                        length: cubeVertices.count * MemoryLayout<Vertex>.stride,
                                        options: [])!
        
        // 索引 Buffer
        indexBuffer = device.makeBuffer(bytes: cubeIndices,
                                       length: cubeIndices.count * MemoryLayout<UInt16>.size,
                                       options: [])!

        super.init()
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        rotation += 0.02
        
        // 计算矩阵 (确保你的 Math.swift 已经包含相关的扩展)
        let projection = matrix_float4x4.perspective(
            degrees: 45,
            aspectRatio: Float(view.drawableSize.width / view.drawableSize.height),
            near: 0.1,
            far: 100
        )
        let viewMatrix = matrix_float4x4.translation(0, 0, -4)
        let modelMatrix = matrix_float4x4.rotation(radians: rotation, axis: [1, 1, 0])
        
        var uniforms = Uniforms(modelViewProjectionMatrix: projection * viewMatrix * modelMatrix)

        // 设置绘制状态
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStencilState)
        
        // 绑定顶点数据
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // 绑定矩阵数据
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        // --- 核心变化：使用索引绘制 ---
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: cubeIndices.count,
                                          indexType: .uint16,
                                          indexBuffer: indexBuffer,
                                          indexBufferOffset: 0)
        
        renderEncoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

# Metal 入门指南：逐行解析 Minecraft Voxel 渲染

本指南基于当前项目的代码，逐行解释 Metal 渲染管线的工作原理。

---

## 目录

1. [概览：渲染管线是如何工作的](#1-概览渲染管线是如何工作的)
2. [Shader 文件 (.metal)](#2-shader-文件-metal)
3. [Renderer.swift 中的 Metal 设置](#3-rendererswift-中的-metal-设置)
4. [关键概念解释](#4-关键概念解释)

---

## 1. 概览：渲染管线是如何工作的

```
CPU                          GPU
┌─────────┐                  ┌─────────────┐
│ Swift   │  发送顶点数据    │  顶点着色器  │ ← 你写的 shader
│ 代码    │ ────────────────→│  (Vertex)   │
└─────────┘                  └─────────────┘
                                  │
                                  ▼
                             ┌─────────────┐
                             │  图元装配   │ ← GPU 自动组装三角形
                             └─────────────┘
                                  │
                                  ▼
                             ┌─────────────┐
                             │ 光栅化      │ ← 像素化
                             └─────────────┘
                                  │
                                  ▼
                             ┌─────────────┐
                             │ 片元着色器  │ ← 你写的 shader
                             │ (Fragment) │
                             └─────────────┘
                                  │
                                  ▼
                             ┌─────────────┐
                             │ 帧缓冲      │ ← 最终画面
                             └─────────────┘
```

---

## 2. Shader 文件 (.metal)

### 文件：`Shaders.metal`

```metal
#include <metal_stdlib>
using namespace metal;
```

**解释**：这是每个 Metal shader 文件的标准头部。

- `#include <metal_stdlib>` — 引入 Metal 标准库，提供 `float4`、`float4x4`、`texture2d` 等类型
- `using namespace metal;` — 让你可以直接写 `float4` 而不是 `metal::float4`，类似 C++ 的 using 声明

---

```metal
// 1. 定义与 Swift 中对应的顶点结构
struct Vertex {
    float3 position;
    float4 color;
};
```

**解释**：定义顶点结构，必须和 Swift 端的 `Vertex` 结构完全一致（内存布局相同）。

- `float3` — Metal 内置类型，等价于 `simd_float3`（3 个 float）
- `float4` — 4 个 float，通常用于颜色 (R,G,B,A) 或齐次坐标 (x,y,z,w)
- `position` 和 `color` 的顺序必须和 Swift 端保持一致

---

```metal
// 2. 定义从 Swift 传来的 Uniforms (矩阵)
struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};
```

**解释**：Uniforms 是每次绘制时从 CPU 传递给 GPU 的数据（通常是变换矩阵）。

- `float4x4` — Metal 内置的 4x4 矩阵类型，等价于 `simd_float4x4`
- 这里定义了一个 MVP 矩阵，用于将顶点从模型空间变换到屏幕空间

---

```metal
// 3. 定义从顶点着色器传递到片元着色器的结构
struct VertexOut {
    float4 position [[position]]; // [[position]] 告诉 Metal 这是裁剪空间坐标
    float4 color;
};
```

**解释**：这是顶点着色器的输出结构，会被 GPU 自动插值后传递给片元着色器。

- `[[position]]` — **属性修饰符**，告诉 Metal 这个字段是顶点的裁剪空间坐标
- `float4 position` 必须是这个结构的一员，且用 `[[position]]` 标记
- `float4 color` — 颜色会被自动**插值**：三角形的每个像素都会根据其重心坐标得到一个渐变颜色

---

```metal
// --- 顶点着色器 ---
// vertices: 对应 renderEncoder.setVertexBuffer(..., index: 0)
// uniforms: 对应 renderEncoder.setVertexBytes(..., index: 1)
// vid: 自动生成的顶点索引
vertex VertexOut vertex_main(
    constant Vertex *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint vid [[vertex_id]]
)
```

**解释**：这是顶点着色器函数，由 GPU 为每个顶点调用一次。

- `vertex` — 关键字，声明这是一个顶点着色器
- `VertexOut` — 返回类型，表示这个着色器的输出
- `vertex_main` — 函数名，Swift 端通过这个名字找到这个函数：`library?.makeFunction(name: "vertex_main")`
- `constant Vertex *vertices [[buffer(0)]]` — 从索引 0 的 buffer 读取顶点数据
  - `constant` — 表示只读（GPU 端不修改）
  - `Vertex *` — 指向顶点数组的指针
  - `[[buffer(0)]]` — **缓冲索引修饰符**，对应 Swift 端的 `setVertexBuffer(buffer, offset: 0, index: 0)`
- `constant Uniforms &uniforms [[buffer(1)]]` — 从索引 1 的 buffer 读取 Uniforms 数据
  - `&` 表示引用，不是指针
  - `[[buffer(1)]]` 对应 `setVertexBytes(&uniforms, ..., index: 1)`
- `uint vid [[vertex_id]]` — 自动生成的顶点 ID（0, 1, 2, ...），GPU 为每个顶点自动递增

---

```metal
{
    VertexOut out;

    // 获取当前顶点的位置并转为 float4 (w 分量设为 1.0)
    float4 position = float4(vertices[vid].position, 1.0);

    // 核心：应用 MVP 矩阵变换
    // 在 Metal 中，矩阵乘法通常是 矩阵 * 向量
    out.position = uniforms.modelViewProjectionMatrix * position;

    // 传递颜色给片元着色器（会自动进行线性插值）
    out.color = vertices[vid].color;

    return out;
}
```

**解释**：顶点着色器的主逻辑，对每个顶点执行一次。

- `vertices[vid]` — 用顶点 ID 从数组中取出当前顶点
- `float4(position, 1.0)` — 将 `float3` 扩展为齐次坐标，`w=1` 表示点（`w=0` 表示方向向量）
- `uniforms.modelViewProjectionMatrix * position` — **MVP 矩阵变换**，这是 3D 渲染的核心：
  - 模型矩阵：将物体从模型空间移到世界空间
  - 视图矩阵：将相机放在原点
  - 投影矩阵：将 3D 场景投影到 2D 屏幕
- `out.color = vertices[vid].color` — 直接传递颜色，会在光栅化时被插值

---

```metal
// --- 片元着色器 ---
// stage_in 表示数据来自顶点着色器的输出
fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    // 直接返回颜色
    return in.color;
}
```

**解释**：片元着色器（也称像素着色器），为每个像素执行一次。

- `fragment` — 关键字，声明这是片元着色器
- `float4` — 返回类型，表示最终像素颜色 (R,G,B,A)
- `fragment_main` — 函数名，Swift 端通过 `library?.makeFunction(name: "fragment_main")` 找到
- `VertexOut in [[stage_in]]` — 接收从顶点着色器插值后的数据
  - `[[stage_in]]` — **修饰符**，表示数据来自渲染管线的上一个阶段（顶点着色器）
  - `in` 是参数名（输入），Metal 会自动填充插值后的数据
- `return in.color` — 直接返回插值后的颜色，这就是为什么立方体能显示渐变色

---

## 3. Renderer.swift 中的 Metal 设置

### 文件：`Renderer.swift`

```swift
let device: MTLDevice
let commandQueue: MTLCommandQueue
let pipelineState: MTLRenderPipelineState
let depthStencilState: MTLDepthStencilState
```

**解释**：声明四个核心 Metal 对象。

| 对象 | 作用 |
|------|------|
| `MTLDevice` | GPU 设备抽象，Metal 所有操作的入口 |
| `MTLCommandQueue` | 命令队列，用于提交 GPU 命令 |
| `MTLRenderPipelineState` | 渲染管线状态（包含 vertex/fragment shader） |
| `MTLDepthStencilState` | 深度/模板测试状态 |

---

```swift
guard let device = MTLCreateSystemDefaultDevice(),
      let commandQueue = device.makeCommandQueue() else { return nil }
```

**解释**：初始化 GPU 设备和命令队列。

- `MTLCreateSystemDefaultDevice()` — 获取系统默认的 GPU 设备（Mac 上通常是独立显卡）
- `device.makeCommandQueue()` — 为该 GPU 创建一个命令队列
- `guard let ... else { return nil }` — 如果任何一步失败（没有 GPU、没有 Metal 支持），返回 nil

---

```swift
metalKitView.device = device
metalKitView.depthStencilPixelFormat = .depth32Float
metalKitView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
```

**解释**：配置 MTKView（Metal 视图）。

- `metalKitView.device = device` — 将 GPU 设备关联到视图
- `depthStencilPixelFormat = .depth32Float` — 启用 32 位深度缓冲，用于深度测试（决定谁在前谁在后）
- `clearColor = MTLClearColor(...)` — 每次绘制前清空屏幕的背景色 (R,G,B,A)，这里设置的是深灰色

---

```swift
// 加载 Shader
let library = device.makeDefaultLibrary()
let vertexFunction = library?.makeFunction(name: "vertex_main")
let fragmentFunction = library?.makeFunction(name: "fragment_main")
```

**解释**：从编译好的 Metal 库中加载 shader 函数。

- `device.makeDefaultLibrary()` — 获取默认的 shader 库（Xcode 会自动编译 .metal 文件）
- `library?.makeFunction(name: "vertex_main")` — 按名字查找顶点着色器函数
- 注意：函数名必须和 .metal 文件中的函数名**完全一致**

---

```swift
// 配置管线
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = vertexFunction
pipelineDescriptor.fragmentFunction = fragmentFunction
pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
```

**解释**：配置渲染管线描述符，定义 GPU 如何渲染图形。

- `MTLRenderPipelineDescriptor()` — 管线描述符，包含所有管线配置
- `vertexFunction / fragmentFunction` — 指定使用哪个 shader
- `colorAttachments[0].pixelFormat` — 颜色缓冲的像素格式，通常和视图一致
- `depthAttachmentPixelFormat` — 深度缓冲格式

---

```swift
do {
    pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
} catch {
    print("Pipeline Error: \(error)")
    return nil
}
```

**解释**：创建渲染管线状态（这是编译 shader 的地方）。

- `device.makeRenderPipelineState(descriptor: pipelineDescriptor)` — 创建管线状态对象
- **这是 shader 实际被编译的地方**，如果 shader 有语法错误，会在这里抛出异常
- 管线状态创建后无法修改（immutable），如果需要改 shader 需要重新创建

---

```swift
// 配置深度测试
let depthDescriptor = MTLDepthStencilDescriptor()
depthDescriptor.depthCompareFunction = .less
depthDescriptor.isDepthWriteEnabled = true
depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)!
```

**解释**：配置深度测试，用于处理物体遮挡关系。

- `depthCompareFunction = .less` — 深度测试函数：只有**更近**的像素才会被绘制（.less = 新像素深度 < 旧像素深度）
- `isDepthWriteEnabled = true` — 启用深度写入：成功通过深度测试的像素会写入深度缓冲
- 这就是为什么近处的方块能遮挡远处的方块

---

```swift
// 创建 Buffer
vertexBuffer = device.makeBuffer(
    bytes: cubeVertices,
    length: cubeVertices.count * MemoryLayout<Vertex>.stride,
    options: []
)
```

**解释**：创建存储顶点数据的 GPU buffer。

- `device.makeBuffer(bytes:, length:, options:)` — 在 GPU 上分配一块内存
- `bytes: cubeVertices` — 把 Swift 数组的数据复制进去
- `length:` — 缓冲区大小，用 `MemoryLayout<Vertex>.stride` 计算单个顶点占用的字节数
- `options: []` — 选项：`[]` 表示默认（CPU/GPU 共享内存），还有 `.storageModeShared` 等
- **关键**：数据会被复制到 GPU 内存，之后修改 Swift 端的数组不会影响 GPU 端的数据

---

```swift
indexBuffer = device.makeBuffer(
    bytes: cubeIndices,
    length: cubeIndices.count * MemoryLayout<UInt16>.size,
    options: []
)
```

**解释**：创建存储索引数据的 buffer。

- `UInt16` — 索引类型，最多支持 65536 个顶点（对 Minecraft 来说足够）
- `MemoryLayout<UInt16>.size` — UInt16 占 2 字节，所以索引 buffer 大小是 `36 * 2 = 72` 字节

---

```swift
func draw(in view: MTKView) {
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let descriptor = view.currentRenderPassDescriptor,
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
```

**解释**：`draw(in:)` 是每帧调用的核心渲染函数，获取三个必需的 GPU 对象。

- `commandQueue.makeCommandBuffer()` — 从队列获取一个命令缓冲区，用于存储渲染命令
- `view.currentRenderPassDescriptor` — 获取当前渲染 pass 的描述符（包含颜色/深度附着）
- `commandBuffer.makeRenderCommandEncoder(descriptor:)` — 创建一个渲染命令编码器

---

```swift
// 绑定顶点数据
renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

// 绑定矩阵数据
renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
```

**解释**：将数据绑定到渲染编码器，供 shader 读取。

- `setVertexBuffer(buffer, offset: 0, index: 0)` — 绑定顶点 buffer 到索引 0
  - 对应 shader 中的 `[[buffer(0)]]`
- `setVertexBytes(&uniforms, ..., index: 1)` — 直接复制 Uniforms 数据到 GPU
  - 对应 shader 中的 `[[buffer(1)]]`
  - `&uniforms` 是指针，`MemoryLayout<Uniforms>.stride` 是大小
  - 注意：每次绘制都应该更新 uniforms（因为 MVP 矩阵每帧都在变）

---

```swift
renderEncoder.drawIndexedPrimitives(
    type: .triangle,
    indexCount: cubeIndices.count,
    indexType: .uint16,
    indexBuffer: indexBuffer,
    indexBufferOffset: 0
)
```

**解释：** 发起绘制命令，告诉 GPU 使用索引数据绘制三角形。

- `type: .triangle` — 图元类型，除了 `.triangle` 还有 `.point`、`.line`、`.triangleStrip` 等
- `indexCount: cubeIndices.count` — 索引数量（36 = 12 个三角形 × 3 个顶点）
- `indexType: .uint16` — 索引类型，必须和创建 buffer 时的类型一致
- `indexBuffer: indexBuffer` — 索引数据来源
- `indexBufferOffset: 0` — 从 buffer 的哪个字节开始读

---

```swift
renderEncoder.endEncoding()
commandBuffer.present(view.currentDrawable!)
commandBuffer.commit()
```

**解释**：结束渲染并提交命令。

- `endEncoding()` — 结束当前渲染 pass，不再接受新命令
- `present(view.currentDrawable!)` — 指定渲染完成后显示哪个 drawable（可显示的纹理）
- `commit()` — **关键**：将命令提交到 GPU 队列，GPU 开始异步执行这些命令
- Metal 是异步的：`commit()` 后 GPU 立即开始工作，但 Swift 代码可以继续执行下一帧

---

## 4. 关键概念解释

### 4.1 修饰符（Attribute）一览

| 修饰符 | 用在哪儿 | 含义 |
|--------|----------|------|
| `[[position]]` | 顶点着色器输出 | 这个 float4 是裁剪空间坐标 |
| `[[buffer(n)]]` | 顶点/片元着色器参数 | 从索引 n 的 buffer 读取数据 |
| `[[vertex_id]]` | 顶点着色器参数 | 自动生成的顶点 ID |
| `[[stage_in]]` | 片元着色器参数 | 接收顶点着色器插值后的数据 |

### 4.2 buffer vs stage_in

```
buffer (GPU 内存)          stage_in (插值后的数据)
┌─────────────────┐        ┌─────────────────┐
│ 顶点着色器      │        │                 │
│ vertices[0]     │───────→│ (插值前的数据)  │
│ vertices[1]     │        │                 │
│ vertices[2]     │        └────────┬────────┘
│ ...             │                 │  GPU 自动插值
└─────────────────┘                 ▼
                           ┌─────────────────┐
                           │ 片元着色器      │
                           │ in.color = ?    │ ← 每个像素不同
                           └─────────────────┘
```

- `buffer` — 原始数据，每次调用 shader 时完全相同
- `stage_in` — 插值数据，每个顶点/像素都不同（由 GPU 根据重心坐标自动计算）

### 4.3 矩阵乘法顺序

```swift
out.position = uniforms.modelViewProjectionMatrix * position;
```

在 Metal 中是 **矩阵在前，向量在后**。由于 Metal 使用**列主序**矩阵：

```
MVP = Projection × View × Model
```

但代码写的是 `MVP * position`，这看起来是反过来的。实际上 Metal 的矩阵乘法是：

```
| m0 m4 m8  m12 |   | x |
| m1 m5 m9  m13 | × | y |
| m2 m6 m10 m14 |   | z |
| m3 m7 m11 m15 |   | w |
```

这是标准的**列主序**矩阵-向量乘法。代码中 `projection * viewMatrix * modelMatrix` 的乘法顺序也是正确的——Swift 的 `*` 操作符会从左到右依次相乘。

### 4.4 深度缓冲的工作原理

```
绘制顺序：先画远的，后画近的

场景：相机 ──── 远方块 ──── 近方块

帧缓冲内容（每像素只存一个值：深度）：
┌────────────────┐
│ 像素 深度值    │
│  0   0.95 (远) │ ← 先画远方块
│  1   0.70 (近) │ ← 后画近方块，深度更小，通过 .less 测试
└────────────────┘

深度测试过程：
if (newDepth < storedDepth) {
    // 通过测试：更近，画上去
    pixel = newPixel;
    storedDepth = newDepth;
} else {
    // 没通过：被挡住了，丢弃
}
```

### 4.5 Minecraft Voxel 的数据结构

```swift
// 8 个顶点定义立方体的 8 个角
cubeVertices[0] = position(-0.5, -0.5,  0.5)  // 左下前
cubeVertices[1] = position( 0.5, -0.5,  0.5)  // 右下前
cubeVertices[2] = position( 0.5,  0.5,  0.5)  // 右上前
cubeVertices[3] = position(-0.5,  0.5,  0.5)  // 左上前
cubeVertices[4] = position(-0.5, -0.5, -0.5)  // 左下后
cubeVertices[5] = position( 0.5, -0.5, -0.5)  // 右下后
cubeVertices[6] = position( 0.5,  0.5, -0.5)  // 右上后
cubeVertices[7] = position(-0.5,  0.5, -0.5)  // 左上后

// 12 个三角形覆盖 6 个面
// 每个面 = 2 个三角形 = 6 个索引
//
//        3 ────── 2          顶点的坐标系：
//        │ ╲     ╲           Y+
//        │   ╲   ╲           │
//        │     ╲ │           │  Z+
//        0 ────── 1          │ /
//        /    ╲   /           │/
//       /  ╲   ╲/            └────── X+
//      4 ────── 5
```

---

## 下一步：如何扩展

### 添加纹理（UV 坐标）

1. 在 `Vertex` 结构中添加 `float2 uv`
2. 在 `VertexOut` 中添加 `float2 uv`
3. 在顶点着色器中传递 `out.uv = vertices[vid].uv`
4. 在 Renderer 中创建 `MTLTexture` 并绑定到 `setFragmentTexture`
5. 在片元着色器中用 `texture2d.sample` 读取纹理颜色

### 添加多 voxel

1. 将所有顶点和索引合并到一个大数组中（chunk 概念）
2. 或者使用 `instanced drawing`（实例化绘制），用一份几何数据绘制多个不同位置的 voxel

### 添加光照

1. 在 `VertexOut` 中添加 `float3 normal`
2. 在顶点着色器中计算法线（从模型矩阵中提取）
3. 在片元着色器中使用法线和光源方向计算漫反射：`color *= max(dot(normal, lightDir), 0.0)`

---

希望这份指南对你有帮助！如果有任何具体的问题，欢迎继续提问。

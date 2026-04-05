#include <metal_stdlib>
using namespace metal;

// 1. 定义与 Swift 中对应的顶点结构
struct Vertex {
    float3 position;
    float4 color;
};

// 2. 定义从 Swift 传来的 Uniforms (矩阵)
struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

// 3. 定义从顶点着色器传递到片元着色器的结构
struct VertexOut {
    float4 position [[position]]; // [[position]] 告诉 Metal 这是裁剪空间坐标
    float4 color;
};

// --- 顶点着色器 ---
// vertices: 对应 renderEncoder.setVertexBuffer(..., index: 0)
// uniforms: 对应 renderEncoder.setVertexBytes(..., index: 1)
// vid: 自动生成的顶点索引
vertex VertexOut vertex_main(constant Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]]) {
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

// --- 片元着色器 ---
// stage_in 表示数据来自顶点着色器的输出
fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    // 直接返回颜色
    return in.color;
}

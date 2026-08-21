//
//  Types.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/4/26.
//

import simd

struct Vertex {
    var position: simd_float3
    var texCoord: simd_float2
    var faceBrightness: Float
    var textureLayer: UInt32 // 必须与 Shaders.metal 中的 VertexIn 保持一致
}

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}

// 当前被准心选中的方块范围。w 为 1 时启用高亮，为 0 时禁用。
struct HighlightUniforms {
    var blockMin: simd_float4
    var blockMax: simd_float4
}

// 天空渐变着色器的 Uniform（与 Shaders.metal 中的 SkyUniforms 内存布局一致）
struct SkyUniforms {
    var invViewProj: simd_float4x4 // 视图投影矩阵的逆矩阵
    var cameraPos: simd_float3     // 相机世界坐标
}

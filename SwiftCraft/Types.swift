//
//  Types.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/4/26.
//

import simd

struct Vertex {
    var position: simd_float3
    var texCoord: simd_float2 // 必须同步更新，且 Shader 里也要改
}

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}

// 天空渐变着色器的 Uniform（与 Shaders.metal 中的 SkyUniforms 内存布局一致）
struct SkyUniforms {
    var invViewProj: simd_float4x4 // 视图投影矩阵的逆矩阵
    var cameraPos: simd_float3     // 相机世界坐标
}

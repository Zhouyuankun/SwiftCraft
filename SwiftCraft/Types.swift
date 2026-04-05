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

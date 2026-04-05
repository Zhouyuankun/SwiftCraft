//
//  Types.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/4/26.
//

import simd

struct Vertex {
    var position: simd_float3
    var color: simd_float4
}

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}

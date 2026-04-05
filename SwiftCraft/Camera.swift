//
//  Camera.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/5/26.
//

import simd

class Camera {
    var position = simd_float3(2.5, 5.0, 15.0) // 初始位置在区块前方稍高处
    var yaw: Float = -90.0  // 水平旋转
    var pitch: Float = 0.0  // 垂直旋转
    
    var lookAt: simd_float3 {
        let x = cos(yaw.radians) * cos(pitch.radians)
        let y = sin(pitch.radians)
        let z = sin(yaw.radians) * cos(pitch.radians)
        return normalize(simd_float3(x, y, z))
    }
    
    func getViewMatrix() -> matrix_float4x4 {
        // 使用标准的 LookAt 变换
        return matrix_float4x4.lookAt(eye: position, center: position + lookAt, up: [0, 1, 0])
    }
}

// 辅助扩展
extension Float {
    var radians: Float { self * .pi / 180 }
}

extension matrix_float4x4 {
    static func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> matrix_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        
        var res = matrix_identity_float4x4
        res.columns.0 = [x.x, y.x, z.x, 0]
        res.columns.1 = [x.y, y.y, z.y, 0]
        res.columns.2 = [x.z, y.z, z.z, 0]
        res.columns.3 = [-dot(x, eye), -dot(y, eye), -dot(z, eye), 1]
        return res
    }
}

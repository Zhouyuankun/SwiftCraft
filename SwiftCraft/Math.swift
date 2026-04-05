import simd

extension matrix_float4x4 {
    // 1. 透视矩阵 (Projection)
    static func perspective(degrees: Float, aspectRatio: Float, near: Float, far: Float) -> matrix_float4x4 {
        let radians = degrees * .pi / 180
        let y = 1 / tan(radians * 0.5)
        let x = y / aspectRatio
        let z = far / (near - far)
        let w = (near * far) / (near - far)
        
        var result = matrix_identity_float4x4
        result.columns.0 = [x, 0, 0, 0]
        result.columns.1 = [0, y, 0, 0]
        result.columns.2 = [0, 0, z, -1]
        result.columns.3 = [0, 0, w, 0]
        return result
    }

    // 2. 位移矩阵 (Translation)
    static func translation(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
        var result = matrix_identity_float4x4
        result.columns.3 = [x, y, z, 1]
        return result
    }

    // 3. 旋转矩阵 (Rotation)
    static func rotation(radians: Float, axis: simd_float3) -> matrix_float4x4 {
        let unitAxis = normalize(axis)
        let ct = cos(radians)
        let st = sin(radians)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        
        var result = matrix_identity_float4x4
        result.columns.0 = [ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0]
        result.columns.1 = [x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0]
        result.columns.2 = [x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0]
        result.columns.3 = [0, 0, 0, 1]
        return result
    }
}

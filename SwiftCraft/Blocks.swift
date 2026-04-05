//
//  Blocks.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/5/26.
//

struct BlockUV {
    let row: Int
    let col: Int
}

enum BlockType: Int {
    case air = 0
    case stone = 1
    case dirt = 2
    case grass = 3
}

struct Chunk {
    static let width = 5
    static let height = 5
    static let depth = 5
    
    // 存储地形数据
    var map: [[[BlockType]]] = Array(repeating: Array(repeating: Array(repeating: .air, count: depth), count: height), count: width)
    
    init() {
        // 生成 5*5*5 地形
        for x in 0..<Chunk.width {
            for z in 0..<Chunk.depth {
                for y in 0..<Chunk.height {
                    if y == 4 {
                        map[x][y][z] = .grass // 最上层草
                    } else if y == 0 {
                        map[x][y][z] = .stone // 最下层石
                    } else {
                        map[x][y][z] = .dirt  // 中间泥土
                    }
                }
            }
        }
    }
}

struct GeometryFactory {
    
    static func createCube(type: BlockType, atlasSize: Int = 4) -> [Vertex] {
        let step = Float(1.0) / Float(atlasSize)
        let coords = type.faceCoords
        
        var vertices = [Vertex]()
        
        // 定义 6 个面的方向和局部坐标
        // 每个面 4 个点：左下, 右下, 右上, 左上
        let facePositions: [[simd_float3]] = [
            [[-0.5, -0.5,  0.5], [ 0.5, -0.5,  0.5], [ 0.5,  0.5,  0.5], [-0.5,  0.5,  0.5]], // 前
            [[ 0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5,  0.5, -0.5], [ 0.5,  0.5, -0.5]], // 后
            [[ 0.5, -0.5,  0.5], [ 0.5, -0.5, -0.5], [ 0.5,  0.5, -0.5], [ 0.5,  0.5,  0.5]], // 右
            [[-0.5, -0.5, -0.5], [-0.5, -0.5,  0.5], [-0.5,  0.5,  0.5], [-0.5,  0.5, -0.5]], // 左
            [[-0.5,  0.5,  0.5], [ 0.5,  0.5,  0.5], [ 0.5,  0.5, -0.5], [-0.5,  0.5, -0.5]], // 上
            [[-0.5, -0.5, -0.5], [ 0.5, -0.5, -0.5], [ 0.5, -0.5,  0.5], [-0.5, -0.5,  0.5]]  // 下
        ]
        
        for (i, posArray) in facePositions.enumerated() {
            let coord = coords[i]
            let u = Float(coord.col) * step
            let v = Float(coord.row) * step
            
            let uvs: [simd_float2] = [
                [u, v + step],         // 左下
                [u + step, v + step],  // 右下
                [u + step, v],         // 右上
                [u, v]                 // 左上
            ]
            
            for j in 0..<4 {
                vertices.append(Vertex(position: posArray[j], texCoord: uvs[j]))
            }
        }
        
        return vertices
    }
}

extension GeometryFactory {
    
    static func generateChunkMesh(chunk: Chunk) -> [Vertex] {
        var vertices = [Vertex]()
        let step = Float(1.0) / 4.0 // 4x4 图集
        
        for x in 0..<Chunk.width {
            for y in 0..<Chunk.height {
                for z in 0..<Chunk.depth {
                    let type = chunk.map[x][y][z]
                    if type == .air { continue }
                    
                    let pos = simd_float3(Float(x), Float(y), Float(z))
                    let coords = type.faceCoords // 之前定义的那个获取 6 个面 UV 的方法
                    
                    // 检查 6 个方向的邻居
                    let directions: [(dx: Int, dy: Int, dz: Int)] = [
                        (0, 0, 1),  // 前
                        (0, 0, -1), // 后
                        (1, 0, 0),  // 右
                        (-1, 0, 0), // 左
                        (0, 1, 0),  // 上
                        (0, -1, 0)  // 下
                    ]
                    
                    for (i, d) in directions.enumerated() {
                        let nx = x + d.dx
                        let ny = y + d.dy
                        let nz = z + d.dz
                        
                        // 剔除逻辑：如果邻居在边界外，或者是空气，则显示这个面
                        var shouldShowFace = false
                        if nx < 0 || nx >= Chunk.width || ny < 0 || ny >= Chunk.height || nz < 0 || nz >= Chunk.depth {
                            shouldShowFace = true // 边界边缘的面要显示
                        } else if chunk.map[nx][ny][nz] == .air {
                            shouldShowFace = true // 邻居是空气要显示
                        }
                        
                        if shouldShowFace {
                            // 只添加这一个面的 4 个顶点
                            let faceVerts = getFaceVertices(directionIndex: i, position: pos, uvCoord: coords[i], step: step)
                            vertices.append(contentsOf: faceVerts)
                        }
                    }
                }
            }
        }
        return vertices
    }
    
    // 辅助方法：生成单个面的 4 个顶点
    private static func getFaceVertices(directionIndex: Int, position: simd_float3, uvCoord: BlockUV, step: Float) -> [Vertex] {
        let u = Float(uvCoord.col) * step
        let v = Float(uvCoord.row) * step
        
        // UV 坐标：左下, 右下, 右上, 左上
        let uvs: [simd_float2] = [
            [u, v + step],
            [u + step, v + step],
            [u + step, v],
            [u, v]
        ]
        
        let allFacePositions: [[simd_float3]] = [
            [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]], // 前 (z+)
            [[1, 0, 0], [0, 0, 0], [0, 1, 0], [1, 1, 0]], // 后 (z-)
            [[1, 0, 1], [1, 0, 0], [1, 1, 0], [1, 1, 1]], // 右 (x+)
            [[0, 0, 0], [0, 0, 1], [0, 1, 1], [0, 1, 0]], // 左 (x-)
            [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]], // 上 (y+)
            [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]]  // 下 (y-)
        ]
        
        // 关键点：将 4 个点转为 6 个点以适配 .triangle 绘制
        let triangleIndices = [0, 1, 2, 0, 2, 3]
        return triangleIndices.map { i in
            Vertex(position: allFacePositions[directionIndex][i] + position,
                   texCoord: uvs[i])
        }
    }
}

extension BlockType {
    // 定义 6 个面的图集坐标：前, 后, 右, 左, 上, 下
    var faceCoords: [BlockUV] {
        switch self {
        case .grass:
            let side = BlockUV(row: 0, col: 2)
            let top = BlockUV(row: 1, col: 3)
            let bottom = BlockUV(row: 0, col: 1)
            return [side, side, side, side, top, bottom]
            
        case .dirt:
            let dirt = BlockUV(row: 0, col: 1)
            return Array(repeating: dirt, count: 6)
            
        case .stone:
            let stone = BlockUV(row: 0, col: 0)
            return Array(repeating: stone, count: 6)
            
        case .air:
            // 空气不需要坐标，返回空或默认值即可（逻辑上 generateChunkMesh 会跳过 air）
            return Array(repeating: BlockUV(row: 0, col: 0), count: 6)
        }
    }
}

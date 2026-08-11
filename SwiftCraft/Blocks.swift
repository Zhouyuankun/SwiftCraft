//
//  Blocks.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/5/26.
//

import Metal
import simd

struct BlockUV {
    let row: Int
    let col: Int
}

enum BlockType: Int {
    case air = 0
    case stone = 1
    case dirt = 2
    case grass = 3
    case coalOre = 4
    case planks = 5
    case log = 6
    case cobblestone = 7
    case bedrock = 8
    case sand = 9
    case bricks = 10
    case furnace = 11
    case litFurnace = 12
}

struct Chunk {
    static let width = 5
    static let height = 8
    static let depth = 5

    // 存储地形数据
    var map: [[[BlockType]]] = Array(repeating: Array(repeating: Array(repeating: .air, count: depth), count: height), count: width)

    init() {
        // 生成固定的 8 层平坦地形：1 层基岩、3 层石头、3 层泥土、1 层草方块
        for x in 0..<Chunk.width {
            for z in 0..<Chunk.depth {
                for y in 0..<Chunk.height {
                    switch y {
                    case 0:
                        map[x][y][z] = .bedrock
                    case 1...3:
                        map[x][y][z] = .stone
                    case 4...6:
                        map[x][y][z] = .dirt
                    case 7:
                        map[x][y][z] = .grass
                    default:
                        break
                    }
                }
            }
        }
    }
}

// MARK: - 区块坐标（Chunk 级别的整数坐标）
struct ChunkCoord: Hashable {
    var x: Int
    var z: Int
}

/// 世界中的整数方块坐标，对应方块 AABB 的最小角。
struct BlockCoord: Equatable {
    var x: Int
    var y: Int
    var z: Int
}

// MARK: - 单个区块的可渲染数据

/// 一个已上传到 GPU 的区块网格
struct ChunkMesh {
    let buffer: MTLBuffer
    let vertexCount: Int
}

// MARK: - 多区块世界管理
//
// 负责根据玩家所在的区块，动态创建/卸载周围的区块。
// 渲染距离 = 1：渲染玩家当前区块 + 周围一圈（3x3 共 9 个区块）。
//
// 数据分两层：
// 1. chunkData —— 区块的方块数据，永久保存。区块离开渲染距离时数据不会被删除，
//    玩家再次进入时从这里还原，保证方块内容（包括未来的破坏/放置修改）不丢失。
// 2. loadedChunks —— 渲染距离内、已上传 GPU 的网格。超出渲染距离时释放，节省显存。
//
// 面剔除支持跨区块：构建网格时会查询相邻区块的方块数据，
// 两个实心方块交界处的面（即使跨区块）也不会生成。
class World {
    /// 渲染距离（区块数）。1 表示当前区块 + 东西南北各一圈，共 3x3。
    static let renderDistance = 1

    /// 所有已生成的区块数据（持久保存，不随卸载删除）
    private var chunkData: [ChunkCoord: Chunk] = [:]

    /// 渲染距离内已加载并上传 GPU 的区块：ChunkCoord -> ChunkMesh
    private(set) var loadedChunks: [ChunkCoord: ChunkMesh] = [:]

    /// Metal 设备，用于创建顶点缓冲
    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    /// 将世界坐标（浮点）转换为区块坐标
    static func worldToChunkCoord(_ pos: simd_float3) -> ChunkCoord {
        // 向下取整，保证负坐标也能正确归入区块
        let cx = Int(floor(pos.x / Float(Chunk.width)))
        let cz = Int(floor(pos.z / Float(Chunk.depth)))
        return ChunkCoord(x: cx, z: cz)
    }

    /// 以玩家所在区块为中心，加载渲染距离内的区块，卸载超出的区块。
    /// 只在区块集合发生变化时才真正做加载/卸载，避免每帧重复工作。
    func update(center: ChunkCoord) {
        var needed = Set<ChunkCoord>()
        let r = World.renderDistance

        // 计算渲染距离内需要的区块（3x3）
        for dx in -r...r {
            for dz in -r...r {
                needed.insert(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }

        // 若需要的区块集合和当前已加载的完全一致，直接跳过
        if needed == Set(loadedChunks.keys) {
            return
        }

        // 1. 先确保所有需要的区块"数据"存在（数据必须先于网格构建就绪，
        //    这样构建网格时才能查询到相邻区块、完成跨区块面剔除）。
        //    记录本次首次生成的区块坐标。
        var newlyCreated: Set<ChunkCoord> = []
        for coord in needed where chunkData[coord] == nil {
            // 首次进入：生成新区块数据（未来在此接入噪声地形）并永久保存，供以后还原
            chunkData[coord] = Chunk()
            newlyCreated.insert(coord)
        }

        // 2. 构建/重建网格：
        //    - 还没有网格的区块需要构建（新进入渲染距离，或之前被卸载过）
        //    - 邻居中有"刚生成"的区块时也要重建：之前该侧没有邻居、边界面被保留，
        //      现在邻居出现了，那些面应当被剔除
        for coord in needed {
            let needsBuild = loadedChunks[coord] == nil
                || neighbors(of: coord).contains(where: newlyCreated.contains)
            if needsBuild {
                loadedChunks[coord] = buildChunkMesh(at: coord)
            }
        }

        // 3. 卸载超出渲染距离的区块：只释放 GPU 网格，
        //    方块数据仍保留在 chunkData 中，下次进入时还原
        for coord in Array(loadedChunks.keys) where !needed.contains(coord) {
            loadedChunks.removeValue(forKey: coord)
        }
    }

    /// 水平方向上相邻的 4 个区块（当前区块高度即世界高度，暂无垂直邻居）
    private func neighbors(of coord: ChunkCoord) -> [ChunkCoord] {
        [
            ChunkCoord(x: coord.x + 1, z: coord.z),
            ChunkCoord(x: coord.x - 1, z: coord.z),
            ChunkCoord(x: coord.x, z: coord.z + 1),
            ChunkCoord(x: coord.x, z: coord.z - 1)
        ]
    }

    /// 用已有的区块数据构建网格并上传到 GPU（顶点坐标已转换到世界坐标）
    private func buildChunkMesh(at coord: ChunkCoord) -> ChunkMesh? {
        guard let chunk = chunkData[coord] else { return nil }

        // 该区块在世界中的原点偏移
        let origin = simd_float3(
            Float(coord.x * Chunk.width),
            0,
            Float(coord.z * Chunk.depth)
        )
        // 传入跨区块查询闭包，实现区块间的面剔除
        let vertices = GeometryFactory.generateChunkMesh(chunk: chunk, worldOrigin: origin) { wx, wy, wz in
            self.blockAtWorld(x: wx, y: wy, z: wz)
        }
        guard !vertices.isEmpty else { return nil }

        let bufferSize = vertices.count * MemoryLayout<Vertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: bufferSize, options: []) else {
            return nil
        }
        return ChunkMesh(buffer: buffer, vertexCount: vertices.count)
    }

    /// 查询世界方块坐标处的方块（可跨区块）。
    /// 所在区块尚未生成、或超出垂直范围时返回 nil（网格生成按空气处理、显示该面）。
    func blockAtWorld(x: Int, y: Int, z: Int) -> BlockType? {
        guard y >= 0, y < Chunk.height else { return nil }

        // 向下取整除法，正确处理负坐标
        let cx = Int(floor(Double(x) / Double(Chunk.width)))
        let cz = Int(floor(Double(z) / Double(Chunk.depth)))
        guard let chunk = chunkData[ChunkCoord(x: cx, z: cz)] else { return nil }

        let lx = x - cx * Chunk.width
        let lz = z - cz * Chunk.depth
        return chunk.map[lx][y][lz]
    }

    /// 从世界坐标中的射线寻找第一个非空气方块。
    /// 使用 3D DDA 逐格穿过体素，不依赖 Chunk 的具体地形生成方式。
    func raycast(origin: simd_float3, direction: simd_float3, maxDistance: Float) -> BlockCoord? {
        let ray = simd_normalize(direction)
        guard ray.x.isFinite, ray.y.isFinite, ray.z.isFinite else { return nil }

        var voxel = BlockCoord(
            x: Int(floor(origin.x)),
            y: Int(floor(origin.y)),
            z: Int(floor(origin.z))
        )

        let stepX = ray.x >= 0 ? 1 : -1
        let stepY = ray.y >= 0 ? 1 : -1
        let stepZ = ray.z >= 0 ? 1 : -1

        let deltaX = ray.x == 0 ? Float.infinity : abs(1 / ray.x)
        let deltaY = ray.y == 0 ? Float.infinity : abs(1 / ray.y)
        let deltaZ = ray.z == 0 ? Float.infinity : abs(1 / ray.z)

        var nextX = ray.x == 0 ? Float.infinity : distanceToBoundary(origin.x, voxel.x, stepX) * deltaX
        var nextY = ray.y == 0 ? Float.infinity : distanceToBoundary(origin.y, voxel.y, stepY) * deltaY
        var nextZ = ray.z == 0 ? Float.infinity : distanceToBoundary(origin.z, voxel.z, stepZ) * deltaZ
        var distance: Float = 0

        while distance <= maxDistance {
            if let block = blockAtWorld(x: voxel.x, y: voxel.y, z: voxel.z), block != .air {
                return voxel
            }

            if nextX <= nextY && nextX <= nextZ {
                voxel.x += stepX
                distance = nextX
                nextX += deltaX
            } else if nextY <= nextZ {
                voxel.y += stepY
                distance = nextY
                nextY += deltaY
            } else {
                voxel.z += stepZ
                distance = nextZ
                nextZ += deltaZ
            }
        }
        return nil
    }

    private func distanceToBoundary(_ origin: Float, _ voxel: Int, _ step: Int) -> Float {
        let boundary = step > 0 ? Float(voxel + 1) : Float(voxel)
        return abs(boundary - origin)
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

    /// 生成区块网格。
    /// - Parameters:
    ///   - worldOrigin: 该区块在世界中的原点偏移（区块角），
    ///     用于把区块局部坐标转换到世界坐标，从而支持多区块拼接。
    ///   - blockAtWorld: 可选闭包——当邻居方块跨越区块边界时，用世界方块坐标查询邻居区块的方块类型。
    ///     返回 nil 表示邻居区块尚未生成（按空气处理、显示该面，即世界边缘的"悬崖面"）。
    static func generateChunkMesh(
        chunk: Chunk,
        worldOrigin: simd_float3 = .zero,
        blockAtWorld: ((Int, Int, Int) -> BlockType?)? = nil
    ) -> [Vertex] {
        var vertices = [Vertex]()
        let step = Float(1.0) / 4.0 // 4x4 图集

        for x in 0..<Chunk.width {
            for y in 0..<Chunk.height {
                for z in 0..<Chunk.depth {
                    let type = chunk.map[x][y][z]
                    if type == .air { continue }

                    let pos = simd_float3(Float(x), Float(y), Float(z)) + worldOrigin
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

                        // 剔除逻辑：邻居是实心方块则不显示该面，否则显示
                        let neighbor: BlockType
                        if nx >= 0, nx < Chunk.width,
                           ny >= 0, ny < Chunk.height,
                           nz >= 0, nz < Chunk.depth {
                            // 邻居在本区块内
                            neighbor = chunk.map[nx][ny][nz]
                        } else if let blockAtWorld = blockAtWorld {
                            // 邻居跨越区块边界：转换为世界坐标查询 World
                            let wx = Int(worldOrigin.x) + nx
                            let wy = ny
                            let wz = Int(worldOrigin.z) + nz
                            neighbor = blockAtWorld(wx, wy, wz) ?? .air
                        } else {
                            // 未提供查询（单区块模式）：按空气处理
                            neighbor = .air
                        }

                        if neighbor == .air {
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
    // terrain_atlas 是 4x4 图集，按从上到下、从左到右排列：
    // 第 0 行：石头、泥土、草侧面、煤矿石
    // 第 1 行：木板、原木侧面、原木端面、草顶部
    // 第 2 行：圆石、基岩、沙子、红砖块
    // 第 3 行：熄灭熔炉正面、熔炉背面/侧面、点燃熔炉正面、熔炉顶面/底面
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

        case .coalOre:
            return Array(repeating: BlockUV(row: 0, col: 3), count: 6)

        case .planks:
            return Array(repeating: BlockUV(row: 1, col: 0), count: 6)

        case .log:
            let side = BlockUV(row: 1, col: 1)
            let end = BlockUV(row: 1, col: 2)
            return [side, side, side, side, end, end]

        case .cobblestone:
            return Array(repeating: BlockUV(row: 2, col: 0), count: 6)

        case .bedrock:
            return Array(repeating: BlockUV(row: 2, col: 1), count: 6)

        case .sand:
            return Array(repeating: BlockUV(row: 2, col: 2), count: 6)

        case .bricks:
            return Array(repeating: BlockUV(row: 2, col: 3), count: 6)

        case .furnace, .litFurnace:
            let front = self == .litFurnace
                ? BlockUV(row: 3, col: 2)
                : BlockUV(row: 3, col: 0)
            let backAndSides = BlockUV(row: 3, col: 1)
            let topAndBottom = BlockUV(row: 3, col: 3)
            return [front, backAndSides, backAndSides, backAndSides, topAndBottom, topAndBottom]

        case .air:
            // 空气不需要坐标，返回空或默认值即可（逻辑上 generateChunkMesh 会跳过 air）
            return Array(repeating: BlockUV(row: 0, col: 0), count: 6)
        }
    }
}

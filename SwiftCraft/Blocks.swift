//
//  Blocks.swift
//  SwiftCraft
//
//  Created by 周源坤 on 4/5/26.
//

import Foundation
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
    static let width = 16
    static let height = 64
    static let depth = 16

    /// 按 `(y * depth + z) * width + x` 连续存储，避免三维嵌套数组产生大量小数组。
    private var blocks = Array(
        repeating: BlockType.air,
        count: Chunk.width * Chunk.height * Chunk.depth
    )

    /// 创建全空气数据容器；具体方块内容由 TerrainGenerating 负责填充。
    init() {}

    private static func index(x: Int, y: Int, z: Int) -> Int {
        precondition((0..<width).contains(x))
        precondition((0..<height).contains(y))
        precondition((0..<depth).contains(z))
        return (y * depth + z) * width + x
    }

    subscript(x: Int, y: Int, z: Int) -> BlockType {
        get { blocks[Self.index(x: x, y: y, z: z)] }
        set { blocks[Self.index(x: x, y: y, z: z)] = newValue }
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

/// 某类区块工作的累计耗时，便于判断后续是否需要异步化。
struct ChunkPerformanceMetrics {
    private(set) var sampleCount = 0
    private(set) var totalMilliseconds: Double = 0
    private(set) var maximumMilliseconds: Double = 0

    var averageMilliseconds: Double {
        sampleCount == 0 ? 0 : totalMilliseconds / Double(sampleCount)
    }

    mutating func record(seconds: TimeInterval) {
        let milliseconds = seconds * 1_000
        sampleCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
    }
}

private struct GeneratedChunkResult {
    let coord: ChunkCoord
    let chunk: Chunk
    let seconds: TimeInterval
}

private struct GeneratedMeshResult {
    let coord: ChunkCoord
    let version: Int
    let vertices: [Vertex]
    let seconds: TimeInterval
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

    /// 当前处于渲染距离内的区块坐标。单个区块即使被挖空、没有网格，也仍算已加载。
    private var loadedChunkCoords: Set<ChunkCoord> = []

    /// 当前 GPU 网格对应的区块版本；空网格也记录版本，避免每帧重复调度。
    private var loadedMeshVersions: [ChunkCoord: Int] = [:]

    /// 每个区块的数据版本。玩家修改时递增，使旧后台网格结果自动失效。
    private var chunkVersions: [ChunkCoord: Int] = [:]

    private var requestedDataCoords: Set<ChunkCoord> = []
    private var meshJobs: [ChunkCoord: Int] = [:]

    private let resultLock = NSLock()
    private var generatedChunkResults: [GeneratedChunkResult] = []
    private var generatedMeshResults: [GeneratedMeshResult] = []
    private var readyMeshResults: [GeneratedMeshResult] = []

    /// 每帧最多把一个完成的 CPU 网格上传为 MTLBuffer，避免结果集中提交。
    private let maximumMeshUploadsPerFrame = 1
    private let meshUploadBudgetMilliseconds: Double = 2

    private let dataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SwiftCraft.TerrainData"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let meshQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SwiftCraft.MeshVertices"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    /// Metal 设备，用于创建顶点缓冲
    private let device: MTLDevice

    /// 本次运行使用的世界种子；应用重启时会重新随机生成。
    let seed: UInt64

    /// 区块方块数据生成与网格构建的累计性能数据。
    private(set) var terrainGenerationPerformance = ChunkPerformanceMetrics()
    private(set) var meshBuildPerformance = ChunkPerformanceMetrics()
    private(set) var vertexGenerationPerformance = ChunkPerformanceMetrics()
    private(set) var bufferCreationPerformance = ChunkPerformanceMetrics()

    /// 只负责创建原始方块数据，不参与网格构建或加载状态管理。
    private let terrainGenerator: any TerrainGenerating

    init(device: MTLDevice, seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        self.device = device
        self.seed = seed
        self.terrainGenerator = HeightmapTerrainGenerator(
            configuration: TerrainConfiguration(seed: seed)
        )

        // 节点 3 仅输出诊断采样；噪声尚未参与地形生成。
        let diagnosticNoise = SeededNoise(seed: seed).fBm2D(x: 12.5, z: -8.25)
        print("World seed: \(seed), noise diagnostic: \(diagnosticNoise)")
    }

    /// 将世界坐标（浮点）转换为区块坐标
    static func worldToChunkCoord(_ pos: simd_float3) -> ChunkCoord {
        WorldCoordinates.chunkCoord(for: pos)
    }

    /// 查询生成器在指定世界坐标柱上的地表高度。
    func surfaceHeight(worldX: Int, worldZ: Int) -> Int {
        terrainGenerator.surfaceHeight(worldX: worldX, worldZ: worldZ)
    }

    /// 以玩家所在区块为中心，加载渲染距离内的区块，卸载超出的区块。
    /// 每帧先接收后台结果，再按需调度缺失数据和网格任务。
    func update(center: ChunkCoord) {
        var needed = Set<ChunkCoord>()
        let r = World.renderDistance

        // 计算渲染距离内需要的区块（3x3）
        for dx in -r...r {
            for dz in -r...r {
                needed.insert(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }

        let visibleSetChanged = needed != loadedChunkCoords
        loadedChunkCoords = needed

        // 超出可见范围时释放 GPU 网格；后台任务可继续完成，但结果会在接收时丢弃。
        if visibleSetChanged {
            for coord in Array(loadedChunks.keys) where !needed.contains(coord) {
                loadedChunks.removeValue(forKey: coord)
            }
            for coord in Array(loadedMeshVersions.keys) where !needed.contains(coord) {
                loadedMeshVersions.removeValue(forKey: coord)
            }
        }

        drainAsyncResults(center: center)

        // 为可见范围及其四侧邻居准备纯数据 halo。
        var dataNeeded = needed
        for coord in needed {
            dataNeeded.formUnion(neighbors(of: coord))
        }
        let scheduledData = scheduleMissingData(in: dataNeeded, center: center)
        let scheduledMeshes = scheduleMissingMeshes(in: needed, center: center)
        if scheduledData > 0 || scheduledMeshes > 0 {
            print("Chunk jobs: data \(scheduledData), mesh \(scheduledMeshes)")
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

    private func scheduleMissingData(in coords: Set<ChunkCoord>, center: ChunkCoord) -> Int {
        let missing = coords
            .filter { chunkData[$0] == nil && !requestedDataCoords.contains($0) }
            .sorted { distanceSquared(from: $0, to: center) < distanceSquared(from: $1, to: center) }
        guard !missing.isEmpty else { return 0 }

        let generator = terrainGenerator
        for coord in missing {
            requestedDataCoords.insert(coord)
            dataQueue.addOperation { [weak self] in
                let start = ProcessInfo.processInfo.systemUptime
                let chunk = generator.generateChunk(at: coord)
                let result = GeneratedChunkResult(
                    coord: coord,
                    chunk: chunk,
                    seconds: ProcessInfo.processInfo.systemUptime - start
                )
                guard let self else { return }
                self.resultLock.lock()
                self.generatedChunkResults.append(result)
                self.resultLock.unlock()
            }
        }
        return missing.count
    }

    private func scheduleMissingMeshes(in coords: Set<ChunkCoord>, center: ChunkCoord) -> Int {
        let candidates = coords
            .filter { coord in
                guard chunkData[coord] != nil else { return false }
                let version = chunkVersions[coord, default: 0]
                return loadedMeshVersions[coord] != version && meshJobs[coord] != version
            }
            .sorted { distanceSquared(from: $0, to: center) < distanceSquared(from: $1, to: center) }
        guard !candidates.isEmpty else { return 0 }

        // 值类型快照通过 Array 的 copy-on-write 与渲染线程隔离。
        let visibleData = Dictionary(uniqueKeysWithValues: loadedChunkCoords.compactMap { coord in
            chunkData[coord].map { (coord, $0) }
        })

        for coord in candidates {
            guard let chunk = visibleData[coord] else { continue }
            let version = chunkVersions[coord, default: 0]
            let origin = WorldCoordinates.worldOrigin(for: coord)
            meshJobs[coord] = version

            meshQueue.addOperation { [weak self] in
                let start = ProcessInfo.processInfo.systemUptime
                let vertices = GeometryFactory.generateChunkMesh(
                    chunk: chunk,
                    worldOrigin: origin
                ) { wx, wy, wz in
                    guard wy >= 0, wy < Chunk.height else { return nil }
                    let location = WorldCoordinates.chunkAndLocal(x: wx, z: wz)
                    guard let neighbor = visibleData[location.coord] else { return nil }
                    return neighbor[location.localX, wy, location.localZ]
                }
                let result = GeneratedMeshResult(
                    coord: coord,
                    version: version,
                    vertices: vertices,
                    seconds: ProcessInfo.processInfo.systemUptime - start
                )
                guard let self else { return }
                self.resultLock.lock()
                self.generatedMeshResults.append(result)
                self.resultLock.unlock()
            }
        }
        return candidates.count
    }

    private func drainAsyncResults(center: ChunkCoord) {
        resultLock.lock()
        let dataResults = generatedChunkResults
        let meshResults = generatedMeshResults
        generatedChunkResults.removeAll(keepingCapacity: true)
        generatedMeshResults.removeAll(keepingCapacity: true)
        resultLock.unlock()

        readyMeshResults.append(contentsOf: meshResults)

        var dataMilliseconds: Double = 0
        for result in dataResults {
            requestedDataCoords.remove(result.coord)
            terrainGenerationPerformance.record(seconds: result.seconds)
            dataMilliseconds += result.seconds * 1_000
            if chunkData[result.coord] == nil {
                chunkData[result.coord] = result.chunk
                chunkVersions[result.coord] = 0
            }
        }

        let vertexMilliseconds = meshResults.reduce(0) { total, result in
            vertexGenerationPerformance.record(seconds: result.seconds)
            return total + result.seconds * 1_000
        }
        var bufferMilliseconds: Double = 0
        var appliedMeshes = 0
        var discardedMeshes = 0

        // 先清除已离开可见范围或版本过期的结果，它们不占上传预算。
        readyMeshResults.removeAll { result in
            let isStale = !loadedChunkCoords.contains(result.coord)
                || chunkVersions[result.coord, default: 0] != result.version
            guard isStale else { return false }
            if meshJobs[result.coord] == result.version {
                meshJobs.removeValue(forKey: result.coord)
            }
            discardedMeshes += 1
            return true
        }

        let uploadStart = ProcessInfo.processInfo.systemUptime
        while appliedMeshes < maximumMeshUploadsPerFrame, !readyMeshResults.isEmpty {
            let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - uploadStart) * 1_000
            if appliedMeshes > 0 && elapsedMilliseconds >= meshUploadBudgetMilliseconds {
                break
            }

            let bestIndex = readyMeshResults.indices.min { lhs, rhs in
                distanceSquared(from: readyMeshResults[lhs].coord, to: center)
                    < distanceSquared(from: readyMeshResults[rhs].coord, to: center)
            }!
            let result = readyMeshResults.remove(at: bestIndex)
            if meshJobs[result.coord] == result.version {
                meshJobs.removeValue(forKey: result.coord)
            }

            let bufferStart = ProcessInfo.processInfo.systemUptime
            let buffer: MTLBuffer?
            if result.vertices.isEmpty {
                buffer = nil
            } else {
                buffer = device.makeBuffer(
                    bytes: result.vertices,
                    length: result.vertices.count * MemoryLayout<Vertex>.stride,
                    options: []
                )
            }
            let bufferSeconds = ProcessInfo.processInfo.systemUptime - bufferStart
            bufferCreationPerformance.record(seconds: bufferSeconds)
            meshBuildPerformance.record(seconds: result.seconds + bufferSeconds)
            bufferMilliseconds += bufferSeconds * 1_000

            if let buffer {
                loadedChunks[result.coord] = ChunkMesh(
                    buffer: buffer,
                    vertexCount: result.vertices.count
                )
            } else {
                loadedChunks.removeValue(forKey: result.coord)
            }
            loadedMeshVersions[result.coord] = result.version
            appliedMeshes += 1
        }

        if !dataResults.isEmpty || !meshResults.isEmpty || appliedMeshes > 0 || discardedMeshes > 0 {
            print(String(
                format: "Async ready: data %d / %.2f ms, mesh arrived %d queued %d applied %d discarded %d / vertices %.2f ms, buffer %.2f ms",
                dataResults.count,
                dataMilliseconds,
                meshResults.count,
                readyMeshResults.count,
                appliedMeshes,
                discardedMeshes,
                vertexMilliseconds,
                bufferMilliseconds
            ))
        }
    }

    private func distanceSquared(from coord: ChunkCoord, to center: ChunkCoord) -> Int {
        let dx = coord.x - center.x
        let dz = coord.z - center.z
        return dx * dx + dz * dz
    }

    /// 查询世界方块坐标处的方块（可跨区块）。
    /// 所在区块尚未生成、或超出垂直范围时返回 nil（网格生成按空气处理、显示该面）。
    func blockAtWorld(x: Int, y: Int, z: Int) -> BlockType? {
        guard y >= 0, y < Chunk.height else { return nil }

        let location = WorldCoordinates.chunkAndLocal(x: x, z: z)
        guard let chunk = chunkData[location.coord] else { return nil }
        return chunk[location.localX, y, location.localZ]
    }

    /// 将指定世界坐标的方块设为空气，并重建所有受影响的已加载网格。
    /// 方块修改写入 chunkData，区块离开渲染距离后仍会保留。
    @discardableResult
    func removeBlock(at block: BlockCoord) -> Bool {
        guard block.y >= 0, block.y < Chunk.height else { return false }

        let location = WorldCoordinates.chunkAndLocal(x: block.x, z: block.z)
        let chunkCoord = location.coord
        guard var chunk = chunkData[chunkCoord] else { return false }

        let localX = location.localX
        let localZ = location.localZ
        guard chunk[localX, block.y, localZ] != .air else { return false }

        chunk[localX, block.y, localZ] = .air
        chunkData[chunkCoord] = chunk

        if loadedChunkCoords.contains(chunkCoord) {
            invalidateMesh(at: chunkCoord)
        }

        // 边界方块消失后，相邻区块原本被遮挡的面也需要出现。
        var affectedNeighbors: [ChunkCoord] = []
        if localX == 0 {
            affectedNeighbors.append(ChunkCoord(x: chunkCoord.x - 1, z: chunkCoord.z))
        }
        if localX == Chunk.width - 1 {
            affectedNeighbors.append(ChunkCoord(x: chunkCoord.x + 1, z: chunkCoord.z))
        }
        if localZ == 0 {
            affectedNeighbors.append(ChunkCoord(x: chunkCoord.x, z: chunkCoord.z - 1))
        }
        if localZ == Chunk.depth - 1 {
            affectedNeighbors.append(ChunkCoord(x: chunkCoord.x, z: chunkCoord.z + 1))
        }
        for neighbor in affectedNeighbors where loadedChunkCoords.contains(neighbor) {
            invalidateMesh(at: neighbor)
        }
        return true
    }

    private func invalidateMesh(at coord: ChunkCoord) {
        chunkVersions[coord, default: 0] += 1
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
            let brightness = faceBrightness[i]
            let uvs = localTileUVs
            let textureLayer = layerIndex(for: coord, atlasSize: atlasSize)
            
            for j in 0..<4 {
                vertices.append(Vertex(
                    position: posArray[j],
                    texCoord: uvs[j],
                    faceBrightness: brightness,
                    textureLayer: textureLayer
                ))
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
        vertices.reserveCapacity(Chunk.width * Chunk.depth * 36)

        for x in 0..<Chunk.width {
            for y in 0..<Chunk.height {
                for z in 0..<Chunk.depth {
                    let type = chunk[x, y, z]
                    if type == .air { continue }

                    let pos = simd_float3(Float(x), Float(y), Float(z)) + worldOrigin

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
                            neighbor = chunk[nx, ny, nz]
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
                            appendFace(
                                to: &vertices,
                                directionIndex: i,
                                position: pos,
                                uvCoord: type.faceCoord(directionIndex: i)
                            )
                        }
                    }
                }
            }
        }
        return vertices
    }
    
    /// 直接向最终数组写入两个三角形，避免为每个可见面创建临时数组。
    private static func appendFace(
        to vertices: inout [Vertex],
        directionIndex: Int,
        position: simd_float3,
        uvCoord: BlockUV
    ) {
        let textureLayer = layerIndex(for: uvCoord, atlasSize: 4)
        let positions = facePositions[directionIndex]
        let brightness = faceBrightness[directionIndex]
        for vertexIndex in triangleIndices {
            vertices.append(Vertex(
                position: positions[vertexIndex] + position,
                texCoord: localTileUVs[vertexIndex],
                faceBrightness: brightness,
                textureLayer: textureLayer
            ))
        }
    }

    private static let directions: [(dx: Int, dy: Int, dz: Int)] = [
        (0, 0, 1),
        (0, 0, -1),
        (1, 0, 0),
        (-1, 0, 0),
        (0, 1, 0),
        (0, -1, 0)
    ]

    private static let facePositions: [[simd_float3]] = [
        [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]],
        [[1, 0, 0], [0, 0, 0], [0, 1, 0], [1, 1, 0]],
        [[1, 0, 1], [1, 0, 0], [1, 1, 0], [1, 1, 1]],
        [[0, 0, 0], [0, 0, 1], [0, 1, 1], [0, 1, 0]],
        [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]],
        [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]]
    ]

    private static let triangleIndices = [0, 1, 2, 0, 2, 3]

    /// 前、后、右、左、上、下六个方向的固定亮度，模拟体素游戏常见的环境面光。
    private static let faceBrightness: [Float] = [0.84, 0.84, 0.72, 0.72, 1.0, 0.55]

    /// 每个数组切片是 16×16 像素；缩进半个纹素，避免落在采样边界。
    private static let localTileUVs: [simd_float2] = {
        let inset = Float(0.5 / 16.0)
        let low = inset
        let high = 1 - inset
        return [[low, high], [high, high], [high, low], [low, low]]
    }()

    private static func layerIndex(for coord: BlockUV, atlasSize: Int) -> UInt32 {
        UInt32(coord.row * atlasSize + coord.col)
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
        (0..<6).map { faceCoord(directionIndex: $0) }
    }

    /// 按单个面查询纹理，避免网格热路径为每个方块分配 6 元素数组。
    func faceCoord(directionIndex: Int) -> BlockUV {
        switch self {
        case .grass:
            if directionIndex == 4 { return BlockUV(row: 1, col: 3) }
            if directionIndex == 5 { return BlockUV(row: 0, col: 1) }
            return BlockUV(row: 0, col: 2)

        case .dirt:
            return BlockUV(row: 0, col: 1)

        case .stone:
            return BlockUV(row: 0, col: 0)

        case .coalOre:
            return BlockUV(row: 0, col: 3)

        case .planks:
            return BlockUV(row: 1, col: 0)

        case .log:
            return directionIndex >= 4
                ? BlockUV(row: 1, col: 2)
                : BlockUV(row: 1, col: 1)

        case .cobblestone:
            return BlockUV(row: 2, col: 0)

        case .bedrock:
            return BlockUV(row: 2, col: 1)

        case .sand:
            return BlockUV(row: 2, col: 2)

        case .bricks:
            return BlockUV(row: 2, col: 3)

        case .furnace, .litFurnace:
            if directionIndex == 0 {
                return self == .litFurnace
                    ? BlockUV(row: 3, col: 2)
                    : BlockUV(row: 3, col: 0)
            }
            if directionIndex >= 4 { return BlockUV(row: 3, col: 3) }
            return BlockUV(row: 3, col: 1)

        case .air:
            return BlockUV(row: 0, col: 0)
        }
    }
}

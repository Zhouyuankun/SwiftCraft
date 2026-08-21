//
//  Terrain.swift
//  SwiftCraft
//

import simd

/// 地形生成使用的集中配置。
struct TerrainConfiguration {
    let seed: UInt64
    var surfaceY: Int
    var dirtDepth: Int
    var baseHeight: Int
    var continentalFrequency: Float
    var continentalAmplitude: Float
    var detailFrequency: Float
    var detailAmplitude: Float
    var hillRegionFrequency: Float
    var ridgeFrequency: Float
    var hillAmplitude: Float
    var maximumSurfaceHeight: Int
    var seaLevel: Int
    var sandDepth: Int
    var coalFrequency: Float
    var coalThreshold: Float
    var maximumCoalY: Int

    init(
        seed: UInt64,
        surfaceY: Int = 7,
        dirtDepth: Int = 3,
        baseHeight: Int = 24,
        continentalFrequency: Float = 0.005,
        continentalAmplitude: Float = 10,
        detailFrequency: Float = 0.045,
        detailAmplitude: Float = 3,
        hillRegionFrequency: Float = 0.007,
        ridgeFrequency: Float = 0.018,
        hillAmplitude: Float = 24,
        maximumSurfaceHeight: Int = 56,
        seaLevel: Int = 25,
        sandDepth: Int = 4,
        coalFrequency: Float = 0.12,
        coalThreshold: Float = 0.38,
        maximumCoalY: Int = 24
    ) {
        self.seed = seed
        self.surfaceY = surfaceY
        self.dirtDepth = dirtDepth
        self.baseHeight = baseHeight
        self.continentalFrequency = continentalFrequency
        self.continentalAmplitude = continentalAmplitude
        self.detailFrequency = detailFrequency
        self.detailAmplitude = detailAmplitude
        self.hillRegionFrequency = hillRegionFrequency
        self.ridgeFrequency = ridgeFrequency
        self.hillAmplitude = hillAmplitude
        self.maximumSurfaceHeight = maximumSurfaceHeight
        self.seaLevel = seaLevel
        self.sandDepth = sandDepth
        self.coalFrequency = coalFrequency
        self.coalThreshold = coalThreshold
        self.maximumCoalY = maximumCoalY
    }
}

/// 将地形规则与 Chunk 数据容器、World 加载流程隔离。
protocol TerrainGenerating {
    func surfaceHeight(worldX: Int, worldZ: Int) -> Int
    func generateChunk(at coord: ChunkCoord) -> Chunk
}

/// 节点 3 的过渡生成器：配置已携带种子，但暂不使用噪声改变地形。
struct FlatTerrainGenerator: TerrainGenerating {
    let configuration: TerrainConfiguration

    init(configuration: TerrainConfiguration) {
        self.configuration = configuration
    }

    func surfaceHeight(worldX: Int, worldZ: Int) -> Int {
        min(max(configuration.surfaceY, 1), Chunk.height - 1)
    }

    func generateChunk(at coord: ChunkCoord) -> Chunk {
        var chunk = Chunk()
        let surfaceY = surfaceHeight(worldX: 0, worldZ: 0)
        let dirtStartY = max(1, surfaceY - max(configuration.dirtDepth, 0))

        for x in 0..<Chunk.width {
            for z in 0..<Chunk.depth {
                for y in 0...surfaceY {
                    switch y {
                    case 0:
                        chunk[x, y, z] = .bedrock
                    case surfaceY:
                        chunk[x, y, z] = .grass
                    case dirtStartY..<surfaceY:
                        chunk[x, y, z] = .dirt
                    default:
                        chunk[x, y, z] = .stone
                    }
                }
            }
        }
        return chunk
    }
}

/// 使用绝对世界坐标生成连续高度图；当前只填充石头、泥土和草。
struct HeightmapTerrainGenerator: TerrainGenerating {
    let configuration: TerrainConfiguration
    private let continentalNoise: SeededNoise
    private let detailNoise: SeededNoise
    private let hillRegionNoise: SeededNoise
    private let ridgeNoise: SeededNoise
    private let coalNoise: SeededNoise

    init(configuration: TerrainConfiguration) {
        self.configuration = configuration
        // 各生成通道使用独立盐值，后续调整某一层时不会与其他层产生相关图案。
        self.continentalNoise = SeededNoise(seed: configuration.seed ^ 0xA24B_AED4_963E_E407)
        self.detailNoise = SeededNoise(seed: configuration.seed ^ 0x9FB2_1C65_1E98_DF25)
        self.hillRegionNoise = SeededNoise(seed: configuration.seed ^ 0xC13F_A9A9_02A6_328F)
        self.ridgeNoise = SeededNoise(seed: configuration.seed ^ 0x91E1_0DA5_C79E_7B1D)
        self.coalNoise = SeededNoise(seed: configuration.seed ^ 0xD1B5_4A32_D192_ED03)
    }

    func surfaceHeight(worldX: Int, worldZ: Int) -> Int {
        let x = Float(worldX)
        let z = Float(worldZ)

        // 大尺度轮廓负责低地与宽缓地势。
        let continental = continentalNoise.fBm2D(
            x: x * configuration.continentalFrequency,
            z: z * configuration.continentalFrequency,
            octaves: 4
        )

        // 高频层只提供少量变化，避免平原成为完全规则的平台。
        let detail = detailNoise.fBm2D(
            x: x * configuration.detailFrequency,
            z: z * configuration.detailFrequency,
            octaves: 3
        )

        // 低频遮罩决定丘陵出现在哪些区域；smoothstep 避免阈值造成台阶。
        let hillRegion = hillRegionNoise.fBm2D(
            x: x * configuration.hillRegionFrequency,
            z: z * configuration.hillRegionFrequency,
            octaves: 3
        )
        let hillBlend = smoothstep(edge0: -0.25, edge1: 0.4, value: hillRegion)

        // 将普通噪声折叠为脊状形态，并用三次曲线拉开山谷与山脊的高度差。
        let ridgeSample = ridgeNoise.fBm2D(
            x: x * configuration.ridgeFrequency,
            z: z * configuration.ridgeFrequency,
            octaves: 4
        )
        let foldedRidge = max(0, 1 - abs(ridgeSample))
        let ridge = foldedRidge * foldedRidge * foldedRidge

        let rawHeight = Float(configuration.baseHeight)
            + continental * configuration.continentalAmplitude
            + detail * configuration.detailAmplitude
            + hillBlend * ridge * configuration.hillAmplitude
        let height = Int(round(rawHeight))
        let upperBound = min(configuration.maximumSurfaceHeight, Chunk.height - 2)
        return min(max(height, 1), upperBound)
    }

    private func smoothstep(edge0: Float, edge1: Float, value: Float) -> Float {
        let amount = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return amount * amount * (3 - 2 * amount)
    }

    func generateChunk(at coord: ChunkCoord) -> Chunk {
        var chunk = Chunk()
        let originX = coord.x * Chunk.width
        let originZ = coord.z * Chunk.depth

        for localX in 0..<Chunk.width {
            for localZ in 0..<Chunk.depth {
                let surfaceY = surfaceHeight(
                    worldX: originX + localX,
                    worldZ: originZ + localZ
                )
                let dirtStartY = max(1, surfaceY - max(configuration.dirtDepth, 0))
                let sandStartY = max(1, surfaceY - max(configuration.sandDepth - 1, 0))
                let isSandyLowland = surfaceY <= configuration.seaLevel

                for y in 0...surfaceY {
                    switch y {
                    case 0:
                        chunk[localX, y, localZ] = .bedrock
                    case sandStartY...surfaceY where isSandyLowland:
                        chunk[localX, y, localZ] = .sand
                    case surfaceY:
                        chunk[localX, y, localZ] = .grass
                    case dirtStartY..<surfaceY:
                        chunk[localX, y, localZ] = .dirt
                    default:
                        let worldX = originX + localX
                        let worldZ = originZ + localZ
                        chunk[localX, y, localZ] = isCoal(
                            worldX: worldX,
                            y: y,
                            worldZ: worldZ
                        ) ? .coalOre : .stone
                    }
                }
            }
        }
        return chunk
    }

    private func isCoal(worldX: Int, y: Int, worldZ: Int) -> Bool {
        guard y > 0, y <= configuration.maximumCoalY else { return false }
        let frequency = configuration.coalFrequency
        let sample = coalNoise.fBm3D(
            x: Float(worldX) * frequency,
            y: Float(y) * frequency,
            z: Float(worldZ) * frequency,
            octaves: 3
        )
        return sample > configuration.coalThreshold
    }
}

/// 基于世界种子和绝对坐标的无状态二维噪声。
/// 相同输入始终得到相同输出，采样结果不依赖调用或 Chunk 加载顺序。
struct SeededNoise {
    let seed: UInt64

    /// 平滑插值后的二维 value noise，返回约 `-1...1`。
    func value2D(x: Float, z: Float) -> Float {
        let x0 = Int(floor(x))
        let z0 = Int(floor(z))
        let x1 = x0 + 1
        let z1 = z0 + 1
        let tx = smooth(x - Float(x0))
        let tz = smooth(z - Float(z0))

        let top = mix(valueAt(x: x0, z: z0), valueAt(x: x1, z: z0), by: tx)
        let bottom = mix(valueAt(x: x0, z: z1), valueAt(x: x1, z: z1), by: tx)
        return mix(top, bottom, by: tz)
    }

    /// 三线性平滑插值的三维 value noise，供矿物等地下结构使用。
    func value3D(x: Float, y: Float, z: Float) -> Float {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let z0 = Int(floor(z))
        let x1 = x0 + 1
        let y1 = y0 + 1
        let z1 = z0 + 1
        let tx = smooth(x - Float(x0))
        let ty = smooth(y - Float(y0))
        let tz = smooth(z - Float(z0))

        let z0y0 = mix(valueAt(x: x0, y: y0, z: z0), valueAt(x: x1, y: y0, z: z0), by: tx)
        let z0y1 = mix(valueAt(x: x0, y: y1, z: z0), valueAt(x: x1, y: y1, z: z0), by: tx)
        let z1y0 = mix(valueAt(x: x0, y: y0, z: z1), valueAt(x: x1, y: y0, z: z1), by: tx)
        let z1y1 = mix(valueAt(x: x0, y: y1, z: z1), valueAt(x: x1, y: y1, z: z1), by: tx)
        let z0Plane = mix(z0y0, z0y1, by: ty)
        let z1Plane = mix(z1y0, z1y1, by: ty)
        return mix(z0Plane, z1Plane, by: tz)
    }

    /// 叠加多层不同频率的 value noise，返回归一化后的约 `-1...1`。
    func fBm2D(
        x: Float,
        z: Float,
        octaves: Int = 4,
        lacunarity: Float = 2,
        persistence: Float = 0.5
    ) -> Float {
        precondition(octaves > 0)
        var frequency: Float = 1
        var amplitude: Float = 1
        var total: Float = 0
        var amplitudeTotal: Float = 0

        for _ in 0..<octaves {
            total += value2D(x: x * frequency, z: z * frequency) * amplitude
            amplitudeTotal += amplitude
            frequency *= lacunarity
            amplitude *= persistence
        }
        return total / amplitudeTotal
    }

    func fBm3D(
        x: Float,
        y: Float,
        z: Float,
        octaves: Int = 3,
        lacunarity: Float = 2,
        persistence: Float = 0.5
    ) -> Float {
        precondition(octaves > 0)
        var frequency: Float = 1
        var amplitude: Float = 1
        var total: Float = 0
        var amplitudeTotal: Float = 0

        for _ in 0..<octaves {
            total += value3D(
                x: x * frequency,
                y: y * frequency,
                z: z * frequency
            ) * amplitude
            amplitudeTotal += amplitude
            frequency *= lacunarity
            amplitude *= persistence
        }
        return total / amplitudeTotal
    }

    private func valueAt(x: Int, z: Int) -> Float {
        var hash = seed
        hash ^= UInt64(bitPattern: Int64(x)) &* 0x9E3779B185EBCA87
        hash = mixed(hash)
        hash ^= UInt64(bitPattern: Int64(z)) &* 0xC2B2AE3D27D4EB4F
        hash = mixed(hash)

        let unit = Float(hash >> 40) / Float(0x00FF_FFFF)
        return unit * 2 - 1
    }

    private func valueAt(x: Int, y: Int, z: Int) -> Float {
        var hash = seed
        hash ^= UInt64(bitPattern: Int64(x)) &* 0x9E3779B185EBCA87
        hash = mixed(hash)
        hash ^= UInt64(bitPattern: Int64(y)) &* 0x165667B19E3779F9
        hash = mixed(hash)
        hash ^= UInt64(bitPattern: Int64(z)) &* 0xC2B2AE3D27D4EB4F
        hash = mixed(hash)

        let unit = Float(hash >> 40) / Float(0x00FF_FFFF)
        return unit * 2 - 1
    }

    private func mixed(_ value: UInt64) -> UInt64 {
        var result = value
        result ^= result >> 30
        result &*= 0xBF58476D1CE4E5B9
        result ^= result >> 27
        result &*= 0x94D049BB133111EB
        result ^= result >> 31
        return result
    }

    private func smooth(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }

    private func mix(_ first: Float, _ second: Float, by amount: Float) -> Float {
        first + (second - first) * amount
    }
}

/// 世界、区块和局部坐标之间的唯一换算入口。
enum WorldCoordinates {
    static func chunkCoord(for position: simd_float3) -> ChunkCoord {
        ChunkCoord(
            x: Int(floor(position.x / Float(Chunk.width))),
            z: Int(floor(position.z / Float(Chunk.depth)))
        )
    }

    static func chunkAndLocal(x: Int, z: Int) -> (coord: ChunkCoord, localX: Int, localZ: Int) {
        let chunkX = floorDivide(x, by: Chunk.width)
        let chunkZ = floorDivide(z, by: Chunk.depth)
        return (
            ChunkCoord(x: chunkX, z: chunkZ),
            x - chunkX * Chunk.width,
            z - chunkZ * Chunk.depth
        )
    }

    static func worldOrigin(for coord: ChunkCoord) -> simd_float3 {
        simd_float3(
            Float(coord.x * Chunk.width),
            0,
            Float(coord.z * Chunk.depth)
        )
    }

    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}

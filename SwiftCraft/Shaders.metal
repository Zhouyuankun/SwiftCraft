#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position;
    float2 texCoord; // 必须匹配 Swift 中的顺序
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float4x4 mvp;
};

vertex VertexOut vertex_main(constant VertexIn *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = uniforms.mvp * float4(vertices[vid].position, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]]) {
    // 关键：开启 Nearest 采样，保持像素颗粒感，不模糊
    sampler textureSampler(mag_filter::nearest, min_filter::nearest);

    float4 color = tex.sample(textureSampler, in.texCoord);

    return color;
}

// MARK: - 天空渐变 (Sky Gradient)

struct SkyVertexOut {
    float4 position [[position]];
    float2 ndc; // 裁剪空间 xy，用于在片元着色器中反推视线方向
};

struct SkyUniforms {
    float4x4 invViewProj; // 视图投影矩阵的逆矩阵
    float3 cameraPos;     // 相机世界坐标
};

// 用 3 个顶点生成一个覆盖全屏的三角形（无需顶点缓冲区），深度贴到远裁剪面
vertex SkyVertexOut sky_vertex(uint vid [[vertex_id]]) {
    SkyVertexOut out;
    float2 pos = float2(
        (vid == 1) ?  3.0 : -1.0,
        (vid == 2) ?  3.0 : -1.0
    );
    out.position = float4(pos, 1.0, 1.0); // z = 1.0：Metal 深度范围的远端
    out.ndc = pos;
    return out;
}

fragment float4 sky_fragment(SkyVertexOut in [[stage_in]],
                             constant SkyUniforms &u [[buffer(1)]]) {
    // 通过逆视图投影矩阵，把屏幕上的像素反投影回世界空间，得到视线方向
    float4 farPoint = u.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 dir = normalize(farPoint.xyz / farPoint.w - u.cameraPos);

    // 三段式渐变：头顶深蓝、地平线浅蓝、地平线以下渐变为深色
    float3 zenith  = float3(0.25, 0.55, 1.00); // 头顶的天空蓝
    float3 horizon = float3(0.75, 0.88, 1.00); // 地平线附近的浅蓝
    float3 ground  = float3(0.04, 0.04, 0.07); // 向下看时的深色

    float3 color;
    if (dir.y >= 0.0) {
        color = mix(horizon, zenith, pow(dir.y, 0.6));
    } else {
        color = mix(horizon, ground, pow(-dir.y, 0.4));
    }
    return float4(color, 1.0);
}

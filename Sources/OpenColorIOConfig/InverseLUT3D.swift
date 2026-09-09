// SPDX-License-Identifier: BSD-3-Clause
// Follows OCIO's inverse LUT extrapolation, range-tree order and tetrahedra.
import Foundation

extension OCIONativeCompiler {
    mutating func appendInverseLUT3D(_ lut: OCIONativeLUT) throws {
        var tree = NativeInverseLUTTree(lut: lut)
        tree.build()
        let gridID = textures.count
        textures.append(OCIONativeTexture(index: gridID, dimension: 3, width: tree.dimension, height: tree.dimension, depth: tree.dimension, channels: 3, values: tree.grid))
        let treeID = textures.count
        let width = min(4096, tree.nodes.count / 4)
        let height = (tree.nodes.count / 4 + width - 1) / width
        let nodeCount = tree.nodes.count / 12
        tree.nodes += Array(repeating: 0, count: width * height * 4 - tree.nodes.count)
        textures.append(OCIONativeTexture(index: treeID, dimension: 2, width: width, height: height, depth: 1, channels: 4, values: tree.nodes))
        let helper = Self.inverseLUTSolver
        if !helperFunctions.contains(helper) { helperFunctions.append(helper) }
        let ranges = zip(lut.domainMinimum, lut.domainMaximum).map { $1 - $0 }
        func read(_ index: String) -> String { "lut\(treeID).read(uint2((\(index)) % \(width)u, (\(index)) / \(width)u))" }
        body.append("""
        {
            float3 target = clamp(select(pixel.rgb, float3(0.0f), isnan(pixel.rgb)), 0.0f, 1.0f);
            float3 result = float3(0.0f);
            uint node = 0u;
            bool found = false;
            while (node < \(nodeCount)u && !found) {
                float3 minimum = \(read("node * 3u")).rgb;
                float3 maximum = \(read("node * 3u + 1u")).rgb;
                float4 info = \(read("node * 3u + 2u"));
                if (any(target < minimum) || any(target > maximum)) { node = uint(info.x); continue; }
                if (info.y < 0.0f) { node++; continue; }
                uint3 lower = uint3(info.yzw);
                float3 base = lut\(gridID).read(lower).rgb;
                float3 diagonal = lut\(gridID).read(lower + 1u).rgb - base;
                const uint3 first[6] = {uint3(1,0,0),uint3(0,1,0),uint3(0,1,0),uint3(0,0,1),uint3(0,0,1),uint3(1,0,0)};
                const uint3 second[6] = {uint3(1,1,0),uint3(1,1,0),uint3(0,1,1),uint3(0,1,1),uint3(1,0,1),uint3(1,0,1)};
                for (uint tetra = 0u; tetra < 6u; tetra++) {
                    float3 a = lut\(gridID).read(lower + first[tetra]).rgb - base;
                    float3 b = lut\(gridID).read(lower + second[tetra]).rgb - base;
                    float3 weights;
                    if (ocio_inverse_tetrahedron(a, b, diagonal, target - base, weights)) {
                        result = float3(lower) + float3(first[tetra]) * weights.x + float3(second[tetra]) * weights.y + weights.z;
                        found = true; break;
                    }
                }
                node++;
            }
            pixel.rgb = clamp(result - 1.0f, 0.0f, \(mslNumber(Double(lut.size - 1)))) / \(mslNumber(Double(lut.size - 1))) * \(mslVector(ranges)) + \(mslVector(lut.domainMinimum));
        }
        """)
    }

    private static let inverseLUTSolver = """
    inline bool ocio_inverse_tetrahedron(float3 a, float3 b, float3 c, float3 target, thread float3 &weights) {
        float4 rows[3] = {float4(a.x,b.x,c.x,target.x),float4(a.y,b.y,c.y,target.y),float4(a.z,b.z,c.z,target.z)};
        uint permutation[3] = {0u,1u,2u};
        uint rank = 0u;
        for (uint col=0u; col<3u; col++) {
            uint pivotRow=col, pivotColumn=col;
            float magnitude=0.0f;
            for (uint y=col; y<3u; y++) for(uint x=col; x<3u; x++) {
                if(abs(rows[y][x])>magnitude) { magnitude=abs(rows[y][x]); pivotRow=y; pivotColumn=x; }
            }
            if(magnitude<1.0e-9f) break;
            float4 temporary=rows[col]; rows[col]=rows[pivotRow]; rows[pivotRow]=temporary;
            if(pivotColumn!=col) {
                for(uint y=0u; y<3u; y++) { float v=rows[y][col]; rows[y][col]=rows[y][pivotColumn]; rows[y][pivotColumn]=v; }
                uint p=permutation[col]; permutation[col]=permutation[pivotColumn]; permutation[pivotColumn]=p;
            }
            for(uint y=col+1u; y<3u; y++) {
                float factor=rows[y][col]/rows[col][col];
                rows[y] -= factor*rows[col];
            }
            rank++;
        }
        for(uint y=rank; y<3u; y++) if(abs(rows[y].w)>1.0e-6f) return false;
        float3 solution=float3(0.0f);
        for(int y=int(rank)-1; y>=0; y--) {
            float sum=rows[y].w;
            for(uint x=uint(y)+1u; x<rank; x++) sum-=rows[y][x]*solution[x];
            solution[y]=sum/rows[y][y];
        }
        weights=float3(0.0f);
        for(uint x=0u; x<3u; x++) weights[permutation[x]]=solution[x];
        return all(weights>=-1.0e-6f) && weights.x+weights.y+weights.z<=1.000001f;
    }
    """
}

private struct NativeInverseLUTTree {
    let dimension: Int
    let grid: [Float]
    var nodes: [Float] = []

    init(lut: OCIONativeLUT) {
        dimension = lut.size + 2
        let size = lut.size, expanded = lut.size + 2
        var grid = Array(repeating: Float(0), count: expanded * expanded * expanded * 3)
        for b in 0..<expanded { for g in 0..<expanded { for r in 0..<expanded {
            let originalR = min(max(r - 1, 0), size - 1)
            let originalG = min(max(g - 1, 0), size - 1)
            let originalB = min(max(b - 1, 0), size - 1)
            let src = (originalR + size * (originalG + size * originalB)) * 3
            let dst = (r + expanded * (g + expanded * b)) * 3
            let boundary = r == 0 || g == 0 || b == 0 || r == expanded - 1 || g == expanded - 1 || b == expanded - 1
            for channel in 0..<3 {
                let value = lut.values[src + channel]
                grid[dst + channel] = boundary ? (value - 0.5) * 4 + 0.5 : value
            }
        } } }
        self.grid = grid
    }
    mutating func build() {
        var size = 1
        while size < dimension - 1 { size *= 2 }
        _ = append(x: 0, y: 0, z: 0, size: size)
    }
    mutating func append(x: Int, y: Int, z: Int, size: Int) -> (minimum: [Float], maximum: [Float])? {
        guard x < dimension - 1, y < dimension - 1, z < dimension - 1 else { return nil }
        let offset = nodes.count
        nodes += Array(repeating: 0, count: 12)
        var minimum = Array(repeating: Float.infinity, count: 3)
        var maximum = Array(repeating: -Float.infinity, count: 3)
        if size == 1 {
            for corner in 0..<8 {
                let r = x + (corner & 1), g = y + ((corner >> 1) & 1), b = z + ((corner >> 2) & 1)
                let index = (r + dimension * (g + dimension * b)) * 3
                for channel in 0..<3 {
                    minimum[channel] = min(minimum[channel], grid[index + channel] - 0.000001)
                    maximum[channel] = max(maximum[channel], grid[index + channel] + 0.000001)
                }
            }
        } else {
            let half = size / 2
            for child in 0..<8 {
                let r = x + (child & 1) * half, g = y + ((child >> 1) & 1) * half, b = z + ((child >> 2) & 1) * half
                if let range = append(x: r, y: g, z: b, size: half) {
                    for channel in 0..<3 { minimum[channel] = min(minimum[channel], range.minimum[channel]); maximum[channel] = max(maximum[channel], range.maximum[channel]) }
                }
            }
        }
        for channel in 0..<3 { nodes[offset + channel] = minimum[channel]; nodes[offset + 4 + channel] = maximum[channel] }
        nodes[offset + 8] = Float(nodes.count / 12)
        nodes[offset + 9] = size == 1 ? Float(x) : -1
        nodes[offset + 10] = size == 1 ? Float(y) : -1
        nodes[offset + 11] = size == 1 ? Float(z) : -1
        return (minimum, maximum)
    }
}

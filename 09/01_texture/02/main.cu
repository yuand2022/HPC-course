#include <cstdio>
#include <vector>
#include <cuda_runtime.h>
#include "helper_cuda.h"
#include "helper_math.h"
#include "CudaArray.cuh"
#include "ticktock.h"
#include "writevdb.h"

__global__ void advect_kernel(CudaTexture<float4>::Accessor texVel, CudaSurface<float4>::Accessor sufLoc, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float4 vel = texVel.sample(x, y, z);
    float4 loc = make_float4(x + 0.5f, y + 0.5f, z + 0.5f, 42.f) - vel;
    sufLoc.write(loc, x, y, z);
}

__global__ void resample_kernel(CudaSurface<float4>::Accessor sufLoc, CudaTexture<float4>::Accessor texClr, CudaSurface<float4>::Accessor sufClrNext, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float4 loc = sufLoc.read(x, y, z);
    float4 clr = texClr.sample(loc.x, loc.y, loc.z);
    sufClrNext.write(clr, x, y, z);
}

__global__ void divergence_kernel(CudaSurface<float4>::Accessor sufVel, CudaSurface<float>::Accessor sufDiv, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float vxp = sufVel.read<cudaBoundaryModeClamp>(x + 1, y, z).x;
    float vxn = sufVel.read<cudaBoundaryModeClamp>(x - 1, y, z).x;
    float vyp = sufVel.read<cudaBoundaryModeClamp>(x, y + 1, z).y;
    float vyn = sufVel.read<cudaBoundaryModeClamp>(x, y - 1, z).y;
    float vzp = sufVel.read<cudaBoundaryModeClamp>(x, y, z + 1).z;
    float vzn = sufVel.read<cudaBoundaryModeClamp>(x, y, z - 1).z;
    float div = (vxp - vxn + vyp - vyn + vzp - vzn) * 0.5f;
    sufDiv.write(div, x, y, z);
}

__global__ void sumloss_kernel(CudaSurface<float>::Accessor sufDiv, float *sum, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float div = sufDiv.read(x, y, z);
    atomicAdd(sum, div * div);
}

__global__ void jacobi_kernel(CudaSurface<float>::Accessor sufDiv, CudaSurface<float>::Accessor sufPre, CudaSurface<float>::Accessor sufPreNext, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float div = sufDiv.read(x, y, z);
    float preNext = (pxp + pxn + pyp + pyn + pzp + pzn - div) * (1.f / 6.f);
    sufPreNext.write(preNext, x, y, z);
}

__global__ void subgradient_kernel(CudaSurface<float>::Accessor sufPre, CudaSurface<float4>::Accessor sufVel, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float4 vel = sufVel.read(x, y, z);
    vel.x -= 0.5f * (pxp - pxn);
    vel.y -= 0.5f * (pyp - pyn);
    vel.z -= 0.5f * (pzp - pzn);
    sufVel.write(vel, x, y, z);
}

template <int phase>
__global__ void rbgs_kernel(CudaSurface<float>::Accessor sufPre, CudaSurface<float>::Accessor sufDiv, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if ((x + y + z) % 2 != phase) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float div = sufDiv.read(x, y, z);
    float preNext = (pxp + pxn + pyp + pyn + pzp + pzn - div) * (1.f / 6.f);
    sufPre.write(preNext, x, y, z);
}

__global__ void residual_kernel(CudaSurface<float>::Accessor sufRes, CudaSurface<float>::Accessor sufPre, CudaSurface<float>::Accessor sufDiv, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float pre = sufPre.read<cudaBoundaryModeClamp>(x, y, z);
    float div = sufDiv.read(x, y, z);
    float res = pxp + pxn + pyp + pyn + pzp + pzn - 6.f * pre - div;
    sufRes.write(res, x, y, z);
}

__global__ void restrict_kernel(CudaSurface<float>::Accessor sufPreNext, CudaSurface<float>::Accessor sufPre, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float ooo = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2, z*2);
    float ioo = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2, z*2);
    float oio = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2+1, z*2);
    float iio = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2+1, z*2);
    float ooi = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2, z*2+1);
    float ioi = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2, z*2+1);
    float oii = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2+1, z*2+1);
    float iii = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2+1, z*2+1);
    float preNext = (ooo + ioo + oio + iio + ooi + ioi + oii + iii);
    sufPreNext.write(preNext, x, y, z);
}

__global__ void fillzero_kernel(CudaSurface<float>::Accessor sufPre, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    sufPre.write(0.f, x, y, z);
}

__global__ void prolongate_kernel(CudaSurface<float>::Accessor sufPreNext, CudaSurface<float>::Accessor sufPre, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float preDelta = sufPre.read(x, y, z) * (0.5f / 8.f);
#pragma unroll
    for (unsigned int dz = 0; dz < 2; dz++) {
#pragma unroll
        for (unsigned int dy = 0; dy < 2; dy++) {
#pragma unroll
            for (unsigned int dx = 0; dx < 2; dx++) {
                float preNext = sufPreNext.read<cudaBoundaryModeZero>(x*2+dx, y*2+dy, z*2+dz);
                preNext += preDelta;
                sufPreNext.write<cudaBoundaryModeZero>(preNext, x*2+dx, y*2+dy, z*2+dz);
            }
        }
    }
}

struct SmokeSim {
    nocopy_t nocopy;

    unsigned int n;
    CudaAS<float4> loc;
    CudaAST<float4> vel;
    CudaAST<float4> velNext;
    CudaAST<float4> clr;
    CudaAST<float4> clrNext;
    CudaAS<float> div;
    CudaAS<float> pre;
    CudaAS<float> preNext;

    std::vector<CudaAS<float>> res;
    std::vector<CudaAS<float>> res2;
    std::vector<CudaAS<float>> err2;
    std::vector<unsigned int> sizes;
    //std::vector<CudaAS<float>> tmpres2;

    SmokeSim(ctor_t, unsigned int _n, unsigned int _n0 = 16)
    : n(_n)
    , loc(ctor, {{n, n, n}})
    , vel(ctor, {{n, n, n}})
    , velNext(ctor, {{n, n, n}})
    , clr(ctor, {{n, n, n}})
    , clrNext(ctor, {{n, n, n}})
    , div(ctor, {{n, n, n}})
    , pre(ctor, {{n, n, n}})
    , preNext(ctor, {{n, n, n}})
    {
        unsigned int tn;
        for (tn = n; tn >= _n0; tn /= 2) {
            res.push_back(CudaAS<float>(ctor, {{tn, tn, tn}}));
            res2.push_back(CudaAS<float>(ctor, {{tn/2, tn/2, tn/2}}));
            err2.push_back(CudaAS<float>(ctor, {{tn/2, tn/2, tn/2}}));
            sizes.push_back(tn);
        }
        //tmpres2.push_back(CudaAS<float>(ctor, {{tn/2, tn/2, tn/2}}));
    }

    void smooth(/*CudaSurface<float> &r, */CudaSurface<float> &v, CudaSurface<float> &f, unsigned int lev, int times = 8) {
        unsigned int tn = sizes[lev];
        for (int step = 0; step < times; step++) {
            //jacobi_kernel<<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(r.access(), v.access(), f.access(), tn);
            //jacobi_kernel<<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(v.access(), r.access(), f.access(), tn);
            rbgs_kernel<0><<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(v.access(), f.access(), tn);
            rbgs_kernel<1><<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(v.access(), f.access(), tn);
        }
    }

    void vcycle(unsigned int lev, CudaSurface<float> &v, CudaSurface<float> &f) {
        if (lev >= sizes.size()) {
            unsigned int tn = sizes.back() / 2;
            smooth(v, f, lev);
            return;
        }
        auto &r = res[lev].suf;
        auto &r2 = res2[lev].suf;
        auto &e2 = err2[lev].suf;
        unsigned int tn = sizes[lev];
        smooth(v, f, lev);
        residual_kernel<<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(r.access(), v.access(), f.access(), tn);
        restrict_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(r2.access(), r.access(), tn/2);
        fillzero_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(e2.access(), tn/2);
        vcycle(lev + 1, e2, r2);
        prolongate_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(v.access(), e2.access(), tn/2);
        smooth(v, f, lev);
    }

    void projection() {
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel.suf.access(), div.suf.access(), n);
        vcycle(0, pre.suf, div.suf);
        subgradient_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(pre.suf.access(), vel.suf.access(), n);
    }

    void advection() {
        advect_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel.tex.access(), loc.suf.access(), n);
        resample_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(loc.suf.access(), clr.tex.access(), clrNext.suf.access(), n);
        resample_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(loc.suf.access(), vel.tex.access(), velNext.suf.access(), n);

        std::swap(vel, velNext);
        std::swap(clr, clrNext);
    }

    void naive_projection(int times = 400) {
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel.suf.access(), div.suf.access(), n);

        for (int step = 0; step < times; step++) {
            jacobi_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(div.suf.access(), pre.suf.access(), preNext.suf.access(), n);
            std::swap(pre, preNext);
        }

        subgradient_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(pre.suf.access(), vel.suf.access(), n);
    }

    float calc_loss() {
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel.suf.access(), div.suf.access(), n);
        float *sum;
        checkCudaErrors(cudaMalloc(&sum, sizeof(float)));
        sumloss_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(div.suf.access(), sum, n);
        float cpu;
        checkCudaErrors(cudaMemcpy(&cpu, sum, sizeof(float), cudaMemcpyDeviceToHost));
        checkCudaErrors(cudaFree(sum));
        return cpu;
    }
};

int main() {
    unsigned int n = 64;
    SmokeSim sim(ctor, n);

    {
        std::vector<float4> cpu(n * n * n);
        for (unsigned int z = 0; z < n; z++) {
            for (unsigned int y = 0; y < n; y++) {
                for (unsigned int x = 0; x < n; x++) {
                    float den = std::hypot((int)x - (int)n / 2, (int)y - (int)n / 2, (int)z - (int)n / 2) < n / 4 ? 1.f : 0.f;
                    cpu[x + n * (y + n * z)] = make_float4(den, 0.f, 0.f, 0.f);
                }
            }
        }
        sim.clr.arr.copyIn(cpu.data());
    }

    {
        std::vector<float4> cpu(n * n * n);
        for (unsigned int z = 0; z < n; z++) {
            for (unsigned int y = 0; y < n; y++) {
                for (unsigned int x = 0; x < n; x++) {
                    float vel = std::hypot((int)x - (int)n / 2, (int)y - (int)n / 2, (int)z - (int)n / 2) < n / 4 ? 0.5f : 0.f;
                    cpu[x + n * (y + n * z)] = make_float4(0.f, 0.f, vel, 0.f);
                }
            }
        }
        sim.vel.arr.copyIn(cpu.data());
    }

    std::vector<float4> cpu(n * n * n);
    for (int frame = 1; frame <= 100; frame++) {
        sim.clr.arr.copyOut(cpu.data());
        writevdb<float, 1>("/tmp/a" + std::to_string(1000 + frame).substr(1) + ".vdb", cpu.data(), n, n, n, sizeof(float4));

        printf("frame=%d, loss=%f\n", frame, sim.calc_loss());
        sim.advection();
        sim.projection();
    }

    return 0;
}

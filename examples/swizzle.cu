/*
This code demonstrates how to use the dense wgmma instructions
to perform matrix multiplication
*/

#include <stdio.h>
#include <cuda.h>
#include <mma.h>
#include <assert.h>
#include <cuda_fp16.h>
#include <random>
#include <iostream>

#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"
#include "wgmma.cuh"

const int M = 64;
const int N = 8;
const int K = 16;

const int threads_per_block = 32 * 4; // 4 warps
const int blocks = 1;

__global__ void kernel(half *A, half *B, half *C)
{
  // metadata
  const int tid = threadIdx.x;
  const int warp_id = tid / 32;
  const int lane_id = tid % 32;
  const int group_id = lane_id >> 2;
  const int lane_in_group = lane_id & 3;

  __syncthreads();

  __align__(16) __shared__ half A_shared[M * K];
  __align__(16) __shared__ half B_shared[K * N];

  __align__(16) __shared__ half buffer[2 * 64];

  // https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#asynchronous-multiply-and-accumulate-instruction-wgmma-mma-async
  // 8x8 core blocks, we use one thread here to
  // easy demonstrate the required layout
  if (tid == 0)
  {
    for (int i = 0; i < M; i++)
    {
      for (int j = 0; j < K; j++)
      {
        int block_x = i / 8;
        int block_row = i % 8;
        int block_y = j / 8;
        int block_col = j % 8;
        int block_id = block_x * 2 + block_y;
        int offset = block_id * 64 + block_row * 8 + block_col;
        A_shared[offset] = A[i * K + j];
      }
    }
    
    // swizzle A
    for (int pair = 0; pair < 8; pair++) {
        
        for (int i = 0; i < 8; i++) {
            if (i % 2 == 0) {
                for (int j = 0; j < 8; j++) {
                    buffer[i * 8 + j] = A_shared[pair * 128 + i / 2 * 8 + j];
                }
            }
            else {
                for (int j = 0; j < 8; j++) {
                    buffer[i * 8 + j] = A_shared[pair * 128 + 64 + i / 2 * 8 + j];
                }
            }
        }
        
        for (int i = 0; i < 8; i++) {
            if (i % 2 == 0) {
                for (int j = 0; j < 8; j++) {
                    buffer[64 + i * 8 + j] = A_shared[pair * 128 + 64 + i / 2 * 8 + j];
                }
            }
            else {
                for (int j = 0; j < 8; j++) {
                    buffer[64 + i * 8 + j] = A_shared[pair * 128 + i / 2 * 8 + j];
                }
            }
        }
        
        // write back to A_shared
        for (int row = 0; row < 16; row ++) {
            for (int col = 0; col < 8; col++) {
                A_shared[pair * 128 + row * 8 + col] = buffer[row * 8 + col];
            }
        }
    }

    for (int i = 0; i < K; i++)
    {
      for (int j = 0; j < N; j++)
      {
        int block_x = i / 8;
        int block_row = i % 8;
        int block_y = j / 8;
        int block_col = j % 8;
        int block_id = block_x * 1 + block_y;
        int offset = block_id * 64 + block_row * 8 + block_col;
        B_shared[offset] = B[i * N + j];
      }
    }
  }

  __syncthreads();

  // create descriptors for the matrices
  GmmaDescriptor desc_a = make_desc_a(A_shared);
  GmmaDescriptor desc_b = make_desc_b(B_shared);

  // accumulator
  uint32_t c[2] = {};

  // called whenever the accumulator is accessed
  warpgroup_arrive();

  // wgmma.mma_async.sync.aligned.shape.dtype.f16.f16  d, a-desc, b-desc, scale-d, imm-scale-a, imme-scale-b, imm-trans-a, imm-trans-b;
  // wgmma.mma_async.sync.aligned.shape.dtype.f16.f16  d, a, b-desc, scale-d, imm-scale-a, imme-scale-b, imm-trans-b;
  asm volatile("wgmma.mma_async.sync.aligned.m64n8k16.f16.f16.f16 "
               "{%0, %1}, " // accumulator
               "%2, %3, "   // matrix a descriptor
               "1, "        // 0 => D = A*B, 1 => D = D + A*B
               "1, 1, "     // 0 => no scaling, 1 => scaling, scaling means times -1 to a or b
               "0, 1;"      // transpose a and b, 0 => no transpose, 1 => transpose
               : "+r"(c[0]), "+r"(c[1])
               : "l"(desc_a), "l"(desc_b));

  // commit, start the computation
  warpgroup_commit_batch();

  // wait for the previous commit to finish
  warpgroup_wait<0>();

  // thread fence needed for async operations
  __threadfence();

  warpgroup_arrive();

  uint32_t *C_ptr = reinterpret_cast<uint32_t *>(C);

  int offset1 = warp_id * 16 * 4 + group_id * 4 + lane_in_group;
  int offset2 = warp_id * 16 * 4 + (group_id + 8) * 4 + lane_in_group;

  // write back to global memory
  C_ptr[offset1] = c[0];
  C_ptr[offset2] = c[1];
}

int main()
{

  half *d_C;
  half h_C[M * N];
  half h_CPU[M * N];
  half h_A[M * K];
  half h_B[K * N];

  fill_fixed(h_C, M, N, 0);

  fill_random(h_A, M, K);
  fill_random(h_B, K, N);

  half *d_A, *d_B;

  cudaMalloc((void **)&d_A, M * K * sizeof(half));
  cudaMalloc((void **)&d_B, K * N * sizeof(half));
  cudaMalloc((void **)&d_C, M * N * sizeof(half));

  cudaMemcpy(d_A, h_A, M * K * sizeof(half), cudaMemcpyHostToDevice);
  cudaMemcpy(d_B, h_B, K * N * sizeof(half), cudaMemcpyHostToDevice);

  kernel<<<blocks, threads_per_block>>>(d_A, d_B, d_C);

  cuda_check_error();

  cudaMemcpy(h_C, d_C, M * N * sizeof(half), cudaMemcpyDeviceToHost);

  // print_matrix(h_C, M, N);

  CPU_gemm(h_A, h_B, h_CPU, M, N, K);

  compare_matrices(h_CPU, h_C, M, N);

  // print_differnce(h_C, h_CPU, M, N, 0.0f);

  return 0;
}

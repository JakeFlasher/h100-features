/*
This code demonstrates how to use the dense wgmma instructions
to perform matrix multiplication
*/

#include <assert.h>
#include <cuda.h>
#include <cuda/barrier>
#include <cuda_fp16.h>
#include <iostream>
#include <mma.h>
#include <random>
#include <stdio.h>

#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"
#include "tma_tensor_map.cuh"
#include "wgmma.cuh"

// Suppress warning about barrier in shared memory
#pragma nv_diag_suppress static_var_with_dynamic_init

using barrier = cuda::barrier<cuda::thread_scope_block>;
namespace cde = cuda::device::experimental;

const int M = 64;
const int N = 8;
const int K = 16;

const int threads_per_block = 32 * 4; // 4 warps
const int blocks = 1;

__global__ void kernel(const __grid_constant__ CUtensorMap tensor_map, half *B,
					   half *C) {
	// metadata
	const int tid = threadIdx.x;
	const int warp_id = tid / 32;
	const int lane_id = tid % 32;
	const int group_id = lane_id >> 2;
	const int lane_in_group = lane_id & 3;

	__syncthreads();

	__align__(128) __shared__ half A_shared[M * K];
	__align__(16) __shared__ half B_shared[K * N];

	__shared__ barrier bar;

	if (threadIdx.x == 0) {
		init(&bar, blockDim.x);
	}
	__syncthreads();

	// https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#asynchronous-multiply-and-accumulate-instruction-wgmma-mma-async
	// 8x8 core blocks, we use one thread here to
	// easy demonstrate the required layout
	if (tid == 0) {
		// load B
		for (int i = 0; i < K; i++) {
			for (int j = 0; j < N; j++) {
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

	// Load A
	uint64_t token;
	if (tid == 0) {
		// call the loading api
		cde::cp_async_bulk_tensor_2d_global_to_shared(A_shared, &tensor_map, 0,
													  0, bar);
		token = cuda::device::barrier_arrive_tx(bar, 1, sizeof(A_shared));
	} else {
		token = bar.arrive();
	}

	bar.wait(cuda::std::move(token));

	__syncthreads();

	// create descriptors for the matrices
	GmmaDescriptor desc_a = make_desc_a<half *, 3>(A_shared);
	GmmaDescriptor desc_b = make_desc_b(B_shared);

	// accumulator
	uint32_t c[2] = {};

	// called whenever the accumulator is accessed
	warpgroup_arrive();

	// wgmma.mma_async.sync.aligned.shape.dtype.f16.f16  d, a-desc, b-desc,
	// scale-d, imm-scale-a, imme-scale-b, imm-trans-a, imm-trans-b;
	// wgmma.mma_async.sync.aligned.shape.dtype.f16.f16  d, a, b-desc, scale-d,
	// imm-scale-a, imme-scale-b, imm-trans-b;
	asm volatile("wgmma.mma_async.sync.aligned.m64n8k16.f16.f16.f16 "
				 "{%0, %1}, " // accumulator
				 "%2, %3, "	  // matrix a descriptor
				 "1, "		  // 0 => D = A*B, 1 => D = D + A*B
				 "1, 1, " // 0 => no scaling, 1 => scaling, scaling means times
						  // -1 to a or b
				 "0, 1;" // transpose a and b, 0 => no transpose, 1 => transpose
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

int main() {

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

	CUtensorMap tensor_map = create_2d_tensor_map_half<1>(M, K, M, K, d_A);

	kernel<<<blocks, threads_per_block>>>(tensor_map, d_B, d_C);

	cuda_check_error();

	cudaMemcpy(h_C, d_C, M * N * sizeof(half), cudaMemcpyDeviceToHost);

	// print_matrix(h_C, M, N);

	CPU_gemm(h_A, h_B, h_CPU, M, N, K);

	compare_matrices(h_CPU, h_C, M, N);

	// print_differnce(h_C, h_CPU, M, N, 0.0f);

	return 0;
}

/*
This code uses TMA's 1d tensor load to load
a portion of an array to shared memory and then
change the value in the shared memory and uses TMA's store
to store the portion back to global memory. We print the result
to show the changes are done.
*/

// supress warning about barrier in shared memory on line 32

#include <cooperative_groups.h>
#include <cuda/barrier>
#include <iostream>

#include "matrix_utilities.cuh"
#include "profile_utilities.cuh"
#include "tma.cuh"
#include "tma_tensor_map.cuh"

using barrier = cuda::barrier<cuda::thread_scope_block>;
namespace cde = cuda::device::experimental;

namespace cg = cooperative_groups;

const int array_size = 128;
const int tile_size = 16;
const int cluster_size = 4; // we use 4 blocks in a cluster

__global__ void __cluster_dims__(cluster_size, 1, 1)
	kernel(const __grid_constant__ CUtensorMap tensor_map, int coordinate,
		   int *result) {
	// cluster metadata
	cg::cluster_group cluster = cg::this_cluster();
	unsigned int clusterBlockRank = cluster.block_rank();

	__shared__ alignas(16) int tile_shared[tile_size];

	// we let the first block in the cluster to load a
	// tile to the shared memory of all 4 blocks
	if (clusterBlockRank == 0) {
		__shared__ barrier bar;

		if (threadIdx.x == 0) {
			init(&bar, blockDim.x);
			cde::fence_proxy_async_shared_cta();
		}
		__syncthreads();

		barrier::arrival_token token;
		if (threadIdx.x == 0) {
			/*
			each bit represents a block in the cluster, starting from the least
			significant bit (the right side)

			here we use block mask 1011, which means
			blocks 0, 1, and 3 will recieve the data from multicast
			whereas block 2 will not

			we will verify this by printing the result
			*/
			uint16_t ctaMask = 0b1011;
			asm volatile(
				"cp.async.bulk.tensor.1d.shared::cluster.global.tile.mbarrier::"
				"complete_tx::bytes.multicast::cluster "
				"[%0], [%1, {%2}], [%3], %4;\n"
				:
				: "r"(static_cast<_CUDA_VSTD::uint32_t>(
					  __cvta_generic_to_shared(tile_shared))),
				  "l"(&tensor_map), "r"(coordinate),
				  "r"(static_cast<_CUDA_VSTD::uint32_t>(
					  __cvta_generic_to_shared(
						  ::cuda::device::barrier_native_handle(bar)))),
				  "h"(ctaMask)
				: "memory");

			token =
				cuda::device::barrier_arrive_tx(bar, 1, sizeof(tile_shared));
		} else {
			token = bar.arrive();
		}

		bar.wait(std::move(token));
	}

	// rest of the clusters needs to wait for cluster 0 to load the data
	cluster.sync();

	// put the results back
	if (clusterBlockRank == 0 && threadIdx.x == 0) {
		for (int i = 0; i < tile_size; ++i) {
			result[clusterBlockRank * tile_size + i] = tile_shared[i];
		}
	}

	if (clusterBlockRank == 1 && threadIdx.x == 0) {
		for (int i = 0; i < tile_size; ++i) {
			result[clusterBlockRank * tile_size + i] = tile_shared[i];
		}
	}

	if (clusterBlockRank == 2 && threadIdx.x == 0) {
		for (int i = 0; i < tile_size; ++i) {
			result[clusterBlockRank * tile_size + i] = tile_shared[i];
		}
	}

	if (clusterBlockRank == 3 && threadIdx.x == 0) {
		for (int i = 0; i < tile_size; ++i) {
			result[clusterBlockRank * tile_size + i] = tile_shared[i];
		}
	}
}

int main() {
	// initialize array and fill it with values
	int h_data[array_size];
	for (size_t i = 0; i < array_size; ++i) {
		h_data[i] = i;
	}

	// print the array before the kernel
	// one tile per line
	print_matrix(h_data, array_size / tile_size, tile_size);

	// transfer array to device
	int *d_data = nullptr;
	cudaMalloc(&d_data, array_size * sizeof(int));
	cudaMemcpy(d_data, h_data, array_size * sizeof(int),
			   cudaMemcpyHostToDevice);

	// create tensor map
	CUtensorMap tensor_map =
		create_1d_tensor_map(array_size, tile_size, d_data);

	// a 2d array that will be used to store the tile loaded to each block
	int *d_result = nullptr;
	cudaMalloc(&d_result, tile_size * cluster_size * sizeof(int));

	size_t offset =
		tile_size * 3; // select the second tile of the array to change
	kernel<<<cluster_size, 128>>>(tensor_map, offset, d_result);

	cuda_check_error();

	// transfer the result back to host
	int h_result[tile_size * cluster_size];
	cudaMemcpy(h_result, d_result, tile_size * cluster_size * sizeof(int),
			   cudaMemcpyDeviceToHost);

	// print the result for each block
	print_matrix(h_result, cluster_size, tile_size);

	cudaFree(d_data);

	return 0;
}

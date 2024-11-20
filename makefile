sm_version=90a
NVCC=/usr/local/cuda-12.4/bin/nvcc
INCLUDES=-I./headers/device/ -I./headers/host/
OPTIMIZATION=-O0
LINKS=-lcudart -lcuda
OUTPUT=bins/bin


all:
	make test
	make run

test:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} archive/test.cu

cluster:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/cluster.cu

dense:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/wgmma_dense.cu

sparse:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/wgmma_sparse.cu

overlap:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/overlap.cu

gemm:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/gemm.cu

tma_1d:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/tma_1d.cu

tma_2d:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/tma_2d.cu

multicast:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/multicast.cu

reduce:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/reduce_store.cu

tma_1d_ptx:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/tma_1d_ptx.cu
	
swizzle:
	${NVCC} -arch=sm_${sm_version} ${OPTIMIZATION} ${INCLUDES} ${LINKS} -o ${OUTPUT} examples/swizzle.cu

pull:
	git pull
	make all

push:
	git add .
	git commit -m "update"
	git push

run:
	./${OUTPUT}

clean:
	rm -rf bins/*